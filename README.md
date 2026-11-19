# Cipherbox Standard

Cipherbox Standard is a self-hosted chat and file-sharing app built with Perl/Mojolicious, PostgreSQL, and Vue. It uses password accounts and server-assisted AES-256-GCM. It does not require Rust, WebAssembly, or post-quantum cryptography. The server can unwrap room keys for authorized users and moderation, so this is not end-to-end encryption against the server.

See [Cipherbox Standard Optimization and Rollout](OPTIMIZATION.md) for the migration, pagination API changes, and verification instructions.

## Local setup

Use Perl 5.36+, Carton, PostgreSQL 15+, and Node.js 20.19+ or 22.12+. Create the application database, then copy the example config and set its PostgreSQL DSN and secrets. Use a different disposable database for tests.

```sh
carton install
cp cipherbox.conf.example cipherbox.conf
# Edit cipherbox.conf before running the migration.
carton exec -- ./script/migrate
carton exec -- ./script/cipherbox daemon -l http://127.0.0.1:3000
```

In a separate terminal, run `npm ci` and `npm run dev` in `frontend/`, then open the Vite URL. Vite forwards `/api` and `/chat` to the local Perl service. For administrative access on a fresh instance, use the existing `script/create_admin` with a dedicated password through a trusted terminal.

For production, run `npm ci` and `npm run build` in `frontend/`. Serve `dist/` with SPA fallback from the HTTPS origin, and proxy `/api` and `/chat` (including WebSocket upgrades) to the Perl listener. Use `carton exec -- hypnotoad script/cipherbox` if you run the service via Hypnotoad. Do not expose the development server publicly.

## Tests

Configure the `test` DSN in `cipherbox.conf` to point only to a disposable database. The Perl tests truncate tables and some use the app storage directory for temporary files, so run them from a disposable checkout as well.

```sh
CIPHERBOX_ENV=test carton exec -- ./script/migrate
carton exec -- prove -l t
```
