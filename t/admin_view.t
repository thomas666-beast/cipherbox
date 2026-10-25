use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

sub make_user {
    my ($name, $role) = @_;
    $role //= 'user';
    $t->post_ok('/api/auth/register' => json => { username => $name, password => 'pw123456' })
      ->status_is(200);
    $t->app->pg->db->query("DELETE FROM auth_attempts WHERE kind = 'register'");
    $t->app->pg->db->query("UPDATE users SET role = ? WHERE username = ?", $role, $name);
    my $token = $t->post_ok('/api/auth/login' => json => { username => $name, password => 'pw123456' })
      ->status_is(200)->tx->res->json->{token};
    my $id = $t->app->pg->db->query(
        'SELECT id FROM users WHERE username = ?', $name
    )->array->[0];
    return ($token, $id);
}

my ($admin_token, $admin_id) = make_user('admin', 'admin');
my ($alice_token, $alice_id) = make_user('alice', 'user');
my ($bob_token,   $bob_id)   = make_user('bob', 'user');

# Create room + message + insert an encrypted message directly
$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'general', type => 'room',
})->status_is(200);
my $room_hash = $t->tx->res->json->{room}{public_hash};
my $room_id   = $t->tx->res->json->{room}{id};
$t->post_ok("/api/rooms/$room_hash/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Alice sends a message via WS
my $alice_ws_token = $t->get_ok('/api/ws-token' => { Authorization => "Bearer $alice_token" })
   ->status_is(200)->tx->res->json->{token};
$t->websocket_ok("/chat?token=$alice_ws_token");
$t->send_ok({json => { type => 'chat.join', room_id => $room_id }});
$t->message_ok;

# Encrypt "hello world" using the room key (simulate what the frontend does)
use MIME::Base64 ();
use Crypt::AuthEnc::GCM;
my $room_key_b64 = $t->get_ok("/api/rooms/$room_hash/key" => { Authorization => "Bearer $alice_token" })
   ->status_is(200)->tx->res->json->{room_key};
my $raw_key = MIME::Base64::decode_base64($room_key_b64);
my $iv = "\x01" x 12;
my $ae = Crypt::AuthEnc::GCM->new('AES', $raw_key, $iv);
my $ct = $ae->encrypt_add("hello world");
my $tag = $ae->encrypt_done;
my $ct_b64  = MIME::Base64::encode_base64($ct, '');
my $iv_b64  = MIME::Base64::encode_base64($iv, '');
my $tag_b64 = MIME::Base64::encode_base64($tag, '');

my $msg_id = $t->app->pg->db->query(
    'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
     VALUES (?, ?, ?, ?, ?) RETURNING id',
    $room_id, $alice_id, $ct_b64, $iv_b64, $tag_b64,
)->array->[0];

# Admin cannot view — no open report yet
$t->get_ok("/api/admin/rooms/$room_hash/view" => { Authorization => "Bearer $admin_token" })
   ->status_is(403);

# Bob reports the message
$t->post_ok("/api/messages/$msg_id/report" => { Authorization => "Bearer $bob_token" } => json => {
    reason => 'harassment',
})->status_is(200);
my $report_id = $t->tx->res->json->{report}{id};

# Now admin can view
$t->get_ok("/api/admin/rooms/$room_hash/view" => { Authorization => "Bearer $admin_token" })
   ->status_is(200)
   ->json_is('/room/name' => 'general')
   ->json_is('/report/reason' => 'harassment')
   ->json_is('/messages/0/text' => 'hello world')
   ->json_is('/messages/0/sender_username' => 'alice');

# Non-admin cannot view
$t->get_ok("/api/admin/rooms/$room_hash/view" => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# After resolving, admin can no longer view
$t->post_ok("/api/admin/reports/$report_id/resolve" => { Authorization => "Bearer $admin_token" } => json => {
    resolution => 'handled',
})->status_is(200);

$t->get_ok("/api/admin/rooms/$room_hash/view" => { Authorization => "Bearer $admin_token" })
   ->status_is(403);

teardown_test_db($t->app);
done_testing();
