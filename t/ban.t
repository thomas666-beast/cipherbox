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

# Alice creates public room, invites Bob
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'general', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Bob leaves voluntarily first (he can rejoin since not banned)
$t->post_ok("/api/rooms/$room_id/leave" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);
$t->post_ok("/api/rooms/$room_id/join" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

# Alice removes Bob (this bans)
$t->post_ok("/api/rooms/$room_id/remove" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Bob cannot join
$t->post_ok("/api/rooms/$room_id/join" => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# Bob cannot get the room key
$t->get_ok("/api/rooms/$room_id/key" => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# Bob cannot get messages
$t->get_ok("/api/rooms/$room_id/messages" => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# Public room metadata shows banned
$t->get_ok("/api/rooms/$room_id" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/room/banned' => 1)
   ->json_is('/room/joinable' => 0)
   ->json_is('/room/is_member' => 0);

# Bob does not see the room in his list
$t->get_ok('/api/rooms' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/rooms' => []);

# Alice cannot invite a banned user
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(400);

# Alice can list bans
$t->get_ok("/api/rooms/$room_id/bans" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
my $bans = $t->tx->res->json->{bans};
is scalar(@$bans), 1, 'one ban';
is $bans->[0]{username}, 'bob', 'bob banned';

# Non-owner cannot list bans
$t->get_ok("/api/rooms/$room_id/bans" => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# Alice unbans Bob
$t->delete_ok("/api/rooms/$room_id/ban/$bob_id" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);

# Bob can join again
$t->post_ok("/api/rooms/$room_id/join" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

teardown_test_db($t->app);
done_testing();
