<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../../core/auth'

const auth = useAuthStore()
const router = useRouter()
const username = ref('')
const password = ref('')
const error = ref('')
const loading = ref(false)

async function submit() {
  error.value = ''
  loading.value = true
  try {
    await auth.login(username.value, password.value)
    router.push('/rooms')
  } catch (e) {
    error.value = e.response?.data?.error || 'Login failed'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="bg-gray-900/80 backdrop-blur border border-gray-800 rounded-lg p-6 shadow-2xl shadow-emerald-500/5">
    <div class="flex items-center gap-2 mb-5">
      <div class="flex gap-1.5">
        <span class="w-3 h-3 rounded-full bg-red-500/70"></span>
        <span class="w-3 h-3 rounded-full bg-yellow-500/70"></span>
        <span class="w-3 h-3 rounded-full bg-emerald-500/70"></span>
      </div>
      <span class="font-mono text-xs text-gray-500 ml-2">login.sh</span>
    </div>

    <form @submit.prevent="submit" class="flex flex-col gap-3 font-mono">
      <label class="block">
        <span class="text-xs text-gray-400">$ username</span>
        <input
          v-model="username"
          autocomplete="username"
          spellcheck="false"
          class="mt-1 w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md font-mono text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500/50 transition-colors placeholder-gray-600"
          placeholder="enter username"
        />
      </label>

      <label class="block">
        <span class="text-xs text-gray-400">$ password</span>
        <input
          v-model="password"
          type="password"
          autocomplete="current-password"
          class="mt-1 w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md font-mono text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500/50 transition-colors placeholder-gray-600"
          placeholder="••••••••"
        />
      </label>

      <button
        type="submit"
        :disabled="loading"
        class="mt-3 bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold py-2 rounded-md font-mono text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500"
      >
        {{ loading ? '> authenticating...' : '> authenticate' }}
      </button>

      <p v-if="error" class="text-xs text-red-400 font-mono mt-1">
        <span class="text-red-500">✗</span> {{ error }}
      </p>
    </form>

    <div class="mt-5 pt-4 border-t border-gray-800 text-center font-mono text-xs text-gray-500">
      no account?
      <router-link to="/register" class="text-emerald-400 hover:text-emerald-300 hover:underline">
        register()
      </router-link>
    </div>
  </div>
</template>
