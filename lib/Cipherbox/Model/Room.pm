package Cipherbox::Model::Room;
use Mojo::Base -base, -signatures;
use Crypt::PRNG qw(random_bytes);

has pg => undef;

sub _new_hash ($self) {
    return unpack('H*', random_bytes(10));
}

sub create ($self, $name, $type, $owner_id, $room_key_encrypted, $is_invite_only = 0) {
    my $db = $self->pg->db;
    my $tx = $db->begin;

    my $hash = $self->_new_hash;

    my $room = $db->query(
        'INSERT INTO rooms (name, type, owner_id, room_key_encrypted, public_hash, is_invite_only)
         VALUES (?, ?, ?, ?, ?, ?) RETURNING *',
        $name, $type, $owner_id, $room_key_encrypted, $hash, $is_invite_only ? 1 : 0,
    )->hash;

    $db->query(
        'INSERT INTO room_members (room_id, user_id, role) VALUES (?, ?, ?)',
        $room->{id}, $owner_id, 'owner',
    );

    $tx->commit;
    return $room;
}

sub find_by_id ($self, $id) {
    return $self->pg->db->query(
        'SELECT * FROM rooms WHERE id = ?', $id
    )->hash;
}

sub find_by_hash ($self, $hash) {
    return $self->pg->db->query(
        'SELECT * FROM rooms WHERE public_hash = ?', $hash
    )->hash;
}

sub find_by_hash_or_id ($self, $param) {
    return undef unless defined $param and length $param;
    if ($param =~ /^\d+$/) {
        return $self->find_by_id($param);
    }
    return $self->find_by_hash($param);
}

sub find_private_room ($self, $user_a_id, $user_b_id) {
    return $self->pg->db->query(
        q{
            SELECT r.*
            FROM rooms r
            WHERE r.type = 'private'
              AND EXISTS (SELECT 1 FROM room_members WHERE room_id = r.id AND user_id = ?)
              AND EXISTS (SELECT 1 FROM room_members WHERE room_id = r.id AND user_id = ?)
            LIMIT 1
        },
        $user_a_id, $user_b_id,
    )->hash;
}

sub add_member ($self, $room_id, $user_id, $role = 'member') {
    $self->pg->db->query(
        'INSERT INTO room_members (room_id, user_id, role) VALUES (?, ?, ?)
         ON CONFLICT (room_id, user_id) DO NOTHING',
        $room_id, $user_id, $role,
    );
}

sub remove_member ($self, $room_id, $user_id) {
    $self->pg->db->query(
        'DELETE FROM room_members WHERE room_id = ? AND user_id = ?',
        $room_id, $user_id,
    );
}

sub is_member ($self, $room_id, $user_id) {
    my $row = $self->pg->db->query(
        'SELECT 1 FROM room_members WHERE room_id = ? AND user_id = ?',
        $room_id, $user_id,
    )->array;
    return $row ? 1 : 0;
}

sub member_role ($self, $room_id, $user_id) {
    my $row = $self->pg->db->query(
        'SELECT role FROM room_members WHERE room_id = ? AND user_id = ?',
        $room_id, $user_id,
    )->array;
    return $row ? $row->[0] : undef;
}

sub list_members ($self, $room_id, $limit = 100, $offset = 0, $q = undef) {
    $limit = 200 if $limit > 200;
    $limit = 1 if $limit < 1;
    $offset = 0 if $offset < 0;

    if (defined $q and length $q) {
        my $like = "%$q%";
        return $self->pg->db->query(
            'SELECT rm.user_id, u.username, rm.role, rm.joined_at
             FROM room_members rm
             JOIN users u ON u.id = rm.user_id
             WHERE rm.room_id = ? AND u.username ILIKE ?
             ORDER BY rm.joined_at
             LIMIT ? OFFSET ?',
            $room_id, $like, $limit, $offset,
        )->hashes->to_array;
    }

    return $self->pg->db->query(
        'SELECT rm.user_id, u.username, rm.role, rm.joined_at
         FROM room_members rm
         JOIN users u ON u.id = rm.user_id
         WHERE rm.room_id = ?
         ORDER BY rm.joined_at
         LIMIT ? OFFSET ?',
        $room_id, $limit, $offset,
    )->hashes->to_array;
}

sub count_members ($self, $room_id, $q = undef) {
    if (defined $q and length $q) {
        my $like = "%$q%";
        return $self->pg->db->query(
            'SELECT count(*) FROM room_members rm
             JOIN users u ON u.id = rm.user_id
             WHERE rm.room_id = ? AND u.username ILIKE ?',
            $room_id, $like,
        )->array->[0];
    }
    return $self->pg->db->query(
        'SELECT count(*) FROM room_members WHERE room_id = ?', $room_id
    )->array->[0];
}

sub list_for_user ($self, $user_id) {
    return $self->pg->db->query(
        q{
            WITH last AS (
                SELECT m.room_id, m.id, m.created_at, u.username AS sender
                FROM messages m
                JOIN users u ON u.id = m.sender_id
                WHERE m.id IN (SELECT max(id) FROM messages GROUP BY room_id)
            )
            SELECT r.id, r.public_hash, r.name, r.type, r.owner_id, r.created_at, r.is_invite_only,
                   rm.role AS my_role,
                   rm.last_read_at,
                   (SELECT count(*) FROM room_members rm2 WHERE rm2.room_id = r.id) AS member_count,
                   last.id           AS last_message_id,
                   last.created_at   AS last_message_at,
                   last.sender       AS last_sender,
                   (SELECT count(*) FROM messages m2
                    WHERE m2.room_id = r.id
                      AND m2.sender_id != ?
                      AND m2.created_at > rm.last_read_at
                      AND m2.deleted_at IS NULL) AS unread_count
            FROM rooms r
            JOIN room_members rm ON rm.room_id = r.id
            LEFT JOIN last ON last.room_id = r.id
            WHERE rm.user_id = ?
              AND NOT EXISTS (SELECT 1 FROM room_bans rb WHERE rb.room_id = r.id AND rb.user_id = ?)
            ORDER BY COALESCE(last.created_at, r.created_at) DESC
        },
        $user_id, $user_id, $user_id,
    )->hashes->to_array;
}

sub list_messages ($self, $room_id, $before = undef, $limit = undef, $max_limit = undef, $default_limit = undef) {
    $default_limit //= 100;
    $max_limit     //= 200;

    $limit //= $default_limit;
    $limit = $max_limit if $limit > $max_limit;
    $limit = 1 if $limit < 1;

    my ($sql, @bind);
    if ($before) {
        $sql = q{
            SELECT m.id, m.sender_id, m.content_encrypted, m.content_iv, m.content_tag,
                   m.created_at, m.deleted_at, m.deleted_by,
                   (SELECT count(*) FROM message_edits me WHERE me.message_id = m.id) AS edit_count
            FROM messages m
            WHERE m.room_id = ? AND m.id < ?
            ORDER BY m.id DESC
            LIMIT ?
        };
        @bind = ($room_id, $before, $limit);
    } else {
        $sql = q{
            SELECT m.id, m.sender_id, m.content_encrypted, m.content_iv, m.content_tag,
                   m.created_at, m.deleted_at, m.deleted_by,
                   (SELECT count(*) FROM message_edits me WHERE me.message_id = m.id) AS edit_count
            FROM messages m
            WHERE m.room_id = ?
            ORDER BY m.id DESC
            LIMIT ?
        };
        @bind = ($room_id, $limit);
    }

    return $self->pg->db->query($sql, @bind)->hashes->to_array;
}

sub find_message ($self, $message_id) {
    return $self->pg->db->query(
        'SELECT id, room_id, sender_id, created_at FROM messages WHERE id = ?',
        $message_id,
    )->hash;
}

sub find_message_full ($self, $message_id) {
    return $self->pg->db->query(
        'SELECT m.*, u.username AS sender_username,
                du.username AS deleted_by_username
         FROM messages m
         JOIN users u ON u.id = m.sender_id
         LEFT JOIN users du ON du.id = m.deleted_by
         WHERE m.id = ?',
        $message_id,
    )->hash;
}

sub delete_message ($self, $message_id) {
    $self->pg->db->query('DELETE FROM messages WHERE id = ?', $message_id);
    return 1;
}

sub soft_delete_message ($self, $message_id, $user_id) {
    $self->pg->db->query(
        'UPDATE messages SET deleted_at = now(), deleted_by = ?
         WHERE id = ? AND deleted_at IS NULL',
        $user_id, $message_id,
    );
    return 1;
}

sub update_message ($self, $message_id, $ct, $iv, $tag) {
    $self->pg->db->query(
        'UPDATE messages
         SET content_encrypted = ?, content_iv = ?, content_tag = ?
         WHERE id = ?',
        $ct, $iv, $tag, $message_id,
    );
    return 1;
}

sub update_name ($self, $room_id, $name) {
    $self->pg->db->query(
        'UPDATE rooms SET name = ? WHERE id = ?',
        $name, $room_id,
    );
    return 1;
}

sub mark_read ($self, $room_id, $user_id) {
    $self->pg->db->query(
        'UPDATE room_members SET last_read_at = now() WHERE room_id = ? AND user_id = ?',
        $room_id, $user_id,
    );
    return 1;
}

sub delete ($self, $room_id) {
    $self->pg->db->query('DELETE FROM rooms WHERE id = ?', $room_id);
    return 1;
}

sub ban_user ($self, $room_id, $user_id, $banned_by) {
    $self->pg->db->query(
        'INSERT INTO room_bans (room_id, user_id, banned_by)
         VALUES (?, ?, ?)
         ON CONFLICT (room_id, user_id) DO NOTHING',
        $room_id, $user_id, $banned_by,
    );
    return 1;
}

sub unban_user ($self, $room_id, $user_id) {
    $self->pg->db->query(
        'DELETE FROM room_bans WHERE room_id = ? AND user_id = ?',
        $room_id, $user_id,
    );
    return 1;
}

sub is_banned ($self, $room_id, $user_id) {
    my $row = $self->pg->db->query(
        'SELECT 1 FROM room_bans WHERE room_id = ? AND user_id = ?',
        $room_id, $user_id,
    )->array;
    return $row ? 1 : 0;
}

sub list_bans ($self, $room_id) {
    return $self->pg->db->query(
        'SELECT rb.user_id, u.username, rb.banned_at,
                bu.username AS banned_by_username
         FROM room_bans rb
         JOIN users u ON u.id = rb.user_id
         JOIN users bu ON bu.id = rb.banned_by
         WHERE rb.room_id = ?
         ORDER BY rb.banned_at DESC',
        $room_id,
    )->hashes->to_array;
}

sub discover ($self, $user_id, $limit = 100, $offset = 0, $q = undef) {
    $limit = 200 if $limit > 200;
    $limit = 1 if $limit < 1;
    $offset = 0 if $offset < 0;

    my @bind = ($user_id, $user_id);
    my $name_clause = '';
    if (defined $q and length $q) {
        $name_clause = ' AND r.name ILIKE ?';
        push @bind, "%$q%";
    }
    push @bind, $limit, $offset;

    return $self->pg->db->query(
        "SELECT r.id, r.public_hash, r.name, r.type, r.owner_id, r.created_at,
                (SELECT count(*) FROM room_members rm2 WHERE rm2.room_id = r.id) AS member_count
         FROM rooms r
         WHERE r.type IN ('room', 'channel')
           AND r.is_invite_only = false
           AND NOT EXISTS (SELECT 1 FROM room_members rm WHERE rm.room_id = r.id AND rm.user_id = ?)
           AND NOT EXISTS (SELECT 1 FROM room_bans rb WHERE rb.room_id = r.id AND rb.user_id = ?)
           $name_clause
         ORDER BY r.created_at DESC
         LIMIT ? OFFSET ?",
        @bind,
    )->hashes->to_array;
}

sub count_discover ($self, $user_id, $q = undef) {
    my @bind = ($user_id, $user_id);
    my $name_clause = '';
    if (defined $q and length $q) {
        $name_clause = ' AND r.name ILIKE ?';
        push @bind, "%$q%";
    }

    return $self->pg->db->query(
        "SELECT count(*)
         FROM rooms r
         WHERE r.type IN ('room', 'channel')
           AND r.is_invite_only = false
           AND NOT EXISTS (SELECT 1 FROM room_members rm WHERE rm.room_id = r.id AND rm.user_id = ?)
           AND NOT EXISTS (SELECT 1 FROM room_bans rb WHERE rb.room_id = r.id AND rb.user_id = ?)
           $name_clause",
        @bind,
    )->array->[0];
}

1;
