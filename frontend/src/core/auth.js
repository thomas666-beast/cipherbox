import { defineStore } from 'pinia'
import api from './api'
import { closeSocket } from './socket'

export const useAuthStore = defineStore('auth', {
  state: () => ({
    token: null,
    username: null,
    role: null,
    ready: false,
    authenticated: false,
  }),
  getters: {
    isAdmin: (state) => state.role === 'admin',
  },
  actions: {
    async login(username, password) {
      await api.post('/auth/login', { username, password })
      await this.fetchMe()
      this.ready = true
    },
    async register(username, password) {
      await api.post('/auth/register', { username, password })
    },
    async fetchMe() {
      try {
        const res = await api.get('/me')
        this.username = res.data.username
        this.role = res.data.role
        this.authenticated = true
        return res.data
      } catch (e) {
        this.username = null
        this.role = null
        this.authenticated = false
        return null
      } finally {
        this.ready = true
      }
    },
    async logout() {
      try { await api.post('/auth/logout') } catch (e) {}
      closeSocket()
      this.token = null
      this.username = null
      this.role = null
      this.authenticated = false
    },
  },
})
