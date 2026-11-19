import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from './api'
import { getSocket } from './socket'
import { useAuthStore } from './auth'

export const useRoomsStore = defineStore('rooms', () => {
  const rooms = ref([])
  const loading = ref(false)
  const error = ref('')
  const nextCursor = ref(null)
  const loadingMore = ref(false)
  let type = 'all'
  let request = 0
  let subscription
  let connectedSocket
  let active = false
  let refreshTimer

  async function load(filter = type) {
    const version = ++request
    if (filter !== type) rooms.value = []
    type = filter
    nextCursor.value = null
    loadingMore.value = false

    loading.value = true
    error.value = ''
    try {
      const res = await api.get('/rooms', { params: { type, limit: 30 } })
      if (version === request) {
        rooms.value = res.data.rooms
        nextCursor.value = res.data.next_cursor
      }
    } catch (e) {
      if (version === request) error.value = e.response?.data?.error || 'Failed to load rooms'
    } finally {
      if (version === request) loading.value = false
    }
  }

  async function loadMore() {
    if (loading.value || loadingMore.value || !nextCursor.value) return
    const version = request
    loadingMore.value = true
    error.value = ''
    try {
      const { data } = await api.get('/rooms', {
        params: { type, limit: 30, cursor: nextCursor.value },
      })
      if (version !== request) return
      const seen = new Set(rooms.value.map(room => room.id))
      rooms.value.push(...data.rooms.filter(room => !seen.has(room.id)))
      nextCursor.value = data.next_cursor
    } catch (e) {
      if (version === request) error.value = e.response?.data?.error || 'Failed to load more rooms'
    } finally {
      if (version === request) loadingMore.value = false
    }
  }

  function setActive(value) {
    active = value
    if (!value) clearTimeout(refreshTimer)
  }

  function subscribe() {
    if (subscription || (connectedSocket && !connectedSocket.closedByUser) || !useAuthStore().authenticated) return
    subscription = connect()
      .catch(() => { error.value = 'Failed to open WebSocket' })
      .finally(() => { subscription = undefined })
  }

  async function connect() {
    const socket = await getSocket()
    connectedSocket = socket
    const refresh = () => {
      if (!active) return
      clearTimeout(refreshTimer)
      refreshTimer = setTimeout(() => load(), 150)
    }
    for (const event of ['room.updated', 'room.created', 'room.removed', 'room.deleted']) {
      socket.on(event, refresh)
    }
    socket.on('chat.recv', (msg) => {
      if (!active) return
      const r = rooms.value.find((x) => x.id === msg.room_id)
      if (r) {
        r.last_message_at = msg.ts
        r.unread_count = (r.unread_count || 0) + 1
      }
    })
  }

  return { rooms, loading, error, nextCursor, loadingMore, load, loadMore, subscribe, setActive }
})
