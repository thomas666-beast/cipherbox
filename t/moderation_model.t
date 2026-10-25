use Mojo::Base -strict;
use Test::More;
use Mojo::Pg;
use Cipherbox::Model::Report;
use Cipherbox::Model::MessageEdit;
use Cipherbox::Model::Room;

my $pg = Mojo::Pg->new('postgresql://cipherbox:cipherbox@127.0.0.1/cipherbox_test');
$pg->db->query('TRUNCATE reports, message_edits, pastes, messages, room_members, room_bans, rooms, users, auth_attempts RESTART IDENTITY CASCADE');

my $alice = $pg->db->query(
    "INSERT INTO users (username, password_hash) VALUES ('alice', 'x') RETURNING *"
)->hash;
my $bob = $pg->db->query(
    "INSERT INTO users (username, password_hash) VALUES ('bob', 'x') RETURNING *"
)->hash;
my $room = $pg->db->query(
    "INSERT INTO rooms (name, type, owner_id, room_key_encrypted)
     VALUES ('r', 'room', ?, 'x') RETURNING *", $alice->{id}
)->hash;
my $msg = $pg->db->query(
    "INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
     VALUES (?, ?, 'ct', 'iv', 'tag') RETURNING *",
    $room->{id}, $alice->{id},
)->hash;

my $reports = Cipherbox::Model::Report->new(pg => $pg);
my $edits   = Cipherbox::Model::MessageEdit->new(pg => $pg);
my $rooms   = Cipherbox::Model::Room->new(pg => $pg);

# --- Reports ---
my $r = $reports->create($bob->{id}, $msg->{id}, $room->{id}, 'bad behavior');
ok $r->{id}, 'report created';
is $reports->count_open, 1, 'one open report';
my $list = $reports->list_open;
is scalar(@$list), 1, 'list shows 1';
is $list->[0]{reporter_username}, 'bob', 'reporter name present';
is $list->[0]{sender_username}, 'alice', 'sender name present';

my $found = $reports->find_by_id($r->{id});
is $found->{status}, 'open', 'status open';

$reports->resolve($r->{id}, $bob->{id}, 'handled');
$found = $reports->find_by_id($r->{id});
is $found->{status}, 'resolved', 'status resolved';
is $reports->count_open, 0, 'no open reports';

# open_for_room
$reports->create($bob->{id}, $msg->{id}, $room->{id}, 'another');
ok $reports->open_for_room($room->{id}), 'open report exists for room';

# --- Message edits ---
$edits->record($msg->{id}, $alice->{id}, 'ct1', 'iv1', 'tag1');
$edits->record($msg->{id}, $alice->{id}, 'ct2', 'iv2', 'tag2');
is $edits->count_for_message($msg->{id}), 2, 'two edits recorded';
my $hist = $edits->list_for_message($msg->{id});
is scalar(@$hist), 2, 'history has 2 entries';
is $hist->[0]{content_encrypted}, 'ct1', 'first edit';
is $hist->[1]{content_encrypted}, 'ct2', 'second edit';
is $hist->[0]{editor_username}, 'alice', 'editor name';

# --- Soft delete ---
$rooms->soft_delete_message($msg->{id}, $alice->{id});
my $deleted = $rooms->find_message_full($msg->{id});
ok $deleted->{deleted_at}, 'deleted_at set';
is $deleted->{deleted_by}, $alice->{id}, 'deleted_by set';
is $deleted->{deleted_by_username}, 'alice', 'deleted_by username';

$pg->db->query('TRUNCATE reports, message_edits, pastes, messages, room_members, room_bans, rooms, users, auth_attempts RESTART IDENTITY CASCADE');
done_testing();
