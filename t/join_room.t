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

# Alice creates a public room
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'public-room', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};

# Bob is not a member: GET metadata says joinable
$t->get_ok("/api/rooms/$room_id" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/room/is_member' => 0)
   ->json_is('/room/joinable' => 1)
   ->json_is('/room/name' => 'public-room');

# Bob joins
$t->post_ok("/api/rooms/$room_id/join" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

# Now Bob is a member
$t->get_ok("/api/rooms/$room_id" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/room/is_member' => 1);

# Joining again is idempotent
$t->post_ok("/api/rooms/$room_id/join" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)->json_is('/already_member' => 1);

# Bob appears in member list
$t->get_ok("/api/rooms/$room_id/members" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);
is scalar(@{ $t->tx->res->json->{members} }), 2, 'two members';

# Private rooms cannot be joined
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'dm-alice-bob', type => 'private', member_id => $bob_id,
})->status_is(200);
my $dm_id = $t->tx->res->json->{room}{id};

my ($carol_token, $carol_id) = make_user('carol');
$t->post_ok("/api/rooms/$dm_id/join" => { Authorization => "Bearer $carol_token" })
   ->status_is(403);

# Channel is joinable too
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'announcements', type => 'channel',
})->status_is(200);
my $channel_id = $t->tx->res->json->{room}{id};

$t->post_ok("/api/rooms/$channel_id/join" => { Authorization => "Bearer $carol_token" })
   ->status_is(200);

# Non-member sees metadata on private room but cannot join
$t->get_ok("/api/rooms/$dm_id" => { Authorization => "Bearer $carol_token" })
   ->status_is(200)
   ->json_is('/room/joinable' => 0);

teardown_test_db($t->app);
done_testing();
