-- Report tickets
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

-- Message edit history
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

-- Soft delete support on messages
ALTER TABLE messages ADD COLUMN deleted_at TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN deleted_by BIGINT REFERENCES users(id);
