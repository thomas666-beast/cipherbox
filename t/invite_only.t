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

# --- Public room (default) ---
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'public-room', type => 'room',
})->status_is(200);
my $public_id = $t->tx->res->json->{room}{id};
my $public_hash = $t->tx->res->json->{room}{public_hash};

# Public room metadata: not invite-only, joinable
$t->get_ok("/api/rooms/$public_hash" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/room/is_invite_only' => 0)
   ->json_is('/room/joinable' => 1);

# Bob joins
$t->post_ok("/api/rooms/$public_hash/join" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

# --- Invite-only room ---
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'secret-room', type => 'room', is_invite_only => 1,
})->status_is(200);
my $secret_id   = $t->tx->res->json->{room}{id};
my $secret_hash = $t->tx->res->json->{room}{public_hash};

# Bob sees it as not joinable
$t->get_ok("/api/rooms/$secret_hash" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/room/is_invite_only' => 1)
   ->json_is('/room/joinable' => 0)
   ->json_is('/room/is_member' => 0);

# Bob cannot join directly
$t->post_ok("/api/rooms/$secret_hash/join" => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# Bob does not see it in his list
$t->get_ok('/api/rooms' => { Authorization => "Bearer $bob_token" })
   ->status_is(200);
my $list = $t->tx->res->json->{rooms};
my @names = map { $_->{name} } @$list;
ok !(grep { $_ eq 'secret-room' } @names), 'invite-only room not in bob list';

# Alice invites Bob
$t->post_ok("/api/rooms/$secret_hash/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Bob is now a member
$t->get_ok("/api/rooms/$secret_hash" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/room/is_member' => 1);

# Bob sees it in his list now
$t->get_ok('/api/rooms' => { Authorization => "Bearer $bob_token" })
   ->status_is(200);
$list = $t->tx->res->json->{rooms};
@names = map { $_->{name} } @$list;
ok((grep { $_ eq 'secret-room' } @names), 'invite-only room in bob list after invite');

# --- Channel with invite-only ---
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'private-channel', type => 'channel', is_invite_only => 1,
})->status_is(200);
my $chan_hash = $t->tx->res->json->{room}{public_hash};

# New user carol cannot join
my ($carol_token, $carol_id) = make_user('carol');
$t->post_ok("/api/rooms/$chan_hash/join" => { Authorization => "Bearer $carol_token" })
   ->status_is(403);

teardown_test_db($t->app);
done_testing();
