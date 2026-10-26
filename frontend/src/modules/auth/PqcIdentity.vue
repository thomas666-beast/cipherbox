import api from '../../core/api' // Add this at the top!

async function generateAndSave() {
  if (!passphrase.value) {
    status.value = 'Please enter a passphrase first.'
    return
  }
  
  status.value = 'Generating Dilithium keypair...'
  
  try {
    const keypair = new MlDsaKeyPair()
    const keys = keypair.exportKeys()
    const sk_bytes = new Uint8Array(keys[0])
    const vk_bytes = new Uint8Array(keys[1])
    
    status.value = 'Encrypting private key...'
    const encrypted_sk = encrypt_private_key(sk_bytes, passphrase.value)
    
    status.value = 'Saving to IndexedDB...'
    await saveIdentity('dilithium_blob', {
      encrypted_sk: encrypted_sk,
      public_key: vk_bytes
    })
    
    status.value = 'Saving public keys to server...'
    // Convert vk_bytes to base64 for JSON
    let binary = ''
    for (let i = 0; i < vk_bytes.byteLength; i++) {
      binary += String.fromCharCode(vk_bytes[i])
    }
    const vk_b64 = btoa(binary)

    await api.post('/auth/pqc/keys', {
      dilithium_public_key: vk_b64,
      kyber_public_key: 'pending-kyber-key' 
    })

    hasStoredKey.value = true
    status.value = 'Success! Identity generated, encrypted, stored, and synced with server.'
    passphrase.value = '' 
    keypair.free()
    
  } catch (err) {
    console.error(err)
    status.value = 'Error: ' + err.message
  }
}
