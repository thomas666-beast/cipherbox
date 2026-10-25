<script setup>
import { ref, onMounted, computed } from 'vue'
import { useRouter } from 'vue-router'
import api from '../../core/api'
import { useAuthStore } from '../../core/auth'
import { useRoomsStore } from '../../core/rooms'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import EmptyState from '../../components/EmptyState.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const auth = useAuthStore()
const router = useRouter()
const store = useRoomsStore()

const newName = ref('')
const newType = ref('room')
const newInviteOnly = ref(false)
const filter = ref('all')
const creating = ref(false)

const showDm = ref(false)
const dmQuery = ref('')
const dmResults = ref([])
const dmError = ref('')
const dmLoading = ref(false)
const dmCreating = ref(false)

const filteredRooms = computed(() => {
  const list = store.rooms
  if (filter.value === 'all') return list
  return list.filter((r) => r.type === filter.value)
})

async function create() {
  if (!newName.value) return
  creating.value = true
  try {
    const payload = { name: newName.value, type: newType.value }
    if (newInviteOnly.value) payload.is_invite_only = 1
    await api.post('/rooms', payload)
    newName.value = ''
    newInviteOnly.value = false
    await store.load()
  } catch (e) {
    store.error = e.response?.data?.error || 'Failed to create room'
  } finally {
    creating.value = false
  }
}

async function searchUsersForDm() {
  dmError.value = ''
  if (!dmQuery.value.trim()) { dmResults.value = []; return }
  dmLoading.value = true
  try {
    const res = await api.get('/users', { params: { q: dmQuery.value.trim() } })
    dmResults.value = res.data.users.filter((u) => u.username !== auth.username)
  } catch (e) {
    dmError.value = e.response?.data?.error || 'Search failed'
  } finally {
    dmLoading.value = false
  }
}

async function openDm(user) {
  dmError.value = ''
  dmCreating.value = true
  try {
    const res = await api.post('/rooms', {
      name: `dm-${[auth.username, user.username].sort().join('-')}`,
      type: 'private',
      member_id: user.id,
    })
    showDm.value = false
    dmQuery.value = ''
    dmResults.value = []
    router.push(`/rooms/${res.data.room.public_hash}`)
  } catch (e) {
    dmError.value = e.response?.data?.error || 'Failed to open DM'
  } finally {
    dmCreating.value = false
  }
}

function typePrefix(type) {
  if (type === 'channel') return '#'
  if (type === 'private') return '@'
  return '>'
}

function typeColor(type) {
  if (type === 'channel') return 'text-red-400'
  if (type === 'private') return 'text-emerald-400'
  return 'text-cyan-400'
}

function displayName(r) {
  if (r.type !== 'private') return r.name
  const other = r.name.replace(/^dm-/, '').split('-').find((u) => u !== auth.username)
  return other ? `@${other}` : r.name
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
          <span class="text-emerald-400">&gt;</span> rooms
        </h2>
        <p class="text-xs text-gray-500 mt-1">
          // {{ store.rooms.length }} room{{ store.rooms.length === 1 ? '' : 's' }}
        </p>
      </div>
      <button
        @click="showDm = !showDm"
        :class="[
          'px-3 py-1.5 rounded-md text-xs transition-colors border',
          showDm
            ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/40'
            : 'bg-gray-900 text-gray-300 border-gray-800 hover:border-emerald-500/40',
        ]"
      >+ dm</button>
    </div>

    <div v-if="showDm" class="mb-6 bg-gray-900 border border-gray-800 rounded-lg p-4">
      <div class="text-xs text-gray-500 mb-3">// start a private chat</div>
      <input
        v-model="dmQuery"
        @input="searchUsersForDm"
        placeholder="search username"
        autocomplete="off"
        class="w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500/50 placeholder-gray-600"
      />
      <p v-if="dmError" class="text-xs text-red-400 mt-2">{{ dmError }}</p>
      <p v-if="dmLoading" class="text-xs text-gray-500 mt-2">searching...</p>
      <ul v-if="dmResults.length" class="mt-2 space-y-1">
        <li v-for="u in dmResults" :key="u.id" class="flex items-center justify-between text-sm">
          <span class="text-gray-300">@{{ u.username }}</span>
          <button
            @click="openDm(u)"
            :disabled="dmCreating"
            class="text-xs text-emerald-400 hover:text-emerald-300 disabled:text-gray-600"
          >open dm →</button>
        </li>
      </ul>
      <p v-else-if="dmQuery && !dmLoading" class="text-xs text-gray-500 mt-2">no matches</p>
    </div>

    <form @submit.prevent="create" class="mb-6 bg-gray-900 border border-gray-800 rounded-lg p-4">
      <div class="text-xs text-gray-500 mb-3">// create room or channel</div>
      <div class="flex flex-col sm:flex-row gap-2">
        <input
          v-model="newName"
          placeholder="name"
          class="flex-1 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500/50 placeholder-gray-600"
        />
        <select
          v-model="newType"
          class="bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-cyan-500"
        >
          <option value="room">room (all post)</option>
          <option value="channel">channel (owner posts)</option>
        </select>
        <button
          type="submit"
          :disabled="creating"
          class="bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold px-5 py-2 rounded-md text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500"
        >
          {{ creating ? '...' : '+ create' }}
        </button>
      </div>
      <label class="flex items-center gap-2 mt-3 text-xs text-gray-400 select-none cursor-pointer">
        <input type="checkbox" v-model="newInviteOnly" class="accent-emerald-500" />
        invite only (not discoverable)
      </label>
    </form>

    <ErrorBanner v-if="store.error" :message="store.error" />

    <div class="flex flex-wrap gap-2 mb-4">
      <button
        v-for="tab in [
          { key: 'all', label: 'all' },
          { key: 'room', label: 'rooms' },
          { key: 'channel', label: 'channels' },
          { key: 'private', label: 'private' },
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
              <span :class="['font-bold text-lg leading-none', typeColor(r.type)]">
                {{ typePrefix(r.type) }}
              </span>
              <span :class="['font-medium truncate', r.unread_count > 0 ? 'text-white' : 'text-gray-200']">
                {{ displayName(r) }}
              </span>
              <span v-if="r.is_invite_only" class="text-xs text-yellow-500" title="invite only">🔒</span>
              <span
                v-if="r.unread_count > 0"
                class="ml-auto inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1.5 rounded-full bg-emerald-500 text-gray-950 text-[10px] font-bold"
              >
                {{ r.unread_count > 99 ? '99+' : r.unread_count }}
              </span>
              <span
                :class="['text-xs text-gray-600 font-mono', r.unread_count > 0 ? '' : 'ml-auto']"
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
        :hint="filter === 'all' ? 'create one above, get invited, or check /discover' : 'try a different filter'"
      />
    </template>
  </div>
</template>
