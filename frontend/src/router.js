import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from './core/auth'

const routes = [
  { path: '/', redirect: '/pqc-login' },
  { path: '/pqc-login', component: () => import('./modules/auth/PqcLogin.vue') },
  { path: '/register', component: () => import('./modules/auth/PqcRegister.vue') },
  { path: '/identity', component: () => import('./modules/auth/IdentityView.vue'), meta: { requiresAuth: true } },
  { path: '/rooms', component: () => import('./modules/chat/RoomListView.vue'), meta: { requiresAuth: true } },
  { path: '/discover', component: () => import('./modules/chat/DiscoverView.vue'), meta: { requiresAuth: true } }, // <-- ADD THIS
  { path: '/rooms/:hash', component: () => import('./modules/chat/RoomView.vue'), meta: { requiresAuth: true } },
  { path: '/rooms/:hash/members', component: () => import('./modules/chat/MembersView.vue'), meta: { requiresAuth: true } },
  { path: '/library', component: () => import('./modules/library/LibraryView.vue'), meta: { requiresAuth: true } },
  { path: '/library/category/:hash', component: () => import('./modules/library/LibraryView.vue'), meta: { requiresAuth: true } },
  { path: '/admin', component: () => import('./modules/admin/AdminView.vue'), meta: { requiresAuth: true, requiresAdmin: true } },
]

const router = createRouter({
  history: createWebHistory(),
  routes,
})

router.beforeEach(async (to) => {
  const auth = useAuthStore()
  
  if (!auth.ready) {
    await auth.fetchMe()
  }

  const publicPages = ['/pqc-login', '/register']
  
  if (publicPages.includes(to.path)) {
    if (auth.authenticated) {
      return { path: '/rooms' }
    }
    return true
  }

  if (!auth.authenticated) {
    return { path: '/pqc-login' }
  }
  
  if (to.meta.requiresAdmin && !auth.isAdmin) {
    return { path: '/rooms' }
  }
})

export default router
