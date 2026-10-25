use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

sub make_user {
    my ($name) = @_;
    $t->post_ok('/api/auth/register' => json => { username => $name, password => 'pw123456' })
      ->status_is(200);
    my $token = $t->post_ok('/api/auth/login' => json => { username => $name, password => 'pw123456' })
      ->status_is(200)->tx->res->json->{token};
    my $id = $t->app->pg->db->query(
        'SELECT id FROM users WHERE username = ?', $name
    )->array->[0];
    return ($token, $id);
}

my ($alice_token, $alice_id) = make_user('alice');
my ($bob_token,   $bob_id)   = make_user('bob');
my ($eve_token,   $eve_id)   = make_user('eve');

# Alice creates a room, invites Bob
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'general', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Insert one message from Bob
my $db = $t->app->pg->db;
my $msg_id = $db->query(
    'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
     VALUES (?, ?, ?, ?, ?) RETURNING id',
    $room_id, $bob_id, 'OLD_CT', 'OLD_IV', 'OLD_TAG',
)->array->[0];

# Eve (non-member) cannot edit
$t->patch_ok("/api/rooms/$room_id/messages/$msg_id" => { Authorization => "Bearer $eve_token" } => json => {
    ct => 'X', iv => 'Y', tag => 'Z',
})->status_is(403);

# Alice (owner but not sender) can edit
$t->patch_ok("/api/rooms/$room_id/messages/$msg_id" => { Authorization => "Bearer $alice_token" } => json => {
    ct => 'NEW_CT_1', iv => 'NEW_IV_1', tag => 'NEW_TAG_1',
})->status_is(200);

my $row = $db->query('SELECT * FROM messages WHERE id = ?', $msg_id)->hash;
is $row->{content_encrypted}, 'NEW_CT_1', 'ciphertext updated by owner';
is $row->{content_iv}, 'NEW_IV_1', 'iv updated';
is $row->{content_tag}, 'NEW_TAG_1', 'tag updated';

# Bob (sender) can edit his own message
$t->patch_ok("/api/rooms/$room_id/messages/$msg_id" => { Authorization => "Bearer $bob_token" } => json => {
    ct => 'NEW_CT_2', iv => 'NEW_IV_2', tag => 'NEW_TAG_2',
})->status_is(200);

$row = $db->query('SELECT * FROM messages WHERE id = ?', $msg_id)->hash;
is $row->{content_encrypted}, 'NEW_CT_2', 'ciphertext updated by sender';

# Missing fields → 400
$t->patch_ok("/api/rooms/$room_id/messages/$msg_id" => { Authorization => "Bearer $bob_token" } => json => {
    ct => 'X',
})->status_is(400);

# Non-existent message → 404
$t->patch_ok("/api/rooms/$room_id/messages/999999" => { Authorization => "Bearer $alice_token" } => json => {
    ct => 'X', iv => 'Y', tag => 'Z',
})->status_is(404);

# Edit history is recorded
my $edits = $db->query(
    'SELECT * FROM message_edits WHERE message_id = ? ORDER BY edited_at',
    $msg_id,
)->hashes;
is scalar(@$edits), 2, 'two edits recorded in history';
is $edits->[0]{content_encrypted}, 'OLD_CT', 'first edit stores old content';
is $edits->[1]{content_encrypted}, 'NEW_CT_1', 'second edit stores previous version';

teardown_test_db($t->app);
done_testing();
