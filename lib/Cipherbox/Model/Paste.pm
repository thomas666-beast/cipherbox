package Cipherbox::Model::Paste;
use Mojo::Base -base, -signatures;
use Crypt::PRNG qw(random_bytes);

has pg => undef;

sub _new_hash ($self) {
    return unpack('H*', random_bytes(10));
}

sub create_text ($self, %args) {
    my $hash = $self->_new_hash;
    return $self->pg->db->query(
        'INSERT INTO pastes
            (public_hash, room_id, sender_id, title, kind,
             content_encrypted, content_iv, content_tag, file_key_encrypted)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING *',
        $hash,
        $args{room_id}, $args{sender_id}, $args{title}, 'text',
        $args{content_encrypted}, $args{content_iv}, $args{content_tag},
        $args{file_key_encrypted},
    )->hash;
}

sub create_file ($self, %args) {
    my $hash = $self->_new_hash;
    return $self->pg->db->query(
        'INSERT INTO pastes
            (public_hash, room_id, sender_id, title, kind,
             mime_type, file_name, file_size, file_path, file_key_encrypted)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING *',
        $hash,
        $args{room_id}, $args{sender_id}, $args{title}, 'file',
        $args{mime_type}, $args{file_name}, $args{file_size},
        $args{file_path}, $args{file_key_encrypted},
    )->hash;
}

sub find_by_hash ($self, $hash) {
    return $self->pg->db->query(
        'SELECT * FROM pastes WHERE public_hash = ?', $hash
    )->hash;
}

sub find_by_hash_or_id ($self, $param) {
    return undef unless defined $param and length $param;
    if ($param =~ /^\d+$/) {
        return $self->pg->db->query(
            'SELECT * FROM pastes WHERE id = ?', $param
        )->hash;
    }
    return $self->find_by_hash($param);
}

sub attach_message ($self, $paste_id, $message_id) {
    $self->pg->db->query(
        'UPDATE pastes SET message_id = ? WHERE id = ?',
        $message_id, $paste_id,
    );
    return 1;
}

sub mark_opened ($self, $paste_id, $user_id) {
    $self->pg->db->query(
        'UPDATE pastes SET opened_by = ?, opened_at = now()
         WHERE id = ? AND opened_at IS NULL AND deleted_at IS NULL',
        $user_id, $paste_id,
    );
    return 1;
}

sub mark_deleted ($self, $paste_id) {
    $self->pg->db->query(
        'UPDATE pastes SET
            deleted_at = now(),
            content_encrypted = NULL,
            content_iv = NULL,
            content_tag = NULL,
            file_key_encrypted = NULL
         WHERE id = ? AND deleted_at IS NULL',
        $paste_id,
    );
    return 1;
}

sub list_for_room ($self, $room_id, $limit = 100, $offset = 0) {
    return $self->pg->db->query(
        'SELECT p.*, s.username AS sender_username,
                o.username AS opened_username
         FROM pastes p
         JOIN users s ON s.id = p.sender_id
         LEFT JOIN users o ON o.id = p.opened_by
         WHERE p.room_id = ?
         ORDER BY p.created_at DESC
         LIMIT ? OFFSET ?',
        $room_id, $limit, $offset,
    )->hashes->to_array;
}

sub expired_pending ($self, $minutes = 60) {
    return $self->pg->db->query(
        "SELECT * FROM pastes
         WHERE opened_at IS NOT NULL
           AND deleted_at IS NULL
           AND opened_at < now() - make_interval(mins => ?)
         ORDER BY opened_at",
        $minutes,
    )->hashes->to_array;
}

sub delete_unopened_by_message ($self, $message_id) {
    return $self->pg->db->query(
        'SELECT file_path FROM pastes
         WHERE message_id = ? AND deleted_at IS NULL AND file_path IS NOT NULL',
        $message_id,
    )->hashes->to_array;
}

1;
