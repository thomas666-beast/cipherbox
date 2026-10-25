CREATE TABLE pastes (
    id                  BIGSERIAL PRIMARY KEY,
    public_hash         TEXT NOT NULL DEFAULT encode(gen_random_bytes(10), 'hex'),
    room_id             BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    sender_id           BIGINT NOT NULL REFERENCES users(id),
    message_id          BIGINT REFERENCES messages(id) ON DELETE CASCADE,
    title               TEXT NOT NULL,
    kind                TEXT NOT NULL CHECK (kind IN ('text', 'file')),
    mime_type           TEXT,
    file_name           TEXT,
    file_size           BIGINT,
    file_path           TEXT,
    content_encrypted   TEXT,
    content_iv          TEXT,
    content_tag         TEXT,
    file_key_encrypted  TEXT,
    opened_by           BIGINT REFERENCES users(id),
    opened_at           TIMESTAMPTZ,
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_pastes_public_hash ON pastes (public_hash);
CREATE INDEX idx_pastes_room ON pastes (room_id, created_at DESC);
CREATE INDEX idx_pastes_pending_delete
    ON pastes (opened_at)
    WHERE opened_at IS NOT NULL AND deleted_at IS NULL;
