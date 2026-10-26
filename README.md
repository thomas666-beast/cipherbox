# Cipherbox

Cipherbox is a self-hosted, encrypted chat and content platform built with **Perl (Mojolicious)**, **Vue 3**, and **PostgreSQL**. It was designed as a practical alternative to tools like Polynom: instead of a heavy native app requiring offline key exchanges, Cipherbox runs entirely in the browser, uses server-assisted encryption, and prioritizes moderation and usability.

## Two Versions of Cipherbox

This repository contains two completely independent architectures, kept in separate branches. They will **never** be merged because they solve different problems.

### 1. `main` (Stable Version)
This is the version you are reading about now. It uses **server-assisted encryption** with AES-256-GCM. The server holds a master key and can wrap/unwrap room keys to deliver them to authorized users. This allows for **moderation**, **report tickets**, and **admin visibility** when a message is reported.

- **Best for:** Communities, teams, and self-hosters who need chat moderation.
- **No Rust required.** Just Perl, PostgreSQL, and Node.js.
- **Location:** The `main` branch.

### 2. `feature/pqc-wasm` (Post-Quantum Version)
This is an experimental branch with **true Zero-Knowledge End-to-End Encryption**. The server never sees the private keys. It uses **ML-KEM (Kyber)** for key encapsulation and **ML-DSA (Dilithium)** for signatures, compiled to WebAssembly via Rust.

- **Best for:** Journalists, activists, and high-security teams.
- **Requires Rust, Cargo, and wasm-pack** to build the crypto engines.
- **Location:** The `feature/pqc-wasm` branch.

To switch between them locally:

    git checkout main
    git checkout feature/pqc-wasm

---

## Core Features (Stable Version)

Cipherbox is not just a chat app. It is a platform with three distinct domains.

### Chat and Rooms
The platform supports multiple room types. **Private Rooms** are invite-only encrypted spaces. **Public Rooms** are open group chats where everyone can post. **Channels** are announcement spaces where only the owner or admins can send messages. Rooms can be discovered publicly or locked down as invite-only.

### Library
The library is a recursive content manager. You can nest categories as deeply as you want, for example `Metal -> Thrash Metal -> Metallica -> Tracks`. Administrators can upload files (books, audio, video) which are encrypted at rest and streamed to disk in configurable chunks. Users can browse the tree and download files.

### Ephemeral Pastes
Sometimes you need to send a secret. You can click the paperclip icon in chat to create a Paste. A paste can be text or a file (up to a configurable limit, default 10MB). It is encrypted before leaving the browser. When someone opens the paste, they can copy the text or download the file. A background cron job automatically wipes the encrypted blob from disk after a configurable expiry time (default 1 hour).

## Security Architecture (Stable Version)

Cipherbox uses standard web security practices combined with server-assisted encryption.

### Authentication
Users log in with a username and password. Passwords are hashed with **Argon2**. The session is managed via an HttpOnly, SameSite=Strict cookie. This prevents Cross-Site Scripting (XSS) attacks from stealing the session token. Rate limiting is enforced on login and registration attempts.

### Encryption
Every room generates a random 256-bit AES key. Messages and files are encrypted with **AES-256-GCM**. The server wraps these room keys with a master key stored in the config file. When a user joins a room, the server unwraps the key and sends it to the browser. The browser then encrypts and decrypts messages locally.

### Moderation and Audit Logs
Because the server holds the master key, administrators have the ability to decrypt messages if necessary. This is a deliberate design choice to allow moderation. If a user reports a message, an admin can open a ticket, view the reported message, its edit history, and the surrounding chat context in read-only mode. Every admin action is written to an audit log table.

### Hardening
The backend sets strict Content-Security-Policy (CSP) headers to block inline scripts. Pastes and library files are securely overwritten (not just unlinked) when deleted. The database schema uses `ON DELETE CASCADE` so that deleting a room or user removes all associated data cleanly.

## Comparison with Polynom

If you are choosing between Cipherbox and Polynom, it helps to understand the difference in philosophy.

**Polynom** is a cryptographic fortress. It is designed for journalists, activists, and enterprises facing nation-state adversaries and quantum computers. It uses Post-Quantum Cryptography (CRYSTALS-Kyber, Dilithium) and Social Encryption, where the key is derived from offline secrets like photos or passphrases. The server never sees the key, meaning even the admin cannot read the messages.

**Cipherbox** is a hardened web platform. It is designed for communities, teams, or self-hosters who want a secure place to chat and share files, but who still need the ability to moderate content and manage users from a browser.

| Feature | Cipherbox (Stable) | Cipherbox (PQC) | Polynom |
| :--- | :--- | :--- | :--- |
| **Platform** | Web browser | Web browser | Native apps |
| **Key Exchange** | Server-assisted | PQC (ML-KEM) | Social Encryption |
| **Encryption** | AES-256-GCM | AES-256-GCM + PQC | AES-256-GCM (CNSA 2.0) |
| **Post-Quantum** | No | Yes (Kyber, Dilithium) | Yes (Kyber, Dilithium) |
| **Admin Visibility** | Yes (Reports, Audit Logs) | No (Zero-Knowledge) | No (Zero-Knowledge) |
| **Moderation** | Built-in | Limited | Difficult |
| **Ephemeral Content** | Pastes (1 hour) | Pastes (1 hour) | Quantum Rooms |
| **Content Library** | Recursive categories | Recursive categories | Flat vaults |
| **Complexity** | Easy (Perl + Postgres) | Complex (Rust + WASM) | Very Complex (Native) |

> **Note on Post-Quantum Cryptography:** The `feature/pqc-wasm` branch of this repository is the version that uses PQC. If your threat model includes "harvest now, decrypt later" by a nation-state with a quantum computer, use that branch.

## Deployment (Stable Version)

### Requirements
- **Perl** 5.36+ with `carton`
- **PostgreSQL** 15+
- **Node.js** 20+ (for the frontend build)

### Backend Setup

1. Install Perl dependencies:

    carton install

2. Create the PostgreSQL databases:

    createdb cipherbox
    createdb cipherbox_test

3. Apply the migrations:

    carton exec -- ./script/migrate

4. Create the first admin user:

    carton exec -- ./script/create_admin yourname yourpassword

5. Start the development server:

    carton exec morbo script/cipherbox

The app will be available at `http://localhost:3000`.

### Production

Cipherbox is designed to run behind **Hypnotoad**. Start it with:

    carton exec -- hypnotoad script/cipherbox

The config is set to run **8 workers**, using PostgreSQL `LISTEN/NOTIFY` for real-time message routing between workers. This means WebSocket messages are delivered across all worker processes.

### Frontend Setup

The frontend is a Vue 3 app inside the `frontend/` directory.

- **Development:** `npm run dev` (Vite proxies `/api` and `/chat` to `http://127.0.0.1:3000`).
- **Production:** `npm run build`, then serve the resulting `dist/` folder via nginx or a static host. The frontend expects `/api` and `/chat` to be proxied to the Mojolicious backend.

### Tests

The backend has a comprehensive test suite. Run:

    carton exec -- prove -l t/

The tests use a separate `cipherbox_test` database and cover authentication, room logic, encryption, pastes, admin actions, and the library.

## Deployment (PQC Version)

The PQC version lives on the `feature/pqc-wasm` branch. It requires the same Perl and PostgreSQL setup as the stable version, but adds two Rust crypto engines.

### Additional Requirements
- **Rust** and **Cargo**
- **wasm-pack**

### Build the Crypto Engines

Clone the two Rust projects (they are separate repositories on GitHub) and build them:

    # Build the WASM module for the frontend
    cd ../cipherbox-pqc-wasm
    wasm-pack build --target web --out-dir ../cipherbox/frontend/src/pqc

    # Build the native binaries for the backend
    cd ../cipherbox-pqc-native
    cargo build --release
    cp target/release/cipherbox-pqc-verify ../cipherbox/bin/
    cp target/release/cipherbox-pqc-wrap ../cipherbox/bin/

Or use the automated build script:

    ./build-crypto.sh

After that, start the server exactly as in the stable version.

## Configuration

All configuration is in `cipherbox.conf`. It has a default section (used for development and production) and a `test` section (used for the test suite). To switch environments, set the `CIPHERBOX_ENV` variable to `test` before running commands.

Important settings include:

- **`pg.dsn`**: PostgreSQL connection string.
- **`secrets`**: JWT signing secret (array; use a strong random value).
- **`master_key`**: Used to wrap and unwrap room keys (stored securely in this config file).
- **`pagination`**: Default and maximum page sizes for messages, members, and library items.
- **`auth_limits`**: Rate limiting thresholds for login and registration.
- **`storage`**: Controls `max_upload_size` (library), `max_paste_size` (chat files), `chunk_size` (streaming), and `paste_expiry_hours` (auto-delete).
- **`hypnotoad.workers`**: Number of backend processes.

## Not Implemented Yet (Stable Version)

The following features are recognized as useful but are out of scope for the stable version:

- **Post-Quantum Cryptography** (Kyber, Dilithium). *See the `feature/pqc-wasm` branch.*
- **True server-blind End-to-End Encryption** (Social Encryption).
- **Message threading and reactions.**
- **Push notifications** (WebPush or native).
- **Multi-tenant support** (multiple isolated workspaces on one server).
- **VoIP / WebRTC calls.**
- **Encrypted identity export/import.**

## License

This project is licensed under the MIT License.

## Acknowledgements

- [Mojolicious](https://mojolicious.org/) — The Perl web framework.
- [Vue.js](https://vuejs.org/) — The frontend framework.
- [PostgreSQL](https://www.postgresql.org/) — The database.
- [Hypnotoad](https://mojolicious.org/perldoc/Mojo/Server/Hypnotoad) — Production web server.
- [ml-kem](https://crates.io/crates/ml-kem) and [ml-dsa](https://crates.io/crates/ml-dsa) — The Rust post-quantum crates used in the PQC branch.
