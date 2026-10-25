package Cipherbox::Model::Settings;
use Mojo::Base -base, -signatures;

has pg => undef;

sub get ($self, $key, $default = undef) {
    my $row = $self->pg->db->query(
        'SELECT value FROM settings WHERE key = ?', $key
    )->array;
    return $row ? $row->[0] : $default;
}

sub set ($self, $key, $value) {
    $self->pg->db->query(
        'INSERT INTO settings (key, value, updated_at)
         VALUES (?, ?, now())
         ON CONFLICT (key) DO UPDATE
            SET value = EXCLUDED.value, updated_at = now()',
        $key, $value,
    );
    return 1;
}

sub bool ($self, $key, $default = 1) {
    my $v = $self->get($key);
    return $default unless defined $v;
    return ($v eq 'true' || $v eq '1') ? 1 : 0;
}

1;
