use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);
$t->app->home->child('storage', 'pastes')->list->each('remove');

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
my ($carol_token, $carol_id) = make_user('carol');

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'pastetest', type => 'room',
})->status_is(200);
my $room_hash = $t->tx->res->json->{room}{public_hash};
$t->post_ok("/api/rooms/$room_hash/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $bob_id,
})->status_is(200);
$t->post_ok("/api/rooms/$room_hash/invite" => { Authorization => "Bearer $alice_token" } => json => {
    user_id => $carol_id,
})->status_is(200);

# --- Text paste ---
$t->post_ok("/api/rooms/$room_hash/pastes" => { Authorization => "Bearer $alice_token" } => form => {
    title => 'API key',
    text  => 'secret-text-12345',
})->status_is(200)->json_has('/paste/public_hash');
my $paste = $t->tx->res->json->{paste};
my $paste_hash = $paste->{public_hash};
like $paste_hash, qr/^[0-9a-f]{20}$/, 'paste hash generated';

# Bob checks info: not opened, can open
$t->get_ok("/api/pastes/$paste_hash" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/paste/can_open' => 1)
   ->json_is('/paste/is_sender' => 0)
   ->json_is('/paste/can_done' => 0);

# Alice (sender) peeks — should succeed with peek flag, no consumption
$t->post_ok("/api/pastes/$paste_hash/open" => { Authorization => "Bearer $alice_token" })
   ->status_is(200)
   ->json_is('/paste/content' => 'secret-text-12345')
   ->json_is('/paste/peek' => 1);

# After peek, paste is still unopened
$t->get_ok("/api/pastes/$paste_hash" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/paste/can_open' => 1);

# Bob opens it — this consumes it
$t->post_ok("/api/pastes/$paste_hash/open" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/paste/content' => 'secret-text-12345');

# Carol tries to open: 409 (already opened by someone else)
$t->post_ok("/api/pastes/$paste_hash/open" => { Authorization => "Bearer $carol_token" })
   ->status_is(409);

# Alice (sender) can still peek after Bob opened
$t->post_ok("/api/pastes/$paste_hash/open" => { Authorization => "Bearer $alice_token" })
   ->status_is(200)
   ->json_is('/paste/peek' => 1);

# Bob does done
$t->post_ok("/api/pastes/$paste_hash/done" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

# After deletion: peek also blocked
$t->post_ok("/api/pastes/$paste_hash/open" => { Authorization => "Bearer $alice_token" })
   ->status_is(410);

# Info shows deleted
$t->get_ok("/api/pastes/$paste_hash" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)->json_is('/paste/can_open' => 0);

# --- File paste ---
my $temp = Mojo::File->new('/tmp/paste-file-test.bin');
$temp->spew("binary content \x00\x01\x02 test data");

$t->post_ok("/api/rooms/$room_hash/pastes" => { Authorization => "Bearer $alice_token" } => form => {
    title => 'secret file',
    file  => { file => $temp->to_string, filename => 'x.bin', 'content-type' => 'application/octet-stream' },
})->status_is(200);
my $file_hash = $t->tx->res->json->{paste}{public_hash};

# Bob (receiver) opens
$t->post_ok("/api/pastes/$file_hash/open" => { Authorization => "Bearer $bob_token" })
   ->status_is(200)
   ->json_is('/paste/kind' => 'file')
   ->json_has('/paste/download_url');

# Bob downloads — content matches
$t->get_ok("/api/pastes/$file_hash/download" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);
my $got = $t->tx->res->content->asset->slurp;
is $got, "binary content \x00\x01\x02 test data", 'file content matches';

# Alice (sender) can also download — peek access for file
$t->get_ok("/api/pastes/$file_hash/download" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);

# Carol (neither sender nor opener) cannot download
$t->get_ok("/api/pastes/$file_hash/download" => { Authorization => "Bearer $carol_token" })
   ->status_is(403);

# Bob does done
$t->post_ok("/api/pastes/$file_hash/done" => { Authorization => "Bearer $bob_token" })
   ->status_is(200);

$t->app->home->child('storage', 'pastes')->list->each('remove');
$temp->remove;
teardown_test_db($t->app);
done_testing();
