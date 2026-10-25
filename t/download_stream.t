use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use Mojo::File 'path';
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);
$t->app->home->child('storage', 'library')->list->each('remove');

sub make_user {
    my ($name, $role) = @_;
    $role //= 'user';
    $t->post_ok('/api/auth/register' => json => { username => $name, password => 'pw123456' })
      ->status_is(200);
    $t->app->pg->db->query("UPDATE users SET role = ? WHERE username = ?", $role, $name);
    return $t->post_ok('/api/auth/login' => json => { username => $name, password => 'pw123456' })
      ->status_is(200)->tx->res->json->{token};
}

my $admin_token = make_user('admin', 'admin');

$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Big', type => 'video',
})->status_is(200);
my $cat_id = $t->tx->res->json->{category}{id};

# 1 MiB of random-ish data
my $big = join('', map { chr(($_ * 37 + 11) % 256) } 1 .. 1_048_576);
my $temp = path('/tmp/cipherbox-big.bin');
$temp->spew($big);

$t->post_ok('/api/library/items' => { Authorization => "Bearer $admin_token" } => form => {
    title       => 'Big file',
    category_id => $cat_id,
    file        => { file => $temp->to_string, filename => 'big.bin', 'content-type' => 'application/octet-stream' },
})->status_is(200);
my $item_id = $t->tx->res->json->{item}{id};

# Download and verify byte-for-byte
$t->get_ok("/api/library/items/$item_id/download" => { Authorization => "Bearer $admin_token" })
   ->status_is(200);
my $got = $t->tx->res->content->asset->slurp;
utf8::encode($got) if utf8::is_utf8($got);
is length($got), length($big), 'downloaded size matches';
is $got, $big, 'downloaded bytes match original';

$temp->remove;
$t->app->home->child('storage', 'library')->list->each('remove');
teardown_test_db($t->app);
done_testing();
