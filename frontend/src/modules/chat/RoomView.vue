<script setup>
import { ref, onMounted, onBeforeUnmount, nextTick, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../../core/auth'
import api from '../../core/api'
import { getSocket } from '../../core/socket'
import { encryptMessage, decryptMessage, decryptBytes, generateAesKey } from '../../core/crypto'
import init, { MlKemKeyPair, decrypt_private_key } from '../../pqc/cipherbox_pqc.js'
import { loadIdentity } from '../../core/pqc-db.js'
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
const memberCount = ref(0)
const loadingOlder = ref(false)
const hasMore = ref(true)
const initialLoading = ref(true)
const sending = ref(false)
const typingUsers = ref({})
const needsInvite = ref(false)
const needsUnlock = ref(false)
const keyMissing = ref(false)

const passphrase = ref('')
const unlocking = ref(false)
const roomAesKey = ref(null)

const showSearch = ref(false)
const searchQuery = ref('')
const searchResults = ref([])
const searchError = ref('')
const searching = ref(false)
const searchDone = ref(false)

const showInvite = ref(false)
const inviteQuery = ref('')
const inviteResults = ref([])
const inviteError = ref('')
const inviteMessage = ref('')

const showManage = ref(false)
const manageQuery = ref('')
const manageResults = ref([])
const manageSearching = ref(false)
const manageError = ref('')
const manageLoading = ref(false)

// Message Edit/Delete State
const editingMessageId = ref(null)
const editingText = ref('')
const hoveredMessageId = ref(null)

// Paste State
const showPasteModal = ref(false)
const pasteTitle = ref('')
const pasteText = ref('')
const pasteMode = ref('text')
const pasteFile = ref(null)
const pasteSubmitting = ref(false)
const pasteProgress = ref(0)
const pasteError = ref('')
const maxPasteSize = ref(10 * 1024 * 1024)
const openingPaste = ref(null)

// Open Paste State
const showOpenPasteModal = ref(false)
const openPasteTitle = ref('')
const openPasteContent = ref('')
const openPasteKind = ref('text')
const openPasteHash = ref('')
const openPasteFileName = ref('')
const downloading = ref(null)
const downloadProgress = ref(0)

const userNames = ref({})

let socket = null
let lastTypingSent = 0
let typingCleanupTimer = null
let unsubs = []
let highlightTimer = null
let manageDebounce = null
let isComponentMounted = false
const isConnected = ref(false)
const isSocketConnected = ref(true)

const myId = ref(null)

const canManage = computed(() => {
  const r = room.value
  if (!r) return false
  if (myId.value && r.owner_id === myId.value) return true
  return r.my_role === 'owner' || r.my_role === 'admin'
})

const isReadOnly = computed(() => {
  const r = room.value
  if (!r) return false
  if (r.type !== 'channel') return false
  if (myId.value && r.owner_id === myId.value) return false
  if (r.my_role === 'admin') return false
  return true
})

const typingLabel = computed(() => {
  const ids = Object.keys(typingUsers.value).filter(id => Number(id) !== myId.value)
  if (ids.length === 0) return ''
  const names = ids.map(id => nameOf(Number(id)))
  if (names.length === 1) return `${names[0]} is typing...`
  if (names.length === 2) return `${names[0]} and ${names[1]} are typing...`
  return `${names.length} people are typing...`
})

function rememberName(id, username) {
  if (!id || !username) return
  if (userNames.value[id] === username) return
  userNames.value = { ...userNames.value, [id]: username }
}

function nameOf(id) {
  return userNames.value[id] || `user#${id}`
}

function initials(id) {
  return nameOf(id).slice(0, 2).toUpperCase()
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
  rememberName(res.data.id, res.data.username)
}

async function loadNames() {
  try {
    const res = await api.get(`/rooms/${roomHash}/members`, { params: { limit: 1000 } })
    const map = { ...userNames.value }
    for (const m of res.data.members) {
      map[m.user_id] = m.username
    }
    userNames.value = map
  } catch (e) {
    console.error('Failed to load usernames', e)
  }
}

async function loadRoom() {
  const meta = await api.get(`/rooms/${roomHash}`)
  room.value = meta.data.room
  memberCount.value = meta.data.room.member_count ?? 0
  
  if (meta.data.room.member_count === undefined) {
    try {
      const countRes = await api.get(`/rooms/${roomHash}/members`, { params: { limit: 1 } })
      memberCount.value = countRes.data.total
    } catch (e) {}
  }

  if (meta.data.room.banned) {
    error.value = 'You are banned from this room.'
    return false
  }
  if (!meta.data.room.is_member) {
    needsInvite.value = true
    return false
  }
  return true
}

async function decryptOne(m) {
  if (m.deleted_at) return { text: null, deleted: true }
  try {
    const text = await decryptMessage(roomAesKey.value, m.ct, m.iv, m.tag)
    let payload
    try { payload = JSON.parse(text) } catch (e) { payload = null }
    if (payload && payload._type === 'paste') return { isPaste: true, paste: payload }
    return { text }
  } catch (e) {
    return { error: true, text: '[decrypt failed]' }
  }
}

async function loadInitialHistory() {
  const res = await api.get(`/rooms/${roomHash}/messages`)
  const out = []
  
  for (const m of res.data.messages) {
    if (m.sender_username) rememberName(m.sender_id, m.sender_username)
    out.push({
      id: m.id,
      sender_id: m.sender_id,
      text: 'decrypting...',
      ts: m.ts,
      edit_count: m.edit_count || 0,
      deleted_at: m.deleted_at,
      loading: true
    })
  }
  
  messages.value = out
  hasMore.value = out.length >= 100
  scrollToBottom()

  for (let i = 0; i < out.length; i++) {
    const m = res.data.messages[i]
    const d = await decryptOne(m)
    
    if (d.isPaste) {
      messages.value[i].isPaste = true
      messages.value[i].paste = d.paste
    } else if (d.error) {
      messages.value[i].text = d.text
      messages.value[i].decryptError = true
    } else {
      messages.value[i].text = d.text
    }
    messages.value[i].loading = false
  }
  
  scrollToBottom()
}

async function loadOlder() {
  if (loadingOlder.value || !hasMore.value || !messages.value.length) return
  loadingOlder.value = true
  try {
    const oldestId = messages.value[0].id
    const res = await api.get(`/rooms/${roomHash}/messages`, { params: { before: oldestId } })
    const older = []
    
    for (const m of res.data.messages) {
      if (m.sender_username) rememberName(m.sender_id, m.sender_username)
      older.push({
        id: m.id,
        sender_id: m.sender_id,
        text: 'decrypting...',
        ts: m.ts,
        edit_count: m.edit_count || 0,
        deleted_at: m.deleted_at,
        loading: true
      })
    }
    
    if (older.length < 100) hasMore.value = false
    const el = logEl.value
    const prevHeight = el ? el.scrollHeight : 0
    messages.value = [...older, ...messages.value]
    await nextTick()
    if (el) el.scrollTop = el.scrollHeight - prevHeight

    for (let i = 0; i < older.length; i++) {
      const m = res.data.messages[i]
      const d = await decryptOne(m)
      
      if (d.isPaste) {
        messages.value[i].isPaste = true
        messages.value[i].paste = d.paste
      } else if (d.error) {
        messages.value[i].text = d.text
        messages.value[i].decryptError = true
      } else {
        messages.value[i].text = d.text
      }
      messages.value[i].loading = false
    }
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

async function unlockRoom() {
  if (!passphrase.value && !room.value.is_public) return

  unlocking.value = true
  error.value = ''
  keyMissing.value = false
  try {
    await init()
    const res = await api.get(`/rooms/${roomHash}/key`)
    
    if (room.value.is_public && res.data.plaintext_room_key) {
      roomAesKey.value = res.data.plaintext_room_key
      needsUnlock.value = false
      
      await loadInitialHistory()
      await markRead()
      await connect()
      scrollToBottom()
      typingCleanupTimer = setInterval(cleanupTyping, 2000)
      return
    }

    if (!res.data.kyber_ciphertext) {
      keyMissing.value = true
      throw new Error('No key envelope for you in this room yet.')
    }
    const payload = JSON.parse(res.data.kyber_ciphertext)

    const stored = await loadIdentity('pqc_identity')
    if (!stored) throw new Error('No identity found.')

    const dk_bytes = decrypt_private_key(stored.encrypted_kem_dk, passphrase.value)
    if (dk_bytes.length === 0) throw new Error('Wrong passphrase.')

    let ek_b64 = ''
    for (let i = 0; i < stored.kem_public_key.byteLength; i++) ek_b64 += String.fromCharCode(stored.kem_public_key[i])
    ek_b64 = btoa(ek_b64)

    const kem = MlKemKeyPair.importKeys(dk_bytes, Uint8Array.from(atob(ek_b64), c => c.charCodeAt(0)))
    let decrypted
    try {
      const ct = Uint8Array.from(atob(payload.ct), c => c.charCodeAt(0))
      const ss = new Uint8Array(kem.decapsulate(ct))
      const sharedKey = await crypto.subtle.importKey('raw', ss, { name: 'AES-GCM' }, false, ['decrypt'])
      const iv = Uint8Array.from(atob(payload.iv), c => c.charCodeAt(0))
      const encAes = Uint8Array.from(atob(payload.enc_aes), c => c.charCodeAt(0))
      decrypted = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, sharedKey, encAes)
    } finally {
      if (kem && kem.free) kem.free()
    }

    roomAesKey.value = new TextDecoder().decode(decrypted)
    needsUnlock.value = false

    await loadInitialHistory()
    await markRead()
    await connect()
    scrollToBottom()
    typingCleanupTimer = setInterval(cleanupTyping, 2000)

  } catch (e) {
    error.value = e.message || 'Failed to unlock room'
  } finally {
    unlocking.value = false
  }
}

async function connect() {
  if (isConnected.value) return
  isConnected.value = true
  socket = await getSocket()
  if (!isComponentMounted) { isConnected.value = false; return }

  unsubs.push(socket.on('open', () => {
    isSocketConnected.value = true
    if (room.value) socket.joinRoom(room.value.id)
  }))

  unsubs.push(socket.on('close', () => { isSocketConnected.value = false }))

  unsubs.push(socket.on('chat.recv', async (msg) => {
    if (!room.value || msg.r !== room.value.id) return
    
    rememberName(msg.u, msg.sender_username)
    
    // Decrypt the message
    const text = await decryptMessage(roomAesKey.value, msg.c, msg.i, msg.g).catch(() => null)
    
    // 1. Check if this is OUR OWN message coming back (optimistic update)
    const tempIdx = messages.value.findIndex(m => 
      typeof m.id === 'string' && 
      m.id.startsWith('temp-') && 
      m.sender_id === msg.u && 
      m.text === text
    )
    
    if (tempIdx !== -1) {
      // Replace the temp message with the real server ID
      let entry
      if (text === null) {
        entry = { id: msg.m, sender_id: msg.u, text: '[decrypt failed]', decryptError: true, ts: msg.s, edit_count: 0, deleted_at: null }
      } else {
        let payload = null
        try { payload = JSON.parse(text) } catch (e) {}
        if (payload && payload._type === 'paste') {
          entry = { id: msg.m, sender_id: msg.u, isPaste: true, paste: payload, ts: msg.s, edit_count: 0, deleted_at: null }
        } else {
          entry = { id: msg.m, sender_id: msg.u, text, ts: msg.s, edit_count: 0, deleted_at: null }
        }
      }
      messages.value.splice(tempIdx, 1, entry)
      delete typingUsers.value[msg.u]
      return
    }
    
    // 2. Otherwise, it's a new message from someone else
    if (messages.value.some(m => m.id === msg.m)) return
    
    let entry
    if (text === null) {
      entry = { id: msg.m, sender_id: msg.u, text: '[decrypt failed]', decryptError: true, ts: msg.s, edit_count: 0, deleted_at: null }
    } else {
      let payload = null
      try { payload = JSON.parse(text) } catch (e) {}
      if (payload && payload._type === 'paste') {
        entry = { id: msg.m, sender_id: msg.u, isPaste: true, paste: payload, ts: msg.s, edit_count: 0, deleted_at: null }
      } else {
        entry = { id: msg.m, sender_id: msg.u, text, ts: msg.s, edit_count: 0, deleted_at: null }
      }
    }
    
    messages.value.push(entry)
    delete typingUsers.value[msg.u]
    await nextTick()
    if (logEl.value) logEl.value.scrollTop = logEl.value.scrollHeight
    markRead()
  }))

  unsubs.push(socket.on('chat.deleted', (msg) => {
    if (!room.value || msg.r !== room.value.id) return
    const idx = messages.value.findIndex((m) => m.id === msg.m)
    if (idx !== -1) {
      const updatedMsg = Object.assign({}, messages.value[idx], { deleted_at: new Date().toISOString() })
      messages.value.splice(idx, 1, updatedMsg)
    }
  }))

  unsubs.push(socket.on('chat.edited', async (msg) => {
    if (!room.value || msg.r !== room.value.id) return
    
    // Decrypt the new text
    const text = await decryptMessage(roomAesKey.value, msg.c, msg.i, msg.g).catch(() => '[decrypt failed]')
    
    const idx = messages.value.findIndex((m) => m.id === msg.m)
    if (idx !== -1 && !messages.value[idx].isPaste) {
      // Use splice to force Vue reactivity
      const updatedMsg = Object.assign({}, messages.value[idx], {
        text: text,
        edit_count: msg.edit_count || (messages.value[idx].edit_count + 1)
      })
      messages.value.splice(idx, 1, updatedMsg)
    }
  }))

  unsubs.push(socket.on('chat.typing', (msg) => {
    if (!room.value || msg.r !== room.value.id) return
    if (msg.u === myId.value) return
    typingUsers.value = { ...typingUsers.value, [msg.u]: Date.now() }
  }))

  unsubs.push(socket.on('room.updated', (msg) => {
    if (!room.value || msg.r !== room.value.id) return
    api.get(`/rooms/${roomHash}`).then(res => {
      room.value = res.data.room
      memberCount.value = res.data.room.member_count ?? 0
    }).catch(() => {})
  }))

  unsubs.push(socket.on('room.deleted', (msg) => {
    if (!room.value || msg.r !== room.value.id) return
    alert('This room has been permanently deleted.')
    router.push('/rooms')
  }))

  unsubs.push(socket.on('error', (msg) => {
    if (msg.reason) error.value = msg.reason
  }))

  socket.joinRoom(room.value.id)
}

function onInput() {
  if (!socket || isReadOnly.value || !room.value) return
  const now = Date.now()
  if (now - lastTypingSent < 2000) return
  lastTypingSent = now
  socket.send({ t: 2, r: room.value.id })
}

async function send() {
  if (!input.value.trim() || sending.value || !socket) return
  
  const textToSend = input.value
  sending.value = true
  
  try {
    const enc = await encryptMessage(roomAesKey.value, textToSend)
    
    socket.send({
      t: 0, 
      r: room.value.id,
      c: enc.ct, 
      i: enc.iv, 
      g: enc.tag,
    })

    // Optimistic UI update
    messages.value.push({
      id: 'temp-' + Date.now(),
      sender_id: myId.value,
      text: textToSend,
      ts: new Date().toISOString(),
      edit_count: 0,
      deleted_at: null
    })

    input.value = ''
    await nextTick()
    if (logEl.value) logEl.value.scrollTop = logEl.value.scrollHeight
    
  } catch (e) {
    console.error("Send failed:", e)
  } finally {
    sending.value = false
  }
}

// ==========================================
// MESSAGE EDIT / DELETE
// ==========================================

function startEdit(m) {
  if (m.isPaste || m.deleted_at) return
  if (typeof m.id === 'string' && m.id.startsWith('temp-')) {
    alert('Message is still sending. Please wait a moment before editing.')
    return
  }
  editingMessageId.value = m.id
  editingText.value = m.text
}

function cancelEdit() {
  editingMessageId.value = null
  editingText.value = ''
}

async function saveEdit(m) {
  if (!editingText.value.trim() || editingText.value === m.text) {
    cancelEdit()
    return
  }

  const newText = editingText.value
  
  // 1. Optimistic Update (Instant UI change)
  const idx = messages.value.findIndex((x) => x.id === m.id)
  if (idx !== -1) {
    const updatedMsg = Object.assign({}, messages.value[idx], {
      text: newText, 
      edit_count: (messages.value[idx].edit_count || 0) + 1
    })
    messages.value.splice(idx, 1, updatedMsg)
  }

  try {
    const enc = await encryptMessage(roomAesKey.value, newText)
    await api.patch(`/rooms/${roomHash}/messages/${m.id}`, {
      ct: enc.ct, iv: enc.iv, tag: enc.tag
    })
    cancelEdit()
  } catch (e) {
    alert(e.response?.data?.error || 'Edit failed')
    // Reload to revert on failure
    await loadInitialHistory()
    cancelEdit()
  }
}

async function deleteMessage(m) {
  if (typeof m.id === 'string' && m.id.startsWith('temp-')) {
    alert('Message is still sending. Please wait a moment before deleting.')
    return
  }
  if (!confirm('Delete this message?')) return
  
  const idx = messages.value.findIndex((x) => x.id === m.id)
  if (idx !== -1) {
    const updatedMsg = Object.assign({}, messages.value[idx], {
      deleted_at: new Date().toISOString()
    })
    messages.value.splice(idx, 1, updatedMsg)
  }

  try {
    await api.delete(`/rooms/${roomHash}/messages/${m.id}`)
  } catch (e) {
    alert(e.response?.data?.error || 'Delete failed')
    await loadInitialHistory()
  }
}

// ==========================================
// PASTE LOGIC
// ==========================================

function closePasteModal() {
  showPasteModal.value = false
  pasteTitle.value = ''
  pasteText.value = ''
  pasteFile.value = null
  pasteError.value = ''
  pasteProgress.value = 0
}

function onPasteFile(e) {
  const f = e.target.files[0]
  if (f && f.size > maxPasteSize.value) {
    pasteError.value = `File too large. Max ${Math.round(maxPasteSize.value / 1024 / 1024)}MB.`
    pasteFile.value = null
    e.target.value = ''
    return
  }
  pasteFile.value = f || null
  pasteError.value = ''
}

async function submitPaste() {
  if (!pasteTitle.value) return (pasteError.value = 'Title is required')
  if (pasteMode.value === 'text' && !pasteText.value) return (pasteError.value = 'Text is required')
  if (pasteMode.value === 'file' && !pasteFile.value) return (pasteError.value = 'File is required')

  pasteSubmitting.value = true
  pasteError.value = ''
  pasteProgress.value = 10

  try {
    const pasteKey = await generateAesKey()
    const wrappedKey = await encryptMessage(roomAesKey.value, pasteKey)
    
    const form = new FormData()
    form.append('title', pasteTitle.value)
    form.append('wrapped_key_ct', wrappedKey.ct)
    form.append('wrapped_key_iv', wrappedKey.iv)
    form.append('wrapped_key_tag', wrappedKey.tag)

    if (pasteMode.value === 'file') {
      pasteProgress.value = 30
      const arrayBuffer = await pasteFile.value.arrayBuffer()
      const key = await crypto.subtle.importKey(
        'raw', Uint8Array.from(atob(pasteKey), c => c.charCodeAt(0)),
        { name: 'AES-GCM' }, false, ['encrypt']
      )
      const iv = crypto.getRandomValues(new Uint8Array(12))
      const encAes = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, arrayBuffer)
      
      const encBytes = new Uint8Array(encAes)
      const ctBytes = encBytes.slice(0, encBytes.length - 16)
      const tagBytes = encBytes.slice(encBytes.length - 16)

      const combined = new Uint8Array(12 + 16 + ctBytes.length)
      combined.set(iv, 0)
      combined.set(tagBytes, 12)
      combined.set(ctBytes, 28)

      form.append('file', new Blob([combined]), pasteFile.value.name)
      form.append('original_size', pasteFile.value.size)
      form.append('mime_type', pasteFile.value.type)
      form.append('file_name', pasteFile.value.name)
    } else {
      const enc = await encryptMessage(pasteKey, pasteText.value)
      form.append('content_ct', enc.ct)
      form.append('content_iv', enc.iv)
      form.append('content_tag', enc.tag)
    }

    pasteProgress.value = 70

    const res = await api.post(`/rooms/${roomHash}/pastes`, form, {
      onUploadProgress: (e) => {
        if (e.total) pasteProgress.value = 70 + Math.round((e.loaded * 30) / e.total)
      }
    })

    const newPaste = res.data.paste
    const chatPayload = JSON.stringify({
      _type: 'paste',
      paste_hash: newPaste.public_hash,
      title: newPaste.title,
      kind: newPaste.kind,
    })
    const chatEnc = await encryptMessage(roomAesKey.value, chatPayload)
    
    socket.send({
      t: 0, r: room.value.id,
      c: chatEnc.ct, i: chatEnc.iv, g: chatEnc.tag,
    })

    // Optimistic Update for Paste
    messages.value.push({
      id: newPaste.id,
      sender_id: myId.value,
      isPaste: true,
      paste: JSON.parse(chatPayload),
      ts: new Date().toISOString(),
      edit_count: 0,
      deleted_at: null
    })

    closePasteModal()
    scrollToBottom()
  } catch (e) {
    pasteError.value = e.response?.data?.error || e.message || 'Upload failed'
  } finally {
    pasteSubmitting.value = false
  }
}

async function handlePasteClick(paste) {
  const hash = paste.paste_hash
  if (!hash) return
  
  openingPaste.value = hash
  
  openPasteHash.value = hash
  openPasteTitle.value = paste.title
  openPasteKind.value = paste.kind
  openPasteContent.value = ''
  pasteError.value = ''
  showOpenPasteModal.value = true

  try {
    const res = await api.post(`/pastes/${hash}/open`)
    const data = res.data.paste
    openPasteFileName.value = data.file_name

    const actualPasteKey = await decryptMessage(
      roomAesKey.value, data.wrapped_key_encrypted, data.wrapped_key_iv, data.wrapped_key_tag
    )

    if (data.kind === 'text') {
      openPasteContent.value = await decryptMessage(actualPasteKey, data.content_encrypted, data.content_iv, data.content_tag)
    }
  } catch (e) {
    pasteError.value = e.response?.data?.error || 'Failed to decrypt paste'
  } finally {
    openingPaste.value = null
  }
}

function closeOpenPasteModal() {
  showOpenPasteModal.value = false
  openPasteHash.value = ''
  openPasteContent.value = ''
}

async function copyOpenPaste() {
  try {
    await navigator.clipboard.writeText(openPasteContent.value)
    alert('Copied to clipboard')
  } catch (e) { alert('Copy failed') }
}

async function downloadPaste(paste) {
  downloading.value = paste.paste_hash
  downloadProgress.value = 0
  try {
    const res = await api.post(`/pastes/${paste.paste_hash}/open`)
    const data = res.data.paste
    
    const actualPasteKey = await decryptMessage(
      roomAesKey.value, data.wrapped_key_encrypted, data.wrapped_key_iv, data.wrapped_key_tag
    )

    const fileRes = await api.get(`/pastes/${paste.paste_hash}/download`, { responseType: 'arraybuffer' })
    const blob = new Uint8Array(fileRes.data)
    
    const iv = blob.slice(0, 12)
    const tag = blob.slice(12, 28)
    const ct = blob.slice(28)
    
    function uint8ToBase64(bytes) {
      let binary = ''
      const chunkSize = 8192
      for (let i = 0; i < bytes.length; i += chunkSize) {
        const chunk = bytes.subarray(i, i + chunkSize)
        binary += String.fromCharCode.apply(null, chunk)
      }
      return btoa(binary)
    }
    
    const ctB64 = uint8ToBase64(ct)
    const ivB64 = uint8ToBase64(iv)
    const tagB64 = uint8ToBase64(tag)
    
    const ptBytes = await decryptBytes(actualPasteKey, ctB64, ivB64, tagB64)
    const downloadBlob = new Blob([ptBytes], { type: data.mime_type })
    
    const url = window.URL.createObjectURL(downloadBlob)
    const a = document.createElement('a')
    a.href = url
    a.download = data.file_name || data.title
    a.click()
    window.URL.revokeObjectURL(url)
  } catch (e) {
    alert('Download failed')
  } finally {
    downloading.value = null
    downloadProgress.value = 0
  }
}

// ==========================================
// INVITES & MANAGE
// ==========================================

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
    if (!user.kyber_public_key) {
      throw new Error(`${user.username} has not generated a PQC identity yet.`)
    }

    const targetPkBytes = Uint8Array.from(atob(user.kyber_public_key), c => c.charCodeAt(0))
    const kem = MlKemKeyPair.importKeys(new Uint8Array(0), targetPkBytes)
    let payload
    try {
      const res = kem.encapsulate()
      const ct = new Uint8Array(res[0])
      const ss = new Uint8Array(res[1])

      const sharedKey = await crypto.subtle.importKey('raw', ss, { name: 'AES-GCM' }, false, ['encrypt'])
      const iv = crypto.getRandomValues(new Uint8Array(12))
      const encAes = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, sharedKey, new TextEncoder().encode(roomAesKey.value))

      payload = JSON.stringify({
        ct: btoa(String.fromCharCode(...ct)),
        iv: btoa(String.fromCharCode(...iv)),
        enc_aes: btoa(String.fromCharCode(...new Uint8Array(encAes)))
      })
    } finally {
      if (kem && kem.free) kem.free()
    }

    await api.post(`/rooms/${roomHash}/invite`, {
      user_id: user.id,
      target_kyber_ciphertext: payload
    })

    inviteMessage.value = `invited ${user.username}`
    inviteResults.value = inviteResults.value.filter((u) => u.id !== user.id)
    memberCount.value += 1
    rememberName(user.id, user.username)
  } catch (e) {
    inviteMessage.value = e.message || 'Invite failed'
  }
}

function toggleInvite() {
  showInvite.value = !showInvite.value
  if (showInvite.value) { showSearch.value = false; closeManage() }
  inviteQuery.value = ''
  inviteResults.value = []
  inviteMessage.value = ''
  inviteError.value = ''
}

function toggleSearch() {
  showSearch.value = !showSearch.value
  if (showSearch.value) { showInvite.value = false; closeManage() }
  if (!showSearch.value) {
    searchQuery.value = ''
    searchResults.value = []
    searchDone.value = false
    searchError.value = ''
  }
}

function openManage() {
  showManage.value = true
  showInvite.value = false
  showSearch.value = false
  manageQuery.value = ''
  manageResults.value = []
  manageError.value = ''
}

function closeManage() {
  showManage.value = false
  manageQuery.value = ''
  manageResults.value = []
  manageError.value = ''
  clearTimeout(manageDebounce)
}

function onManageInput() {
  clearTimeout(manageDebounce)
  manageDebounce = setTimeout(runManageSearch, 300)
}

async function runManageSearch() {
  const q = manageQuery.value.trim()
  if (!q) { manageResults.value = []; return }
  manageSearching.value = true
  manageError.value = ''
  try {
    const res = await api.get(`/rooms/${roomHash}/members`, {
      params: { q, limit: 20, offset: 0 },
    })
    for (const m of res.data.members) rememberName(m.user_id, m.username)
    manageResults.value = res.data.members
  } catch (e) {
    manageError.value = e.response?.data?.error || 'Search failed'
  } finally {
    manageSearching.value = false
  }
}

async function removeMember(m) {
  if (!confirm(`Remove ${m.username} from this room?`)) return
  manageLoading.value = true
  manageError.value = ''
  try {
    await api.post(`/rooms/${roomHash}/remove`, { user_id: m.user_id })
    manageResults.value = manageResults.value.filter(x => x.user_id !== m.user_id)
    memberCount.value = Math.max(0, memberCount.value - 1)
    
    const nextMap = { ...userNames.value }
    delete nextMap[m.user_id]
    userNames.value = nextMap
  } catch (e) {
    manageError.value = e.response?.data?.error || 'Remove failed'
  } finally {
    manageLoading.value = false
  }
}

async function runSearch() {
  const q = searchQuery.value.trim().toLowerCase()
  if (!q) { searchResults.value = []; searchDone.value = false; return }
  searching.value = true
  searchError.value = ''
  searchDone.value = false
  searchResults.value = []
  try {
    let before = null
    let pages = 0
    while (pages < 20) {
      const params = before ? { before } : {}
      const res = await api.get(`/rooms/${roomHash}/messages`, { params })
      const batch = res.data.messages
      if (!batch.length) break
      for (const m of batch) {
        if (m.sender_username) rememberName(m.sender_id, m.sender_username)
        const d = await decryptOne(m)
        if (d.isPaste || d.deleted || d.error) continue
        if (d.text && d.text.toLowerCase().includes(q)) {
          searchResults.value.push({ id: m.id, sender_id: m.sender_id, text: d.text, ts: m.ts })
        }
      }
      before = batch[0].id
      pages++
      if (batch.length < 100) break
    }
    searchDone.value = true
  } catch (e) {
    searchError.value = e.response?.data?.error || 'Search failed'
  } finally {
    searching.value = false
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

onMounted(async () => {
  isComponentMounted = true
  try {
    const configRes = await api.get('/config')
    if (configRes.data.max_paste_size) maxPasteSize.value = configRes.data.max_paste_size
  } catch(e) {}

  try {
    await loadMe()
    const ok = await loadRoom()
    if (!ok) { initialLoading.value = false; return }
    
    loadNames()
    
    if (room.value.is_member) needsUnlock.value = true
  } catch (e) {
    if (e.response?.status === 404) error.value = 'Room not found.'
    else if (e.response?.status === 403) error.value = 'You do not have access to this room.'
    else error.value = e.response?.data?.error || e.message
  } finally {
    initialLoading.value = false
  }
})

onBeforeUnmount(() => {
  isComponentMounted = false
  isConnected.value = false
  unsubs.forEach((fn) => fn())
  unsubs = []
  if (socket) socket.send({ t: 4 })
  if (typingCleanupTimer) clearInterval(typingCleanupTimer)
  if (highlightTimer) clearTimeout(highlightTimer)
  clearTimeout(manageDebounce)
})
</script>

<template>
  <div class="flex flex-col h-[calc(100dvh-3.5rem)] lg:h-[calc(100dvh-3rem)] -my-6 -mx-4 sm:-mx-6 font-mono relative">
    <!-- Header -->
    <div class="flex items-center justify-between px-4 sm:px-6 py-3 border-b border-gray-800 bg-gray-950/80 backdrop-blur sticky top-0 z-10">
      <div class="min-w-0 flex items-center gap-2 flex-1">
        <button @click="router.push('/rooms')" class="text-gray-500 hover:text-emerald-400 text-sm flex-shrink-0" title="Back to rooms">&lt;</button>
        <span class="text-emerald-400 flex-shrink-0">{{ room && room.type === 'channel' ? '#' : room && room.type === 'private' ? '@' : '>' }}</span>
        <span class="text-white font-medium truncate">{{ room ? room.name : 'room' }}</span>
        <span v-if="!isSocketConnected" class="text-xs text-red-500 animate-pulse ml-2 flex-shrink-0" title="Reconnecting...">● offline</span>
      </div>
      <div class="flex items-center gap-1 flex-shrink-0" v-if="room && room.is_member">
        <button
          @click="toggleSearch"
          :class="['px-2.5 py-1 rounded-md text-xs transition-colors', showSearch ? 'bg-gray-800 text-emerald-400' : 'text-gray-400 hover:bg-gray-800 hover:text-white']"
          title="Search messages">⌕</button>

        <button
          @click="router.push(`/rooms/${roomHash}/members`)"
          class="px-2.5 py-1 rounded-md text-xs text-gray-400 hover:bg-gray-800 hover:text-white"
          title="View all members"
        >
          members <span class="text-gray-600">({{ memberCount }})</span>
        </button>

        <button
          v-if="canManage"
          @click="openManage"
          :class="['px-2.5 py-1 rounded-md text-xs transition-colors', showManage ? 'bg-red-500/10 text-red-400' : 'text-gray-400 hover:bg-gray-800 hover:text-white']"
          title="Manage members"
        >
          manage
        </button>

        <button
          v-if="canManage"
          @click="toggleInvite"
          :class="['px-2.5 py-1 rounded-md text-xs transition-colors', showInvite ? 'bg-emerald-500/10 text-emerald-400' : 'text-gray-400 hover:bg-gray-800 hover:text-white']"
        >
          + invite
        </button>

        <button
          v-if="room && room.is_member && (room.owner_id !== myId || (room.is_ephemeral && memberCount === 1))"
          @click="leaveRoom"
          class="px-2.5 py-1 rounded-md text-xs text-gray-400 hover:bg-red-500/10 hover:text-red-400 transition-colors"
          title="Leave this room"
        >
          leave
        </button>

        <button
          v-if="room && room.is_member && room.owner_id === myId"
          @click="deleteRoom"
          class="px-2.5 py-1 rounded-md text-xs text-gray-400 hover:bg-red-500/20 hover:text-red-300 transition-colors font-bold"
          title="Delete this room permanently"
        >
          delete room
        </button>
      </div>
    </div>

    <!-- Invite Panel -->
    <div v-if="showInvite" class="px-4 sm:px-6 py-3 border-b border-gray-800 bg-gray-900 z-20">
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

    <!-- Search Panel -->
    <div v-if="showSearch" class="px-4 sm:px-6 py-3 border-b border-gray-800 bg-gray-900 z-20">
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

    <!-- Unlock Screen -->
    <div v-if="needsUnlock" class="flex-1 flex items-center justify-center p-6 relative z-10">
      <div class="bg-gray-900 border border-gray-800 rounded-lg p-6 w-full max-w-md">
        <h3 class="text-white text-lg mb-2">Unlock Room</h3>
        
        <p v-if="room.is_public" class="text-xs text-gray-400 mb-4">
          This is a public {{ room.type === 'channel' ? 'channel' : 'room' }}. Just click unlock to load the messages.
        </p>
        <p v-else class="text-xs text-gray-400 mb-4">
          Enter your passphrase to decrypt this private {{ room.type === 'channel' ? 'channel' : 'room' }}.
        </p>
        
        <input
          v-if="!room.is_public"
          v-model="passphrase"
          type="password"
          placeholder="passphrase"
          class="w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm mb-3 focus:outline-none focus:border-emerald-500"
        />
        
        <button
          @click="unlockRoom"
          :disabled="unlocking"
          class="w-full bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold py-2 rounded-md text-sm disabled:bg-gray-700"
        >
          {{ unlocking ? 'Unlocking...' : 'Unlock' }}
        </button>
        <p v-if="error" class="text-xs text-red-400 mt-2">{{ error }}</p>
        <p v-if="keyMissing" class="text-xs text-yellow-400 mt-2">
          // no key envelope for you yet — ask the owner to re-invite you
        </p>
      </div>
    </div>

    <!-- Not a member Screen -->
    <div v-if="needsInvite" class="px-4 sm:px-6 py-8 text-center flex flex-col items-center justify-center flex-1">
      <p class="text-sm text-gray-400 mb-2">You are not a member of this room.</p>
      <p class="text-xs text-gray-500 mb-4">This room is private and end-to-end encrypted. You must be invited by the owner.</p>
      <button @click="router.push('/rooms')" class="px-5 py-2 rounded-md bg-gray-800 hover:bg-gray-700 text-gray-300 font-bold text-sm transition-colors">
        &lt; back to rooms
      </button>
    </div>

    <!-- Main Chat Area -->
    <template v-if="!needsUnlock && !needsInvite && !error">
      <div ref="logEl" @scroll="onScroll" class="flex-1 overflow-y-auto px-4 sm:px-6 py-4 space-y-1">
        <div v-if="loadingOlder" class="text-center text-xs text-gray-500 py-2">loading older messages...</div>
        <div v-else-if="!hasMore && messages.length" class="text-center text-xs text-gray-600 py-2">// start of conversation</div>
        <div v-if="!messages.length" class="text-center text-xs text-gray-600 py-8">// no messages yet</div>

        <div
          v-for="m in messages"
          :key="m.id + (m.deleted_at ? '_deleted' : '')"
          :data-mid="m.id"
          @mouseenter="hoveredMessageId = m.id"
          @mouseleave="hoveredMessageId = null"
          :class="['group flex gap-2 rounded-md transition-colors relative', m.sender_id === myId ? 'justify-end' : 'justify-start']"
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

            <!-- Deleted State -->
            <template v-if="m.deleted_at">
              <div class="px-3 py-2 rounded-2xl text-sm italic text-gray-500 border border-gray-800 bg-gray-900/50">
                [deleted message]
              </div>
            </template>

            <!-- Paste State -->
            <template v-else-if="m.isPaste">
              <div 
                @click="handlePasteClick(m.paste)"
                class="border border-cyan-500/40 bg-cyan-500/5 hover:bg-cyan-500/10 cursor-pointer rounded-lg p-3 min-w-[260px] max-w-full transition-colors"
              >
                <div class="flex items-center gap-2">
                  <span class="text-cyan-400 text-lg">📎</span>
                  <div class="min-w-0">
                    <div class="text-white font-medium truncate">{{ m.paste.title }}</div>
                    <div class="text-[10px] text-gray-500 mt-0.5">by {{ nameOf(m.sender_id) }} · {{ m.paste.kind }}</div>
                  </div>
                </div>
                <div v-if="openingPaste === m.paste.paste_hash" class="text-xs text-cyan-400 mt-2 animate-pulse">
                  Decrypting...
                </div>
              </div>
            </template>

            <!-- Decrypt Error -->
            <template v-else-if="m.decryptError">
              <div class="px-3 py-2 rounded-2xl text-sm italic text-yellow-500 border border-yellow-500/30 bg-yellow-500/5">
                [could not decrypt]
              </div>
            </template>

            <!-- Editing State -->
            <template v-else-if="editingMessageId === m.id">
              <div class="flex flex-col gap-2 items-end w-full">
                <input 
                  v-model="editingText" 
                  @keyup.enter="saveEdit(m)" 
                  @keyup.escape="cancelEdit"
                  class="w-full min-w-[300px] bg-gray-900 border border-emerald-500/50 text-gray-100 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500"
                  autofocus
                />
                <div class="flex gap-2 text-xs">
                  <button @click="cancelEdit" class="text-gray-400 hover:text-white">cancel</button>
                  <button @click="saveEdit(m)" class="text-emerald-400 hover:text-emerald-300 font-bold">save</button>
                </div>
              </div>
            </template>

            <!-- Normal Message -->
            <template v-else>
              <div 
                :class="[
                  'px-3 py-2 rounded-2xl text-sm whitespace-pre-wrap break-words border relative', 
                  m.sender_id === myId 
                    ? 'bg-emerald-600/20 text-emerald-100 border-emerald-600/30 rounded-tr-sm' 
                    : 'bg-gray-800 text-gray-100 border-gray-700 rounded-tl-sm',
                  m.loading ? 'opacity-50 italic' : ''
                ]"
              >
                {{ m.text }}
                
                <!-- HOVER ACTIONS (EDIT/DELETE) -->
                <div 
                  v-if="m.sender_id === myId && !m.loading && hoveredMessageId === m.id && !(typeof m.id === 'string' && m.id.startsWith('temp-'))" 
                  class="absolute -top-3 -left-16 flex gap-1 bg-gray-900 border border-gray-800 rounded-md px-1 py-0.5 shadow-lg z-10"
                >
                  <button @click="startEdit(m)" class="text-gray-400 hover:text-cyan-400 p-1" title="Edit">
                    <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 21.036H3v-3.572L16.732 3.732z"/></svg>
                  </button>
                  <button @click="deleteMessage(m)" class="text-gray-400 hover:text-red-400 p-1" title="Delete">
                    <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>
                  </button>
                </div>
              </div>
            </template>
          </div>
        </div>
      </div>

      <div class="border-t border-gray-800 bg-gray-950">
        <div v-if="typingLabel" class="px-4 sm:px-6 pt-2 text-xs text-gray-500 italic">{{ typingLabel }}</div>
        <form @submit.prevent="send" class="px-4 sm:px-6 py-3">
          <div v-if="isReadOnly" class="text-xs text-gray-500 py-1">// read-only channel</div>
          <div v-else class="flex gap-2 items-center">
            <span class="text-emerald-400 font-bold">&gt;</span>
            <input v-model="input" @input="onInput" placeholder="type a message..." class="flex-1 bg-transparent text-gray-100 px-0 py-2 text-sm focus:outline-none placeholder-gray-600" />
            
            <!-- PAPERCLIP ON THE RIGHT -->
            <button type="button" @click="showPasteModal = true" class="text-gray-400 hover:text-cyan-400 text-lg px-2 transition-colors flex-shrink-0" title="Attach file or paste">
              📎
            </button>
            
            <button type="submit" :disabled="!input.trim() || sending" class="px-4 py-1.5 rounded-md bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold text-sm transition-colors disabled:bg-gray-800 disabled:text-gray-600">send</button>
          </div>
        </form>
      </div>
    </template>

    <!-- Error -->
    <div v-if="error && !needsUnlock && !needsInvite" class="px-4 sm:px-6 py-8 text-center">
      <ErrorBanner :message="error" />
      <button @click="router.push('/rooms')" class="text-xs text-emerald-400 hover:underline mt-2">&lt; back to rooms</button>
    </div>

    <LoadingSpinner v-if="initialLoading" label="loading..." />

    <!-- Paste creation modal -->
    <div v-if="showPasteModal" class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4" @click.self="closePasteModal">
      <div class="bg-gray-900 border border-gray-800 rounded-lg w-full max-w-lg p-5 font-mono">
        <div class="flex items-center justify-between mb-4">
          <div class="text-sm text-white"><span class="text-cyan-400">📋</span> new secure paste</div>
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
          <div class="text-[10px] text-gray-600 mt-1">max {{ Math.round(maxPasteSize / 1024 / 1024) }} MB</div>
        </div>

        <div v-else class="mb-3">
          <input type="file" @change="onPasteFile" class="w-full text-xs text-gray-400 file:mr-2 file:py-1.5 file:px-3 file:rounded-md file:border-0 file:bg-gray-800 file:text-cyan-400 file:font-mono file:cursor-pointer hover:file:bg-gray-700" />
          <div class="text-[10px] text-gray-600 mt-1">max {{ Math.round(maxPasteSize / 1024 / 1024) }} MB</div>
        </div>

        <div v-if="pasteSubmitting" class="mb-3">
          <div class="h-1 bg-gray-800 rounded overflow-hidden">
            <div class="h-full bg-cyan-500 transition-all" :style="{ width: pasteProgress + '%' }"></div>
          </div>
          <div class="text-[10px] text-gray-500 mt-1">{{ pasteProgress }}%</div>
        </div>

        <p v-if="pasteError" class="text-xs text-red-400 mb-2">{{ pasteError }}</p>

        <div class="flex justify-end gap-2">
          <button @click="closePasteModal" class="px-3 py-1.5 rounded-md text-gray-400 hover:text-white text-xs">cancel</button>
          <button @click="submitPaste" :disabled="pasteSubmitting" class="px-4 py-1.5 rounded-md bg-cyan-600 hover:bg-cyan-500 text-gray-950 font-bold text-xs transition-colors disabled:bg-gray-700 disabled:text-gray-500">
            {{ pasteSubmitting ? '...' : '> encrypt & create' }}
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
          </div>
        </div>
      </div>
    </div>

    <!-- Manage members slide-over -->
    <teleport to="body">
      <div v-if="showManage" class="fixed inset-0 z-50 flex font-mono">
        <div class="flex-1 bg-black/50" @click="closeManage"></div>
        <div class="w-full max-w-md h-full bg-gray-900 border-l border-gray-800 flex flex-col">
          <div class="h-14 flex items-center justify-between px-4 border-b border-gray-800 flex-shrink-0">
            <div class="text-sm text-white">
              <span class="text-red-400">!</span> manage members
            </div>
            <button @click="closeManage" class="text-gray-500 hover:text-white">✕</button>
          </div>

          <div class="p-4 border-b border-gray-800 flex-shrink-0">
            <input
              v-model="manageQuery"
              @input="onManageInput"
              placeholder="search username to remove"
              autocomplete="off"
              class="w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600"
            />
            <p class="text-[10px] text-gray-600 mt-1">// type to search, click ✕ to remove from room</p>
            <p v-if="manageError" class="text-xs text-red-400 mt-2">{{ manageError }}</p>
          </div>

          <div class="flex-1 overflow-y-auto p-4">
            <div v-if="manageSearching" class="text-xs text-gray-500">searching...</div>
            <div v-else-if="!manageQuery.trim()" class="text-xs text-gray-600">
              // start typing to search members
            </div>
            <div v-else-if="!manageResults.length" class="text-xs text-gray-600">
              // no matches
            </div>
            <ul v-else class="space-y-1">
              <li
                v-for="m in manageResults"
                :key="m.user_id"
                class="flex items-center gap-2 bg-gray-950 border border-gray-800 rounded-md px-3 py-2"
              >
                <span class="w-7 h-7 rounded-full bg-gray-800 flex items-center justify-center text-[10px] text-emerald-400 font-bold flex-shrink-0">
                  {{ m.username.slice(0,2).toUpperCase() }}
                </span>
                <div class="min-w-0 flex-1">
                  <div class="text-sm text-gray-200 truncate">{{ m.username }}</div>
                  <div class="text-[10px] text-gray-600">[{{ m.role }}]</div>
                </div>
                <button
                  v-if="m.role !== 'owner' && m.user_id !== myId"
                  @click="removeMember(m)"
                  :disabled="manageLoading"
                  class="text-xs text-red-400 hover:text-red-300 disabled:text-gray-600 flex-shrink-0"
                >
                  ✕ remove
                </button>
                <span v-else class="text-[10px] text-gray-600 flex-shrink-0">
                  {{ m.role === 'owner' ? 'owner' : 'you' }}
                </span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </teleport>
  </div>
</template>
