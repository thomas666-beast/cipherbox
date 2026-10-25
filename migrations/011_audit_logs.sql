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
