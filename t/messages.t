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
my $bob_token   = make_user('bob');
my $eve_token   = make_user('eve');

$t->post_ok('/api/rooms' => { Authorization => "Bearer $alice_token" } => json => {
    name => 'history-test', type => 'room',
})->status_is(200);
my $room_id = $t->tx->res->json->{room}{id};

my $db = $t->app->pg->db;
my $alice_id = $db->query("SELECT id FROM users WHERE username = 'alice'")->array->[0];
for my $i (1 .. 5) {
    $db->query(
        'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
         VALUES (?, ?, ?, ?, ?)',
        $room_id, $alice_id, "ct$i", "iv$i", "tag$i",
    );
}

# Alice fetches all
$t->get_ok("/api/rooms/$room_id/messages" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
my $msgs = $t->tx->res->json->{messages};
is scalar(@$msgs), 5, 'got 5 messages';
is $msgs->[0]{ct}, 'ct1', 'first message is oldest';
is $msgs->[4]{ct}, 'ct5', 'last message is newest';

# Non-member (eve) cannot fetch
$t->get_ok("/api/rooms/$room_id/messages" => { Authorization => "Bearer $eve_token" })
   ->status_is(403);

# Pagination: before=fourth id
my $fourth_id = $msgs->[3]{id};
$t->get_ok("/api/rooms/$room_id/messages?before=$fourth_id" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
my $before_msgs = $t->tx->res->json->{messages};
is scalar(@$before_msgs), 3, 'before pagination returns 3';

# Limit
$t->get_ok("/api/rooms/$room_id/messages?limit=2" => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
my $limited = $t->tx->res->json->{messages};
is scalar(@$limited), 2, 'limit returns 2';

teardown_test_db($t->app);
done_testing();
