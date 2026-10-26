-- =========================================================
-- Cipherbox Full Schema (001_full_schema.sql)
-- =========================================================

-- pgcrypto for gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- users ----------
CREATE TABLE users (
    id                   BIGSERIAL PRIMARY KEY,
    username             TEXT UNIQUE NOT NULL,
    password_hash        TEXT NOT NULL DEFAULT 'PQC-ONLY',
    role                 TEXT NOT NULL DEFAULT 'user',
    dilithium_public_key TEXT,
    kyber_public_key     TEXT,
    current_nonce        TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- rooms ----------
CREATE TABLE rooms (
    id                 BIGSERIAL PRIMARY KEY,
    public_hash        TEXT NOT NULL DEFAULT encode(gen_random_bytes(10), 'hex'),
    name               TEXT NOT NULL,
    type               TEXT NOT NULL CHECK (type IN ('private', 'channel', 'room')),
    owner_id           BIGINT NOT NULL REFERENCES users(id),
    room_key_encrypted TEXT,
    is_invite_only     BOOLEAN NOT NULL DEFAULT false,
    is_ephemeral       BOOLEAN NOT NULL DEFAULT false,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_rooms_public_hash ON rooms (public_hash);

-- ---------- room_members ----------
CREATE TABLE room_members (
    room_id          BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    user_id          BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role             TEXT NOT NULL DEFAULT 'member',
    kyber_ciphertext TEXT,
    joined_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_read_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
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
    deleted_at        TIMESTAMPTZ,
    deleted_by        BIGINT REFERENCES users(id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_messages_room_created ON messages (room_id, created_at DESC);

-- ---------- pastes (True E2EE Files/Text) ----------
CREATE TABLE pastes (
    id                    BIGSERIAL PRIMARY KEY,
    public_hash           TEXT NOT NULL DEFAULT encode(gen_random_bytes(10), 'hex'),
    room_id               BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    sender_id             BIGINT NOT NULL REFERENCES users(id),
    message_id            BIGINT REFERENCES messages(id) ON DELETE CASCADE,
    title                 TEXT NOT NULL,
    kind                  TEXT NOT NULL CHECK (kind IN ('text', 'file')),
    mime_type             TEXT,
    file_name             TEXT,
    file_size             BIGINT,
    file_path             TEXT,
    content_encrypted     TEXT,
    content_iv            TEXT,
    content_tag           TEXT,
    wrapped_key_encrypted TEXT,
    wrapped_key_iv        TEXT,
    wrapped_key_tag       TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at            TIMESTAMPTZ
);
CREATE UNIQUE INDEX idx_pastes_public_hash ON pastes (public_hash);
CREATE INDEX idx_pastes_room ON pastes (room_id, created_at DESC);

-- ---------- moderation ----------
CREATE TABLE reports (
    id           BIGSERIAL PRIMARY KEY,
    reporter_id  BIGINT NOT NULL REFERENCES users(id),
    message_id   BIGINT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    room_id      BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    reason       TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
    resolved_by  BIGINT REFERENCES users(id),
    resolved_at  TIMESTAMPTZ,
    resolution   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_reports_status ON reports (status, created_at DESC);
CREATE INDEX idx_reports_room ON reports (room_id);

CREATE TABLE message_edits (
    id                BIGSERIAL PRIMARY KEY,
    message_id        BIGINT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    editor_id         BIGINT NOT NULL REFERENCES users(id),
    content_encrypted TEXT NOT NULL,
    content_iv        TEXT NOT NULL,
    content_tag       TEXT NOT NULL,
    edited_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_message_edits_message ON message_edits (message_id, edited_at DESC);

-- ---------- library ----------
CREATE TABLE library_categories (
    id          BIGSERIAL PRIMARY KEY,
    public_hash TEXT NOT NULL DEFAULT encode(gen_random_bytes(10), 'hex'),
    name        TEXT NOT NULL,
    parent_id   BIGINT REFERENCES library_categories(id) ON DELETE CASCADE,
    type        TEXT NOT NULL CHECK (type IN ('book', 'audio', 'video'))
);
CREATE UNIQUE INDEX idx_library_categories_public_hash ON library_categories (public_hash);

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

-- ---------- admin & settings ----------
CREATE TABLE settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO settings (key, value) VALUES ('registration_enabled', 'true') ON CONFLICT DO NOTHING;

CREATE TABLE audit_logs (
    id         BIGSERIAL PRIMARY KEY,
    admin_id   BIGINT NOT NULL REFERENCES users(id),
    action     TEXT NOT NULL,
    target     TEXT,
    details    JSONB,
    ip_address TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_logs_admin ON audit_logs (admin_id, created_at DESC);
CREATE INDEX idx_audit_logs_action ON audit_logs (action, created_at DESC);

CREATE TABLE auth_attempts (
    id         BIGSERIAL PRIMARY KEY,
    ip         TEXT NOT NULL,
    username   TEXT,
    kind       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_auth_attempts_lookup ON auth_attempts (ip, username, kind, created_at);

-- ---------- schema_migrations ----------
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename   TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
