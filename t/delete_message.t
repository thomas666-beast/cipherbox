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
    $t->app->pg->db->query("DELETE FROM auth_attempts WHERE kind = 'register'");
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

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'general', type => 'room',
})->status_is(200);
my $room_hash = $t->tx->res->json->{room}{public_hash};
$t->post_ok("/api/rooms/$room_hash/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Insert messages directly
my $db = $t->app->pg->db;
my @msg_ids;
for my $pair ([$alice_id, 'A1'], [$bob_id, 'B1'], [$alice_id, 'A2']) {
    my $id = $db->query(
        'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
         VALUES (?, ?, ?, ?, ?) RETURNING id',
        $t->app->pg->db->query(
            'SELECT id FROM rooms WHERE public_hash = ?', $room_hash
        )->array->[0],
        $pair->[0], $pair->[1], 'IV', 'TAG',
    )->array->[0];
    push @msg_ids, $id;
}

# Eve (non-member) cannot delete
$t->delete_ok("/api/rooms/$room_hash/messages/$msg_ids[0]" => { Authorization => "Bearer $eve_token" })
   ->status_is(403);

# Bob cannot delete Alice's message
$t->delete_ok("/api/rooms/$room_hash/messages/$msg_ids[0]" => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# Bob can delete his own
$t->delete_ok("/api/rooms/$room_hash/messages/$msg_ids[1]" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

# Message still exists but deleted_at is set
my $row = $db->query('SELECT * FROM messages WHERE id = ?', $msg_ids[1])->hash;
ok $row, 'message row still exists';
ok $row->{deleted_at}, 'deleted_at set';
is $row->{deleted_by}, $bob_id, 'deleted_by is bob';
is $row->{content_encrypted}, 'B1', 'content preserved';

# Alice can delete her own
$t->delete_ok("/api/rooms/$room_hash/messages/$msg_ids[0]" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);

# Owner can delete Bob's message
my $bob_msg = $db->query(
    'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
     VALUES (?, ?, ?, ?, ?) RETURNING id',
    $db->query('SELECT id FROM rooms WHERE public_hash = ?', $room_hash)->array->[0],
    $bob_id, 'B2', 'IV', 'TAG',
)->array->[0];

$t->delete_ok("/api/rooms/$room_hash/messages/$bob_msg" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);

# Messages list includes deleted_at and edit_count
$t->get_ok("/api/rooms/$room_hash/messages" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
my $msgs = $t->tx->res->json->{messages};
ok(defined $msgs->[0]{deleted_at}, 'deleted_at in response');
ok(exists $msgs->[0]{edit_count}, 'edit_count in response');

teardown_test_db($t->app);
done_testing();
