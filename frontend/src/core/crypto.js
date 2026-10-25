function b64ToBytes(b64) {
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes
}

function bytesToB64(bytes) {
  let bin = ''
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin)
}

async function importKey(b64Key) {
  const raw = b64ToBytes(b64Key)
  return crypto.subtle.importKey(
    'raw',
    raw,
    { name: 'AES-GCM' },
    false,
    ['encrypt', 'decrypt']
  )
}

export async function encryptMessage(b64Key, plaintext) {
  const key = await importKey(b64Key)
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const ct = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    key,
    new TextEncoder().encode(plaintext)
  )
  // Web Crypto appends a 16-byte tag to the ciphertext; split it out
  const ctBytes = new Uint8Array(ct)
  const tag = ctBytes.slice(ctBytes.length - 16)
  const payload = ctBytes.slice(0, ctBytes.length - 16)
  return {
    ct: bytesToB64(payload),
    iv: bytesToB64(iv),
    tag: bytesToB64(tag),
  }
}

export async function decryptMessage(b64Key, ctB64, ivB64, tagB64) {
  const key = await importKey(b64Key)
  const iv = b64ToBytes(ivB64)
  const ct = b64ToBytes(ctB64)
  const tag = b64ToBytes(tagB64)
  // Reassemble: ciphertext || tag (Web Crypto expects the tag appended)
  const combined = new Uint8Array(ct.length + tag.length)
  combined.set(ct, 0)
  combined.set(tag, ct.length)
  const pt = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv },
    key,
    combined
  )
  return new TextDecoder().decode(pt)
}
