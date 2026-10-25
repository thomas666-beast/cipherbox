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
    $t->post_ok('/api/auth/register' => json => {
        username => $name, password => 'pw123456',
    })->status_is(200);
    return $t->post_ok('/api/auth/login' => json => {
        username => $name, password => 'pw123456',
    })->status_is(200)->tx->res->json->{token};
}

my $alice_token = make_user('alice');
my $bob_token   = make_user('bob');

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'test', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};

my $bob_id = $t->app->pg->db->query("SELECT id FROM users WHERE username = 'bob'")->array->[0];
$t->post_ok("/api/rooms/$room_id/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Get ws-specific tokens (this is what the frontend does)
my $alice_ws_token = $t->get_ok('/api/ws-token' => { Authorization => "Bearer $alice_token" })
   ->status_is(200)->tx->res->json->{token};

my $bob_ws_token = $t->get_ok('/api/ws-token' => { Authorization => "Bearer $bob_token" })
   ->status_is(200)->tx->res->json->{token};

$t->websocket_ok("/chat?token=$alice_ws_token");
$t->send_ok({json => { type => 'chat.join', room_id => $room_id }});
$t->message_ok;
is decode_json($t->message->[1])->{type}, 'chat.joined', 'alice joined';

$t->websocket_ok("/chat?token=$bob_ws_token");
$t->send_ok({json => { type => 'chat.join', room_id => $room_id }});
$t->message_ok;
is decode_json($t->message->[1])->{type}, 'chat.joined', 'bob joined';

my $enc = { ct => 'dGVzdA==', iv => 'aXZpdml2aXZpdg==', tag => 'dGFndGFndGFn' };
$t->send_ok({json => {
    type => 'chat.send', room_id => $room_id,
    %$enc,
}});

$t->message_ok;
my $recv = decode_json($t->message->[1]);
is $recv->{type}, 'chat.recv', 'bob received';
is $recv->{room_id}, $room_id, 'room id correct';
is $recv->{ct}, $enc->{ct}, 'ciphertext matches';

my $stored = $t->app->pg->db->query(
    'SELECT * FROM messages WHERE room_id = ?', $room_id
)->hash;
ok $stored, 'message stored in DB';
is $stored->{content_encrypted}, $enc->{ct}, 'stored ciphertext matches';

teardown_test_db($t->app);
done_testing();
