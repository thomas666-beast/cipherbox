# Cipherbox

> A Web-Native, Post-Quantum Encrypted Collaboration Platform.

Cipherbox is an open-source, self-hosted alternative to proprietary secure messengers (like Polynom). It is built for journalists, researchers, and privacy-conscious teams who need **Zero-Knowledge End-to-End Encryption** without relying on heavy desktop apps or proprietary servers.

Built with **Perl (Mojolicious)**, **Vue.js**, and **Rust**, Cipherbox combines a lightweight, auditable web interface with NIST-standard Post-Quantum Cryptography.

## Features

- **True End-to-End Encryption (E2EE):** Messages, text pastes, and file uploads are encrypted in the browser. The server never sees the plaintext.
- **Post-Quantum Cryptography:** Uses **ML-KEM (Kyber-768)** for key encapsulation and **ML-DSA (Dilithium-3)** for digital signatures.
- **4 Room Types:**
  - *Private Rooms:* E2EE group chats (invite-only).
  - *Private Channels:* E2EE read-only news feeds.
  - *Public Rooms:* Server-managed group chats (open to anyone).
  - *Public Channels:* Server-managed read-only broadcasts.
- **Ephemeral Rooms:** "Quantum Rooms" that self-destruct permanently when the last member leaves.
- **Zero-Knowledge File Sharing:** Upload files up to 100MB (configurable). Files are encrypted in chunks, streamed to disk, and automatically wiped after 1 hour.
- **Traffic Obfuscation:** WebSocket payloads are obfuscated to hide the fact that a chat app is running.
- **PQC Identity Management:** Users manage their own keys. The server cannot recover them.

## Architecture

Cipherbox is split into three independent components:

1. **Frontend (Vue.js + Tailwind):** The UI, local IndexedDB key storage, and client-side encryption.
2. **Backend (Perl / Mojolicious):** The API, WebSocket broker, and PostgreSQL database.
3. **Crypto Engines (Rust):**
   - `cipherbox-pqc-wasm`: Runs in the browser (via WebAssembly) for client-side crypto.
   - `cipherbox-pqc-native`: Runs on the server (CLI binaries) for signature verification and key wrapping.

## Cipherbox vs. Polynom

| Feature | Polynom | Cipherbox |
| :--- | :--- | :--- |
| **Core Crypto** | Kyber-1024 & Dilithium5 (CNSA 2.0) | ML-KEM (Kyber) & ML-DSA (Dilithium) |
| **Platform** | Native iOS / Android (Heavy Qt client) | Web-Native (Browser-based, zero install) |
| **Deployment** | SaaS / Proprietary Appliance | Self-Hosted, Open-Source (Perl + Rust) |
| **Key Exchange** | "Social Encryption" (shared secrets) | Standard ML-KEM (invite-based wrapping) |
| **Room Types** | Quantum Rooms, Announcement Rooms | 4 types (Public/Private, Room/Channel) |
| **File Sharing** | Yes | Yes (Zero-Knowledge, 100MB stream) |
| **Ephemeral Rooms** | Yes | Yes (Configurable self-destruct) |
| **Traffic Obfuscation** | Hiding-in-Plain-Sight | Numeric WebSocket keys |
| **Verifiable Code** | Proprietary Black Box | 100% Open Source (Auditable) |
| **Multi-Sig** | In development | Planned (ML-DSA signatures) |

## Security Model

Cipherbox uses a **Zero-Knowledge** architecture:

- **Registration:** The browser generates an ML-KEM and ML-DSA keypair. The private keys are encrypted with the user's passphrase (using Argon2 + ChaCha20-Poly1305) and saved to IndexedDB. Only the public keys are sent to the server.
- **Room Keys:** Every private room has a random AES-256-GCM key. This key is wrapped using the room members' ML-KEM public keys. The server stores only the wrapped keys.
- **Messages:** Encrypted in the browser with the room's AES key. The server stores only the ciphertext, IV, and authentication tag.
- **Files:** Encrypted in the browser, streamed to the server, and served back as encrypted blobs. The server deletes them automatically after the configured expiry time.

## Prerequisites

- **Perl** 5.30+ with `carton`
- **PostgreSQL** 14+
- **Rust** and **Cargo** (for building the crypto engines)
- **wasm-pack** (for the browser WASM module)
- **Node.js** 18+ (for the Vue frontend)

## Installation

### 1. Clone the repository

    git clone https://github.com/yourusername/cipherbox.git
    cd cipherbox

### 2. Install Perl dependencies

    carton install

### 3. Set up the database

Create a PostgreSQL database and apply the schema:

    createdb cipherbox
    psql cipherbox < migrations/001_full_schema.sql

### 4. Configure the application

Edit your config `cipherbox.conf`. If you break it or something goes wrong:

    cp cipherbox.conf.example cipherbox.conf

Set your database DSN, JWT secret, master key, and storage limits in `cipherbox.conf`.

### 5. Build the Rust crypto engines

Cipherbox uses two separate Rust projects hosted on GitHub.

    # Build WASM (for the frontend)
    cd ../cipherbox-pqc-wasm
    wasm-pack build --target web --out-dir ../cipherbox/frontend/src/pqc

    # Build Native (for the backend)
    cd ../cipherbox-pqc-native
    cargo build --release
    cp target/release/cipherbox-pqc-verify ../cipherbox/bin/
    cp target/release/cipherbox-pqc-wrap ../cipherbox/bin/

Or use the automated build script:

    ./build-crypto.sh

### 6. Build the frontend

    cd frontend
    npm install
    npm run build

### 7. Start the server

    carton exec morbo script/cipherbox

The app will be available at `http://localhost:3000`.

## Configuration

The `cipherbox.conf` file controls the core behavior:

    {
        secrets => ['your-jwt-secret'],
        master_key => 'your-32-byte-master-key',
        pg => {
            dsn => 'postgresql://user:pass@localhost/cipherbox'
        },
        storage => {
            max_upload_size => 104857600,  # 100MB for library
            max_paste_size  => 10485760,   # 10MB for chat files
            chunk_size      => 65536,      # 64KB streaming chunks
            paste_expiry_hours => 1        # Auto-delete pastes after 1h
        }
    }

## Testing the PQC Flow

1. Register a new user at `/register`.
2. Log out, then log in at `/pqc-login` using your username and passphrase.
3. Create a private room, invite a second user, and send a message.
4. Upload a file using the paperclip icon. It will be encrypted, streamed, and stored as a `.bin` file on the server.
5. After 1 hour, the server cron job will wipe the file from disk.

## Roadmap

- [x] Post-Quantum E2EE Messaging
- [x] Zero-Knowledge File Sharing
- [x] Ephemeral Rooms
- [x] Traffic Obfuscation
- [ ] Multi-Signature Channel Announcements (for journalistic verification)
- [ ] VoIP / WebRTC Calls with PQC key exchange
- [ ] Encrypted identity export/import (for cross-device backup)

## License

This project is licensed under the MIT License.

## Acknowledgements

- [Mojolicious](https://mojolicious.org/) — The Perl web framework.
- [Vue.js](https://vuejs.org/) — The frontend framework.
- [ml-kem](https://crates.io/crates/ml-kem) and [ml-dsa](https://crates.io/crates/ml-dsa) — The Rust post-quantum crates.
- [wasm-pack](https://rustwasm.github.io/wasm-pack/) — For compiling Rust to WebAssembly.
