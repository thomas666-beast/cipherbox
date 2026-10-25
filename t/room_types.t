use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use Mojo::JSON qw(decode_json);
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
my ($carol_token, $carol_id) = make_user('carol');

my $alice_ws_token = $t->get_ok('/api/ws-token' => { Authorization => "Bearer $alice_token" })
   ->status_is(200)->tx->res->json->{token};
my $bob_ws_token = $t->get_ok('/api/ws-token' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)->tx->res->json->{token};

# --- Private room ---
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'dm', type => 'private', member_id => $bob_id,
})->status_is(200);
my $private_id = $t->tx->res->json->{room}{id};

$t->post_ok("/api/rooms/$private_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $carol_id,
})->status_is(400);

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'dm2', type => 'private',
})->status_is(400);

# --- Channel ---
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'announcements', type => 'channel',
})->status_is(200);
my $channel_id = $t->tx->res->json->{room}{id};

$t->post_ok("/api/rooms/$channel_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);
$t->post_ok("/api/rooms/$channel_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $carol_id,
})->status_is(200);

$t->websocket_ok("/chat?token=$alice_ws_token");
$t->send_ok({json => { type => 'chat.join', room_id => $channel_id }});
$t->message_ok;
is decode_json($t->message->[1])->{type}, 'chat.joined', 'alice joined channel';

$t->send_ok({json => {
    type => 'chat.send', room_id => $channel_id,
    ct => 'Y3Q=', iv => 'aXY=', tag => 'dGFn',
}});

# Skip past any room.updated to find chat.recv
my $msg;
my $found = 0;
for (1 .. 5) {
    last unless $t->message_ok;
    $msg = decode_json($t->message->[1]);
    if ($msg->{type} eq 'chat.recv') { $found = 1; last }
}
ok $found, 'alice (owner) can post';

# Bob joins channel, cannot post
$t->websocket_ok("/chat?token=$bob_ws_token");
$t->send_ok({json => { type => 'chat.join', room_id => $channel_id }});
$t->message_ok;
is decode_json($t->message->[1])->{type}, 'chat.joined', 'bob joined channel';

$t->send_ok({json => {
    type => 'chat.send', room_id => $channel_id,
    ct => 'Y3Q=', iv => 'aXY=', tag => 'dGFn',
}});

$found = 0;
for (1 .. 5) {
    last unless $t->message_ok;
    $msg = decode_json($t->message->[1]);
    if ($msg->{type} eq 'error') { $found = 1; last }
}
ok $found, 'bob cannot post';
is $msg->{reason}, 'read_only', 'reason read_only';

# --- Regular room ---
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'general', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

$t->websocket_ok("/chat?token=$bob_ws_token");
$t->send_ok({json => { type => 'chat.join', room_id => $room_id }});
$t->message_ok;
is decode_json($t->message->[1])->{type}, 'chat.joined', 'bob joined general';

$t->send_ok({json => {
    type => 'chat.send', room_id => $room_id,
    ct => 'Y3Q=', iv => 'aXY=', tag => 'dGFn',
}});

$found = 0;
for (1 .. 5) {
    last unless $t->message_ok;
    $msg = decode_json($t->message->[1]);
    if ($msg->{type} eq 'chat.recv') { $found = 1; last }
}
ok $found, 'bob can post in general';

teardown_test_db($t->app);
done_testing();
