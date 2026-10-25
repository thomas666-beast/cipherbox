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
const disabled = ref(false)

async function submit() {
  error.value = ''
  loading.value = true
  try {
    await auth.register(username.value, password.value)
    await auth.login(username.value, password.value)
    router.push('/rooms')
  } catch (e) {
    const msg = e.response?.data?.error || 'Registration failed'
    if (msg === 'registration is disabled') {
      disabled.value = true
      error.value = ''
    } else {
      error.value = msg
    }
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="bg-gray-900/80 backdrop-blur border border-gray-800 rounded-lg p-6 shadow-2xl shadow-cyan-500/5">
    <div class="flex items-center gap-2 mb-5">
      <div class="flex gap-1.5">
        <span class="w-3 h-3 rounded-full bg-red-500/70"></span>
        <span class="w-3 h-3 rounded-full bg-yellow-500/70"></span>
        <span class="w-3 h-3 rounded-full bg-cyan-500/70"></span>
      </div>
      <span class="font-mono text-xs text-gray-500 ml-2">register.sh</span>
    </div>

    <div v-if="disabled" class="font-mono">
      <div class="text-sm text-yellow-400 mb-2">
        <span class="text-red-500">✗</span> registration is currently disabled
      </div>
      <p class="text-xs text-gray-500">
        ask an admin for an invite or to enable registration.
      </p>
      <router-link
        to="/login"
        class="block mt-4 text-center text-xs text-emerald-400 hover:text-emerald-300"
      >
        back to login()
      </router-link>
    </div>

    <template v-else>
      <form @submit.prevent="submit" class="flex flex-col gap-3 font-mono">
        <label class="block">
          <span class="text-xs text-gray-400">$ new_username</span>
          <input
            v-model="username"
            autocomplete="username"
            spellcheck="false"
            class="mt-1 w-full bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md font-mono text-sm focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500/50 transition-colors placeholder-gray-600"
            placeholder="choose username"
          />
        </label>

        <label class="block">
          <span class="text-xs text-gray-400">$ new_password</span>
          <input
            v-model="password"
            type="password"
            autocomplete="new-password"
            class="mt-1 w-full bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md font-mono text-sm focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500/50 transition-colors placeholder-gray-600"
            placeholder="••••••••"
          />
        </label>

        <button
          type="submit"
          :disabled="loading"
          class="mt-3 bg-cyan-600 hover:bg-cyan-500 text-gray-950 font-bold py-2 rounded-md font-mono text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500"
        >
          {{ loading ? '> creating...' : '> create_account' }}
        </button>

        <p v-if="error" class="text-xs text-red-400 font-mono mt-1">
          <span class="text-red-500">✗</span> {{ error }}
        </p>
      </form>

      <div class="mt-5 pt-4 border-t border-gray-800 text-center font-mono text-xs text-gray-500">
        already registered?
        <router-link to="/login" class="text-cyan-400 hover:text-cyan-300 hover:underline">
          login()
        </router-link>
      </div>
    </template>
  </div>
</template>
