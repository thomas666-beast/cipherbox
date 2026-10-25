use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

# Unauthenticated request (before any login — cookie jar is empty)
$t->get_ok('/api/rooms')->status_is(401);

sub make_user {
    my ($name) = @_;
    $t->post_ok('/api/auth/register' => json => {
        username => $name, password => 'pw123456',
    })->status_is(200);
    return $t->post_ok('/api/auth/login' => json => {
        username => $name, password => 'pw123456',
    })->status_is(200)->tx->res->json->{token};
}

my $alice_token = make_user('alice');
my $bob_token   = make_user('bob');

# Alice's list is empty initially
$t->get_ok('/api/rooms' => { Authorization => "Bearer $alice_token" })
   ->status_is(200)
   ->json_is('/rooms' => []);

# Alice creates a room
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'general', type => 'room',
})->status_is(200)->json_has('/room/id');

my $room_id = $t->tx->res->json->{room}{id};

# Alice's room list contains the room
$t->get_ok('/api/rooms' => { Authorization => "Bearer $alice_token" })
   ->status_is(200)
   ->json_is('/rooms/0/name' => 'general')
   ->json_is('/rooms/0/type' => 'room')
   ->json_is('/rooms/0/my_role' => 'owner');

# New activity fields present
my $first_room = $t->tx->res->json->{rooms}[0];
ok defined $first_room->{member_count}, 'member_count present';
is $first_room->{member_count}, 1, 'one member (owner)';
ok exists $first_room->{last_message_id}, 'last_message_id key present';
ok exists $first_room->{last_message_at}, 'last_message_at key present';
ok exists $first_room->{last_sender}, 'last_sender key present';
is $first_room->{last_message_id}, undef, 'no messages yet';

# Bob cannot invite (not a member)
my $bob_id = $t->app->pg->db->query(
    "SELECT id FROM users WHERE username = 'bob'"
)->array->[0];

$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $bob_token" } => json => {
    user_id => $bob_id,
})->status_is(403);

# Alice invites Bob
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Bob is now a member; his list contains the room
$t->get_ok('/api/rooms' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/rooms/0/name' => 'general')
   ->json_is('/rooms/0/my_role' => 'member');

# Member count updated
my $bob_view = $t->tx->res->json->{rooms}[0];
is $bob_view->{member_count}, 2, 'two members after invite';

# Alice sees the same count
$t->get_ok('/api/rooms' => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
is $t->tx->res->json->{rooms}[0]{member_count}, 2, 'alice sees two members';

# Member list endpoint
$t->get_ok("/api/rooms/$room_id/members" => { Authorization => "Bearer $alice_token" })
   ->status_is(200)
   ->json_is('/members/0/role' => 'owner')
   ->json_is('/members/1/role' => 'member');

# Bob (member) cannot remove anyone
my $alice_id = $t->app->pg->db->query(
    "SELECT id FROM users WHERE username = 'alice'"
)->array->[0];

$t->post_ok("/api/rooms/$room_id/remove" => { Authorization => "Bearer $bob_token" } => json => {
    user_id => $alice_id,
})->status_is(403);

# Alice removes Bob
$t->post_ok("/api/rooms/$room_id/remove" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Bob's list is empty again
$t->get_ok('/api/rooms' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/rooms' => []);

# Owner cannot be removed
$t->post_ok("/api/rooms/$room_id/remove" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $alice_id,
})->status_is(400);

# Private room reuse
my $bob_id2 = $t->app->pg->db->query("SELECT id FROM users WHERE username = 'bob'")->array->[0];
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'dm-with-bob', type => 'private', member_id => $bob_id2,
})->status_is(200);
my $dm1_id = $t->tx->res->json->{room}{id};

# Alice creates another "private" with Bob — should reuse the same room
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'whatever', type => 'private', member_id => $bob_id2,
})->status_is(200)->json_is('/reused' => 1);
is $t->tx->res->json->{room}{id}, $dm1_id, 'same private room reused';

# Unread count: Alice creates room, inserts 3 messages from Bob
my $db = $t->app->pg->db;
$db->query(
    'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
     VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
    $room_id, $bob_id, 'A', 'IV', 'TAG',
    $room_id, $bob_id, 'B', 'IV', 'TAG',
    $room_id, $bob_id, 'C', 'IV', 'TAG',
);

$t->get_ok('/api/rooms' => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
is $t->tx->res->json->{rooms}[0]{unread_count}, 3, 'alice has 3 unread';

# Alice marks read
$t->post_ok("/api/rooms/$room_id/read" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);

$t->get_ok('/api/rooms' => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
is $t->tx->res->json->{rooms}[0]{unread_count}, 0, 'unread cleared after mark_read';

# New message after read
$db->query(
    'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
     VALUES (?, ?, ?, ?, ?)',
    $room_id, $bob_id, 'D', 'IV', 'TAG',
);
$t->get_ok('/api/rooms' => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
is $t->tx->res->json->{rooms}[0]{unread_count}, 1, 'one new unread';

teardown_test_db($t->app);
done_testing();
