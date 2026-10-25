package Cipherbox::Model::User;
use Mojo::Base -base, -signatures;
use Crypt::Passphrase;

has pg => undef;

my $passphrase = Crypt::Passphrase->new(
    encoder => {
        module => 'Argon2',
        cost   => 2,
    },
);

sub create ($self, $username, $password, $role = 'user') {
    my $hash = $passphrase->hash_password($password);
    my $row  = $self->pg->db->query(
        'INSERT INTO users (username, password_hash, role)
         VALUES (?, ?, ?) RETURNING id, username, role',
        $username, $hash, $role,
    )->hash;
    return $row;
}

sub find_by_username ($self, $username) {
    return $self->pg->db->query(
        'SELECT * FROM users WHERE username = ?', $username
    )->hash;
}

sub find_by_id ($self, $id) {
    return $self->pg->db->query(
        'SELECT * FROM users WHERE id = ?', $id
    )->hash;
}

sub verify_password ($self, $user, $password) {
    return $passphrase->verify_password($password, $user->{password_hash});
}

sub search ($self, $query, $limit = 50) {
    return [] unless defined $query and length $query;
    my $like = "%$query%";
    return $self->pg->db->query(
        'SELECT id, username, role FROM users
         WHERE username ILIKE ?
         ORDER BY username
         LIMIT ?',
        $like, $limit,
    )->hashes->to_array;
}

sub list_all ($self, $limit = 100, $offset = 0) {
    return $self->pg->db->query(
        'SELECT id, username, role, created_at FROM users
         ORDER BY id
         LIMIT ? OFFSET ?',
        $limit, $offset,
    )->hashes->to_array;
}

sub count ($self) {
    return $self->pg->db->query('SELECT count(*) FROM users')->array->[0];
}

sub delete ($self, $id) {
    $self->pg->db->query('DELETE FROM users WHERE id = ?', $id);
    return 1;
}

sub count_admins ($self) {
    return $self->pg->db->query(
        "SELECT count(*) FROM users WHERE role = 'admin'"
    )->array->[0];
}

sub update_role ($self, $user_id, $role) {
    $self->pg->db->query(
        'UPDATE users SET role = ? WHERE id = ?',
        $role, $user_id,
    );
    return 1;
}

1;
