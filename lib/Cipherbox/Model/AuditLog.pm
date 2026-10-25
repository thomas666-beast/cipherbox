package Cipherbox::Model::AuditLog;
use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);

has pg => undef;

sub record ($self, $admin_id, $action, $target = undef, $details = undef, $ip = undef) {
    my $details_json = $details ? encode_json($details) : undef;
    $self->pg->db->query(
        'INSERT INTO audit_logs (admin_id, action, target, details, ip_address)
         VALUES (?, ?, ?, ?, ?)',
        $admin_id, $action, $target, $details_json, $ip,
    );
    return 1;
}

1;
