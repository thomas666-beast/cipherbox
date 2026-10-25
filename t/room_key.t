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
    name => 'secret', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Alice (owner) can fetch key
$t->get_ok("/api/rooms/$room_id/key" => { Authorization => "Bearer $alice_token" })
   ->status_is(200)->json_has('/room_key');
my $alice_key = $t->tx->res->json->{room_key};

# Bob (member) gets the same key
$t->get_ok("/api/rooms/$room_id/key" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);
my $bob_key = $t->tx->res->json->{room_key};
is $bob_key, $alice_key, 'members get same room key';

# Eve (non-member) is denied
$t->get_ok("/api/rooms/$room_id/key" => { Authorization => "Bearer $eve_token" })
   ->status_is(403);

# Key is 44 base64 chars (32 bytes)
is length($alice_key), 44, 'key is 44 base64 chars (32 bytes)';

teardown_test_db($t->app);
done_testing();
