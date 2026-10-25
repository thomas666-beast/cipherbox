<script setup>
import { ref, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import api from '../../core/api'
import { useAuthStore } from '../../core/auth'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import EmptyState from '../../components/EmptyState.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const categoryHash = route.params.hash

const subcategories = ref([])
const items = ref([])
const category = ref(null)
const error = ref('')
const loading = ref(true)

const newName = ref('')
const newType = ref('book')

const uploadTitle = ref('')
const uploadFile = ref(null)
const uploadMessage = ref('')
const uploading = ref(false)

const editingItemId = ref(null)
const editingTitle = ref('')

async function load() {
  loading.value = true
  error.value = ''
  try {
    const catRes = await api.get(`/library/categories/${categoryHash}`)
    category.value = catRes.data.category

    const cats = await api.get('/library/categories', { params: { parent_id: categoryHash } })
    subcategories.value = cats.data.categories

    const its = await api.get(`/library/categories/${categoryHash}/items`)
    items.value = its.data.items
  } catch (e) {
    if (e.response?.status === 404) {
      error.value = 'category not found'
    } else {
      error.value = e.response?.data?.error || 'Failed to load category'
    }
  } finally {
    loading.value = false
  }
}

async function createSubcategory() {
  if (!newName.value.trim()) return
  try {
    await api.post('/library/categories', {
      name: newName.value.trim(),
      type: newType.value,
      parent_id: categoryHash,
    })
    newName.value = ''
    await load()
  } catch (e) {
    alert(e.response?.data?.error || 'Create failed')
  }
}

function onFileChange(e) {
  uploadFile.value = e.target.files[0] || null
}

async function upload() {
  uploadMessage.value = ''
  if (!uploadTitle.value.trim() || !uploadFile.value) return
  uploading.value = true
  try {
    const form = new FormData()
    form.append('title', uploadTitle.value.trim())
    form.append('category_id', categoryHash)
    form.append('file', uploadFile.value)
    await api.post('/library/items', form)
    uploadMessage.value = 'uploaded'
    uploadTitle.value = ''
    uploadFile.value = null
    const fileInput = document.getElementById('upload-file')
    if (fileInput) fileInput.value = ''
    await load()
  } catch (e) {
    uploadMessage.value = e.response?.data?.error || 'Upload failed'
  } finally {
    uploading.value = false
  }
}

async function download(item) {
  try {
    const res = await api.get(`/library/items/${item.public_hash}/download`, { responseType: 'blob' })
    const url = window.URL.createObjectURL(res.data)
    const a = document.createElement('a')
    a.href = url
    a.download = item.title
    a.click()
    window.URL.revokeObjectURL(url)
  } catch (e) {
    alert('Download failed')
  }
}

async function deleteCategory(cat) {
  if (!confirm(`Delete category "${cat.name}" and everything inside it?`)) return
  try {
    await api.delete(`/library/categories/${cat.public_hash}`)
    await load()
  } catch (e) {
    alert(e.response?.data?.error || 'Delete failed')
  }
}

async function deleteItem(item) {
  if (!confirm(`Delete item "${item.title}"?`)) return
  try {
    await api.delete(`/library/items/${item.public_hash}`)
    await load()
  } catch (e) {
    alert(e.response?.data?.error || 'Delete failed')
  }
}

async function deleteCurrentCategory() {
  if (!category.value) return
  if (!confirm(`Delete category "${category.value.name}" and everything inside it?`)) return
  try {
    await api.delete(`/library/categories/${categoryHash}`)
    router.push('/library')
  } catch (e) {
    alert(e.response?.data?.error || 'Delete failed')
  }
}

function startEditItem(item) {
  editingItemId.value = item.public_hash
  editingTitle.value = item.title
}

function cancelEdit() {
  editingItemId.value = null
  editingTitle.value = ''
}

async function saveEditItem(item) {
  if (!editingTitle.value.trim()) return
  try {
    await api.patch(`/library/items/${item.public_hash}`, { title: editingTitle.value.trim() })
    cancelEdit()
    await load()
  } catch (e) {
    alert(e.response?.data?.error || 'Rename failed')
  }
}

function typeIcon(type) {
  if (type === 'audio') return '♪'
  if (type === 'video') return '▶'
  return '▤'
}

function typeColor(type) {
  if (type === 'audio') return 'text-yellow-400'
  if (type === 'video') return 'text-red-400'
  return 'text-cyan-400'
}

function sizeLabel(bytes) {
  if (!bytes) return '0 B'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`
}

onMounted(load)
watch(() => route.params.hash, load)
</script>

<template>
  <div class="font-mono">
    <div class="flex items-center gap-2 text-sm mb-2">
      <button @click="router.push('/library')" class="text-gray-500 hover:text-emerald-400">&lt;</button>
      <router-link to="/library" class="text-gray-400 hover:text-emerald-400">library</router-link>
      <span class="text-gray-600">/</span>
      <span v-if="category" class="text-white font-medium">{{ category.name }}</span>
    </div>
    <p v-if="category" class="text-xs text-gray-500 mb-6">
      [{{ category.type }}]
      <button v-if="auth.isAdmin" @click="deleteCurrentCategory" class="ml-3 text-red-400 hover:text-red-300">delete category</button>
    </p>

    <ErrorBanner v-if="error" :message="error" />

    <LoadingSpinner v-if="loading" label="loading category..." />

    <template v-else-if="!error">
      <div v-if="auth.isAdmin" class="grid sm:grid-cols-2 gap-3 mb-6">
        <form @submit.prevent="createSubcategory" class="bg-gray-900 border border-gray-800 rounded-lg p-4">
          <div class="text-xs text-gray-500 mb-3">// new subcategory</div>
          <div class="flex flex-col gap-2">
            <input v-model="newName" placeholder="subcategory name" class="bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500/50 placeholder-gray-600" />
            <div class="flex gap-2">
              <select v-model="newType" class="flex-1 bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-cyan-500">
                <option value="book">books</option>
                <option value="audio">audio</option>
                <option value="video">video</option>
              </select>
              <button type="submit" class="bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold px-4 rounded-md text-sm transition-colors">+ create</button>
            </div>
          </div>
        </form>

        <form @submit.prevent="upload" class="bg-gray-900 border border-gray-800 rounded-lg p-4">
          <div class="text-xs text-gray-500 mb-3">// upload item</div>
          <div class="flex flex-col gap-2">
            <input v-model="uploadTitle" placeholder="item title" class="bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500/50 placeholder-gray-600" />
            <div class="flex gap-2 items-center">
              <input id="upload-file" type="file" @change="onFileChange" class="flex-1 min-w-0 text-xs text-gray-400 file:mr-2 file:py-1 file:px-3 file:rounded-md file:border-0 file:bg-gray-800 file:text-emerald-400 file:font-mono file:cursor-pointer hover:file:bg-gray-700" />
              <button type="submit" :disabled="uploading" class="bg-cyan-600 hover:bg-cyan-500 text-gray-950 font-bold px-4 py-2 rounded-md text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500 flex-shrink-0">{{ uploading ? '...' : '↑ upload' }}</button>
            </div>
            <p v-if="uploadMessage" class="text-xs text-emerald-400">{{ uploadMessage }}</p>
          </div>
        </form>
      </div>

      <section v-if="subcategories.length" class="mb-6">
        <div class="text-xs text-gray-500 mb-2">// subcategories</div>
        <ul class="space-y-2">
          <li v-for="c in subcategories" :key="c.id">
            <router-link :to="`/library/category/${c.public_hash}`" class="flex items-center gap-3 bg-gray-900 border border-gray-800 hover:border-emerald-500/40 rounded-lg px-4 py-3 transition-colors group">
              <span :class="['text-lg leading-none flex-shrink-0', typeColor(c.type)]">{{ typeIcon(c.type) }}</span>
              <span class="text-white font-medium truncate flex-1">{{ c.name }}</span>
              <span class="text-xs text-gray-500 flex-shrink-0">[{{ c.type }}]</span>
              <button v-if="auth.isAdmin" @click.prevent.stop="deleteCategory(c)" class="text-xs text-red-400 hover:text-red-300 opacity-0 group-hover:opacity-100 flex-shrink-0">delete</button>
              <span class="text-emerald-400 flex-shrink-0">→</span>
            </router-link>
          </li>
        </ul>
      </section>

      <section>
        <div class="text-xs text-gray-500 mb-2">// items ({{ items.length }})</div>
        <ul v-if="items.length" class="space-y-2">
          <li v-for="it in items" :key="it.id">
            <div class="bg-gray-900 border border-gray-800 rounded-lg px-4 py-3">
              <div class="flex items-start gap-3">
                <span class="text-cyan-400 text-lg leading-none mt-0.5 flex-shrink-0">▤</span>
                <div class="flex-1 min-w-0">
                  <template v-if="editingItemId === it.public_hash">
                    <div class="flex flex-wrap gap-2 items-center">
                      <input v-model="editingTitle" @keyup.enter="saveEditItem(it)" @keyup.escape="cancelEdit" class="flex-1 min-w-0 bg-gray-950 border border-emerald-500/40 text-emerald-200 px-2 py-1 rounded-md text-sm focus:outline-none focus:border-emerald-500" />
                      <button @click="saveEditItem(it)" class="text-xs text-emerald-400 hover:text-emerald-300">save</button>
                      <button @click="cancelEdit" class="text-xs text-gray-500 hover:text-gray-400">cancel</button>
                    </div>
                  </template>
                  <template v-else>
                    <div class="text-white font-medium truncate">{{ it.title }}</div>
                    <div class="text-xs text-gray-500 mt-0.5 truncate">{{ it.mime_type }} · {{ sizeLabel(it.file_size) }} · by <span class="text-gray-400">{{ it.uploaded_by }}</span></div>
                    <div class="flex flex-wrap gap-3 text-xs mt-2 sm:hidden">
                      <button @click="download(it)" class="text-emerald-400 hover:text-emerald-300">↓ get</button>
                      <button v-if="auth.isAdmin" @click="startEditItem(it)" class="text-cyan-400 hover:text-cyan-300">rename</button>
                      <button v-if="auth.isAdmin" @click="deleteItem(it)" class="text-red-400 hover:text-red-300">delete</button>
                    </div>
                  </template>
                </div>
                <div v-if="editingItemId !== it.public_hash" class="hidden sm:flex gap-2 text-xs flex-shrink-0">
                  <button @click="download(it)" class="text-emerald-400 hover:text-emerald-300">↓ get</button>
                  <button v-if="auth.isAdmin" @click="startEditItem(it)" class="text-cyan-400 hover:text-cyan-300">rename</button>
                  <button v-if="auth.isAdmin" @click="deleteItem(it)" class="text-red-400 hover:text-red-300">delete</button>
                </div>
              </div>
            </div>
          </li>
        </ul>
        <EmptyState v-else title="no items yet" hint="upload something above" />
      </section>
    </template>
  </div>
</template>
