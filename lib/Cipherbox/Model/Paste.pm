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
             content_encrypted, content_iv, content_tag,
             wrapped_key_encrypted, wrapped_key_iv, wrapped_key_tag)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING *',
        $hash,
        $args{room_id}, $args{sender_id}, $args{title}, 'text',
        $args{content_encrypted}, $args{content_iv}, $args{content_tag},
        $args{wrapped_key_encrypted}, $args{wrapped_key_iv}, $args{wrapped_key_tag},
    )->hash;
}

sub create_file ($self, %args) {
    my $hash = $self->_new_hash;
    return $self->pg->db->query(
        'INSERT INTO pastes
            (public_hash, room_id, sender_id, title, kind,
             mime_type, file_name, file_size, file_path,
             wrapped_key_encrypted, wrapped_key_iv, wrapped_key_tag)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING *',
        $hash,
        $args{room_id}, $args{sender_id}, $args{title}, 'file',
        $args{mime_type}, $args{file_name}, $args{file_size},
        $args{file_path},
        $args{wrapped_key_encrypted}, $args{wrapped_key_iv}, $args{wrapped_key_tag},
    )->hash;
}

sub find_by_hash ($self, $hash) {
    return $self->pg->db->query(
        'SELECT * FROM pastes WHERE public_hash = ?', $hash
    )->hash;
}

sub attach_message ($self, $paste_id, $message_id) {
    $self->pg->db->query(
        'UPDATE pastes SET message_id = ? WHERE id = ?',
        $message_id, $paste_id,
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
            wrapped_key_encrypted = NULL,
            wrapped_key_iv = NULL,
            wrapped_key_tag = NULL
         WHERE id = ? AND deleted_at IS NULL',
        $paste_id,
    );
    return 1;
}

1;
