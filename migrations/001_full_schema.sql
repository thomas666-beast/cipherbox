-- pgcrypto for gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- users ----------
CREATE TABLE users (
    id            BIGSERIAL PRIMARY KEY,
    username      TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'user',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- rooms ----------
CREATE TABLE rooms (
    id                 BIGSERIAL PRIMARY KEY,
    public_hash        TEXT NOT NULL DEFAULT encode(gen_random_bytes(10), 'hex'),
    name               TEXT NOT NULL,
    type               TEXT NOT NULL CHECK (type IN ('private', 'channel', 'room')),
    owner_id           BIGINT NOT NULL REFERENCES users(id),
    room_key_encrypted TEXT NOT NULL,
    is_invite_only     BOOLEAN NOT NULL DEFAULT false,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_rooms_public_hash ON rooms (public_hash);

-- ---------- room_members ----------
CREATE TABLE room_members (
    room_id      BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role         TEXT NOT NULL DEFAULT 'member',
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_read_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (room_id, user_id)
);

-- ---------- room_bans ----------
CREATE TABLE room_bans (
    room_id   BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    user_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    banned_by BIGINT NOT NULL REFERENCES users(id),
    banned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (room_id, user_id)
);
CREATE INDEX idx_room_bans_user ON room_bans (user_id);

-- ---------- messages ----------
CREATE TABLE messages (
    id                BIGSERIAL PRIMARY KEY,
    room_id           BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    sender_id         BIGINT NOT NULL REFERENCES users(id),
    content_encrypted TEXT NOT NULL,
    content_iv        TEXT NOT NULL,
    content_tag       TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_messages_room_created ON messages (room_id, created_at DESC);

-- ---------- library_categories ----------
CREATE TABLE library_categories (
    id          BIGSERIAL PRIMARY KEY,
    public_hash TEXT NOT NULL DEFAULT encode(gen_random_bytes(10), 'hex'),
    name        TEXT NOT NULL,
    parent_id   BIGINT REFERENCES library_categories(id) ON DELETE CASCADE,
    type        TEXT NOT NULL CHECK (type IN ('book', 'audio', 'video'))
);
CREATE UNIQUE INDEX idx_library_categories_public_hash ON library_categories (public_hash);

-- ---------- library_items ----------
CREATE TABLE library_items (
    id                 BIGSERIAL PRIMARY KEY,
    public_hash        TEXT NOT NULL DEFAULT encode(gen_random_bytes(10), 'hex'),
    category_id        BIGINT NOT NULL REFERENCES library_categories(id) ON DELETE CASCADE,
    title              TEXT NOT NULL,
    file_path          TEXT NOT NULL,
    file_key_encrypted TEXT NOT NULL,
    mime_type          TEXT,
    file_size          BIGINT,
    uuid               TEXT UNIQUE,
    uploaded_by        BIGINT NOT NULL REFERENCES users(id),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_library_items_public_hash ON library_items (public_hash);

-- ---------- auth_attempts (rate limiting) ----------
CREATE TABLE auth_attempts (
    id         BIGSERIAL PRIMARY KEY,
    ip         TEXT NOT NULL,
    username   TEXT,
    kind       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_auth_attempts_lookup
    ON auth_attempts (ip, username, kind, created_at);

-- ---------- schema_migrations (for script/migrate) ----------
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename   TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
