package Cipherbox::Model::AuthAttempts;
use Mojo::Base -base, -signatures;

has pg => undef;

sub _cleanup ($self) {
    $self->pg->db->query(
        "DELETE FROM auth_attempts WHERE created_at < now() - interval '1 hour'"
    );
}

sub recent_failures ($self, $ip, $username) {
    return $self->pg->db->query(
        q{
            SELECT count(*) FROM auth_attempts
            WHERE ip = ? AND username = ? AND kind = 'login_fail'
              AND created_at > now() - interval '15 minutes'
        },
        $ip, $username,
    )->array->[0];
}

sub record_failure ($self, $ip, $username) {
    $self->pg->db->query(
        "INSERT INTO auth_attempts (ip, username, kind) VALUES (?, ?, 'login_fail')",
        $ip, $username,
    );
}

sub clear_failures ($self, $ip, $username) {
    $self->pg->db->query(
        "DELETE FROM auth_attempts WHERE ip = ? AND username = ? AND kind = 'login_fail'",
        $ip, $username,
    );
}

sub recent_registrations ($self, $ip) {
    return $self->pg->db->query(
        q{
            SELECT count(*) FROM auth_attempts
            WHERE ip = ? AND kind = 'register'
              AND created_at > now() - interval '1 hour'
        },
        $ip,
    )->array->[0];
}

sub record_registration ($self, $ip) {
    $self->pg->db->query(
        "INSERT INTO auth_attempts (ip, kind) VALUES (?, 'register')",
        $ip,
    );
}

1;
