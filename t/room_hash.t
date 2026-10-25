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
    return $t->post_ok('/api/auth/login' => json => { username => $name, password => 'pw123456' })
      ->status_is(200)->tx->res->json->{token};
}

my $alice_token = make_user('alice');

# Create room → response contains public_hash
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'hashed', type => 'room',
})->status_is(200)->json_has('/room/public_hash');
my $room = $t->tx->res->json->{room};
my $hash = $room->{public_hash};
my $id   = $room->{id};

like $hash, qr/^[0-9a-f]{20}$/, 'public_hash is 20 hex chars';

# List contains public_hash
$t->get_ok('/api/rooms' => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
is $t->tx->res->json->{rooms}[0]{public_hash}, $hash, 'list exposes public_hash';

# Fetch by hash
$t->get_ok("/api/rooms/$hash" => { Authorization => "Bearer $alice_token" })
   ->status_is(200)
   ->json_is('/room/name' => 'hashed');

# Fetch by numeric id also works (backwards compat)
$t->get_ok("/api/rooms/$id" => { Authorization => "Bearer $alice_token" })
   ->status_is(200)
   ->json_is('/room/name' => 'hashed');

# Other endpoints accept hash
$t->get_ok("/api/rooms/$hash/members" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
$t->get_ok("/api/rooms/$hash/key" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
$t->get_ok("/api/rooms/$hash/messages" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);

# Non-existent hash → 404
$t->get_ok('/api/rooms/00000000000000000000' => { Authorization => "Bearer $alice_token" })
   ->status_is(404);

teardown_test_db($t->app);
done_testing();
