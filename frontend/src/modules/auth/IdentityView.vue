<script setup>
import { ref } from 'vue'
import init, { MlDsaKeyPair, MlKemKeyPair, encrypt_private_key } from '../../pqc/cipherbox_pqc.js'
import { saveIdentity, loadIdentity } from '../../core/pqc-db.js'
import api from '../../core/api'

const wasmLoaded = ref(false)
const status = ref('Initializing WASM...')
const passphrase = ref('')
const hasStoredKey = ref(false)

init().then(() => {
  wasmLoaded.value = true
  status.value = 'WASM Ready.'
  checkStoredKey()
})

async function checkStoredKey() {
  const stored = await loadIdentity('pqc_identity')
  if (stored) {
    hasStoredKey.value = true
    status.value = 'Found existing PQC identity in IndexedDB.'
  }
}

async function generateAndSave() {
  if (!passphrase.value) {
    status.value = 'Please enter a passphrase first.'
    return
  }

  if (hasStoredKey.value) {
    const confirmOverwrite = confirm(
      "WARNING: This device already has a PQC identity stored.\n\n" +
      "If you continue, your current private keys will be permanently overwritten, and you will lose access to any encrypted rooms you have joined.\n\n" +
      "Do you really want to generate new keys?"
    )
    if (!confirmOverwrite) return
  }
  
  status.value = 'Generating Dilithium keypair...'
  let dsa_keypair = null
  let kem_keypair = null
  
  try {
    // 1. Dilithium (Signatures)
    dsa_keypair = new MlDsaKeyPair()
    const dsa_keys = dsa_keypair.exportKeys()
    const dsa_sk_bytes = new Uint8Array(dsa_keys[0])
    const dsa_vk_bytes = new Uint8Array(dsa_keys[1])
    
    status.value = 'Generating Kyber keypair...'
    // 2. Kyber (Encryption / Key Exchange)
    kem_keypair = new MlKemKeyPair()
    const kem_keys = kem_keypair.exportKeys()
    const kem_dk_bytes = new Uint8Array(kem_keys[0])
    const kem_ek_bytes = new Uint8Array(kem_keys[1])
    
    status.value = 'Encrypting private keys...'
    // 3. Encrypt both private keys with the passphrase
    const encrypted_dsa_sk = encrypt_private_key(dsa_sk_bytes, passphrase.value)
    const encrypted_kem_dk = encrypt_private_key(kem_dk_bytes, passphrase.value)
    
    status.value = 'Saving public keys to server...'
    // 4. Send both public keys to the backend (base64 encoded)
    let dsa_b64 = ''
    for (let i = 0; i < dsa_vk_bytes.byteLength; i++) dsa_b64 += String.fromCharCode(dsa_vk_bytes[i])
    dsa_b64 = btoa(dsa_b64)

    let kem_b64 = ''
    for (let i = 0; i < kem_ek_bytes.byteLength; i++) kem_b64 += String.fromCharCode(kem_ek_bytes[i])
    kem_b64 = btoa(kem_b64)

    await api.post('/auth/pqc/keys', {
      dilithium_public_key: dsa_b64,
      kyber_public_key: kem_b64
    })

    status.value = 'Saving to IndexedDB...'
    // 5. Save encrypted private keys and plaintext public keys
    await saveIdentity('pqc_identity', {
      encrypted_dsa_sk: encrypted_dsa_sk,
      dsa_public_key: dsa_vk_bytes,
      encrypted_kem_dk: encrypted_kem_dk,
      kem_public_key: kem_ek_bytes
    })

    hasStoredKey.value = true
    status.value = 'Success! Both keys generated, encrypted, stored, and synced.'
    passphrase.value = ''
    
  } catch (err) {
    console.error(err)
    status.value = 'Error: ' + err.message
  } finally {
    // Clean up WASM memory
    if (dsa_keypair && dsa_keypair.free) dsa_keypair.free()
    if (kem_keypair && kem_keypair.free) kem_keypair.free()
  }
}
</script>

<template>
  <div class="font-mono w-full">
    <h2 class="text-2xl font-bold text-white mb-2">
      <span class="text-emerald-400">&gt;</span> PQC Identity Settings
    </h2>
    <p class="text-sm text-gray-400 mb-6">
      Manage your Post-Quantum Cryptography (PQC) identity. Your private keys are encrypted with your passphrase and stored locally in your browser's IndexedDB. The server <strong>never</strong> sees your private keys or passphrase.
    </p>

    <!-- Info Box: Changing Passphrase -->
    <div class="bg-gray-900 border border-cyan-500/30 rounded-lg p-4 mb-6">
      <h3 class="text-cyan-400 text-sm font-bold mb-2">💡 What happens if I change my passphrase?</h3>
      <p class="text-xs text-gray-300 mb-2">
        Your passphrase is <strong>only</strong> used to lock/unlock your local private keys on this specific device. It is not tied to your account on the server.
      </p>
      <ul class="text-xs text-gray-400 list-disc list-inside space-y-1">
        <li><strong>If you just want to change it:</strong> You must export your current identity, generate a new one with the new passphrase, and re-import it.</li>
        <li><strong>Old messages:</strong> Changing your passphrase does <strong>not</strong> affect your ability to read old messages, as long as you keep the <em>same</em> ML-KEM (Kyber) private key. The passphrase just encrypts that key locally.</li>
        <li><strong>If you generate a completely new identity:</strong> You will lose access to all existing encrypted rooms because the new ML-KEM key will not match the rooms' encrypted history.</li>
      </ul>
    </div>

    <div class="bg-gray-900 border border-gray-800 rounded-lg p-6">
      <div class="text-xs text-emerald-400 mb-4">{{ status }}</div>
      
      <div class="flex flex-col gap-3">
        <label class="block">
          <span class="text-xs text-gray-400">$ passphrase (to encrypt local keys)</span>
          <input 
            v-model="passphrase" 
            type="password" 
            placeholder="enter a strong passphrase" 
            class="mt-1 w-full bg-gray-950 border border-gray-800 text-gray-100 px-3 py-2 rounded-md text-sm focus:outline-none focus:border-emerald-500"
          />
        </label>
        
        <button 
          @click="generateAndSave" 
          :disabled="!wasmLoaded"
          class="bg-emerald-600 hover:bg-emerald-500 text-gray-950 font-bold py-2 rounded-md text-sm disabled:bg-gray-700 transition-colors"
        >
          {{ hasStoredKey ? 'Regenerate & Overwrite Identity' : 'Generate & Save Identity' }}
        </button>
        
        <p class="text-xs text-gray-500 mt-2">
          Note: If you lose this passphrase, you cannot log in with PQC, and you will lose access to all encrypted rooms. There is no "password reset" because the server cannot read your keys.
        </p>
      </div>
    </div>
  </div>
</template>
