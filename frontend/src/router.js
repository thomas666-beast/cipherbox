import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from './core/auth'

const routes = [
  { path: '/', redirect: '/rooms' },
  { path: '/login', component: () => import('./modules/auth/LoginView.vue') },
  { path: '/register', component: () => import('./modules/auth/RegisterView.vue') },
  { path: '/rooms', component: () => import('./modules/chat/RoomListView.vue'), meta: { requiresAuth: true } },
  { path: '/discover', component: () => import('./modules/chat/DiscoverView.vue'), meta: { requiresAuth: true } },
  { path: '/rooms/:hash', component: () => import('./modules/chat/RoomView.vue'), meta: { requiresAuth: true } },
  { path: '/library', component: () => import('./modules/library/LibraryView.vue'), meta: { requiresAuth: true } },
  { path: '/library/category/:hash', component: () => import('./modules/library/CategoryView.vue'), meta: { requiresAuth: true } },
  { path: '/admin', component: () => import('./modules/admin/AdminView.vue'), meta: { requiresAuth: true, requiresAdmin: true } },
  { path: '/rooms/:hash/members', component: () => import('./modules/chat/MembersView.vue'), meta: { requiresAuth: true } },
  { path: '/library', component: () => import('./modules/library/LibraryView.vue'), meta: { requiresAuth: true } },
  { path: '/library/category/:hash', component: () => import('./modules/library/LibraryView.vue'), meta: { requiresAuth: true } }
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
  if (to.meta.requiresAuth && !auth.authenticated) return { path: '/login' }
  if (to.meta.requiresAdmin && !auth.isAdmin) return { path: '/rooms' }
  if ((to.path === '/login' || to.path === '/register') && auth.authenticated) return { path: '/rooms' }
})

export default router
