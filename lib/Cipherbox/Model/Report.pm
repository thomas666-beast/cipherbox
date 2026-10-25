package Cipherbox::Model::Report;
use Mojo::Base -base, -signatures;

has pg => undef;

sub create ($self, $reporter_id, $message_id, $room_id, $reason) {
    return $self->pg->db->query(
        'INSERT INTO reports (reporter_id, message_id, room_id, reason)
         VALUES (?, ?, ?, ?) RETURNING *',
        $reporter_id, $message_id, $room_id, $reason,
    )->hash;
}

sub find_by_id ($self, $id) {
    return $self->pg->db->query(
        'SELECT * FROM reports WHERE id = ?', $id
    )->hash;
}

sub list_open ($self, $limit = 100, $offset = 0) {
    return $self->pg->db->query(
        'SELECT r.*, u.username AS reporter_username,
                m.sender_id, ms.username AS sender_username,
                rm.name AS room_name, rm.public_hash AS room_hash
         FROM reports r
         JOIN users u ON u.id = r.reporter_id
         JOIN messages m ON m.id = r.message_id
         JOIN users ms ON ms.id = m.sender_id
         JOIN rooms rm ON rm.id = r.room_id
         WHERE r.status = ?
         ORDER BY r.created_at DESC
         LIMIT ? OFFSET ?',
        'open', $limit, $offset,
    )->hashes->to_array;
}

sub count_open ($self) {
    return $self->pg->db->query(
        "SELECT count(*) FROM reports WHERE status = 'open'"
    )->array->[0];
}

sub resolve ($self, $id, $admin_id, $resolution) {
    $self->pg->db->query(
        "UPDATE reports
         SET status = 'resolved', resolved_by = ?, resolved_at = now(), resolution = ?
         WHERE id = ? AND status = 'open'",
        $admin_id, $resolution, $id,
    );
    return 1;
}

sub open_for_room ($self, $room_id) {
    return $self->pg->db->query(
        "SELECT * FROM reports WHERE room_id = ? AND status = 'open' LIMIT 1",
        $room_id,
    )->hash;
}

1;
