<script setup>
import { ref, onMounted, onBeforeUnmount, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import api from '../../core/api'
import { useAuthStore } from '../../core/auth'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import EmptyState from '../../components/EmptyState.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const roomHash = route.params.hash

const PAGE = 100

const members = ref([])
const total = ref(0)
const loading = ref(true)
const loadingMore = ref(false)
const error = ref('')
const query = ref('')
const room = ref(null)
const myId = ref(null)
const isOwner = ref(false)
const ownerId = ref(null)

const scrollEl = ref(null)

let debounceTimer = null

async function loadMe() {
  const res = await api.get('/me')
  myId.value = res.data.id
}

async function loadRoom() {
  const res = await api.get(`/rooms/${roomHash}`)
  room.value = res.data.room
  ownerId.value = res.data.room.owner_id
  isOwner.value = res.data.room.owner_id === myId.value
}

async function loadFirst() {
  loading.value = true
  error.value = ''
  try {
    const params = { limit: PAGE, offset: 0 }
    if (query.value.trim()) params.q = query.value.trim()
    const res = await api.get(`/rooms/${roomHash}/members`, { params })
    members.value = res.data.members
    total.value = res.data.total
    if (scrollEl.value) scrollEl.value.scrollTop = 0
  } catch (e) {
    error.value = e.response?.data?.error || 'Failed to load members'
  } finally {
    loading.value = false
  }
}

async function loadMore() {
  if (loadingMore.value || members.value.length >= total.value) return
  loadingMore.value = true
  try {
    const params = { limit: PAGE, offset: members.value.length }
    if (query.value.trim()) params.q = query.value.trim()
    const res = await api.get(`/rooms/${roomHash}/members`, { params })
    members.value = [...members.value, ...res.data.members]
  } catch (e) {
    error.value = e.response?.data?.error || 'Failed to load more'
  } finally {
    loadingMore.value = false
  }
}

function onScroll(e) {
  const el = e.target
  if (el.scrollTop + el.clientHeight >= el.scrollHeight - 100) {
    loadMore()
  }
}

watch(query, () => {
  clearTimeout(debounceTimer)
  debounceTimer = setTimeout(loadFirst, 300)
})

async function removeMember(m) {
  if (!confirm(`Remove and BAN ${m.username}? They cannot rejoin unless you unban them.`)) return
  try {
    await api.post(`/rooms/${roomHash}/remove`, { user_id: m.user_id })
    await loadFirst()
  } catch (e) {
    alert(e.response?.data?.error || 'Remove failed')
  }
}

function formatTs(ts) {
  if (!ts) return ''
  const d = new Date(ts)
  if (isNaN(d.getTime())) return ''
  return d.toLocaleDateString([], { year: 'numeric', month: 'short', day: 'numeric' })
}

onMounted(async () => {
  try {
    await loadMe()
    await loadRoom()
    await loadFirst()
  } catch (e) {
    error.value = e.response?.data?.error || 'Failed to load'
    loading.value = false
  }
})

onBeforeUnmount(() => {
  clearTimeout(debounceTimer)
})
</script>

<template>
  <div class="font-mono">
    <div class="flex items-center gap-2 mb-4">
      <button @click="router.push(`/rooms/${roomHash}`)" class="text-gray-500 hover:text-emerald-400">&lt;</button>
      <span class="text-gray-400">back to</span>
      <span class="text-white font-medium">{{ room ? room.name : 'room' }}</span>
    </div>

    <div class="flex items-center justify-between mb-4">
      <div>
        <h2 class="text-2xl font-bold text-white">
          <span class="text-emerald-400">&gt;</span> members
        </h2>
        <p class="text-xs text-gray-500 mt-1">
          // {{ query ? `${total} match${total === 1 ? '' : 'es'}` : `${total} member${total === 1 ? '' : 's'}` }}
        </p>
      </div>
    </div>

    <ErrorBanner v-if="error" :message="error" />

    <input
      v-model="query"
      placeholder="filter by username"
      autocomplete="off"
      class="w-full mb-4 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500/50 placeholder-gray-600"
    />

    <LoadingSpinner v-if="loading" label="loading members..." />

    <div
      v-else-if="!error"
      ref="scrollEl"
      @scroll="onScroll"
      class="bg-gray-900 border border-gray-800 rounded-lg max-h-[calc(100dvh-16rem)] overflow-y-auto"
    >
      <ul v-if="members.length">
        <li
          v-for="m in members"
          :key="m.user_id"
          class="flex items-center gap-3 px-4 py-2.5 border-b border-gray-800 last:border-0 hover:bg-gray-800/40 transition-colors"
        >
          <span class="w-7 h-7 rounded-full bg-gray-800 flex items-center justify-center text-[10px] text-emerald-400 font-bold flex-shrink-0">
            {{ m.username.slice(0, 2).toUpperCase() }}
          </span>
          <div class="min-w-0 flex-1">
            <div class="text-gray-200 truncate">
              {{ m.username }}
              <span v-if="m.user_id === myId" class="text-xs text-gray-600">(you)</span>
            </div>
            <div class="text-[10px] text-gray-600">joined {{ formatTs(m.joined_at) }}</div>
          </div>
          <span :class="[
            'text-xs px-2 py-0.5 rounded border',
            m.role === 'owner' ? 'bg-red-500/10 text-red-400 border-red-500/30'
              : m.role === 'admin' ? 'bg-yellow-500/10 text-yellow-400 border-yellow-500/30'
              : 'bg-cyan-500/10 text-cyan-400 border-cyan-500/30',
          ]">{{ m.role }}</span>
          <button
            v-if="isOwner && m.role !== 'owner'"
            @click="removeMember(m)"
            class="text-xs text-red-400 hover:text-red-300 flex-shrink-0"
          >remove + ban</button>
        </li>
        <li v-if="loadingMore" class="px-4 py-2 text-center text-xs text-gray-500">loading more...</li>
        <li v-else-if="members.length >= total" class="px-4 py-2 text-center text-xs text-gray-600">// end of list</li>
      </ul>
      <p v-else class="px-4 py-6 text-center text-xs text-gray-600">no matches</p>
    </div>
  </div>
</template>
