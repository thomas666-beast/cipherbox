<script setup>
import { ref, onMounted, computed } from 'vue'
import api from '../../core/api'
import { useAuthStore } from '../../core/auth'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import EmptyState from '../../components/EmptyState.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const auth = useAuthStore()

const users = ref([])
const total = ref(0)
const offset = ref(0)
const limit = 100
const error = ref('')
const loading = ref(true)

const myId = computed(() => {
  const me = users.value.find((u) => u.username === auth.username)
  return me ? me.id : null
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await api.get('/admin/users', { params: { limit, offset: offset.value } })
    users.value = res.data.users
    total.value = res.data.total
  } catch (e) {
    error.value = e.response?.data?.error || 'Failed to load users'
  } finally {
    loading.value = false
  }
}

async function removeUser(user) {
  if (!confirm(`Revoke access for ${user.username}? This will delete their account.`)) return
  try {
    await api.delete(`/admin/users/${user.id}`)
    await load()
  } catch (e) {
    alert(e.response?.data?.error || 'Remove failed')
  }
}

function nextPage() {
  if (offset.value + limit < total.value) {
    offset.value += limit
    load()
  }
}

function prevPage() {
  if (offset.value > 0) {
    offset.value = Math.max(0, offset.value - limit)
    load()
  }
}

function roleBadge(role) {
  return role === 'admin'
    ? 'bg-red-500/10 text-red-400 border-red-500/30'
    : 'bg-cyan-500/10 text-cyan-400 border-cyan-500/30'
}

onMounted(load)
</script>

<template>
  <div class="font-mono">
    <div class="flex items-center justify-between mb-6">
      <div>
        <h2 class="text-2xl font-bold text-white">
          <span class="text-emerald-400">&gt;</span> admin
        </h2>
        <p class="text-xs text-gray-500 mt-1">
          // {{ total }} user{{ total === 1 ? '' : 's' }} on the platform
        </p>
      </div>
    </div>

    <ErrorBanner v-if="error" :message="error" />

    <LoadingSpinner v-if="loading" label="loading users..." />
    <template v-else>
      <div v-if="users.length" class="bg-gray-900 border border-gray-800 rounded-lg overflow-hidden">
        <table class="w-full text-sm">
          <thead class="bg-gray-950/50 border-b border-gray-800">
            <tr class="text-xs text-gray-500">
              <th class="text-left px-4 py-2 font-normal">id</th>
              <th class="text-left px-4 py-2 font-normal">username</th>
              <th class="text-left px-4 py-2 font-normal">role</th>
              <th class="text-left px-4 py-2 font-normal hidden sm:table-cell">created</th>
              <th class="text-right px-4 py-2 font-normal">actions</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="u in users"
              :key="u.id"
              class="border-b border-gray-800/70 last:border-0 hover:bg-gray-800/30 transition-colors"
            >
              <td class="px-4 py-2 text-gray-600 text-xs">{{ u.id }}</td>
              <td class="px-4 py-2">
                <span class="text-gray-200">{{ u.username }}</span>
                <span v-if="u.id === myId" class="text-xs text-gray-600 ml-1">(you)</span>
              </td>
              <td class="px-4 py-2">
                <span :class="['text-xs px-2 py-0.5 rounded border', roleBadge(u.role)]">
                  {{ u.role }}
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-gray-600 hidden sm:table-cell">{{ u.created_at }}</td>
              <td class="px-4 py-2 text-right">
                <button
                  v-if="u.id !== myId"
                  @click="removeUser(u)"
                  class="text-xs text-red-400 hover:text-red-300"
                >
                  revoke
                </button>
                <span v-else class="text-xs text-gray-600">—</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else title="no users" hint="nobody is here yet" />

      <div v-if="total > limit" class="flex justify-between items-center mt-4 text-xs">
        <button
          @click="prevPage"
          :disabled="offset === 0"
          class="px-3 py-1 rounded-md bg-gray-900 border border-gray-800 text-gray-300 hover:border-emerald-500/40 disabled:opacity-30 disabled:cursor-not-allowed"
        >&lt; prev</button>
        <span class="text-gray-500">
          {{ offset + 1 }}–{{ Math.min(offset + limit, total) }} / {{ total }}
        </span>
        <button
          @click="nextPage"
          :disabled="offset + limit >= total"
          class="px-3 py-1 rounded-md bg-gray-900 border border-gray-800 text-gray-300 hover:border-emerald-500/40 disabled:opacity-30 disabled:cursor-not-allowed"
        >next &gt;</button>
      </div>
    </template>
  </div>
</template>
