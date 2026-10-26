<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../../core/auth'
import api from '../../core/api'
import init, { MlDsaKeyPair, decrypt_private_key } from '../../pqc/cipherbox_pqc.js'
import { loadIdentity } from '../../core/pqc-db.js'

const auth = useAuthStore()
const router = useRouter()

const username = ref('')
const passphrase = ref('')
const error = ref('')
const loading = ref(false)

async function submit() {
  error.value = ''
  loading.value = true
  
  try {
    await init()
    
    // 1. Get Challenge from Server (Base64)
    const chalRes = await api.post('/auth/pqc/challenge', { username: username.value })
    const nonceB64 = chalRes.data.nonce

    // 2. Load Identity from IndexedDB
    const stored = await loadIdentity('pqc_identity')
    if (!stored) throw new Error('No PQC identity found on this device.')
    
    // 3. Decrypt the Dilithium private key
    const sk_bytes = decrypt_private_key(stored.encrypted_dsa_sk, passphrase.value)
    if (sk_bytes.length === 0) throw new Error('Wrong passphrase.')

    // 4. Sign the Challenge (Raw Bytes)
    const keypair = MlDsaKeyPair.importKeys(sk_bytes, stored.dsa_public_key)
    
    // Decode Base64 nonce to raw bytes
    const nonceBytes = Uint8Array.from(atob(nonceB64), c => c.charCodeAt(0))
    
    const sig = keypair.sign(nonceBytes)
    
    // 5. Convert Signature to Base64
    let binary = ''
    for (let i = 0; i < sig.byteLength; i++) {
      binary += String.fromCharCode(sig[i])
    }
    const sig_b64 = btoa(binary)

    // Free WASM memory
    if (keypair && keypair.free) keypair.free()

    // 6. Send to Server for Verification
    await api.post('/auth/pqc/verify', {
      username: username.value,
      signature: sig_b64
    })

    // 7. Update auth store and redirect
    await auth.fetchMe()
    
    if (auth.authenticated) {
      router.push('/rooms')
    } else {
      throw new Error('Login failed: server did not authorize session.')
    }
    
  } catch (e) {
    console.error("PQC LOGIN ERROR:", e.response?.data?.error || e.message)
    error.value = e.response?.data?.error || e.message || 'Login failed'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="bg-gray-900/80 backdrop-blur border border-gray-800 rounded-lg p-6 shadow-2xl shadow-emerald-500/5 font-mono">
    <div class="flex items-center justify-between mb-5">
      <div class="flex gap-1.5">
        <span class="w-3 h-3 rounded-full bg-red-500/70"></span>
        <span class="w-3 h-3 rounded-full bg-yellow-500/70"></span>
        <span class="w-3 h-3 rounded-full bg-emerald-500/70"></span>
      </div>
      <span class="font-mono text-xs text-gray-500 ml-2">pqc-login.sh</span>
    </div>

    <form @submit.prevent="submit" class="flex flex-col gap-3">
      <label class="block">
        <span class="text-xs text-gray-400">$ username</span>
        <input 
          v-model="username" 
          autocomplete="username" 
          class="mt-1 w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md font-mono text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" 
          placeholder="enter username"
        />
      </label>

      <label class="block">
        <span class="text-xs text-gray-400">$ passphrase</span>
        <input 
          v-model="passphrase" 
          type="password" 
          class="mt-1 w-full bg-gray-950 border border-gray-800 text-emerald-300 px-3 py-2 rounded-md font-mono text-sm focus:outline-none focus:border-emerald-500 placeholder-gray-600" 
          placeholder="unlock private key"
        />
      </label>

      <button 
        type="submit" 
        :disabled="loading" 
        class="mt-3 bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold py-2 rounded-md font-mono text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500"
      >
        {{ loading ? '> authenticating...' : '> unlock with pqc' }}
      </button>

      <p v-if="error" class="text-xs text-red-400 font-mono mt-1">
        <span class="text-red-500">✗</span> {{ error }}
      </p>
    </form>

    <div class="mt-5 pt-4 border-t border-gray-800 text-center font-mono text-xs text-gray-500">
      no identity yet?
      <router-link to="/register" class="text-cyan-400 hover:text-cyan-300 hover:underline">
        create_account()
      </router-link>
    </div>
  </div>
</template>
