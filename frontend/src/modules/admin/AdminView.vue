<script setup>
import { ref, onMounted, computed, nextTick } from 'vue'
import api from '../../core/api'
import { useAuthStore } from '../../core/auth'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import EmptyState from '../../components/EmptyState.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const auth = useAuthStore()

const tab = ref('users')

// ---- Users tab ----
const users = ref([])
const total = ref(0)
const offset = ref(0)
const limit = 100
const error = ref('')
const loading = ref(true)

const newUsername = ref('')
const newPassword = ref('')
const newRole = ref('user')
const createMessage = ref('')
const creating = ref(false)

const settings = ref({ registration_enabled: 1 })
const settingsLoading = ref(true)
const settingsError = ref('')
const settingsSaving = ref(false)

const myId = computed(() => {
  const me = users.value.find((u) => u.username === auth.username)
  return me ? me.id : null
})

// ---- Reports tab ----
const reports = ref([])
const reportsTotal = ref(0)
const reportsError = ref('')
const reportsLoading = ref(false)
const selectedReport = ref(null)
const reportDetail = ref(null)
const reportDetailError = ref('')
const reportDetailLoading = ref(false)
const resolutionText = ref('')
const resolving = ref(false)

// ---- viewer state ----
const viewerRoom = ref(null)
const viewerMessages = ref([])
const viewerLoading = ref(false)
const viewerError = ref('')
const viewerBefore = ref(null)
const viewerHasMore = ref(true)

async function loadSettings() {
  settingsLoading.value = true
  settingsError.value = ''
  try {
    const res = await api.get('/admin/settings')
    settings.value = res.data.settings
  } catch (e) {
    settingsError.value = e.response?.data?.error || 'Failed to load settings'
  } finally {
    settingsLoading.value = false
  }
}

async function toggleRegistration() {
  settingsSaving.value = true
  settingsError.value = ''
  try {
    const next = settings.value.registration_enabled ? 0 : 1
    const res = await api.patch('/admin/settings', { registration_enabled: next })
    settings.value = res.data.settings
  } catch (e) {
    settingsError.value = e.response?.data?.error || 'Failed to update settings'
  } finally {
    settingsSaving.value = false
  }
}

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

async function createUser() {
  createMessage.value = ''
  if (!newUsername.value || !newPassword.value) return
  creating.value = true
  try {
    await api.post('/admin/users', {
      username: newUsername.value,
      password: newPassword.value,
      role: newRole.value,
    })
    createMessage.value = `created ${newUsername.value}`
    newUsername.value = ''
    newPassword.value = ''
    newRole.value = 'user'
    await load()
  } catch (e) {
    createMessage.value = e.response?.data?.error || 'Create failed'
  } finally {
    creating.value = false
  }
}

async function removeUser(user) {
  if (!confirm(`Remove ${user.username} from the platform?`)) return
  try {
    await api.delete(`/admin/users/${user.id}`)
    await load()
  } catch (e) {
    alert(e.response?.data?.error || 'Remove failed')
  }
}

async function toggleRole(user) {
  const next = user.role === 'admin' ? 'user' : 'admin'
  const verb = next === 'admin' ? 'promote' : 'demote'
  if (!confirm(`${verb} ${user.username} to ${next}?`)) return
  try {
    await api.patch(`/admin/users/${user.id}`, { role: next })
    await load()
  } catch (e) {
    alert(e.response?.data?.error || 'Role change failed')
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

// ---- reports ----

async function loadReports() {
  reportsLoading.value = true
  reportsError.value = ''
  try {
    const res = await api.get('/admin/reports')
    reports.value = res.data.reports
    reportsTotal.value = res.data.total
  } catch (e) {
    reportsError.value = e.response?.data?.error || 'Failed to load reports'
  } finally {
    reportsLoading.value = false
  }
}

async function openReport(report) {
  selectedReport.value = report
  reportDetailLoading.value = true
  reportDetailError.value = ''
  reportDetail.value = null
  viewerMessages.value = []
  viewerBefore.value = null
  viewerHasMore.value = true
  resolutionText.value = ''
  try {
    const res = await api.get(`/admin/reports/${report.id}`)
    reportDetail.value = res.data
    await loadViewer()
  } catch (e) {
    reportDetailError.value = e.response?.data?.error || 'Failed to load report'
  } finally {
    reportDetailLoading.value = false
  }
}

async function loadViewer() {
  if (!reportDetail.value?.room) return
  viewerLoading.value = true
  viewerError.value = ''
  try {
    const params = {}
    if (viewerBefore.value) params.before = viewerBefore.value
    const res = await api.get(`/admin/rooms/${reportDetail.value.room.public_hash}/view`, { params })
    viewerRoom.value = res.data.room
    const batch = res.data.messages || []
    if (batch.length < 100) viewerHasMore.value = false
    if (batch.length) viewerBefore.value = batch[0].id
    viewerMessages.value = [...batch, ...viewerMessages.value]
  } catch (e) {
    viewerError.value = e.response?.data?.error || 'Failed to load messages'
  } finally {
    viewerLoading.value = false
  }
}

async function resolveReport() {
  if (!reportDetail.value) return
  resolving.value = true
  try {
    await api.post(`/admin/reports/${reportDetail.value.report.id}/resolve`, {
      resolution: resolutionText.value,
    })
    selectedReport.value = null
    reportDetail.value = null
    await loadReports()
  } catch (e) {
    alert(e.response?.data?.error || 'Failed to resolve')
  } finally {
    resolving.value = false
  }
}

function closeReport() {
  selectedReport.value = null
  reportDetail.value = null
  viewerMessages.value = []
}

function formatTs(ts) {
  if (!ts) return ''
  const d = new Date(ts)
  if (isNaN(d.getTime())) return ''
  return d.toLocaleString()
}

async function switchTab(t) {
  tab.value = t
  if (t === 'reports') await loadReports()
  if (t === 'users') await load()
}

onMounted(async () => {
  await loadSettings()
  await load()
})
</script>

<template>
  <div class="font-mono">
    <div class="flex items-center justify-between mb-4">
      <div>
        <h2 class="text-2xl font-bold text-white">
          <span class="text-emerald-400">&gt;</span> admin
        </h2>
        <p class="text-xs text-gray-500 mt-1">
          // {{ tab === 'users' ? `${total} user${total === 1 ? '' : 's'}` : `${reportsTotal} open report${reportsTotal === 1 ? '' : 's'}` }}
        </p>
      </div>
    </div>

    <div class="flex gap-2 mb-6">
      <button
        @click="switchTab('users')"
        :class="[
          'px-3 py-1.5 rounded-md text-xs transition-colors border',
          tab === 'users'
            ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/40'
            : 'bg-gray-900 text-gray-500 border-gray-800 hover:text-gray-300',
        ]"
      >users</button>
      <button
        @click="switchTab('reports')"
        :class="[
          'px-3 py-1.5 rounded-md text-xs transition-colors border',
          tab === 'reports'
            ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/40'
            : 'bg-gray-900 text-gray-500 border-gray-800 hover:text-gray-300',
        ]"
      >reports <span v-if="reportsTotal" class="text-red-400">({{ reportsTotal }})</span></button>
    </div>

    <!-- USERS TAB -->
    <div v-if="tab === 'users'">
      <ErrorBanner v-if="error" :message="error" />

      <section class="mb-6 bg-gray-900 border border-gray-800 rounded-lg p-4">
        <div class="text-xs text-gray-500 mb-3">// platform settings</div>
        <LoadingSpinner v-if="settingsLoading" label="loading settings..." />
        <template v-else>
          <div class="flex items-center justify-between gap-4">
            <div class="min-w-0">
              <div class="text-sm text-white">public registration</div>
              <div class="text-xs text-gray-500">allow new users to register without an invite</div>
            </div>
            <button
              @click="toggleRegistration"
              :disabled="settingsSaving"
              :class="[
                'px-4 py-1.5 rounded-md text-xs font-bold transition-colors border',
                settings.registration_enabled
                  ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/40 hover:bg-emerald-500/20'
                  : 'bg-gray-950 text-gray-500 border-gray-700 hover:text-gray-300',
              ]"
            >
              {{ settingsSaving ? '...' : (settings.registration_enabled ? 'ENABLED' : 'DISABLED') }}
            </button>
          </div>
          <p v-if="settingsError" class="text-xs text-red-400 mt-2">{{ settingsError }}</p>
        </template>
      </section>

      <form @submit.prevent="createUser" class="mb-6 bg-gray-900 border border-gray-800 rounded-lg p-4">
        <div class="text-xs text-gray-500 mb-3">// create user</div>
        <div class="flex flex-col sm:flex-row gap-2">
          <input v-model="newUsername" placeholder="username" autocomplete="off" class="flex-1 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" />
          <input v-model="newPassword" type="password" placeholder="password" autocomplete="new-password" class="flex-1 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" />
          <select v-model="newRole" class="bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-cyan-500">
            <option value="user">user</option>
            <option value="admin">admin</option>
          </select>
          <button type="submit" :disabled="creating" class="bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold px-5 py-2 rounded-md text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500">
            {{ creating ? '...' : '+ create' }}
          </button>
        </div>
        <p v-if="createMessage" class="text-xs text-emerald-400 mt-2">{{ createMessage }}</p>
      </form>

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
              <tr v-for="u in users" :key="u.id" class="border-b border-gray-800/70 last:border-0 hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-gray-600 text-xs">{{ u.id }}</td>
                <td class="px-4 py-2">
                  <span class="text-gray-200">{{ u.username }}</span>
                  <span v-if="u.id === myId" class="text-xs text-gray-600 ml-1">(you)</span>
                </td>
                <td class="px-4 py-2">
                  <span :class="['text-xs px-2 py-0.5 rounded border', roleBadge(u.role)]">{{ u.role }}</span>
                </td>
                <td class="px-4 py-2 text-xs text-gray-600 hidden sm:table-cell">{{ u.created_at }}</td>
                <td class="px-4 py-2 text-right">
                  <template v-if="u.id !== myId">
                    <button @click="toggleRole(u)" class="text-xs text-cyan-400 hover:text-cyan-300 mr-3">{{ u.role === 'admin' ? 'demote' : 'promote' }}</button>
                    <button @click="removeUser(u)" class="text-xs text-red-400 hover:text-red-300">remove</button>
                  </template>
                  <span v-else class="text-xs text-gray-600">—</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <EmptyState v-else title="no users" hint="create one above" />

        <div v-if="total > limit" class="flex justify-between items-center mt-4 text-xs">
          <button @click="prevPage" :disabled="offset === 0" class="px-3 py-1 rounded-md bg-gray-900 border border-gray-800 text-gray-300 hover:border-emerald-500/40 disabled:opacity-30">&lt; prev</button>
          <span class="text-gray-500">{{ offset + 1 }}–{{ Math.min(offset + limit, total) }} / {{ total }}</span>
          <button @click="nextPage" :disabled="offset + limit >= total" class="px-3 py-1 rounded-md bg-gray-900 border border-gray-800 text-gray-300 hover:border-emerald-500/40 disabled:opacity-30">next &gt;</button>
        </div>
      </template>
    </div>

    <!-- REPORTS TAB -->
    <div v-if="tab === 'reports'">
      <ErrorBanner v-if="reportsError" :message="reportsError" />

      <div v-if="!selectedReport">
        <LoadingSpinner v-if="reportsLoading" label="loading reports..." />
        <template v-else>
          <ul v-if="reports.length" class="space-y-2">
            <li v-for="r in reports" :key="r.id">
              <div class="bg-gray-900 border border-gray-800 rounded-lg px-4 py-3 flex items-start gap-3">
                <span class="text-red-400 text-lg leading-none mt-0.5">⚑</span>
                <div class="min-w-0 flex-1">
                  <div class="text-white text-sm">
                    <span class="text-red-400">#{{ r.id }}</span>
                    <span class="ml-2">{{ r.reason }}</span>
                  </div>
                  <div class="text-xs text-gray-500 mt-1">
                    reported by <span class="text-gray-300">{{ r.reporter_username }}</span>
                    · sender <span class="text-gray-300">{{ r.sender_username }}</span>
                    · room <span class="text-cyan-400">{{ r.room_name }}</span>
                    · {{ formatTs(r.created_at) }}
                  </div>
                </div>
                <button @click="openReport(r)" class="text-xs text-emerald-400 hover:text-emerald-300 flex-shrink-0">open →</button>
              </div>
            </li>
          </ul>
          <EmptyState v-else title="no open reports" hint="all clear" />
        </template>
      </div>

      <div v-else>
        <div class="flex items-center gap-2 mb-4 text-sm">
          <button @click="closeReport" class="text-gray-500 hover:text-emerald-400">&lt;</button>
          <span class="text-gray-400">back to reports</span>
        </div>

        <ErrorBanner v-if="reportDetailError" :message="reportDetailError" />
        <LoadingSpinner v-if="reportDetailLoading" label="loading report..." />

        <template v-if="reportDetail">
          <div class="bg-gray-900 border border-red-500/30 rounded-lg p-4 mb-4">
            <div class="text-xs text-gray-500 mb-1">// report #{{ reportDetail.report.id }}</div>
            <div class="text-white text-sm mb-1">{{ reportDetail.report.reason }}</div>
            <div class="text-xs text-gray-500">
              reported by <span class="text-gray-300">{{ reportDetail.report.reporter }}</span>
              · {{ formatTs(reportDetail.report.created_at) }}
            </div>
          </div>

          <div class="bg-gray-900 border border-gray-800 rounded-lg p-4 mb-4">
            <div class="text-xs text-gray-500 mb-2">// reported message</div>
            <div class="text-[10px] text-gray-500 mb-1">
              {{ reportDetail.message?.sender_username }} · {{ formatTs(reportDetail.message?.created_at) }}
              <span v-if="reportDetail.message?.deleted_at" class="text-red-400">· deleted at {{ formatTs(reportDetail.message.deleted_at) }} by {{ reportDetail.message.deleted_by }}</span>
            </div>
            <div class="bg-gray-950 border border-gray-800 rounded-md px-3 py-2 text-sm text-gray-100 whitespace-pre-wrap break-words">
              {{ reportDetail.message?.content_encrypted || '[unavailable]' }}
            </div>
            <p class="text-[10px] text-gray-600 mt-1">raw ciphertext — decrypting requires the message content to be sent decrypted by the viewer endpoint below</p>

            <div v-if="reportDetail.edits?.length" class="mt-3">
              <div class="text-xs text-gray-500 mb-1">// edit history ({{ reportDetail.edits.length }})</div>
              <ul class="space-y-1">
                <li v-for="(ed, i) in reportDetail.edits" :key="i" class="bg-gray-950 border border-gray-800 rounded-md px-3 py-2 text-xs">
                  <div class="text-gray-500">
                    v{{ i + 1 }} · {{ ed.editor }} · {{ formatTs(ed.edited_at) }}
                  </div>
                  <div class="text-gray-200 mt-1 break-words">{{ ed.content_encrypted }}</div>
                </li>
              </ul>
            </div>
          </div>

          <div class="bg-gray-900 border border-gray-800 rounded-lg p-4 mb-4">
            <div class="text-xs text-gray-500 mb-2">// room viewer (read-only)</div>
            <ErrorBanner v-if="viewerError" :message="viewerError" />
            <LoadingSpinner v-if="viewerLoading && !viewerMessages.length" label="loading messages..." />
            <div class="max-h-[60vh] overflow-y-auto bg-gray-950 border border-gray-800 rounded-md p-3 space-y-1">
              <div
                v-for="m in viewerMessages"
                :key="m.id"
                :class="['text-sm flex gap-2', m.deleted_at ? 'opacity-60' : '']"
              >
                <span class="text-gray-500 text-xs flex-shrink-0">{{ m.sender_username }}:</span>
                <span :class="['flex-1 break-words', m.deleted_at ? 'line-through text-gray-500' : 'text-gray-200']">
                  {{ m.text }}
                </span>
                <span v-if="m.deleted_at" class="text-[10px] text-red-400 flex-shrink-0">[deleted]</span>
                <span v-if="m.edit_count" class="text-[10px] text-cyan-400 flex-shrink-0">[edited {{ m.edit_count }}x]</span>
              </div>
              <div v-if="!viewerMessages.length && !viewerLoading" class="text-xs text-gray-600 text-center py-4">no messages</div>
            </div>
            <button
              v-if="viewerHasMore"
              @click="loadViewer"
              :disabled="viewerLoading"
              class="mt-2 text-xs text-emerald-400 hover:text-emerald-300 disabled:text-gray-600"
            >{{ viewerLoading ? 'loading...' : 'load older' }}</button>
          </div>

          <div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
            <div class="text-xs text-gray-500 mb-2">// resolve</div>
            <textarea v-model="resolutionText" rows="3" placeholder="resolution note (optional)" class="w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm font-mono focus:outline-none focus:border-emerald-500 resize-none placeholder-gray-600"></textarea>
            <div class="flex justify-end gap-2 mt-2">
              <button @click="closeReport" class="px-3 py-1.5 rounded-md text-gray-400 hover:text-white text-xs">cancel</button>
              <button @click="resolveReport" :disabled="resolving" class="px-4 py-1.5 rounded-md bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold text-xs transition-colors disabled:bg-gray-700 disabled:text-gray-500">
                {{ resolving ? '...' : '> resolve' }}
              </button>
            </div>
          </div>
        </template>
      </div>
    </div>
  </div>
</template>
