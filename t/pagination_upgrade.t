use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);
my $db = $t->app->pg->db;

$t->post_ok('/api/auth/register' => json => { username => 'page_admin', password => 'test-password' })
  ->status_is(200);
my $owner = $db->query("UPDATE users SET role = 'admin' WHERE username = 'page_admin' RETURNING id")->array->[0];
$t->post_ok('/api/auth/login' => json => { username => 'page_admin', password => 'test-password' })
  ->status_is(200);
my $other = $db->query(
    "INSERT INTO users (username, password_hash) VALUES ('other', 'not-a-login-fixture') RETURNING id"
)->array->[0];
my $crypto = $t->app->crypto;
my $key = $crypto->generate_room_key;
my $wrapped = $crypto->wrap_room_key($key);
my @rooms;
for my $type (qw(channel room room room room room)) {
    my $room = $t->app->rooms->create("fixture " . @rooms, $type, $owner, $wrapped);
    push @rooms, $room;
}
$t->app->rooms->create('not a member', 'room', $other, $wrapped);
$db->query(q{UPDATE rooms SET created_at = '2024-01-01T00:00:00Z'});
my $hidden = $rooms[4];
$db->query('INSERT INTO room_bans (room_id, user_id, banned_by) VALUES (?, ?, ?)', $hidden->{id}, $owner, $other);
my $room = $rooms[1];
my @messages;
for my $i (1 .. 4) {
    my $payload = $crypto->encrypt_message($key, "test page $i");
    push @messages, $db->query(q{
        INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag, created_at)
        VALUES (?, ?, ?, ?, ?, '2024-02-01T00:00:00Z') RETURNING id
    }, $room->{id}, $other, @$payload{qw(ct iv tag)})->array->[0];
    $t->app->reports->create($owner, $messages[-1], $room->{id}, "test reason $i");
}

$t->get_ok('/api/rooms?limit=2')->status_is(200)
  ->json_is('/rooms/0/id' => $room->{id})
  ->json_is('/rooms/0/last_message_id' => $messages[-1])
  ->json_is('/rooms/1/id' => $rooms[5]{id});
my $room_page = $t->tx->res->json;
$t->get_ok('/api/rooms?limit=2&cursor=' . $room_page->{next_cursor})->status_is(200)
  ->json_is('/rooms/0/id' => $rooms[3]{id})
  ->json_is('/rooms/1/id' => $rooms[2]{id});
my $room_page2 = $t->tx->res->json;
$t->get_ok('/api/rooms?limit=2&cursor=' . $room_page2->{next_cursor})->status_is(200)
  ->json_is('/rooms/0/id' => $rooms[0]{id})->json_is('/next_cursor' => undef);
$t->get_ok('/api/rooms?type=channel&limit=1')->status_is(200)
  ->json_is('/rooms/0/id' => $rooms[0]{id})->json_is('/next_cursor' => undef);
$t->get_ok('/api/rooms?cursor=bad')->status_is(400);

my $history = "/api/rooms/$room->{public_hash}/messages";
$t->get_ok("$history?limit=2")->status_is(200)
  ->json_is('/messages/0/id' => $messages[2])
  ->json_is('/messages/1/id' => $messages[3]);
my $message_cursor = $t->tx->res->json->{next_cursor};
$t->get_ok("$history?limit=2&before=$message_cursor")->status_is(200)
  ->json_is('/messages/0/id' => $messages[0])
  ->json_is('/messages/1/id' => $messages[1])->json_is('/next_cursor' => undef);
$t->get_ok("$history?limit=bad")->status_is(400);
$t->get_ok("$history?before=9223372036854775808")->status_is(400);

my $lib = $t->app->library;
my $root = $lib->create_category('A root', 'book');
$lib->create_category('B root', 'book');
my $child = $lib->create_category('Child', 'book', $root->{id});
my $leaf = $lib->create_category('Leaf', 'book', $child->{id});
$t->get_ok('/api/library/categories?limit=1')->status_is(200)
  ->json_is('/categories/0/name' => 'A root')->json_is('/categories/0/has_children' => 1)
  ->json_is('/next_offset' => 1);
$t->get_ok('/api/library/categories?limit=1&offset=1')->status_is(200)
  ->json_is('/categories/0/name' => 'B root')->json_is('/next_offset' => undef);
$t->get_ok("/api/library/categories?parent_id=$root->{public_hash}&limit=1")->status_is(200)
  ->json_is('/categories/0/name' => 'Child')->json_is('/next_offset' => undef);
$t->get_ok("/api/library/categories/$leaf->{public_hash}")->status_is(200)
  ->json_is('/path/0/name' => 'A root')->json_is('/path/1/name' => 'Child')->json_is('/path/2/name' => 'Leaf');
for my $num (1 .. 2) {
    $db->query(q{
        INSERT INTO library_items (category_id, title, file_path, file_key_encrypted, uploaded_by, created_at)
        VALUES (?, ?, ?, ?, ?, '2024-01-01T00:00:00Z')
    }, $leaf->{id}, "File $num", 'fixture-path', $wrapped, $owner);
}
my $items = "/api/library/categories/$leaf->{public_hash}/items";
$t->get_ok("$items?limit=1")->status_is(200)->json_is('/items/0/title' => 'File 2')->json_is('/next_offset' => 1);
$t->get_ok("$items?limit=1&offset=1")->status_is(200)
  ->json_is('/items/0/title' => 'File 1')->json_is('/next_offset' => undef);
$t->get_ok("$items?offset=-1")->status_is(400);

$t->get_ok('/api/admin/reports?limit=2&offset=2')->status_is(200)->json_is('/total' => 4);
is scalar(@{$t->tx->res->json->{reports}}), 2, 'bounded report page';
$t->get_ok("/api/admin/rooms/$room->{public_hash}/view?limit=2&before=$message_cursor")->status_is(200)
  ->json_is('/messages/0/text' => 'test page 1')->json_is('/messages/0/sender_username' => 'other')
  ->json_is('/next_cursor' => undef);

teardown_test_db($t->app);
done_testing;
