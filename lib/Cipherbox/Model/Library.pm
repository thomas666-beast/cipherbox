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

sub list_categories ($self, $parent_id, $limit, $offset) {
    my ($where, @bind) = defined($parent_id) ? ('c.parent_id = ?', $parent_id) : ('c.parent_id IS NULL');
    return $self->pg->db->query(
        "SELECT c.*, EXISTS (SELECT 1 FROM library_categories child WHERE child.parent_id = c.id) AS has_children
         FROM library_categories c WHERE $where ORDER BY c.name, c.id LIMIT ? OFFSET ?",
        @bind, $limit, $offset,
    )->hashes->to_array;
}

sub category_path ($self, $id) {
    return $self->pg->db->query(
        q{WITH RECURSIVE ancestors AS (
            SELECT id, parent_id, public_hash, name, 0 AS depth, ARRAY[id] AS visited
            FROM library_categories WHERE id = ?
            UNION ALL
            SELECT p.id, p.parent_id, p.public_hash, p.name, a.depth + 1, a.visited || p.id
            FROM ancestors a JOIN library_categories p ON p.id = a.parent_id
            WHERE NOT p.id = ANY(a.visited)
        ) SELECT id, public_hash, name FROM ancestors ORDER BY depth DESC},
        $id,
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
         ORDER BY li.created_at DESC, li.id DESC
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
