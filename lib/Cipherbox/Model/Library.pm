package Cipherbox::Model::Library;
use Mojo::Base -base, -signatures;
use Crypt::PRNG qw(random_bytes);

has pg => undef;

sub _new_hash ($self) {
    return unpack('H*', random_bytes(10));
}

# ---------- Categories ----------

sub create_category ($self, $name, $type, $parent_id = undef) {
    my $hash = $self->_new_hash;
    return $self->pg->db->query(
        'INSERT INTO library_categories (name, type, parent_id, public_hash)
         VALUES (?, ?, ?, ?) RETURNING *',
        $name, $type, $parent_id, $hash,
    )->hash;
}

sub find_category ($self, $id) {
    return $self->pg->db->query(
        'SELECT * FROM library_categories WHERE id = ?', $id
    )->hash;
}

sub find_category_by_hash ($self, $hash) {
    return $self->pg->db->query(
        'SELECT * FROM library_categories WHERE public_hash = ?', $hash
    )->hash;
}

sub find_category_by_hash_or_id ($self, $param) {
    return undef unless defined $param and length $param;
    if ($param =~ /^\d+$/) {
        return $self->find_category($param);
    }
    return $self->find_category_by_hash($param);
}

sub list_categories ($self, $parent_id = undef) {
    if (defined $parent_id) {
        return $self->pg->db->query(
            'SELECT * FROM library_categories WHERE parent_id = ? ORDER BY name',
            $parent_id,
        )->hashes->to_array;
    }
    return $self->pg->db->query(
        'SELECT * FROM library_categories WHERE parent_id IS NULL ORDER BY name'
    )->hashes->to_array;
}

sub delete_category ($self, $id) {
    $self->pg->db->query('DELETE FROM library_categories WHERE id = ?', $id);
    return 1;
}

# ---------- Items ----------

sub create_item ($self, %args) {
    my $hash = $self->_new_hash;
    return $self->pg->db->query(
        'INSERT INTO library_items
            (category_id, title, file_path, file_key_encrypted, mime_type, uploaded_by, file_size, uuid, public_hash)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING *',
        @args{qw(category_id title file_path file_key_encrypted mime_type uploaded_by file_size uuid)},
        $hash,
    )->hash;
}

sub find_item ($self, $id) {
    return $self->pg->db->query(
        'SELECT * FROM library_items WHERE id = ?', $id
    )->hash;
}

sub find_item_by_hash ($self, $hash) {
    return $self->pg->db->query(
        'SELECT * FROM library_items WHERE public_hash = ?', $hash
    )->hash;
}

sub find_item_by_hash_or_id ($self, $param) {
    return undef unless defined $param and length $param;
    if ($param =~ /^\d+$/) {
        return $self->find_item($param);
    }
    return $self->find_item_by_hash($param);
}

sub list_items ($self, $category_id, $limit = 100, $offset = 0) {
    return $self->pg->db->query(
        'SELECT li.id, li.category_id, li.public_hash, li.title, li.mime_type,
                li.file_size, li.created_at,
                u.username AS uploaded_by
         FROM library_items li
         JOIN users u ON u.id = li.uploaded_by
         WHERE li.category_id = ?
         ORDER BY li.created_at DESC
         LIMIT ? OFFSET ?',
        $category_id, $limit, $offset,
    )->hashes->to_array;
}

sub delete_item ($self, $id) {
    $self->pg->db->query('DELETE FROM library_items WHERE id = ?', $id);
    return 1;
}

sub update_item_title ($self, $id, $title) {
    $self->pg->db->query(
        'UPDATE library_items SET title = ? WHERE id = ?',
        $title, $id,
    );
    return 1;
}

sub tree ($self) {
    my $rows = $self->pg->db->query(
        'SELECT id, public_hash, name, parent_id, type FROM library_categories ORDER BY name'
    )->hashes;

    my %by_parent;
    for my $row (@$rows) {
        my $key = defined $row->{parent_id} ? $row->{parent_id} : 'root';
        push @{ $by_parent{$key} }, $row;
    }

    my $build;
    $build = sub {
        my ($parent_key) = @_;
        my @children = @{ $by_parent{$parent_key} // [] };
        return [
            map {
                {
                    id          => $_->{id},
                    public_hash => $_->{public_hash},
                    name        => $_->{name},
                    type        => $_->{type},
                    children    => $build->($_->{id}),
                }
            } @children
        ];
    };

    return $build->('root');
}

1;

