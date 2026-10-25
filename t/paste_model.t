use Mojo::Base -strict;
use Test::More;
use lib 't/lib';
use TestSetup;
use Mojo::Pg;
use Cipherbox::Model::Paste;

my $pg = Mojo::Pg->new('postgresql://cipherbox:cipherbox@127.0.0.1/cipherbox_test');

# Seed the schema fixtures the model needs
$pg->db->query('TRUNCATE pastes, messages, room_members, room_bans, rooms, users, auth_attempts RESTART IDENTITY CASCADE');

my $alice = $pg->db->query(
    "INSERT INTO users (username, password_hash) VALUES ('alice', 'x') RETURNING *"
)->hash;
my $bob = $pg->db->query(
    "INSERT INTO users (username, password_hash) VALUES ('bob', 'x') RETURNING *"
)->hash;
my $room = $pg->db->query(
    "INSERT INTO rooms (name, type, owner_id, room_key_encrypted)
     VALUES ('r', 'room', ?, 'x') RETURNING *",
    $alice->{id},
)->hash;

my $pastes = Cipherbox::Model::Paste->new(pg => $pg);

# Create a text paste
my $text = $pastes->create_text(
    room_id            => $room->{id},
    sender_id          => $alice->{id},
    title              => 'API keys',
    content_encrypted  => 'ct',
    content_iv         => 'iv',
    content_tag        => 'tag',
    file_key_encrypted => 'wrapped',
);
ok $text->{id}, 'text paste created';
like $text->{public_hash}, qr/^[0-9a-f]{20}$/, 'hash is 20 hex chars';
is $text->{kind}, 'text', 'kind is text';

# Find by hash
my $found = $pastes->find_by_hash($text->{public_hash});
is $found->{id}, $text->{id}, 'find by hash';
my $found_id = $pastes->find_by_hash_or_id($text->{id});
is $found_id->{id}, $text->{id}, 'find by numeric id';

# Create a file paste
my $file = $pastes->create_file(
    room_id            => $room->{id},
    sender_id          => $alice->{id},
    title              => 'secret.pdf',
    mime_type          => 'application/pdf',
    file_name          => 'secret.pdf',
    file_size          => 1234,
    file_path          => 'abc.bin',
    file_key_encrypted => 'wrapped2',
);
is $file->{kind}, 'file', 'kind is file';

# Mark opened
$pastes->mark_opened($text->{id}, $bob->{id});
my $opened = $pastes->find_by_hash($text->{public_hash});
is $opened->{opened_by}, $bob->{id}, 'opened_by set';
ok $opened->{opened_at}, 'opened_at set';

# Second open attempt should be idempotent (no change)
$pastes->mark_opened($text->{id}, $alice->{id});
my $still = $pastes->find_by_hash($text->{public_hash});
is $still->{opened_by}, $bob->{id}, 'second open does not override';

# Mark deleted
$pastes->mark_deleted($text->{id});
my $deleted = $pastes->find_by_hash($text->{public_hash});
ok $deleted->{deleted_at}, 'deleted_at set';
is $deleted->{content_encrypted}, undef, 'content_encrypted cleared';
is $deleted->{file_key_encrypted}, undef, 'file_key_encrypted cleared';

# List for room
my $list = $pastes->list_for_room($room->{id});
is scalar(@$list), 2, 'two pastes in room';

# Expired pending (no expired ones yet)
my $expired = $pastes->expired_pending(60);
is scalar(@$expired), 0, 'nothing expired yet';

# Make one expire by setting opened_at far in the past
$pg->db->query(
    "UPDATE pastes SET opened_at = now() - interval '2 hours' WHERE id = ?",
    $file->{id},
);
$pg->db->query(
    "UPDATE pastes SET opened_by = ? WHERE id = ?", $bob->{id}, $file->{id},
);
my $expired2 = $pastes->expired_pending(60);
is scalar(@$expired2), 1, 'one expired';
is $expired2->[0]{id}, $file->{id}, 'correct row expired';

$pg->db->query('TRUNCATE pastes, messages, room_members, room_bans, rooms, users, auth_attempts RESTART IDENTITY CASCADE');
done_testing();
