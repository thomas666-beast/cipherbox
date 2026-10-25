<script setup>
import { ref, onMounted, onBeforeUnmount, nextTick, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../../core/auth'
import api from '../../core/api'
import { getSocket } from '../../core/socket'
import { encryptMessage, decryptMessage } from '../../core/crypto'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const roomHash = route.params.hash

const messages = ref([])
const input = ref('')
const error = ref('')
const logEl = ref(null)
const room = ref(null)
const members = ref([])
const loadingOlder = ref(false)
const hasMore = ref(true)
const initialLoading = ref(true)
const sending = ref(false)
const typingUsers = ref({})
const needsJoin = ref(false)
const joining = ref(false)
const showMembers = ref(false)
const showInvite = ref(false)
const showBans = ref(false)
const showSearch = ref(false)

const searchQuery = ref('')
const searchResults = ref([])
const searchError = ref('')
const searching = ref(false)
const searchDone = ref(false)

const inviteQuery = ref('')
const inviteResults = ref([])
const inviteError = ref('')
const inviteMessage = ref('')

const banQuery = ref('')
const banResults = ref([])
const banError = ref('')
const banLoading = ref(false)

const bannedUsers = ref([])

const membersFilter = ref('')
const filteredMembers = computed(() => {
  const q = membersFilter.value.trim().toLowerCase()
  if (!q) return members.value
  return members.value.filter(m => m.username.toLowerCase().includes(q))
})

const editingId = ref(null)
const editingText = ref('')

// Paste state
const pastesByHash = ref({})
const showPasteModal = ref(false)
const pasteMode = ref('text')
const pasteTitle = ref('')
const pasteText = ref('')
const pasteFile = ref(null)
const pasteSubmitting = ref(false)
const pasteError = ref('')
const pasteProgress = ref(0)

const showOpenPasteModal = ref(false)
const openPasteContent = ref('')
const openPasteTitle = ref('')
const openPasteKind = ref('text')
const openPasteHash = ref(null)
const openPasteFileName = ref('')
const openPastePeek = ref(false)

const downloading = ref(null)
const downloadProgress = ref(0)

// Report state
const reportedIds = ref({})
const showReportModal = ref(false)
const reportMessage = ref(null)
const reportReason = ref('')
const reportSubmitting = ref(false)
const reportError = ref('')

let socket = null
let roomKey = null
let lastTypingSent = 0
let typingCleanupTimer = null
let unsubs = []
let highlightTimer = null
let isComponentMounted = false
const isConnected = ref(false)
const isSocketConnected = ref(true)

const myId = ref(null)

const canManage = computed(() => {
  const r = room.value
  return r && (r.my_role === 'owner' || r.my_role === 'admin')
})
const isOwner = computed(() => room.value && room.value.owner_id === myId.value)
const isReadOnly = computed(() => {
  const r = room.value
  if (!r) return false
  if (r.type !== 'channel') return false
  return r.my_role !== 'owner' && r.my_role !== 'admin'
})

const typingLabel = computed(() => {
  const ids = Object.keys(typingUsers.value).filter(id => Number(id) !== myId.value)
  if (ids.length === 0) return ''
  const names = ids.map(id => nameOf(Number(id)))
  if (names.length === 1) return `${names[0]} is typing...`
  if (names.length === 2) return `${names[0]} and ${names[1]} are typing...`
  return `${names.length} people are typing...`
})

function nameOf(id) {
  const m = members.value.find(x => x.user_id === id)
  return m ? m.username : `user#${id}`
}

function initials(id) {
  const n = nameOf(id)
  return n.slice(0, 2).toUpperCase()
}

function formatTs(ts) {
  if (!ts) return ''
  const d = new Date(ts)
  if (isNaN(d.getTime())) return ''
  const today = new Date()
  const sameDay = d.toDateString() === today.toDateString()
  if (sameDay) return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) +
    ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

function scrollToBottom() {
  nextTick(() => {
    const el = logEl.value
    if (el) el.scrollTop = el.scrollHeight
  })
}

async function loadMe() {
  const res = await api.get('/me')
  myId.value = res.data.id
}

async function loadRoom() {
  const meta = await api.get(`/rooms/${roomHash}`)
  room.value = meta.data.room
  if (meta.data.room.banned) {
    error.value = 'You are banned from this room.'
    return false
  }
  if (!meta.data.room.is_member) {
    if (meta.data.room.joinable) {
      needsJoin.value = true
      return false
    }
    error.value = 'You are not a member of this room.'
    return false
  }
  return true
}

async function loadKey() {
  const res = await api.get(`/rooms/${roomHash}/key`)
  roomKey = res.data.room_key
}

async function loadMembers() {
  const res = await api.get(`/rooms/${roomHash}/members`)
  members.value = res.data.members
}

async function loadBans() {
  try {
    const res = await api.get(`/rooms/${roomHash}/bans`)
    bannedUsers.value = res.data.bans
  } catch (e) {}
}

async function decryptOne(m) {
  if (m.deleted_at) {
    return { text: null, deleted: true }
  }
  try {
    const text = await decryptMessage(roomKey, m.ct, m.iv, m.tag)
    let payload
    try { payload = JSON.parse(text) } catch (e) { payload = null }
    if (payload && payload._type === 'paste') {
      return { isPaste: true, paste: payload }
    }
    return { text }
  } catch (e) {
    return { text: '[decrypt failed]' }
  }
}

async function loadInitialHistory() {
  const res = await api.get(`/rooms/${roomHash}/messages`)
  const out = []
  for (const m of res.data.messages) {
    const d = await decryptOne(m)
    if (d.isPaste) {
      out.push({ id: m.id, sender_id: m.sender_id, isPaste: true, paste: d.paste, ts: m.ts, edit_count: m.edit_count, deleted_at: m.deleted_at })
    } else {
      out.push({ id: m.id, sender_id: m.sender_id, text: d.text, ts: m.ts, edit_count: m.edit_count, deleted_at: m.deleted_at })
    }
  }
  messages.value = out
  hasMore.value = out.length >= 100

  for (const m of out) {
    if (m.isPaste) {
      try {
        const res = await api.get(`/pastes/${m.paste.paste_hash}`)
        const p = res.data.paste
        pastesByHash.value[m.paste.paste_hash] = {
          title: p.title,
          kind: p.kind,
          file_name: p.file_name,
          opened_username: p.opened_username,
          deleted_at: p.deleted_at,
          is_sender: p.is_sender,
          can_open: p.can_open,
          can_done: p.can_done,
          can_download: p.can_download,
        }
      } catch (e) {
        pastesByHash.value[m.paste.paste_hash] = {
          title: m.paste.title,
          kind: m.paste.kind,
          opened_username: null,
          deleted_at: null,
          is_sender: false,
          can_open: true,
          can_done: false,
          can_download: false,
        }
      }
    }
  }
}

async function loadOlder() {
  if (loadingOlder.value || !hasMore.value || !messages.value.length) return
  loadingOlder.value = true
  try {
    const oldestId = messages.value[0].id
    const res = await api.get(`/rooms/${roomHash}/messages`, { params: { before: oldestId } })
    const older = []
    for (const m of res.data.messages) {
      const d = await decryptOne(m)
      if (d.isPaste) {
        older.push({ id: m.id, sender_id: m.sender_id, isPaste: true, paste: d.paste, ts: m.ts, edit_count: m.edit_count, deleted_at: m.deleted_at })
      } else {
        older.push({ id: m.id, sender_id: m.sender_id, text: d.text, ts: m.ts, edit_count: m.edit_count, deleted_at: m.deleted_at })
      }
    }
    if (older.length < 100) hasMore.value = false
    const el = logEl.value
    const prevHeight = el ? el.scrollHeight : 0
    messages.value = [...older, ...messages.value]
    await nextTick()
    if (el) el.scrollTop = el.scrollHeight - prevHeight
  } catch (e) {
    error.value = e.response?.data?.error || 'Failed to load older messages'
  } finally {
    loadingOlder.value = false
  }
}

function onScroll() {
  if (!logEl.value) return
  if (logEl.value.scrollTop < 60) loadOlder()
}

async function markRead() {
  try { await api.post(`/rooms/${roomHash}/read`) } catch (e) {}
}

function cleanupTyping() {
  const now = Date.now()
  const next = {}
  for (const [id, ts] of Object.entries(typingUsers.value)) {
    if (now - ts < 4000) next[id] = ts
  }
  typingUsers.value = next
}

async function connect() {
  if (isConnected.value) return
  isConnected.value = true

  socket = await getSocket()
  if (!isComponentMounted) {
    isConnected.value = false
    return
  }

  unsubs.push(socket.on('open', () => {
    isSocketConnected.value = true
    socket.joinRoom(room.value.id)
  }))

  unsubs.push(socket.on('close', () => {
    isSocketConnected.value = false
  }))

  unsubs.push(socket.on('chat.recv', async (msg) => {
    if (msg.room_id !== room.value.id) return
    // GUARD: prevent duplicates
    if (messages.value.some(m => m.id === msg.message_id)) return

    const text = await decryptMessage(roomKey, msg.ct, msg.iv, msg.tag).catch(() => null)
    let payload = null
    try { payload = text ? JSON.parse(text) : null } catch (e) {}
    if (payload && payload._type === 'paste') {
      if (!pastesByHash.value[payload.paste_hash]) {
        try {
          const res = await api.get(`/pastes/${payload.paste_hash}`)
          const p = res.data.paste
          pastesByHash.value[payload.paste_hash] = {
            title: p.title,
            kind: p.kind,
            file_name: p.file_name,
            opened_username: p.opened_username,
            deleted_at: p.deleted_at,
            is_sender: p.is_sender,
            can_open: p.can_open,
            can_done: p.can_done,
            can_download: p.can_download,
          }
        } catch (e) {
          pastesByHash.value[payload.paste_hash] = {
            title: payload.title,
            kind: payload.kind,
            opened_username: null,
            deleted_at: null,
            is_sender: false,
            can_open: true,
            can_done: false,
            can_download: false,
          }
        }
      }
      messages.value.push({ id: msg.message_id, sender_id: msg.sender_id, isPaste: true, paste: payload, ts: msg.ts, edit_count: 0, deleted_at: null })
    } else {
      messages.value.push({ id: msg.message_id, sender_id: msg.sender_id, text: text || '[decrypt failed]', ts: msg.ts, edit_count: 0, deleted_at: null })
    }
    delete typingUsers.value[msg.sender_id]
    await nextTick()
    if (logEl.value) logEl.value.scrollTop = logEl.value.scrollHeight
    markRead()
  }))

  unsubs.push(socket.on('chat.deleted', (msg) => {
    if (msg.room_id !== room.value.id) return
    const idx = messages.value.findIndex((m) => m.id === msg.message_id)
    if (idx !== -1) {
      messages.value[idx].deleted_at = new Date().toISOString()
    }
  }))

  unsubs.push(socket.on('chat.edited', async (msg) => {
    if (msg.room_id !== room.value.id) return
    const text = await decryptMessage(roomKey, msg.ct, msg.iv, msg.tag).catch(() => '[decrypt failed]')
    const idx = messages.value.findIndex((m) => m.id === msg.message_id)
    if (idx !== -1 && !messages.value[idx].isPaste) {
      messages.value[idx].text = text
      messages.value[idx].edit_count = (messages.value[idx].edit_count || 0) + 1
    }
    const sidx = searchResults.value.findIndex((m) => m.id === msg.message_id)
    if (sidx !== -1 && !searchResults.value[sidx].isPaste) searchResults.value[sidx].text = text
  }))

  unsubs.push(socket.on('chat.typing', (msg) => {
    if (msg.room_id !== room.value.id) return
    if (msg.sender_id === myId.value) return
    typingUsers.value = { ...typingUsers.value, [msg.sender_id]: Date.now() }
  }))

  unsubs.push(socket.on('paste.opened', (msg) => {
    if (msg.room_id !== room.value.id) return
    const p = pastesByHash.value[msg.paste_hash]
    if (p) {
      pastesByHash.value[msg.paste_hash] = {
        ...p,
        opened_username: msg.opened_by,
        can_open: false,
      }
    }
  }))

  unsubs.push(socket.on('paste.deleted', (msg) => {
    if (msg.room_id !== room.value.id) return
    const p = pastesByHash.value[msg.paste_hash]
    if (p) {
      pastesByHash.value[msg.paste_hash] = {
        ...p,
        deleted_at: new Date().toISOString(),
        can_open: false,
        can_done: false,
        can_download: false,
      }
    }
  }))

  unsubs.push(socket.on('error', (msg) => {
    if (msg.reason) error.value = msg.reason
  }))

  socket.joinRoom(room.value.id)
}

function onInput() {
  if (!socket || isReadOnly.value) return
  const now = Date.now()
  if (now - lastTypingSent < 2000) return
  lastTypingSent = now
  socket.send({ type: 'chat.typing', room_id: room.value.id })
}

async function send() {
  if (!input.value.trim() || sending.value) return
  sending.value = true
  try {
    const enc = await encryptMessage(roomKey, input.value)
    socket.send({
      type: 'chat.send', room_id: room.value.id,
      ct: enc.ct, iv: enc.iv, tag: enc.tag,
    })
    input.value = ''
    await nextTick()
    if (logEl.value) logEl.value.scrollTop = logEl.value.scrollHeight
  } finally {
    sending.value = false
  }
}

// --- Paste creation ---
function openPasteModal() {
  showPasteModal.value = true
  pasteMode.value = 'text'
  pasteTitle.value = ''
  pasteText.value = ''
  pasteFile.value = null
  pasteError.value = ''
  pasteProgress.value = 0
}

function closePasteModal() {
  showPasteModal.value = false
}

function onPasteFile(e) {
  pasteFile.value = e.target.files[0] || null
}

async function submitPaste() {
  pasteError.value = ''
  if (!pasteTitle.value.trim()) {
    pasteError.value = 'title is required'
    return
  }
  pasteSubmitting.value = true
  pasteProgress.value = 0
  try {
    const form = new FormData()
    form.append('title', pasteTitle.value.trim())
    if (pasteMode.value === 'text') {
      if (!pasteText.value) {
        pasteError.value = 'text is empty'
        pasteSubmitting.value = false
        return
      }
      form.append('text', pasteText.value)
    } else {
      if (!pasteFile.value) {
        pasteError.value = 'no file selected'
        pasteSubmitting.value = false
        return
      }
      form.append('file', pasteFile.value)
    }
    const res = await api.post(`/rooms/${roomHash}/pastes`, form, {
      onUploadProgress: (e) => {
        if (e.total) pasteProgress.value = Math.floor((e.loaded / e.total) * 100)
      },
    })
    const p = res.data.paste
    pastesByHash.value[p.public_hash] = {
      title: p.title,
      kind: p.kind,
      file_name: p.file_name,
      opened_username: null,
      deleted_at: null,
      is_sender: true,
      can_open: true,
      can_done: false,
      can_download: p.kind === 'file',
    }
    showPasteModal.value = false
    pasteTitle.value = ''
    pasteText.value = ''
    pasteFile.value = null
    pasteProgress.value = 0
  } catch (e) {
    pasteError.value = e.response?.data?.error || 'failed to create paste'
  } finally {
    pasteSubmitting.value = false
  }
}

// --- Paste actions ---
async function openPaste(paste) {
  try {
    const res = await api.post(`/pastes/${paste.paste_hash}/open`)
    const p = res.data.paste

    if (p.peek) {
      openPastePeek.value = true
      if (p.kind === 'text' && p.content != null) {
        openPasteContent.value = p.content
        openPasteTitle.value = p.title
        openPasteKind.value = 'text'
        openPasteHash.value = paste.paste_hash
        showOpenPasteModal.value = true
      } else if (p.kind === 'file') {
        openPasteTitle.value = p.title
        openPasteKind.value = 'file'
        openPasteHash.value = paste.paste_hash
        openPasteFileName.value = p.file_name || p.title
        openPasteContent.value = ''
        showOpenPasteModal.value = true
      }
      return
    }

    openPastePeek.value = false
    pastesByHash.value[paste.paste_hash] = {
      ...pastesByHash.value[paste.paste_hash],
      opened_username: p.opened_username || auth.username,
      can_open: false,
      can_done: true,
      can_download: p.kind === 'file',
    }
    if (p.kind === 'text' && p.content != null) {
      openPasteContent.value = p.content
      openPasteTitle.value = p.title
      openPasteKind.value = 'text'
      openPasteHash.value = paste.paste_hash
      showOpenPasteModal.value = true
    } else if (p.kind === 'file') {
      openPasteTitle.value = p.title
      openPasteKind.value = 'file'
      openPasteHash.value = paste.paste_hash
      openPasteFileName.value = p.file_name || p.title
      openPasteContent.value = ''
      showOpenPasteModal.value = true
    }
  } catch (e) {
    alert(e.response?.data?.error || 'failed to open paste')
  }
}

function closeOpenPasteModal() {
  showOpenPasteModal.value = false
  openPasteContent.value = ''
  openPasteHash.value = null
  openPastePeek.value = false
}

async function copyOpenPaste() {
  try { await navigator.clipboard.writeText(openPasteContent.value) } catch (e) {}
}

async function downloadPaste(paste) {
  downloading.value = paste.paste_hash
  downloadProgress.value = 0
  try {
    const res = await api.get(`/pastes/${paste.paste_hash}/download`, {
      responseType: 'blob',
      onDownloadProgress: (e) => {
        if (e.total) downloadProgress.value = Math.floor((e.loaded / e.total) * 100)
      },
    })
    const url = window.URL.createObjectURL(res.data)
    const a = document.createElement('a')
    a.href = url
    a.download = paste.file_name || paste.title
    a.click()
    window.URL.revokeObjectURL(url)
  } catch (e) {
    alert(e.response?.data?.error || 'failed to download')
  } finally {
    downloading.value = null
    downloadProgress.value = 0
  }
}

async function donePaste(paste) {
  if (!confirm('This will permanently delete the paste. Continue?')) return
  try {
    await api.post(`/pastes/${paste.paste_hash}/done`)
    pastesByHash.value[paste.paste_hash] = {
      ...pastesByHash.value[paste.paste_hash],
      deleted_at: new Date().toISOString(),
      can_open: false,
      can_done: false,
      can_download: false,
    }
  } catch (e) {
    alert(e.response?.data?.error || 'failed')
  }
}

// --- Report ---
function openReportModal(m) {
  if (m.isPaste || m.deleted_at) return
  reportMessage.value = m
  reportReason.value = ''
  reportError.value = ''
  showReportModal.value = true
}

function closeReportModal() {
  showReportModal.value = false
  reportMessage.value = null
  reportReason.value = ''
  reportError.value = ''
}

async function submitReport() {
  if (!reportMessage.value) return
  reportSubmitting.value = true
  reportError.value = ''
  try {
    await api.post(`/messages/${reportMessage.value.id}/report`, {
      reason: reportReason.value || 'reported',
    })
    reportedIds.value[reportMessage.value.id] = true
    closeReportModal()
  } catch (e) {
    if (e.response?.status === 409) {
      reportedIds.value[reportMessage.value.id] = true
      closeReportModal()
    } else {
      reportError.value = e.response?.data?.error || 'failed to report'
    }
  } finally {
    reportSubmitting.value = false
  }
}

// --- Search ---
const MAX_SEARCH_PAGES = 20

async function runSearch() {
  const q = searchQuery.value.trim().toLowerCase()
  if (!q) {
    searchResults.value = []
    searchDone.value = false
    return
  }
  searching.value = true
  searchError.value = ''
  searchDone.value = false
  searchResults.value = []
  try {
    let before = null
    let pages = 0
    while (pages < MAX_SEARCH_PAGES) {
      const params = before ? { before } : {}
      const res = await api.get(`/rooms/${roomHash}/messages`, { params })
      const batch = res.data.messages
      if (!batch.length) break
      for (const m of batch) {
        const d = await decryptOne(m)
        if (d.isPaste || d.deleted) continue
        if (d.text && d.text.toLowerCase().includes(q)) {
          searchResults.value.push({ id: m.id, sender_id: m.sender_id, text: d.text, ts: m.ts })
        }
      }
      before = batch[0].id
      pages++
      if (batch.length < 100) break
    }
    searchResults.value.sort((a, b) => new Date(a.ts) - new Date(b.ts))
    searchDone.value = true
  } catch (e) {
    searchError.value = e.response?.data?.error || 'Search failed'
  } finally {
    searching.value = false
  }
}

function toggleSearch() {
  showSearch.value = !showSearch.value
  if (showSearch.value) { showInvite.value = false; showMembers.value = false; showBans.value = false }
  if (!showSearch.value) {
    searchQuery.value = ''
    searchResults.value = []
    searchDone.value = false
    searchError.value = ''
  }
}

async function jumpToMessage(id) {
  const idx = messages.value.findIndex((m) => m.id === id)
  if (idx === -1) await loadInitialHistory()
  await nextTick()
  const el = document.querySelector(`[data-mid="${id}"]`)
  if (el) {
    el.scrollIntoView({ behavior: 'smooth', block: 'center' })
    el.classList.add('bg-emerald-500/20')
    clearTimeout(highlightTimer)
    highlightTimer = setTimeout(() => el.classList.remove('bg-emerald-500/20'), 2000)
  }
  showSearch.value = false
}

function snippet(text, q) {
  const idx = text.toLowerCase().indexOf(q.toLowerCase())
  if (idx === -1) return text.slice(0, 80)
  const start = Math.max(0, idx - 30)
  const end = Math.min(text.length, idx + q.length + 40)
  return (start > 0 ? '…' : '') + text.slice(start, end) + (end < text.length ? '…' : '')
}

async function searchUsers() {
  inviteError.value = ''
  inviteMessage.value = ''
  if (!inviteQuery.value.trim()) { inviteResults.value = []; return }
  try {
    const res = await api.get('/users', { params: { q: inviteQuery.value.trim() } })
    inviteResults.value = res.data.users
  } catch (e) {
    inviteError.value = e.response?.data?.error || 'Search failed'
  }
}

async function invite(user) {
  inviteMessage.value = ''
  try {
    await api.post(`/rooms/${roomHash}/invite`, { user_id: user.id })
    inviteMessage.value = `invited ${user.username}`
    inviteResults.value = inviteResults.value.filter((u) => u.id !== user.id)
    await loadMembers()
  } catch (e) {
    inviteMessage.value = e.response?.data?.error || 'Invite failed'
  }
}

function toggleInvite() {
  showInvite.value = !showInvite.value
  if (showInvite.value) { showMembers.value = false; showSearch.value = false; showBans.value = false }
  inviteQuery.value = ''
  inviteResults.value = []
  inviteMessage.value = ''
  inviteError.value = ''
}

async function toggleMembers() {
  showMembers.value = !showMembers.value
  if (showMembers.value) {
    showInvite.value = false; showSearch.value = false; showBans.value = false
    membersFilter.value = ''
    await loadMembers()
  }
}

async function toggleBans() {
  showBans.value = !showBans.value
  if (showBans.value) {
    showInvite.value = false; showMembers.value = false; showSearch.value = false
    banQuery.value = ''
    banResults.value = []
    banError.value = ''
    await loadBans()
  }
}

async function searchUsersForBan() {
  banError.value = ''
  if (!banQuery.value.trim()) { banResults.value = []; return }
  banLoading.value = true
  try {
    const res = await api.get('/users', { params: { q: banQuery.value.trim() } })
    banResults.value = res.data.users.filter(u => u.username !== auth.username)
  } catch (e) {
    banError.value = e.response?.data?.error || 'Search failed'
  } finally {
    banLoading.value = false
  }
}

async function banUser(user) {
  if (!confirm(`Ban ${user.username} from this room? They cannot rejoin unless you unban them.`)) return
  try {
    await api.post(`/rooms/${roomHash}/remove`, { user_id: user.id })
    banResults.value = banResults.value.filter(u => u.id !== user.id)
    await loadMembers()
    await loadBans()
  } catch (e) {
    alert(e.response?.data?.error || 'Ban failed')
  }
}

async function removeMember(user) {
  if (!confirm(`Remove and BAN ${user.username}? They cannot rejoin unless you unban them.`)) return
  try {
    await api.post(`/rooms/${roomHash}/remove`, { user_id: user.user_id })
    await loadMembers()
    await loadBans()
  } catch (e) {
    alert(e.response?.data?.error || 'Remove failed')
  }
}

async function unbanUser(u) {
  if (!confirm(`Unban ${u.username}? They can rejoin.`)) return
  try {
    await api.delete(`/rooms/${roomHash}/ban/${u.user_id}`)
    await loadBans()
  } catch (e) {
    alert(e.response?.data?.error || 'Unban failed')
  }
}

function canEdit(m) {
  if (m.isPaste || m.deleted_at) return false
  return m.sender_id === myId.value || canManage.value
}

async function deleteMessage(m) {
  if (!confirm('Delete this message?')) return
  try { await api.delete(`/rooms/${roomHash}/messages/${m.id}`) }
  catch (e) { alert(e.response?.data?.error || 'Delete failed') }
}

function startEdit(m) {
  if (m.isPaste || m.deleted_at) return
  editingId.value = m.id
  editingText.value = m.text
}
function cancelEdit() { editingId.value = null; editingText.value = '' }

async function saveEdit(m) {
  if (!editingText.value.trim()) return
  try {
    const enc = await encryptMessage(roomKey, editingText.value)
    await api.patch(`/rooms/${roomHash}/messages/${m.id}`, {
      ct: enc.ct, iv: enc.iv, tag: enc.tag,
    })
    cancelEdit()
  } catch (e) {
    alert(e.response?.data?.error || 'Edit failed')
  }
}

async function joinRoom() {
  joining.value = true
  try {
    await api.post(`/rooms/${roomHash}/join`)
    needsJoin.value = false
    await loadRoom()
    await loadKey()
    await loadMembers()
    await loadInitialHistory()
    await markRead()
    await connect()
    typingCleanupTimer = setInterval(cleanupTyping, 2000)
  } catch (e) {
    if (e.response?.status === 403) {
      error.value = e.response?.data?.error || 'Cannot join this room.'
    } else {
      error.value = e.response?.data?.error || 'Failed to join'
    }
  } finally {
    joining.value = false
  }
}

onMounted(async () => {
  isComponentMounted = true
  try {
    await loadMe()
    const ok = await loadRoom()
    if (!ok) { initialLoading.value = false; return }
    await loadKey()
    await loadMembers()
    await loadInitialHistory()
    await markRead()
    await connect()
    typingCleanupTimer = setInterval(cleanupTyping, 2000)
  } catch (e) {
    if (e.response?.status === 404) error.value = 'Room not found.'
    else if (e.response?.status === 403) error.value = 'You do not have access to this room.'
    else error.value = e.response?.data?.error || e.message
  } finally {
    initialLoading.value = false
    await nextTick()
    if (logEl.value) logEl.value.scrollTop = logEl.value.scrollHeight
  }
})

onBeforeUnmount(() => {
  isComponentMounted = false
  isConnected.value = false
  unsubs.forEach((fn) => fn())
  unsubs = []
  if (socket) socket.send({ type: 'chat.leave' })
  if (typingCleanupTimer) clearInterval(typingCleanupTimer)
  if (highlightTimer) clearTimeout(highlightTimer)
})
</script>

<template>
  <div class="flex flex-col h-[calc(100dvh-3.5rem)] lg:h-[calc(100dvh-3rem)] -my-6 -mx-4 sm:-mx-6 font-mono">
    <div class="flex items-center justify-between px-4 sm:px-6 py-3 border-b border-gray-800 bg-gray-950/80 backdrop-blur sticky top-0 z-10">
      <div class="min-w-0 flex items-center gap-2 flex-1">
        <button @click="router.push('/rooms')" class="text-gray-500 hover:text-emerald-400 text-sm flex-shrink-0" title="Back to rooms">&lt;</button>
        <span class="text-emerald-400 flex-shrink-0">{{ room && room.type === 'channel' ? '#' : room && room.type === 'private' ? '@' : '>' }}</span>
        <span class="text-white font-medium truncate">{{ room ? room.name : 'room' }}</span>
        <span v-if="room" class="text-xs text-gray-500 ml-1 hidden sm:inline flex-shrink-0">[{{ room.type }}]</span>
        <span v-if="room && room.is_invite_only" class="text-xs text-yellow-500 ml-1 flex-shrink-0" title="invite only">🔒</span>
        <span v-if="!isSocketConnected" class="text-xs text-red-500 animate-pulse ml-2 flex-shrink-0" title="Reconnecting...">● offline</span>
        <span v-if="isReadOnly" class="text-xs text-red-400 ml-1 flex-shrink-0 hidden sm:inline">read-only</span>
      </div>
      <div class="flex items-center gap-1 flex-shrink-0">
        <button v-if="room && room.is_member" @click="toggleSearch" :class="['px-2.5 py-1 rounded-md text-xs transition-colors', showSearch ? 'bg-gray-800 text-emerald-400' : 'text-gray-400 hover:bg-gray-800 hover:text-white']" title="Search messages">⌕</button>
        <router-link
          :to="`/rooms/${roomHash}/members`"
          class="px-2.5 py-1 rounded-md text-xs transition-colors text-gray-400 hover:bg-gray-800 hover:text-white"
        >
          members <span class="text-gray-600">({{ members.length }})</span>
        </router-link>
        <button v-if="canManage" @click="toggleInvite" :class="['px-2.5 py-1 rounded-md text-xs transition-colors', showInvite ? 'bg-emerald-500/10 text-emerald-400' : 'text-gray-400 hover:bg-gray-800 hover:text-white']">
          + invite
        </button>
        <button v-if="isOwner" @click="toggleBans" :class="['px-2.5 py-1 rounded-md text-xs transition-colors', showBans ? 'bg-red-500/10 text-red-400' : 'text-gray-400 hover:bg-gray-800 hover:text-red-400']">banned</button>
      </div>
    </div>

    <div v-if="showSearch" class="px-4 sm:px-6 py-3 border-b border-gray-800 bg-gray-900">
      <div class="text-xs text-gray-500 mb-2">// search messages (last 2,000)</div>
      <div class="flex gap-2">
        <input v-model="searchQuery" @keyup.enter="runSearch" placeholder="search query, then enter" autocomplete="off" class="flex-1 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-1.5 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" />
        <button @click="runSearch" :disabled="searching" class="px-3 py-1.5 rounded-md bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold text-xs transition-colors disabled:bg-gray-700 disabled:text-gray-500">{{ searching ? '...' : 'search' }}</button>
      </div>
      <p v-if="searchError" class="text-xs text-red-400 mt-2">{{ searchError }}</p>
      <p v-if="searchDone && !searchResults.length && !searchError" class="text-xs text-gray-500 mt-2">no matches</p>
      <ul v-if="searchResults.length" class="mt-3 max-h-60 overflow-y-auto space-y-1">
        <li v-for="r in searchResults" :key="r.id" class="text-sm bg-gray-950 border border-gray-800 rounded-md px-3 py-2 cursor-pointer hover:border-emerald-500/40" @click="jumpToMessage(r.id)">
          <div class="text-[10px] text-gray-500 mb-0.5">
            <span class="text-emerald-400">{{ nameOf(r.sender_id) }}</span>
            <span class="ml-2">{{ formatTs(r.ts) }}</span>
          </div>
          <div class="text-gray-200 break-words">{{ snippet(r.text, searchQuery) }}</div>
        </li>
      </ul>
    </div>

    <div v-if="showInvite" class="px-4 sm:px-6 py-3 border-b border-gray-800 bg-gray-900">
      <div class="text-xs text-gray-500 mb-2">// invite by username</div>
      <input v-model="inviteQuery" @input="searchUsers" placeholder="search username" autocomplete="off" class="w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-1.5 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" />
      <p v-if="inviteError" class="text-xs text-red-400 mt-2">{{ inviteError }}</p>
      <p v-if="inviteMessage" class="text-xs text-emerald-400 mt-2">{{ inviteMessage }}</p>
      <ul v-if="inviteResults.length" class="mt-2 space-y-1">
        <li v-for="u in inviteResults" :key="u.id" class="flex items-center justify-between text-sm">
          <span class="text-gray-300">@{{ u.username }}</span>
          <button @click="invite(u)" class="text-xs text-emerald-400 hover:text-emerald-300">+ invite</button>
        </li>
      </ul>
    </div>

    <div v-if="showBans" class="px-4 sm:px-6 py-3 border-b border-gray-800 bg-gray-900">
      <div class="text-xs text-gray-500 mb-2">// ban a user from this room</div>
      <input v-model="banQuery" @input="searchUsersForBan" placeholder="search username to ban" autocomplete="off" class="w-full bg-gray-950 border border-red-500/30 text-red-300 px-3 py-1.5 rounded-md text-sm focus:outline-none focus:border-red-500 placeholder-gray-600" />
      <p v-if="banError" class="text-xs text-red-400 mt-2">{{ banError }}</p>
      <p v-if="banLoading" class="text-xs text-gray-500 mt-2">searching...</p>
      <ul v-if="banResults.length" class="mt-2 space-y-1">
        <li v-for="u in banResults" :key="u.id" class="flex items-center justify-between text-sm">
          <span class="text-gray-300">@{{ u.username }}</span>
          <button @click="banUser(u)" class="text-xs text-red-400 hover:text-red-300">ban</button>
        </li>
      </ul>
      <div class="text-xs text-gray-500 mt-4 mb-2">// banned users ({{ bannedUsers.length }})</div>
      <ul v-if="bannedUsers.length" class="space-y-1 max-h-60 overflow-y-auto">
        <li v-for="b in bannedUsers" :key="b.user_id" class="flex items-center gap-2 text-sm">
          <span class="text-gray-300 truncate">{{ b.username }}</span>
          <span class="text-xs text-gray-600">banned {{ formatTs(b.banned_at) }}</span>
          <button @click="unbanUser(b)" class="ml-auto text-xs text-emerald-400 hover:text-emerald-300 flex-shrink-0">unban</button>
        </li>
      </ul>
      <p v-else class="text-xs text-gray-600">no banned users</p>
    </div>

    <div v-if="needsJoin" class="px-4 sm:px-6 py-8 text-center">
      <p class="text-sm text-gray-400 mb-4">You're not a member of this room yet.</p>
      <button @click="joinRoom" :disabled="joining" class="px-5 py-2 rounded-md bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold font-mono text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500">
        {{ joining ? 'joining...' : '> join room' }}
      </button>
    </div>

    <div v-if="error" class="px-4 sm:px-6 py-3">
      <ErrorBanner :message="error" />
      <button @click="router.push('/rooms')" class="text-xs text-emerald-400 hover:underline mt-1">&lt; back to rooms</button>
    </div>

    <LoadingSpinner v-if="initialLoading" label="loading messages..." />

    <div v-else-if="!error && !needsJoin" ref="logEl" @scroll="onScroll" class="flex-1 overflow-y-auto px-4 sm:px-6 py-4 space-y-1">
      <div v-if="loadingOlder" class="text-center text-xs text-gray-500 py-2">loading older messages...</div>
      <div v-else-if="!hasMore && messages.length" class="text-center text-xs text-gray-600 py-2">// start of conversation</div>
      <div v-if="!messages.length" class="text-center text-xs text-gray-600 py-8">// no messages yet</div>

      <div
        v-for="m in messages"
        :key="m.id"
        :data-mid="m.id"
        :class="['group flex gap-2 rounded-md transition-colors', m.sender_id === myId ? 'justify-end' : 'justify-start']"
      >
        <div v-if="m.sender_id !== myId" class="w-8 h-8 rounded-full bg-gray-800 flex items-center justify-center text-[10px] text-emerald-400 font-bold flex-shrink-0 mt-1">
          {{ initials(m.sender_id) }}
        </div>
        <div :class="['max-w-[75%] flex flex-col', m.sender_id === myId ? 'items-end' : 'items-start']">
          <div :class="['text-[10px] mb-0.5 flex items-center gap-2 flex-wrap', m.sender_id === myId ? 'text-emerald-400' : 'text-gray-400']">
            <span class="font-medium">{{ nameOf(m.sender_id) }}</span>
            <span class="text-gray-600">{{ formatTs(m.ts) }}</span>
            <span v-if="m.edit_count" class="text-cyan-500">[edited {{ m.edit_count }}x]</span>
            <span v-if="m.deleted_at" class="text-red-500">[deleted]</span>
          </div>

          <template v-if="m.isPaste">
            <div class="border border-cyan-500/40 bg-cyan-500/5 rounded-lg p-3 min-w-[260px] max-w-full">
              <div class="flex items-start gap-2">
                <span class="text-cyan-400 text-lg leading-none">📋</span>
                <div class="min-w-0 flex-1">
                  <div class="text-white font-medium truncate">{{ m.paste.title }}</div>
                  <div class="text-[10px] text-gray-500 mt-0.5">
                    {{ m.paste.kind === 'file' ? 'file' : 'text' }}
                    · by {{ nameOf(m.sender_id) }}
                    <template v-if="pastesByHash[m.paste.paste_hash]?.deleted_at">
                      · deleted
                    </template>
                    <template v-else-if="pastesByHash[m.paste.paste_hash]?.opened_username">
                      · opened by {{ pastesByHash[m.paste.paste_hash].opened_username }}
                    </template>
                    <template v-else>
                      · ready
                    </template>
                  </div>
                </div>
              </div>
              <div class="flex gap-2 mt-2 text-xs justify-end flex-wrap items-center">
                <template v-if="pastesByHash[m.paste.paste_hash]?.deleted_at">
                  <span class="text-gray-600">deleted</span>
                </template>
                <template v-else-if="pastesByHash[m.paste.paste_hash]?.can_done">
                  <span v-if="downloading === m.paste.paste_hash" class="text-cyan-400 text-[10px]">↓ {{ downloadProgress }}%</span>
                  <button v-else-if="pastesByHash[m.paste.paste_hash]?.can_download" @click="downloadPaste(m.paste)" class="text-cyan-400 hover:text-cyan-300">↓ download</button>
                  <button @click="donePaste(m.paste)" class="text-emerald-400 hover:text-emerald-300">done</button>
                </template>
                <template v-else-if="pastesByHash[m.paste.paste_hash]?.is_sender && m.paste.kind === 'file'">
                  <span v-if="downloading === m.paste.paste_hash" class="text-cyan-400 text-[10px]">↓ {{ downloadProgress }}%</span>
                  <button v-else @click="downloadPaste(m.paste)" class="text-cyan-400 hover:text-cyan-300">↓ download</button>
                  <button @click="openPaste(m.paste)" class="text-gray-400 hover:text-emerald-400">peek</button>
                </template>
                <template v-else-if="pastesByHash[m.paste.paste_hash]?.can_open">
                  <button @click="openPaste(m.paste)" class="text-emerald-400 hover:text-emerald-300">open</button>
                  <span v-if="pastesByHash[m.paste.paste_hash]?.is_sender" class="text-gray-600 text-[10px]">(peek)</span>
                </template>
                <template v-else>
                  <span class="text-gray-600">opened</span>
                </template>
              </div>
            </div>
          </template>

          <template v-else-if="m.deleted_at">
            <div class="px-3 py-2 rounded-2xl text-sm italic text-gray-500 border border-gray-800 bg-gray-900/50">
              [deleted message]
            </div>
          </template>

          <template v-else>
            <template v-if="editingId === m.id">
              <div class="flex gap-1 items-center">
                <input v-model="editingText" @keyup.enter="saveEdit(m)" @keyup.escape="cancelEdit" class="bg-gray-950 border border-emerald-500/40 text-emerald-200 px-3 py-1.5 rounded-lg text-sm focus:outline-none focus:border-emerald-500 min-w-[200px]" />
                <button @click="saveEdit(m)" class="text-xs text-emerald-400 hover:text-emerald-300">save</button>
                <button @click="cancelEdit" class="text-xs text-gray-500 hover:text-gray-400">cancel</button>
              </div>
            </template>
            <template v-else>
              <div :class="['px-3 py-2 rounded-2xl text-sm whitespace-pre-wrap break-words', m.sender_id === myId ? 'bg-emerald-600/20 text-emerald-100 border border-emerald-600/30 rounded-tr-sm' : 'bg-gray-800 text-gray-100 border border-gray-700 rounded-tl-sm']">{{ m.text }}</div>
              <div class="opacity-0 group-hover:opacity-100 transition-opacity flex gap-2 text-[10px] mt-0.5">
                <template v-if="canEdit(m)">
                  <button @click="startEdit(m)" class="text-gray-500 hover:text-emerald-400">edit</button>
                  <button @click="deleteMessage(m)" class="text-gray-500 hover:text-red-400">delete</button>
                </template>
                <button
                  v-if="!reportedIds[m.id]"
                  @click="openReportModal(m)"
                  class="text-gray-500 hover:text-yellow-400"
                >report</button>
                <span v-else class="text-yellow-500">reported</span>
              </div>
            </template>
          </template>
        </div>
      </div>
    </div>

    <div v-if="!error && !needsJoin" class="border-t border-gray-800 bg-gray-950">
      <div v-if="typingLabel" class="px-4 sm:px-6 pt-2 text-xs text-gray-500 italic">{{ typingLabel }}</div>
      <form @submit.prevent="send" class="px-4 sm:px-6 py-3">
        <div v-if="isReadOnly" class="text-xs text-gray-500 py-1">// read-only channel — only owner/admin can post</div>
        <div v-else class="flex gap-2 items-center">
          <span class="text-emerald-400 font-bold">&gt;</span>
          <input v-model="input" @input="onInput" :disabled="initialLoading" placeholder="type a message..." class="flex-1 bg-transparent text-gray-100 px-0 py-2 text-sm focus:outline-none placeholder-gray-600" />
          <button type="button" @click="openPasteModal" class="px-2 py-1.5 rounded-md text-gray-400 hover:text-cyan-400 hover:bg-gray-800 transition-colors" title="Create paste">📎</button>
          <button type="submit" :disabled="!input.trim() || sending" class="px-4 py-1.5 rounded-md bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold text-sm transition-colors disabled:bg-gray-800 disabled:text-gray-600">send</button>
        </div>
      </form>
    </div>

    <!-- Paste creation modal -->
    <div v-if="showPasteModal" class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4" @click.self="closePasteModal">
      <div class="bg-gray-900 border border-gray-800 rounded-lg w-full max-w-lg p-5 font-mono">
        <div class="flex items-center justify-between mb-4">
          <div class="text-sm text-white"><span class="text-cyan-400">📋</span> new paste</div>
          <button @click="closePasteModal" class="text-gray-500 hover:text-white">✕</button>
        </div>

        <div class="mb-3">
          <div class="text-xs text-gray-500 mb-1">title (required)</div>
          <input v-model="pasteTitle" placeholder="e.g. API keys for staging" class="w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" />
        </div>

        <div class="flex gap-2 mb-3">
          <button @click="pasteMode = 'text'" :class="['px-3 py-1 rounded-md text-xs border transition-colors', pasteMode === 'text' ? 'bg-cyan-500/10 text-cyan-400 border-cyan-500/40' : 'bg-gray-950 text-gray-500 border-gray-800']">text</button>
          <button @click="pasteMode = 'file'" :class="['px-3 py-1 rounded-md text-xs border transition-colors', pasteMode === 'file' ? 'bg-cyan-500/10 text-cyan-400 border-cyan-500/40' : 'bg-gray-950 text-gray-500 border-gray-800']">file</button>
        </div>

        <div v-if="pasteMode === 'text'" class="mb-3">
          <textarea v-model="pasteText" rows="8" placeholder="paste your text here..." class="w-full bg-gray-950 border border-gray-800 text-gray-100 px-3 py-2 rounded-md text-sm font-mono focus:outline-none focus:border-cyan-500 resize-none placeholder-gray-600"></textarea>
          <div class="text-[10px] text-gray-600 mt-1">max 1 MB</div>
        </div>

        <div v-else class="mb-3">
          <input type="file" @change="onPasteFile" class="w-full text-xs text-gray-400 file:mr-2 file:py-1.5 file:px-3 file:rounded-md file:border-0 file:bg-gray-800 file:text-cyan-400 file:font-mono file:cursor-pointer hover:file:bg-gray-700" />
          <div class="text-[10px] text-gray-600 mt-1">max 50 MB</div>
        </div>

        <div v-if="pasteSubmitting && pasteMode === 'file'" class="mb-3">
          <div class="h-1 bg-gray-800 rounded overflow-hidden">
            <div class="h-full bg-cyan-500 transition-all" :style="{ width: pasteProgress + '%' }"></div>
          </div>
          <div class="text-[10px] text-gray-500 mt-1">{{ pasteProgress }}%</div>
        </div>

        <p v-if="pasteError" class="text-xs text-red-400 mb-2">{{ pasteError }}</p>

        <div class="flex justify-end gap-2">
          <button @click="closePasteModal" class="px-3 py-1.5 rounded-md text-gray-400 hover:text-white text-xs">cancel</button>
          <button @click="submitPaste" :disabled="pasteSubmitting" class="px-4 py-1.5 rounded-md bg-cyan-600 hover:bg-cyan-500 text-gray-950 font-bold text-xs transition-colors disabled:bg-gray-700 disabled:text-gray-500">
            {{ pasteSubmitting ? '...' : '> create paste' }}
          </button>
        </div>
      </div>
    </div>

    <!-- Open paste modal -->
    <div v-if="showOpenPasteModal" class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4" @click.self="closeOpenPasteModal">
      <div class="bg-gray-900 border border-gray-800 rounded-lg w-full max-w-2xl p-5 font-mono">
        <div class="flex items-center justify-between mb-4">
          <div class="text-sm text-white flex items-center gap-2 min-w-0">
            <span class="text-cyan-400">📋</span>
            <span class="truncate">{{ openPasteTitle }}</span>
            <span v-if="openPastePeek" class="text-[10px] text-gray-500">(peek)</span>
          </div>
          <button @click="closeOpenPasteModal" class="text-gray-500 hover:text-white flex-shrink-0">✕</button>
        </div>

        <div v-if="openPasteKind === 'text'" class="mb-3">
          <div class="text-xs text-gray-500 mb-2">// paste content — copy it now</div>
          <textarea readonly :value="openPasteContent" rows="12" class="w-full bg-gray-950 border border-gray-800 text-emerald-100 px-3 py-2 rounded-md text-sm font-mono focus:outline-none resize-none"></textarea>
          <div class="text-[10px] text-gray-600 mt-1">{{ openPasteContent.length }} chars</div>
        </div>

        <div v-else class="mb-3">
          <div class="text-xs text-gray-500 mb-2">// file ready for download</div>
          <div class="bg-gray-950 border border-gray-800 rounded-md px-3 py-3 text-sm">
            <div class="text-white truncate">{{ openPasteFileName }}</div>
          </div>
          <div v-if="downloading === openPasteHash" class="mt-2">
            <div class="h-1 bg-gray-800 rounded overflow-hidden">
              <div class="h-full bg-cyan-500 transition-all" :style="{ width: downloadProgress + '%' }"></div>
            </div>
            <div class="text-[10px] text-gray-500 mt-1">{{ downloadProgress }}%</div>
          </div>
        </div>

        <div class="flex justify-between items-center gap-2">
          <div class="flex gap-2">
            <button
              v-if="openPasteKind === 'text'"
              @click="copyOpenPaste"
              class="px-3 py-1.5 rounded-md bg-gray-800 hover:bg-gray-700 text-gray-200 text-xs"
            >copy</button>
            <button
              v-else
              @click="downloadPaste({ paste_hash: openPasteHash, file_name: openPasteFileName, title: openPasteTitle })"
              :disabled="downloading === openPasteHash"
              class="px-3 py-1.5 rounded-md bg-cyan-600 hover:bg-cyan-500 text-gray-950 font-bold text-xs disabled:bg-gray-700 disabled:text-gray-500"
            >{{ downloading === openPasteHash ? 'downloading...' : '↓ download' }}</button>
          </div>
          <div class="flex gap-2">
            <button @click="closeOpenPasteModal" class="px-3 py-1.5 rounded-md text-gray-400 hover:text-white text-xs">close</button>
            <button
              v-if="!openPastePeek"
              @click="donePaste({ paste_hash: openPasteHash }); closeOpenPasteModal()"
              class="px-4 py-1.5 rounded-md bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold text-xs"
            >done — delete forever</button>
          </div>
        </div>
      </div>
    </div>

    <!-- Report modal -->
    <div v-if="showReportModal" class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4" @click.self="closeReportModal">
      <div class="bg-gray-900 border border-yellow-500/40 rounded-lg w-full max-w-md p-5 font-mono">
        <div class="flex items-center justify-between mb-4">
          <div class="text-sm text-white"><span class="text-yellow-400">⚑</span> report message</div>
          <button @click="closeReportModal" class="text-gray-500 hover:text-white">✕</button>
        </div>
        <div class="mb-3">
          <div class="text-xs text-gray-500 mb-1">reason (optional)</div>
          <textarea v-model="reportReason" rows="4" placeholder="what's wrong with this message?" class="w-full bg-gray-950 border border-gray-800 text-gray-100 px-3 py-2 rounded-md text-sm font-mono focus:outline-none focus:border-yellow-500 resize-none placeholder-gray-600"></textarea>
        </div>
        <p v-if="reportError" class="text-xs text-red-400 mb-2">{{ reportError }}</p>
        <div class="flex justify-end gap-2">
          <button @click="closeReportModal" class="px-3 py-1.5 rounded-md text-gray-400 hover:text-white text-xs">cancel</button>
          <button @click="submitReport" :disabled="reportSubmitting" class="px-4 py-1.5 rounded-md bg-yellow-600 hover:bg-yellow-500 text-gray-950 font-bold text-xs transition-colors disabled:bg-gray-700 disabled:text-gray-500">
            {{ reportSubmitting ? '...' : '> report' }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
