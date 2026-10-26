<script>
import { defineComponent, h } from 'vue'

const TreeNode = defineComponent({
  name: 'TreeNode',
  props: {
    node: { type: Object, required: true },
    depth: { type: Number, default: 0 },
    selected: { type: String, default: null },
    expanded: { type: Object, default: () => ({}) },
  },
  emits: ['select', 'toggle'],
  setup(props, { emit }) {
    const typeIcon = (t) => t === 'audio' ? '♪' : t === 'video' ? '▶' : '▤'
    const typeColor = (t) => t === 'audio' ? 'text-yellow-400' : t === 'video' ? 'text-red-400' : 'text-cyan-400'

    return () => {
      const hasChildren = props.node.children && props.node.children.length > 0
      const isExpanded = !!props.expanded[props.node.public_hash]
      const isSelected = props.selected === props.node.public_hash

      const row = h('div', {
        class: [
          'flex items-center gap-1 rounded transition-colors',
          isSelected ? 'bg-emerald-500/10' : 'hover:bg-gray-800',
        ].join(' '),
        style: { paddingLeft: (props.depth * 12) + 'px' },
      }, [
        hasChildren
          ? h('button', {
              class: 'text-xs text-gray-500 w-4 flex-shrink-0',
              onClick: (e) => { e.stopPropagation(); emit('toggle', props.node) },
            }, isExpanded ? '▾' : '▸')
          : h('span', { class: 'w-4 flex-shrink-0' }),
        h('button', {
          class: [
            'flex items-center gap-1 flex-1 text-left py-1 text-xs truncate',
            isSelected ? 'text-emerald-400' : 'text-gray-400 hover:text-white',
          ].join(' '),
          onClick: () => emit('select', props.node.public_hash),
        }, [
          h('span', { class: typeColor(props.node.type) }, typeIcon(props.node.type)),
          h('span', { class: 'truncate' }, props.node.name),
        ]),
      ])

      const children = hasChildren && isExpanded
        ? props.node.children.map((child) =>
            h(TreeNode, {
              key: child.id,
              node: child,
              depth: props.depth + 1,
              selected: props.selected,
              expanded: props.expanded,
              onSelect: (hash) => emit('select', hash),
              onToggle: (n) => emit('toggle', n),
            }))
        : []

      return h('div', {}, [row, ...children])
    }
  },
})

export default {
  name: 'LibraryView',
  components: { TreeNode },
}
</script>

<script setup>
import { ref, onMounted, computed, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import api from '../../core/api'
import { useAuthStore } from '../../core/auth'
import LoadingSpinner from '../../components/LoadingSpinner.vue'
import EmptyState from '../../components/EmptyState.vue'
import ErrorBanner from '../../components/ErrorBanner.vue'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const tree = ref([])
const treeLoading = ref(true)
const treeError = ref('')
const expandedNodes = ref({})

const selectedHash = ref(route.params.hash || null)

const category = ref(null)
const subcategories = ref([])
const items = ref([])
const contentLoading = ref(false)
const contentError = ref('')

const newName = ref('')
const newType = ref('book')
const creating = ref(false)
const createError = ref('')

const uploadTitle = ref('')
const uploadFile = ref(null)
const uploadMessage = ref('')
const uploading = ref(false)
const uploadProgress = ref(0)

const editingItemId = ref(null)
const editingTitle = ref('')

const breadcrumb = computed(() => {
  if (!selectedHash.value) return []
  const path = []
  const walk = (nodes, trail) => {
    for (const node of nodes) {
      const t = [...trail, node]
      if (node.public_hash === selectedHash.value) {
        path.push(...t)
        return true
      }
      if (node.children && walk(node.children, t)) return true
    }
    return false
  }
  walk(tree.value, [])
  return path
})

function expandAncestorsOf(hash) {
  if (!hash) return
  const trail = []
  const walk = (nodes) => {
    for (const node of nodes) {
      if (node.public_hash === hash) return true
      trail.push(node.public_hash)
      if (node.children && walk(node.children)) return true
      trail.pop()
    }
    return false
  }
  walk(tree.value)
  for (const h of trail) {
    expandedNodes.value[h] = true
  }
}

async function loadTree() {
  treeLoading.value = true
  treeError.value = ''
  try {
    const res = await api.get('/library/tree')
    tree.value = res.data.tree
  } catch (e) {
    treeError.value = e.response?.data?.error || 'Failed to load library'
  } finally {
    treeLoading.value = false
  }
}

async function loadContent() {
  if (!selectedHash.value) {
    category.value = null
    subcategories.value = []
    items.value = []
    return
  }
  contentLoading.value = true
  contentError.value = ''
  try {
    const catRes = await api.get(`/library/categories/${selectedHash.value}`)
    category.value = catRes.data.category

    const subsRes = await api.get('/library/categories', { params: { parent_id: selectedHash.value } })
    subcategories.value = subsRes.data.categories

    const itemsRes = await api.get(`/library/categories/${selectedHash.value}/items`)
    items.value = itemsRes.data.items
  } catch (e) {
    contentError.value = e.response?.data?.error || 'Failed to load category'
  } finally {
    contentLoading.value = false
  }
}

function toggleNode(node) {
  expandedNodes.value[node.public_hash] = !expandedNodes.value[node.public_hash]
}

function selectCategory(hash) {
  router.push(hash ? `/library/category/${hash}` : '/library')
}

async function createCategory() {
  createError.value = ''
  if (!newName.value.trim()) return
  creating.value = true
  try {
    await api.post('/library/categories', {
      name: newName.value.trim(),
      type: newType.value,
      parent_id: selectedHash.value || undefined,
    })
    newName.value = ''
    
    // Refresh tree and content
    await loadTree()
    if (selectedHash.value) {
      await loadContent()
    }
  } catch (e) {
    createError.value = e.response?.data?.error || 'Failed to create category'
  } finally {
    creating.value = false
  }
}

async function upload() {
  uploadMessage.value = ''
  if (!uploadTitle.value.trim() || !uploadFile.value || !selectedHash.value) return
  uploading.value = true
  uploadProgress.value = 0
  
  try {
    const form = new FormData()
    form.append('title', uploadTitle.value.trim())
    form.append('category_id', selectedHash.value)
    form.append('file', uploadFile.value)

    await api.post('/library/items', form, {
      onUploadProgress: (e) => {
        uploadProgress.value = Math.round((e.loaded * 100) / e.total)
      }
    })
    
    uploadMessage.value = 'uploaded'
    uploadTitle.value = ''
    uploadFile.value = null
    uploadProgress.value = 0
    
    const fileInput = document.getElementById('upload-file')
    if (fileInput) fileInput.value = ''
    
    await loadTree()
    await loadContent()
    
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
  if (!confirm(`Delete "${cat.name}" and everything inside it? This cannot be undone.`)) return
  try {
    await api.delete(`/library/categories/${cat.public_hash}`)
    const wasInPath = breadcrumb.value.some(b => b.public_hash === cat.public_hash)
    if (wasInPath) {
      selectCategory(null)
    } else {
      await loadTree()
    }
  } catch (e) {
    alert(e.response?.data?.error || 'Delete failed')
  }
}

async function deleteItem(item) {
  if (!confirm(`Delete "${item.title}"?`)) return
  try {
    await api.delete(`/library/items/${item.public_hash}`)
    await loadContent()
  } catch (e) {
    alert(e.response?.data?.error || 'Delete failed')
  }
}

async function deleteCurrent() {
  if (!category.value) return
  if (!confirm(`Delete "${category.value.name}" and everything inside it? This cannot be undone.`)) return
  try {
    await api.delete(`/library/categories/${selectedHash.value}`)
    selectCategory(null)
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
    await loadContent()
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

// THE FIX: Watch for route changes and reload the UI
watch(() => route.params.hash, async (newHash) => {
  selectedHash.value = newHash || null
  if (selectedHash.value) {
    expandAncestorsOf(selectedHash.value)
  }
  await loadContent()
})

const maxUploadSize = ref(100 * 1024 * 1024) // default 100MB

onMounted(async () => {
  try {
    const res = await api.get('/config')
    if (res.data.max_upload_size) {
      maxUploadSize.value = res.data.max_upload_size
    }
  } catch (e) {}
  
  await loadTree()
  if (selectedHash.value) {
    expandAncestorsOf(selectedHash.value)
  }
  await loadContent()
})

function onFileChange(e) {
  const f = e.target.files[0]
  if (f && f.size > maxUploadSize.value) {
    uploadMessage.value = `File too large. Max ${Math.round(maxUploadSize.value / 1024 / 1024)}MB.`
    uploadFile.value = null
    e.target.value = ''
    return
  }
  uploadFile.value = f || null
  uploadMessage.value = ''
}
</script>

<template>
  <div class="font-mono">
    <div class="flex items-center justify-between mb-4">
      <div>
        <h2 class="text-2xl font-bold text-white">
          <span class="text-emerald-400">&gt;</span> library
        </h2>
        <p class="text-xs text-gray-500 mt-1">
          // {{ tree.length }} top-level categor{{ tree.length === 1 ? 'y' : 'ies' }}
        </p>
      </div>
    </div>

    <ErrorBanner v-if="treeError" :message="treeError" />

    <div class="flex flex-col lg:flex-row gap-4">
      <aside class="lg:w-64 flex-shrink-0 bg-gray-900 border border-gray-800 rounded-lg p-3 self-start">
        <div class="text-xs text-gray-500 mb-2">// categories</div>
        <LoadingSpinner v-if="treeLoading" label="loading..." />
        <template v-else>
          <button
            @click="selectCategory(null)"
            :class="[
              'block w-full text-left px-2 py-1 rounded text-xs mb-1 transition-colors',
              !selectedHash ? 'bg-emerald-500/10 text-emerald-400' : 'text-gray-400 hover:text-white hover:bg-gray-800',
            ]"
          >~ all</button>
          <TreeNode
            v-for="node in tree"
            :key="node.id"
            :node="node"
            :depth="0"
            :selected="selectedHash"
            :expanded="expandedNodes"
            @select="selectCategory"
            @toggle="toggleNode"
          />
          <p v-if="!tree.length" class="text-xs text-gray-600 py-2">no categories yet</p>
        </template>
      </aside>

      <section class="flex-1 min-w-0">
        <ErrorBanner v-if="contentError" :message="contentError" />

        <div v-if="breadcrumb.length" class="flex items-center gap-1 text-xs mb-3 flex-wrap">
          <button @click="selectCategory(null)" class="text-gray-500 hover:text-emerald-400">library</button>
          <template v-for="(b, i) in breadcrumb" :key="b.id">
            <span class="text-gray-600">/</span>
            <button
              @click="selectCategory(b.public_hash)"
              :class="i === breadcrumb.length - 1 ? 'text-white' : 'text-gray-400 hover:text-emerald-400'"
            >{{ b.name }}</button>
          </template>
        </div>

        <LoadingSpinner v-if="contentLoading" label="loading category..." />

        <template v-else-if="!selectedHash">
          <EmptyState
            title="select a category"
            hint="pick one from the tree on the left, or create one below"
          />

          <form v-if="auth.isAdmin" @submit.prevent="createCategory" class="mt-4 bg-gray-900 border border-gray-800 rounded-lg p-4">
            <div class="text-xs text-gray-500 mb-3">// new top-level category</div>
            <div class="flex flex-col sm:flex-row gap-2">
              <input v-model="newName" placeholder="category name" class="flex-1 bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" />
              <select v-model="newType" class="bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-cyan-500">
                <option value="book">books</option>
                <option value="audio">audio</option>
                <option value="video">video</option>
              </select>
              <button type="submit" :disabled="creating" class="bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold px-5 py-2 rounded-md text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500">
                {{ creating ? '...' : '+ create' }}
              </button>
            </div>
            <p v-if="createError" class="text-xs text-red-400 mt-2">{{ createError }}</p>
          </form>
        </template>

        <template v-else-if="category">
          <div class="flex items-center gap-2 mb-3 flex-wrap">
            <span :class="['text-2xl leading-none', typeColor(category.type)]">{{ typeIcon(category.type) }}</span>
            <h3 class="text-white text-lg font-medium">{{ category.name }}</h3>
            <span class="text-xs text-gray-500">[{{ category.type }}]</span>
            <button v-if="auth.isAdmin" @click="deleteCurrent" class="ml-auto text-xs text-red-400 hover:text-red-300">delete category</button>
          </div>

          <div v-if="auth.isAdmin" class="grid sm:grid-cols-2 gap-3 mb-4">
            <form @submit.prevent="createCategory" class="bg-gray-900 border border-gray-800 rounded-lg p-4">
              <div class="text-xs text-gray-500 mb-3">// new subcategory under <span class="text-emerald-400">{{ category.name }}</span></div>
              <div class="flex flex-col gap-2">
                <input v-model="newName" placeholder="subcategory name" class="bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" />
                <div class="flex gap-2">
                  <select v-model="newType" class="flex-1 bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-cyan-500">
                    <option value="book">books</option>
                    <option value="audio">audio</option>
                    <option value="video">video</option>
                  </select>
                  <button type="submit" :disabled="creating" class="bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold px-4 rounded-md text-sm transition-colors">+ create</button>
                </div>
              </div>
              <p v-if="createError" class="text-xs text-red-400 mt-2">{{ createError }}</p>
            </form>

            <form @submit.prevent="upload" class="bg-gray-900 border border-gray-800 rounded-lg p-4">
              <div class="text-xs text-gray-500 mb-3">// upload item</div>
              <div class="flex flex-col gap-2">
                <input v-model="uploadTitle" placeholder="item title" class="bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" />
                <div class="flex gap-2 items-center">
                  <input id="upload-file" type="file" @change="onFileChange" class="flex-1 min-w-0 text-xs text-gray-400 file:mr-2 file:py-1 file:px-3 file:rounded-md file:border-0 file:bg-gray-800 file:text-emerald-400 file:font-mono file:cursor-pointer hover:file:bg-gray-700" />
                  <button type="submit" :disabled="uploading" class="bg-cyan-600 hover:bg-cyan-500 text-gray-950 font-bold px-4 py-2 rounded-md text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500 flex-shrink-0">
                    {{ uploading ? '...' : '↑' }}
                  </button>
                </div>
                <div v-if="uploadProgress > 0 && uploadProgress < 100" class="w-full bg-gray-800 rounded-full h-2 mt-2">
                  <div class="bg-cyan-500 h-2 rounded-full transition-all" :style="{ width: uploadProgress + '%' }"></div>
                </div>
                <p v-if="uploadMessage" class="text-xs text-emerald-400">{{ uploadMessage }}</p>
              </div>
            </form>
          </div>

          <section v-if="subcategories.length" class="mb-4">
            <div class="text-xs text-gray-500 mb-2">// subcategories ({{ subcategories.length }})</div>
            <ul class="space-y-2">
              <li v-for="c in subcategories" :key="c.id">
                <div class="flex items-center gap-3 bg-gray-900 border border-gray-800 hover:border-emerald-500/40 rounded-lg px-4 py-3 transition-colors group">
                  <button @click="selectCategory(c.public_hash)" class="flex items-center gap-3 flex-1 min-w-0 text-left">
                    <span :class="['text-lg leading-none flex-shrink-0', typeColor(c.type)]">{{ typeIcon(c.type) }}</span>
                    <span class="text-white font-medium truncate flex-1">{{ c.name }}</span>
                    <span class="text-xs text-gray-500 flex-shrink-0">[{{ c.type }}]</span>
                    <span class="text-emerald-400 flex-shrink-0">→</span>
                  </button>
                  <button v-if="auth.isAdmin" @click="deleteCategory(c)" class="text-xs text-red-400 hover:text-red-300 opacity-0 group-hover:opacity-100 flex-shrink-0">delete</button>
                </div>
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
      </section>
    </div>
  </div>
</template>
