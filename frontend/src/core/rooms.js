import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from './api'
import { getSocket } from './socket'
import { useAuthStore } from './auth'

export const useRoomsStore = defineStore('rooms', () => {
  const rooms = ref([])
  const loading = ref(false)
  const error = ref('')
  const subscribed = ref(false)

  async function load() {
    loading.value = true
    error.value = ''
    try {
      const res = await api.get('/rooms')
      rooms.value = res.data.rooms
    } catch (e) {
      error.value = e.response?.data?.error || 'Failed to load rooms'
    } finally {
      loading.value = false
    }
  }

  async function subscribe() {
    if (subscribed.value) return
    const auth = useAuthStore()
    if (!auth.authenticated) return

    try {
      const socket = await getSocket()
      socket.on('room.updated', () => load())
      socket.on('room.created', () => load())
      socket.on('room.removed', () => load())
      socket.on('room.deleted', () => load())
      socket.on('chat.recv', (msg) => {
        const r = rooms.value.find((x) => x.id === msg.room_id)
        if (r) {
          r.last_message_at = msg.ts
          r.unread_count = (r.unread_count || 0) + 1
        }
      })
      subscribed.value = true
    } catch (e) {
      error.value = 'Failed to open WebSocket'
    }
  }

  return { rooms, loading, error, load, subscribe }
})
