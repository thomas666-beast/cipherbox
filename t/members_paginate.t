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

my ($owner_token, $owner_id) = make_user('owner');

$t->post_ok('/api/rooms' => { Authorization => "Bearer $owner_token" } => json => {
    name => 'big-room', type => 'room',
})->status_is(200);
my $room_hash = $t->tx->res->json->{room}{public_hash};
my $room_id   = $t->tx->res->json->{room}{id};

# Add 250 members via direct DB inserts (fast)
my $db = $t->app->pg->db;
for my $i (1 .. 250) {
    my $u = $db->query(
        "INSERT INTO users (username, password_hash) VALUES (?, 'x') RETURNING id",
        "member$i",
    )->hash;
    $db->query(
        'INSERT INTO room_members (room_id, user_id, role) VALUES (?, ?, ?)',
        $room_id, $u->{id}, 'member',
    );
}

# Total count is 251 (owner + 250)
$t->get_ok("/api/rooms/$room_hash/members" => { Authorization => "Bearer $owner_token" })
   ->status_is(200)
   ->json_is('/total' => 251)
   ->json_is('/limit' => 100)
   ->json_is('/offset' => 0);
is scalar(@{ $t->tx->res->json->{members} }), 100, 'first page has 100';

$t->get_ok("/api/rooms/$room_hash/members?offset=100" => { Authorization => "Bearer $owner_token" })
   ->status_is(200);
is scalar(@{ $t->tx->res->json->{members} }), 100, 'second page has 100';

$t->get_ok("/api/rooms/$room_hash/members?offset=200" => { Authorization => "Bearer $owner_token" })
   ->status_is(200);
is scalar(@{ $t->tx->res->json->{members} }), 51, 'third page has 51';

# Filter by username
$t->get_ok("/api/rooms/$room_hash/members?q=member1" => { Authorization => "Bearer $owner_token" })
   ->status_is(200)
   ->json_is('/total' => 111);

$t->get_ok("/api/rooms/$room_hash/members?q=member42" => { Authorization => "Bearer $owner_token" })
   ->status_is(200)
   ->json_is('/total' => 1);

# Limit cap
$t->get_ok("/api/rooms/$room_hash/members?limit=500" => { Authorization => "Bearer $owner_token" })
   ->status_is(200)
   ->json_is('/limit' => 200);

teardown_test_db($t->app);
done_testing();
