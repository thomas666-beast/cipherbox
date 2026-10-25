# Cipherbox

Cipherbox is a self-hosted, encrypted chat and content platform. It was built to be a practical alternative to tools like Polynom: instead of a native app requiring post-quantum cryptography and offline key exchanges, Cipherbox runs entirely in the browser, uses server-assisted encryption, and prioritizes moderation and usability.

## Core Features

Cipherbox is not just a chat app. It is a platform with three distinct domains.

**Chat and Rooms**
The platform supports three types of rooms. Private rooms are strictly for two people, like Direct Messages. Public Rooms are group chats where everyone can post. Channels are announcement spaces where only the owner or admins can send messages. Rooms can be discovered publicly or locked down as invite-only.

**Library**
The library is a recursive content manager. You can nest categories as deeply as you want, for example Metal -> Thrash Metal -> Metallica -> Tracks. Administrators can upload files (books, audio, video) which are encrypted at rest. Users can browse the tree and download files.

**Ephemeral Pastes**
Sometimes you need to send a secret. You can click the paperclip icon in chat to create a Paste. A paste can be text or a file. It is encrypted, and the first person to open it consumes it. Once they click "Done", the file is securely wiped from the disk. If they forget, a background timer wipes it after one hour.

## Security Architecture

Cipherbox uses standard web security practices combined with server-assisted encryption.

**Authentication**
Users log in with a username and password. Passwords are hashed with Argon2. The session is managed via an HttpOnly, SameSite=Strict cookie. This prevents Cross-Site Scripting (XSS) attacks from stealing the session token.

**Encryption**
Every room generates a random 256-bit AES key. Messages and files are encrypted with AES-256-GCM. The server wraps these room keys with a master key stored in the config file. When a user joins a room, the server unwraps the key and sends it to the browser. The browser then encrypts and decrypts messages locally.

**Moderation and Audit Logs**
Because the server holds the master key, administrators have the ability to decrypt messages if necessary. This is a deliberate design choice to allow moderation. If a user reports a message, an admin can open a ticket and view the reported message, its edit history, and the surrounding chat context in read-only mode. Every time an admin views a report or changes a user role, an audit log is written to the database.

**Hardening**
The backend sets strict Content-Security-Policy (CSP) headers to block inline scripts. Pastes and library files are securely overwritten (not just unlinked) when deleted.

## Comparison with Polynom

If you are choosing between Cipherbox and Polynom, it helps to understand the difference in philosophy.

Polynom is a cryptographic fortress. It is designed for journalists, activists, and enterprises facing nation-state adversaries and quantum computers. It uses Post-Quantum Cryptography (CRYSTALS-Kyber, Dilithium) and Social Encryption, where the key is derived from offline secrets like photos or passphrases. The server never sees the key, meaning even the admin cannot read the messages.

Cipherbox is a hardened web platform. It is designed for communities, teams, or self-hosters who want a secure place to chat and share files, but who still need the ability to moderate content and manage users from a browser.

| Feature | Cipherbox | Polynom |
| :--- | :--- | :--- |
| Platform | Web browser (Vue 3 + Mojolicious) | Native apps (Windows, Linux, macOS, iOS, Android) |
| Key Exchange | Server-assisted (Server wraps and sends keys to members) | Social Encryption (Offline entropy, server never sees keys) |
| Encryption at Rest | AES-256-GCM (Standard) | AES-256-GCM (CNSA 2.0 compliant) |
| Post-Quantum Crypto | None (Uses standard AES and JWT) | Yes (CRYSTALS-Kyber, Dilithium) |
| Admin Visibility | Technically possible (Admin has a viewer for reports and audit logs) | Mathematically impossible (Server cannot decrypt SE rooms) |
| Moderation | Built-in (Report tickets, read-only admin viewer, soft delete) | Difficult (Admin cannot read SE rooms, so cannot moderate content) |
| Ephemeral Content | Pastes (One-time secrets, auto-delete after 1 hour) | Quantum Rooms (Entire rooms self-destruct when empty) |
| Content Library | Recursive categories (Metal -> Thrash -> Metallica) with file uploads | Flat encrypted file vaults |
| Complexity | Easy to self-host (Perl + Postgres + Vue) | Complex setup (Requires specialized server and native clients) |

### A note on Post-Quantum Cryptography

Polynom is ready for the quantum era. It uses algorithms specifically designed to resist attacks from future quantum computers. Cipherbox does not. If your threat model includes "harvest now, decrypt later" by a nation-state with a quantum computer, Polynom is the right choice.

Adding PQC to Cipherbox in the future is possible but difficult. It would require compiling Kyber and Dilithium into WebAssembly, implementing a client-side key exchange, and rewriting the authentication flow. For now, Cipherbox relies on standard, well-tested cryptography which is secure against all classical attacks.

## Deployment

### Requirements
Perl 5.36+, Carton, PostgreSQL 15+, and Node.js 20+ (for the frontend).

### Backend Setup
Install dependencies by running `carton install`. Create the PostgreSQL user and databases (`cipherbox` and `cipherbox_test`). Apply the migrations by running `carton exec -- ./script/migrate`. Create the first admin by running `carton exec -- ./script/create_admin yourname yourpassword`.

To run in production, use Hypnotoad. Start it with `carton exec -- hypnotoad script/cipherbox`. The config file is set to run 8 workers, using PostgreSQL LISTEN/NOTIFY for real-time message routing between workers.

### Frontend Setup
The frontend is a Vue 3 app inside the `frontend/` directory. During development, run `npm run dev`. In production, run `npm run build` and serve the resulting `dist/` folder via nginx or a static host. The frontend expects `/api` and `/chat` to be proxied to the Mojolicious backend.

### Tests
The backend has a comprehensive test suite. Run `carton exec -- prove -l t/` to execute it. The tests use a separate `cipherbox_test` database and cover authentication, room logic, encryption, pastes, admin actions, and the library.

## Not Implemented Yet

The following features are recognized as useful but are out of scope for the current version. 
- Post-Quantum Cryptography (Kyber, Dilithium).
- True server-blind End-to-End Encryption (Social Encryption).
- Message threading and reactions.
- Push notifications (WebPush or native).
- Multi-tenant support (multiple isolated workspaces on one server).

## Configuration

All configuration is in `cipherbox.conf`. It has a default section (for development and production) and a `test` section (for the test suite). To switch environments, set the `CIPHERBOX_ENV` variable to `test` before running commands.

Important settings include:
`pg.dsn` for the database connection.
`secrets` for the JWT signing secret.
`master_key` for the room key wrapping.
`pagination` for library and message limits.
`auth_limits` for rate limiting on login and registration.
`hypnotoad.workers` for the number of backend processes.
