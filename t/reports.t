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
my ($eve_token,   $eve_id)   = make_user('eve', 'user');

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'general', type => 'room',
})->status_is(200);
my $room_hash = $t->tx->res->json->{room}{public_hash};
my $room_id = $t->tx->res->json->{room}{id};
$t->post_ok("/api/rooms/$room_hash/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);

# Fetch the room key, encrypt "badcontent" properly
my $room_key_b64 = $t->get_ok("/api/rooms/$room_hash/key" => { Authorization => "Bearer $alice_token" })
   ->status_is(200)->tx->res->json->{room_key};

use MIME::Base64 ();
use Crypt::AuthEnc::GCM;

my $raw_key = MIME::Base64::decode_base64($room_key_b64);
my $iv = "\x02" x 12;
my $ae = Crypt::AuthEnc::GCM->new('AES', $raw_key, $iv);
my $ct = $ae->encrypt_add("badcontent");
my $tag = $ae->encrypt_done;

my $msg_id = $t->app->pg->db->query(
    'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
     VALUES (?, ?, ?, ?, ?) RETURNING id',
    $room_id, $alice_id,
    MIME::Base64::encode_base64($ct, ''),
    MIME::Base64::encode_base64($iv, ''),
    MIME::Base64::encode_base64($tag, ''),
)->array->[0];

# Bob reports the message
$t->post_ok("/api/messages/$msg_id/report" => { Authorization => "Bearer $bob_token" } => json => {
    reason => 'harassment',
})->status_is(200)->json_has('/report/id');
my $report_id = $t->tx->res->json->{report}{id};

# Duplicate report from same user fails
$t->post_ok("/api/messages/$msg_id/report" => { Authorization => "Bearer $bob_token" } => json => {
    reason => 'again',
})->status_is(409);

# Non-member cannot report
$t->post_ok("/api/messages/$msg_id/report" => { Authorization => "Bearer $eve_token" } => json => {
    reason => 'spam',
})->status_is(403);

# Non-admin cannot list reports
$t->get_ok('/api/admin/reports' => { Authorization => "Bearer $bob_token" })
   ->status_is(403);

# Admin lists open reports
$t->get_ok('/api/admin/reports' => { Authorization => "Bearer $admin_token" })
   ->status_is(200)
   ->json_is('/total' => 1);
my $reports = $t->tx->res->json->{reports};
is scalar(@$reports), 1, 'one open report';
is $reports->[0]{reporter_username}, 'bob', 'reporter name';
is $reports->[0]{sender_username}, 'alice', 'sender name';
is $reports->[0]{room_hash}, $room_hash, 'room hash';

# Admin gets report detail
$t->get_ok("/api/admin/reports/$report_id" => { Authorization => "Bearer $admin_token" })
   ->status_is(200)
   ->json_is('/report/reason' => 'harassment')
   ->json_is('/report/status' => 'open')
   ->json_is('/report/reporter' => 'bob')
   ->json_is('/room/name' => 'general')
   ->json_is('/message/sender_username' => 'alice')
   ->json_is('/message/text' => 'badcontent');

# Admin resolves
$t->post_ok("/api/admin/reports/$report_id/resolve" => { Authorization => "Bearer $admin_token" } => json => {
    resolution => 'warning issued',
})->status_is(200);

# List is now empty
$t->get_ok('/api/admin/reports' => { Authorization => "Bearer $admin_token" })
   ->status_is(200)->json_is('/total' => 0);

# Cannot resolve already-resolved
$t->post_ok("/api/admin/reports/$report_id/resolve" => { Authorization => "Bearer $admin_token" } => json => {
    resolution => 'again',
})->status_is(400);

teardown_test_db($t->app);
done_testing();
