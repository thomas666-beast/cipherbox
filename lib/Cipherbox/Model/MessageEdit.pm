package Cipherbox::Model::MessageEdit;
use Mojo::Base -base, -signatures;

has pg => undef;

sub record ($self, $message_id, $editor_id, $ct, $iv, $tag) {
    return $self->pg->db->query(
        'INSERT INTO message_edits (message_id, editor_id, content_encrypted, content_iv, content_tag)
         VALUES (?, ?, ?, ?, ?) RETURNING *',
        $message_id, $editor_id, $ct, $iv, $tag,
    )->hash;
}

sub list_for_message ($self, $message_id) {
    return $self->pg->db->query(
        'SELECT me.*, u.username AS editor_username
         FROM message_edits me
         JOIN users u ON u.id = me.editor_id
         WHERE me.message_id = ?
         ORDER BY me.edited_at ASC',
        $message_id,
    )->hashes->to_array;
}

sub count_for_message ($self, $message_id) {
    return $self->pg->db->query(
        'SELECT count(*) FROM message_edits WHERE message_id = ?', $message_id
    )->array->[0];
}

1;
