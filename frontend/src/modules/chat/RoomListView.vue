<script setup>
import { ref, onMounted, computed } from 'vue'
import { useRouter } from 'vue-router'
import api from '../../core/api'
import { useAuthStore } from '../../core/auth'
import { useRoomsStore } from '../../core/rooms'
import { generateAesKey } from '../../core/crypto'
import init, { MlKemKeyPair, decrypt_private_key } from '../../pqc/cipherbox_pqc.js'
import { loadIdentity } from '../../core/pqc-db.js'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import EmptyState from '../../components/EmptyState.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const auth = useAuthStore()
const router = useRouter()
const store = useRoomsStore()

const newName = ref('')
const newType = ref('room') // room, private_channel, channel, public_room
const newPassphrase = ref('')
const newEphemeral = ref(false)
const filter = ref('all')
const creating = ref(false)
const error = ref('')

const filteredRooms = computed(() => {
  const list = store.rooms
  if (filter.value === 'all') return list
  if (filter.value === 'room') return list.filter((r) => r.type === 'room' || r.type === 'private')
  if (filter.value === 'channel') return list.filter((r) => r.type === 'channel')
  return list
})

async function deleteRoom(r) {
  if (!confirm(`Delete "${r.name}" permanently? This cannot be undone and will remove it for everyone.`)) return
  
  try {
    await api.delete(`/rooms/${r.public_hash}`)
    await store.load() // Refresh the list instantly
  } catch (e) {
    alert(e.response?.data?.error || 'Failed to delete room')
  }
}

async function create() {
  if (!newName.value) return
  
  // Passphrase is only required for private E2EE rooms/channels
  const isPrivate = newType.value === 'room' || newType.value === 'private_channel'
  
  if (isPrivate && !newPassphrase.value) {
    error.value = 'Please enter your passphrase to encrypt the room key.'
    return
  }

  creating.value = true
  error.value = ''
  
  try {
    await init()
    
    const roomAesKey = await generateAesKey()
    
    let is_invite_only = false
    let owner_ciphertext = null
    let plaintext_room_key = null
    let final_type = newType.value

    // PUBLIC CHANNEL or PUBLIC ROOM
    if (newType.value === 'channel' || newType.value === 'public_room') {
      is_invite_only = false
      plaintext_room_key = roomAesKey
      final_type = (newType.value === 'channel') ? 'channel' : 'room'
    } 
    // PRIVATE ROOM or PRIVATE CHANNEL (E2EE)
    else {
      is_invite_only = true
      final_type = (newType.value === 'private_channel') ? 'channel' : 'room'
      
      const stored = await loadIdentity('pqc_identity')
      if (!stored) throw new Error('No PQC identity found. Generate one first in /identity.')
      
      const dk_bytes = decrypt_private_key(stored.encrypted_kem_dk, newPassphrase.value)
      if (dk_bytes.length === 0) throw new Error('Wrong passphrase.')

      let ek_b64 = ''
      for (let i = 0; i < stored.kem_public_key.byteLength; i++) ek_b64 += String.fromCharCode(stored.kem_public_key[i])
      ek_b64 = btoa(ek_b64)

      const kem = MlKemKeyPair.importKeys(dk_bytes, Uint8Array.from(atob(ek_b64), c => c.charCodeAt(0)))
      
      let ct, ss
      try {
        const res = kem.encapsulate()
        ct = new Uint8Array(res[0])
        ss = new Uint8Array(res[1])
      } finally {
        if (kem && kem.free) kem.free()
      }

      const sharedKey = await crypto.subtle.importKey('raw', ss, { name: 'AES-GCM' }, false, ['encrypt'])
      const iv = crypto.getRandomValues(new Uint8Array(12))
      const encAes = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, sharedKey, new TextEncoder().encode(roomAesKey))

      owner_ciphertext = JSON.stringify({
        ct: btoa(String.fromCharCode(...ct)),
        iv: btoa(String.fromCharCode(...iv)),
        enc_aes: btoa(String.fromCharCode(...new Uint8Array(encAes)))
      })
    }

    const payload = {
      name: newName.value,
      type: final_type,
      is_invite_only: is_invite_only,
      owner_kyber_ciphertext: owner_ciphertext,
      plaintext_room_key: plaintext_room_key,
      is_ephemeral: newEphemeral.value
    }

    const roomRes = await api.post('/rooms', payload)
    newName.value = ''
    newPassphrase.value = ''
    newEphemeral.value = false
    await store.load()
    router.push(`/rooms/${roomRes.data.room.public_hash}`)
    
  } catch (e) {
    error.value = e.response?.data?.error || e.message || 'Failed to create room'
  } finally {
    creating.value = false
  }
}

function typePrefix(type, isInviteOnly) {
  if (type === 'channel') return isInviteOnly ? '§' : '#'
  if (type === 'private') return '@'
  return isInviteOnly ? '!' : '>'
}

function typeColor(type, isInviteOnly) {
  if (type === 'channel') return isInviteOnly ? 'text-yellow-400' : 'text-red-400'
  if (type === 'private') return 'text-emerald-400'
  return isInviteOnly ? 'text-emerald-400' : 'text-cyan-400'
}

function timeAgo(ts) {
  if (!ts) return 'no messages'
  const d = new Date(ts)
  if (isNaN(d.getTime())) return ''
  const diff = Math.floor((Date.now() - d.getTime()) / 1000)
  if (diff < 60) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  if (diff < 604800) return `${Math.floor(diff / 86400)}d ago`
  return d.toLocaleDateString()
}

onMounted(async () => {
  store.subscribe()
  await store.load()
})
</script>

<template>
  <div class="font-mono">
    <div class="flex items-center justify-between mb-6">
      <div>
        <h2 class="text-2xl font-bold text-white">
          <span class="text-emerald-400">&gt;</span> rooms & channels
        </h2>
        <p class="text-xs text-gray-500 mt-1">
          // {{ store.rooms.length }} total
        </p>
      </div>
      <button @click="router.push('/discover')" class="px-3 py-1.5 rounded-md bg-gray-800 hover:bg-gray-700 text-cyan-400 text-xs font-bold transition-colors">
        ~ discover channels
      </button>
    </div>

    <form @submit.prevent="create" class="mb-6 bg-gray-900 border border-gray-800 rounded-lg p-4">
      <div class="text-xs text-gray-500 mb-3">// create new</div>
      
      <div class="flex flex-col gap-3">
        <div class="flex flex-col sm:flex-row gap-2">
          <input
            v-model="newName"
            placeholder="name"
            class="flex-1 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600"
          />
          <select
            v-model="newType"
            class="bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-cyan-500"
          >
            <option value="room">Private Room (E2EE)</option>
            <option value="private_channel">Private Channel (E2EE, Read-only)</option>
            <option value="public_room">Public Room (Chat)</option>
            <option value="channel">Public Channel (Read-only)</option>
          </select>
        </div>

        <!-- Passphrase is required ONLY for Private Room and Private Channel -->
        <div v-if="newType === 'room' || newType === 'private_channel'" class="flex flex-col sm:flex-row gap-2">
          <input
            v-model="newPassphrase"
            type="password"
            placeholder="your passphrase (to encrypt room key)"
            class="flex-1 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600"
          />
        </div>
        
        <!-- No passphrase needed for public options -->
        <div v-else class="flex flex-col sm:flex-row gap-2">
          <div class="flex-1 text-xs text-gray-500 py-2 italic">
            // public room, no passphrase needed
          </div>
        </div>

        <!-- Ephemeral Checkbox -->
        <div class="flex items-center justify-between border-t border-gray-800 pt-3 mt-1">
          <label class="flex items-center gap-2 text-xs text-gray-400 cursor-pointer">
            <input 
              type="checkbox" 
              v-model="newEphemeral" 
              class="rounded bg-gray-950 border-gray-800 text-emerald-500 focus:ring-emerald-500 focus:ring-offset-gray-900"
            >
            <span>Ephemeral Room (self-destructs on last leave)</span>
          </label>
          
          <button
            type="submit"
            :disabled="creating"
            class="bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold px-5 py-2 rounded-md text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500"
          >
            {{ creating ? '...' : '+ create' }}
          </button>
        </div>
      </div>
    </form>

    <ErrorBanner v-if="error" :message="error" />

    <div class="flex flex-wrap gap-2 mb-4">
      <button
        v-for="tab in [
          { key: 'all', label: 'all' },
          { key: 'room', label: 'rooms' },
          { key: 'channel', label: 'channels' },
        ]"
        :key="tab.key"
        @click="filter = tab.key"
        :class="[
          'px-3 py-1 rounded-md text-xs transition-colors border',
          filter === tab.key
            ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/40'
            : 'bg-gray-900 text-gray-500 border-gray-800 hover:text-gray-300 hover:border-gray-700',
        ]"
      >
        {{ tab.label }}
      </button>
    </div>

    <LoadingSpinner v-if="store.loading" label="loading rooms..." />
    <template v-else>
      <ul v-if="filteredRooms.length" class="space-y-2">
        <li v-for="r in filteredRooms" :key="r.id">
          <router-link
            :to="`/rooms/${r.public_hash}`"
            class="block bg-gray-900 border border-gray-800 hover:border-emerald-500/40 rounded-lg px-4 py-3 transition-colors group"
          >
            <div class="flex items-center gap-2 mb-1">
              <span :class="['font-bold text-lg leading-none', typeColor(r.type, r.is_invite_only)]">
                {{ typePrefix(r.type, r.is_invite_only) }}
              </span>
              <span :class="['font-medium truncate', r.unread_count > 0 ? 'text-white' : 'text-gray-200']">
                {{ r.name }}
              </span>
              
              <!-- Ephemeral Badge -->
              <span v-if="r.is_ephemeral" class="text-[10px] text-red-400 border border-red-500/30 bg-red-500/10 px-1.5 py-0.5 rounded">
                ephemeral
              </span>

              <span
                v-if="r.unread_count > 0"
                class="ml-auto inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1.5 rounded-full bg-emerald-500 text-gray-950 text-[10px] font-bold"
              >
                {{ r.unread_count > 99 ? '99+' : r.unread_count }}
              </span>
              
              <!-- Delete Button (Owner Only) -->
              <button 
                v-if="r.my_role === 'owner'" 
                @click.prevent.stop="deleteRoom(r)" 
                class="ml-auto text-[10px] text-red-400 hover:text-red-300 opacity-0 group-hover:opacity-100 transition-opacity border border-red-500/20 px-1.5 py-0.5 rounded"
                title="Delete room permanently"
              >
                delete
              </button>

              <span
                :class="['text-xs text-gray-600 font-mono', (r.unread_count > 0 || r.my_role === 'owner') ? '' : 'ml-auto']"
              >
                [{{ r.my_role }}]
              </span>
            </div>
            <div class="text-xs text-gray-500 flex flex-wrap items-center gap-x-2">
              <span>{{ r.member_count }} member{{ r.member_count === 1 ? '' : 's' }}</span>
              <span v-if="r.last_sender" class="text-gray-600">·</span>
              <span v-if="r.last_sender">
                last: <span class="text-gray-400">{{ r.last_sender }}</span>
              </span>
              <span class="text-gray-600">·</span>
              <span class="text-gray-600">{{ timeAgo(r.last_message_at) }}</span>
            </div>
          </router-link>
        </li>
      </ul>
      <EmptyState
        v-else
        title="no rooms found"
        hint="create one above or discover public channels"
      />
    </template>
  </div>
</template>
