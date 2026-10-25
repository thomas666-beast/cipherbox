<script setup>
import { ref, onMounted, watch } from 'vue'
import { useRouter } from 'vue-router'
import api from '../../core/api'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import EmptyState from '../../components/EmptyState.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const router = useRouter()

const PAGE = 100

const rooms = ref([])
const total = ref(0)
const loading = ref(true)
const loadingMore = ref(false)
const error = ref('')
const query = ref('')
const joining = ref(null)
const scrollEl = ref(null)

let debounceTimer = null

async function loadFirst() {
  loading.value = true
  error.value = ''
  try {
    const params = { limit: PAGE, offset: 0 }
    if (query.value.trim()) params.q = query.value.trim()
    const res = await api.get('/rooms/discover', { params })
    rooms.value = res.data.rooms
    total.value = res.data.total
    if (scrollEl.value) scrollEl.value.scrollTop = 0
  } catch (e) {
    error.value = e.response?.data?.error || 'Failed to load rooms'
  } finally {
    loading.value = false
  }
}

async function loadMore() {
  if (loadingMore.value || rooms.value.length >= total.value) return
  loadingMore.value = true
  try {
    const params = { limit: PAGE, offset: rooms.value.length }
    if (query.value.trim()) params.q = query.value.trim()
    const res = await api.get('/rooms/discover', { params })
    rooms.value = [...rooms.value, ...res.data.rooms]
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

function typePrefix(type) {
  if (type === 'channel') return '#'
  return '>'
}

function typeColor(type) {
  if (type === 'channel') return 'text-red-400'
  return 'text-cyan-400'
}

function typeLabel(type) {
  if (type === 'channel') return 'channel'
  return 'room'
}

function timeAgo(ts) {
  if (!ts) return ''
  const d = new Date(ts)
  if (isNaN(d.getTime())) return ''
  const diff = Math.floor((Date.now() - d.getTime()) / 1000)
  if (diff < 60) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  if (diff < 604800) return `${Math.floor(diff / 86400)}d ago`
  return d.toLocaleDateString()
}

async function join(room) {
  joining.value = room.public_hash
  try {
    await api.post(`/rooms/${room.public_hash}/join`)
    // Remove from discover list — we're now a member
    rooms.value = rooms.value.filter(r => r.public_hash !== room.public_hash)
    total.value = Math.max(0, total.value - 1)
    router.push(`/rooms/${room.public_hash}`)
  } catch (e) {
    alert(e.response?.data?.error || 'Failed to join')
  } finally {
    joining.value = null
  }
}

onMounted(loadFirst)
</script>

<template>
  <div class="font-mono">
    <div class="flex items-center justify-between mb-6">
      <div>
        <h2 class="text-2xl font-bold text-white">
          <span class="text-emerald-400">~</span> discover
        </h2>
        <p class="text-xs text-gray-500 mt-1">
          // {{ query ? `${total} match${total === 1 ? '' : 'es'}` : `${total} public room${total === 1 ? '' : 's'}` }}
        </p>
      </div>
    </div>

    <input
      v-model="query"
      placeholder="search rooms by name"
      autocomplete="off"
      class="w-full mb-4 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500/50 placeholder-gray-600"
    />

    <ErrorBanner v-if="error" :message="error" />

    <LoadingSpinner v-if="loading" label="loading discoverable rooms..." />

    <div
      v-else-if="!error"
      ref="scrollEl"
      @scroll="onScroll"
      class="space-y-2"
    >
      <ul v-if="rooms.length" class="space-y-2">
        <li v-for="r in rooms" :key="r.id">
          <div class="bg-gray-900 border border-gray-800 hover:border-emerald-500/40 rounded-lg px-4 py-3 transition-colors flex items-center gap-3">
            <span :class="['font-bold text-2xl leading-none flex-shrink-0', typeColor(r.type)]">
              {{ typePrefix(r.type) }}
            </span>
            <div class="min-w-0 flex-1">
              <div class="text-white font-medium truncate">{{ r.name }}</div>
              <div class="text-xs text-gray-500 flex flex-wrap items-center gap-x-2 mt-0.5">
                <span class="text-gray-400">[{{ typeLabel(r.type) }}]</span>
                <span class="text-gray-600">·</span>
                <span>{{ r.member_count }} member{{ r.member_count === 1 ? '' : 's' }}</span>
                <span class="text-gray-600">·</span>
                <span>created {{ timeAgo(r.created_at) }}</span>
              </div>
            </div>
            <button
              @click="join(r)"
              :disabled="joining === r.public_hash"
              class="px-3 py-1.5 rounded-md bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold text-xs transition-colors disabled:bg-gray-700 disabled:text-gray-500 flex-shrink-0"
            >
              {{ joining === r.public_hash ? '...' : '> join' }}
            </button>
          </div>
        </li>
        <li v-if="loadingMore" class="text-center text-xs text-gray-500 py-2">loading more...</li>
        <li v-else-if="rooms.length >= total" class="text-center text-xs text-gray-600 py-2">// end of results</li>
      </ul>
      <EmptyState
        v-else
        title="no rooms to discover"
        :hint="query ? 'try a different search' : 'nothing public right now'"
      />
    </div>
  </div>
</template>
