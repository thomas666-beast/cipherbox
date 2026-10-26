<script setup>
import { ref, onMounted } from 'vue'
import { encryptMessage, generateAesKey } from '../../core/crypto'
import api from '../../core/api'

const props = defineProps({
  roomId: { type: [String, Number], required: true },
  roomAesKey: { type: String, required: true }
})
const emit = defineEmits(['close', 'created'])

const title = ref('')
const text = ref('')
const file = ref(null)
const uploading = ref(false)
const progress = ref(0)
const error = ref('')

// Default to 10MB, but we will fetch the real limit from the server
const maxPasteSize = ref(10 * 1024 * 1024)

onMounted(async () => {
  try {
    const res = await api.get('/config')
    if (res.data.max_paste_size) {
      maxPasteSize.value = res.data.max_paste_size
    }
  } catch (e) {
    console.error('Failed to load config', e)
  }
})

function onFileChange(e) {
  const f = e.target.files[0]
  if (f && f.size > maxPasteSize.value) {
    error.value = `File too large. Max ${Math.round(maxPasteSize.value / 1024 / 1024)}MB.`
    file.value = null
    e.target.value = ''
    return
  }
  file.value = f || null
  error.value = ''
}

async function submit() {
  if (!title.value) {
    error.value = 'Please enter a title.'
    return
  }
  if (!text.value && !file.value) {
    error.value = 'Please provide text or a file.'
    return
  }

  uploading.value = true
  error.value = ''
  progress.value = 10

  try {
    // 1. Generate a unique paste key
    const pasteKey = await generateAesKey()
    progress.value = 30

    // 2. Wrap the paste key using the room AES key
    const wrappedKey = await encryptMessage(props.roomAesKey, pasteKey)
    progress.value = 50

    const form = new FormData()
    form.append('title', title.value)
    form.append('wrapped_key_ct', wrappedKey.ct)
    form.append('wrapped_key_iv', wrappedKey.iv)
    form.append('wrapped_key_tag', wrappedKey.tag)

    if (file.value) {
      // FILE UPLOAD
      const arrayBuffer = await file.value.arrayBuffer()
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

      const encryptedBlob = new Blob([combined])
      
      form.append('file', encryptedBlob, file.value.name)
      form.append('original_size', file.value.size)
      form.append('mime_type', file.value.type)
      form.append('file_name', file.value.name)
      
    } else {
      // TEXT UPLOAD
      const enc = await encryptMessage(pasteKey, text.value)
      form.append('content_ct', enc.ct)
      form.append('content_iv', enc.iv)
      form.append('content_tag', enc.tag)
    }

    progress.value = 70

    const res = await api.post(`/rooms/${props.roomId}/pastes`, form, {
      onUploadProgress: (e) => {
        if (e.total) {
          progress.value = 70 + Math.round((e.loaded * 30) / e.total)
        }
      }
    })

    emit('created', res.data.paste)
    emit('close')
  } catch (e) {
    error.value = e.response?.data?.error || e.message || 'Upload failed'
  } finally {
    uploading.value = false
  }
}
</script>

<template>
  <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 font-mono">
    <div class="bg-gray-900 border border-gray-800 rounded-lg p-6 w-full max-w-md">
      <h3 class="text-white text-lg mb-4">Create Secure Paste</h3>
      
      <div class="flex flex-col gap-3">
        <input 
          v-model="title" 
          placeholder="Title" 
          class="bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm outline-none focus:border-emerald-500" 
        />
        
        <textarea 
          v-if="!file" 
          v-model="text" 
          placeholder="Paste text here..." 
          rows="4" 
          class="bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm outline-none focus:border-emerald-500"
        ></textarea>
        
        <input 
          type="file" 
          @change="onFileChange" 
          class="text-xs text-gray-400 file:mr-2 file:py-1 file:px-3 file:rounded-md file:border-0 file:bg-gray-800 file:text-emerald-400 file:cursor-pointer" 
        />
        
        <div v-if="progress > 0 && progress < 100" class="w-full bg-gray-800 rounded-full h-2 mt-2">
          <div class="bg-emerald-500 h-2 rounded-full transition-all" :style="{ width: progress + '%' }"></div>
        </div>
        
        <p v-if="error" class="text-xs text-red-400">{{ error }}</p>
        
        <div class="flex justify-end gap-2 mt-2">
          <button @click="emit('close')" class="px-4 py-2 text-sm text-gray-400 hover:text-white">Cancel</button>
          <button 
            @click="submit" 
            :disabled="uploading" 
            class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold text-sm rounded-md disabled:bg-gray-700"
          >
            {{ uploading ? 'Encrypting...' : 'Encrypt & Upload' }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
