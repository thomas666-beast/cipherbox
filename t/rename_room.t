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

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'old-name', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};

# Eve (non-member) cannot rename
$t->patch_ok("/api/rooms/$room_id" => { Authorization => "Bearer $eve_token" } => json => {
    name => 'hacked',
})->status_is(403);

# Invite Bob as member
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Bob (member, not owner) cannot rename
$t->patch_ok("/api/rooms/$room_id" => { Authorization => "Bearer $bob_token" } => json => {
    name => 'bobs-name',
})->status_is(403);

# Alice (owner) can rename
$t->patch_ok("/api/rooms/$room_id" => { Authorization => "Bearer $alice_token" } => json => {
    name => 'new-name',
})->status_is(200)->json_is('/name' => 'new-name');

# Verify in list
$t->get_ok('/api/rooms' => { Authorization => "Bearer $alice_token" })
   ->status_is(200)
   ->json_is('/rooms/0/name' => 'new-name');

# Missing name → 400
$t->patch_ok("/api/rooms/$room_id" => { Authorization => "Bearer $alice_token" } => json => {})
   ->status_is(400);

# Non-existent room → 404
$t->patch_ok('/api/rooms/999999' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'whatever',
})->status_is(404);

teardown_test_db($t->app);
done_testing();
