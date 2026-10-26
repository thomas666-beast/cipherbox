<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useAuthStore } from './core/auth'
import { useRoomsStore } from './core/rooms'

const auth = useAuthStore()
const roomsStore = useRoomsStore()
const router = useRouter()
const route = useRoute()

const sidebarOpen = ref(true)
const mobileMenuOpen = ref(false)

const publicRoutes = ['/login', '/register', '/pqc-login']
const isPublicPage = computed(() => publicRoutes.includes(route.path))

const isAuthenticated = computed(() => auth.authenticated)

const navItems = computed(() => {
  if (!isAuthenticated.value) return []
  const items = [
    { to: '/rooms', label: 'rooms', icon: '>_' },
    { to: '/library', label: 'library', icon: '[]' },
    { to: '/identity', label: 'pqc identity', icon: '#' },
  ]
  if (auth.isAdmin) {
    items.push({ to: '/admin', label: 'admin', icon: '**' })
  }
  return items
})

function isActive(path) {
  if (path === '/rooms') return route.path.startsWith('/rooms') && !route.path.startsWith('/rooms/')
  if (path === '/library') return route.path.startsWith('/library')
  return route.path === path
}

async function logout() {
  await auth.logout()
  router.push('/login')
}

function toggleSidebar() {
  sidebarOpen.value = !sidebarOpen.value
}

function closeMobile() {
  mobileMenuOpen.value = false
}

onMounted(async () => {
  if (!auth.ready) {
    await auth.fetchMe()
  }
  if (auth.authenticated) {
    roomsStore.subscribe()
  }
})

watch(isAuthenticated, (v) => {
  if (v) roomsStore.subscribe()
})
</script>

<template>
  <div class="flex h-screen bg-gray-950 text-gray-200 font-sans">
    <!-- Public Layout -->
    <template v-if="isPublicPage">
      <div class="relative flex-1 flex items-center justify-center p-6 bg-gray-950 overflow-hidden">
        <div class="absolute inset-0 opacity-[0.07]" aria-hidden="true">
          <div class="absolute inset-0" style="background-image:
            linear-gradient(to right, #fff 1px, transparent 1px),
            linear-gradient(to bottom, #fff 1px, transparent 1px);
            background-size: 40px 40px;"></div>
        </div>
        <div class="absolute top-1/4 left-1/2 -translate-x-1/2 w-[600px] h-[600px] rounded-full bg-emerald-500/10 blur-3xl pointer-events-none" aria-hidden="true"></div>
        <div class="absolute bottom-0 right-1/4 w-[400px] h-[400px] rounded-full bg-cyan-500/10 blur-3xl pointer-events-none" aria-hidden="true"></div>

        <div class="relative w-full max-w-md">
          <div class="flex flex-col items-center mb-8">
            <img src="/logo.svg" alt="Cipherbox" class="h-16 w-auto mb-2" />
            <p class="text-gray-500 text-sm font-mono">encrypted chat &amp; content platform</p>
          </div>
          <router-view />
          <p class="text-center text-xs text-gray-600 mt-8 font-mono">
            // PQC · AES-256-GCM · WebSocket
          </p>
        </div>
      </div>
    </template>

    <!-- Authenticated Layout -->
    <template v-else>
      <!-- Mobile top bar -->
      <div class="lg:hidden fixed top-0 left-0 right-0 h-14 bg-gray-900 border-b border-gray-800 flex items-center justify-between px-4 z-30">
        <button @click="mobileMenuOpen = true" class="p-2 -ml-2 text-gray-400 hover:text-white" aria-label="Open menu">
          <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"/>
          </svg>
        </button>
        <span class="font-mono text-sm">
          <span class="text-emerald-400">&gt;</span> cipherbox
        </span>
        <button @click="logout" class="text-xs font-mono text-gray-500 hover:text-emerald-400">exit</button>
      </div>

      <!-- Sidebar -->
      <aside
        :class="[
          'fixed inset-y-0 left-0 z-40 bg-gray-900 border-r border-gray-800 transition-transform duration-200 flex flex-col',
          sidebarOpen ? 'w-64' : 'w-16',
          mobileMenuOpen ? 'translate-x-0' : '-translate-x-full lg:translate-x-0',
        ]"
      >
        <div class="h-14 flex items-center px-4 border-b border-gray-800">
          <img v-if="sidebarOpen" src="/logo.svg" alt="Cipherbox" class="h-8 w-auto" />
          <img v-else src="/favicon.svg" alt="C" class="h-6 w-6" />
        </div>

        <nav class="flex-1 py-3 font-mono text-sm">
          <router-link
            v-for="item in navItems"
            :key="item.to"
            :to="item.to"
            @click="closeMobile"
            :class="[
              'flex items-center gap-3 mx-2 my-1 px-3 py-2 rounded-md transition-colors',
              isActive(item.to)
                ? 'bg-gray-800 text-emerald-400'
                : 'text-gray-400 hover:bg-gray-800 hover:text-white',
            ]"
          >
            <span class="text-xs text-gray-500 w-5">{{ item.icon }}</span>
            <span v-if="sidebarOpen">{{ item.label }}</span>
          </router-link>
        </nav>

        <div class="border-t border-gray-800 p-3 font-mono">
          <div v-if="sidebarOpen" class="flex items-center justify-between">
            <div class="min-w-0">
              <div class="text-sm font-medium text-emerald-300 truncate">
                {{ auth.username }}
              </div>
              <div class="text-xs text-gray-500">role: {{ auth.role }}</div>
            </div>
            <button @click="logout" class="text-gray-500 hover:text-red-400" title="Logout">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/>
              </svg>
            </button>
          </div>
          <button v-else @click="logout" class="w-full flex justify-center text-gray-500 hover:text-red-400" title="Logout">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/>
            </svg>
          </button>
        </div>

        <button
          @click="toggleSidebar"
          class="hidden lg:flex items-center justify-center h-10 border-t border-gray-800 text-gray-500 hover:text-emerald-400 text-xs font-mono"
        >
          {{ sidebarOpen ? '« collapse' : '»' }}
        </button>
      </aside>

      <div v-if="mobileMenuOpen" @click="closeMobile" class="fixed inset-0 bg-black/60 z-30 lg:hidden"></div>

      <main
        :class="[
          'flex-1 flex flex-col transition-[margin] duration-200 pt-14 lg:pt-0',
          sidebarOpen ? 'lg:ml-64' : 'lg:ml-16',
        ]"
      >
        <div class="flex-1 overflow-y-auto w-full">
          <!-- Removed max-w-6xl and mx-auto to make it 100% wide -->
          <div class="w-full px-4 sm:px-6 py-6">
            <router-view />
          </div>
        </div>
      </main>
    </template>
  </div>
</template>
