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

# Alice creates room, invites Bob
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'general', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Owner cannot leave
$t->post_ok("/api/rooms/$room_id/leave" => { Authorization => "Bearer $alice_token" })
   ->status_is(400);

# Non-member cannot leave
$t->post_ok("/api/rooms/$room_id/leave" => { Authorization => "Bearer $eve_token" })
   ->status_is(403);

# Bob leaves
$t->post_ok("/api/rooms/$room_id/leave" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

# Bob is no longer a member: room list empty
$t->get_ok('/api/rooms' => { Authorization => "Bearer $bob_token" })
   ->status_is(200);
is scalar(@{ $t->tx->res->json->{rooms} }), 0, 'bob sees no rooms';

# Non-owner cannot delete
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);
$t->delete_ok("/api/rooms/$room_id" => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# Owner deletes
$t->delete_ok("/api/rooms/$room_id" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);

# Room is gone: 404 on fetch
$t->get_ok("/api/rooms/$room_id/messages" => { Authorization => "Bearer $alice_token" })
   ->status_is(404);

# Members cascade-deleted
my $member_count = $t->app->pg->db->query(
    'SELECT count(*) FROM room_members WHERE room_id = ?', $room_id
)->array->[0];
is $member_count, 0, 'members cascade-deleted';

teardown_test_db($t->app);
done_testing();
