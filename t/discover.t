use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

# Unauthenticated FIRST — before any login cookie is set
$t->get_ok('/api/rooms/discover')->status_is(401);

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

for my $n ('cats', 'dogs', 'birds') {
    $t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
        name => $n, type => 'room',
    })->status_is(200);
}

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'secret', type => 'room', is_invite_only => 1,
})->status_is(200);

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'dm-alice-bob', type => 'private', member_id => $bob_id,
})->status_is(200);

# Bob discovers — should see 3 public rooms
$t->get_ok('/api/rooms/discover' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/total' => 3);
my $list = $t->tx->res->json->{rooms};
my @names = map { $_->{name} } @$list;
is scalar(@names), 3, 'three discoverable';
ok((grep { $_ eq 'cats' }  @names), 'cats present');
ok((grep { $_ eq 'dogs' }  @names), 'dogs present');
ok((grep { $_ eq 'birds' } @names), 'birds present');
ok(!(grep { $_ eq 'secret' } @names), 'secret room excluded');

# Search
$t->get_ok('/api/rooms/discover?q=do' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/total' => 1);
is $t->tx->res->json->{rooms}[0]{name}, 'dogs', 'search filtered to dogs';

# Bob joins cats
my ($cats) = grep { $_->{name} eq 'cats' } @$list;
$t->post_ok("/api/rooms/$cats->{public_hash}/join" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

# Discover no longer shows cats
$t->get_ok('/api/rooms/discover' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/total' => 2);
$list = $t->tx->res->json->{rooms};
@names = map { $_->{name} } @$list;
ok(!(grep { $_ eq 'cats' } @names), 'cats removed after join');

# Public vs invite-only channel
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'chan-secret', type => 'channel', is_invite_only => 1,
})->status_is(200);
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'chan-public', type => 'channel',
})->status_is(200);

$t->get_ok('/api/rooms/discover?q=chan' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/total' => 1);
is $t->tx->res->json->{rooms}[0]{name}, 'chan-public', 'only public channel discoverable';

teardown_test_db($t->app);
done_testing();
