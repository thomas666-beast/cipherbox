<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../../core/auth'
import api from '../../core/api'
import init, { MlDsaKeyPair, MlKemKeyPair, encrypt_private_key } from '../../pqc/cipherbox_pqc.js'
import { saveIdentity } from '../../core/pqc-db.js'

const auth = useAuthStore()
const router = useRouter()

const username = ref('')
const passphrase = ref('')
const error = ref('')
const loading = ref(false)

async function submit() {
  error.value = ''
  if (!username.value || !passphrase.value) {
    error.value = 'Please fill in all fields.'
    return
  }
  
  loading.value = true
  let dsa_keypair = null
  let kem_keypair = null
  
  try {
    await init()
    
    // 1. Generate Dilithium
    dsa_keypair = new MlDsaKeyPair()
    const dsa_keys = dsa_keypair.exportKeys()
    const dsa_sk_bytes = new Uint8Array(dsa_keys[0])
    const dsa_vk_bytes = new Uint8Array(dsa_keys[1])
    
    // 2. Generate Kyber
    kem_keypair = new MlKemKeyPair()
    const kem_keys = kem_keypair.exportKeys()
    const kem_dk_bytes = new Uint8Array(kem_keys[0])
    const kem_ek_bytes = new Uint8Array(kem_keys[1])
    
    // 3. Encrypt private keys
    const encrypted_dsa_sk = encrypt_private_key(dsa_sk_bytes, passphrase.value)
    const encrypted_kem_dk = encrypt_private_key(kem_dk_bytes, passphrase.value)
    
    // 4. Convert public keys to Base64 for transport
    let dsa_b64 = ''
    for (let i = 0; i < dsa_vk_bytes.byteLength; i++) dsa_b64 += String.fromCharCode(dsa_vk_bytes[i])
    dsa_b64 = btoa(dsa_b64)

    let kem_b64 = ''
    for (let i = 0; i < kem_ek_bytes.byteLength; i++) kem_b64 += String.fromCharCode(kem_ek_bytes[i])
    kem_b64 = btoa(kem_b64)

    // 5. Send public keys to server FIRST
    await api.post('/auth/register', {
      username: username.value,
      dilithium_public_key: dsa_b64,
      kyber_public_key: kem_b64
    })

    // 6. Only save to IndexedDB if registration succeeded
    await saveIdentity('pqc_identity', {
      encrypted_dsa_sk: encrypted_dsa_sk,
      dsa_public_key: dsa_vk_bytes,
      encrypted_kem_dk: encrypted_kem_dk,
      kem_public_key: kem_ek_bytes
    })

    // 7. Update auth store and redirect
    await auth.fetchMe()
    router.push('/rooms')
    
  } catch (e) {
    error.value = e.response?.data?.error || e.message || 'Registration failed'
  } finally {
    // Clean up WASM memory
    if (dsa_keypair && dsa_keypair.free) dsa_keypair.free()
    if (kem_keypair && kem_keypair.free) kem_keypair.free()
    loading.value = false
  }
}
</script>

<template>
  <div class="bg-gray-900/80 backdrop-blur border border-gray-800 rounded-lg p-6 shadow-2xl shadow-cyan-500/5 font-mono">
    <div class="flex items-center justify-between mb-5">
      <div class="flex gap-1.5">
        <span class="w-3 h-3 rounded-full bg-red-500/70"></span>
        <span class="w-3 h-3 rounded-full bg-yellow-500/70"></span>
        <span class="w-3 h-3 rounded-full bg-cyan-500/70"></span>
      </div>
      <span class="font-mono text-xs text-gray-500 ml-2">register.sh</span>
    </div>

    <form @submit.prevent="submit" class="flex flex-col gap-3">
      <label class="block">
        <span class="text-xs text-gray-400">$ new_username</span>
        <input 
          v-model="username" 
          autocomplete="username" 
          spellcheck="false"
          class="mt-1 w-full bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md font-mono text-sm focus:outline-none focus:border-cyan-500 placeholder-gray-600" 
          placeholder="choose username"
        />
      </label>

      <label class="block">
        <span class="text-xs text-gray-400">$ passphrase (encrypts your private keys)</span>
        <input 
          v-model="passphrase" 
          type="password" 
          class="mt-1 w-full bg-gray-950 border border-gray-800 text-cyan-300 px-3 py-2 rounded-md font-mono text-sm focus:outline-none focus:border-cyan-500 placeholder-gray-600" 
          placeholder="enter a strong passphrase"
        />
        <p class="text-[10px] text-gray-500 mt-1">If you lose this, you lose access to your account.</p>
      </label>

      <button 
        type="submit" 
        :disabled="loading" 
        class="mt-3 bg-cyan-600 hover:bg-cyan-500 text-gray-950 font-bold py-2 rounded-md font-mono text-sm transition-colors disabled:bg-gray-700 disabled:text-gray-500"
      >
        {{ loading ? '> generating keys...' : '> create_account' }}
      </button>

      <p v-if="error" class="text-xs text-red-400 font-mono mt-1">
        <span class="text-red-500">✗</span> {{ error }}
      </p>
    </form>

    <div class="mt-5 pt-4 border-t border-gray-800 text-center font-mono text-xs text-gray-500">
      already have an identity?
      <router-link to="/pqc-login" class="text-cyan-400 hover:text-cyan-300 hover:underline">
        login()
      </router-link>
    </div>
  </div>
</template>
