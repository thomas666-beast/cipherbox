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
    $t->app->pg->db->query("DELETE FROM auth_attempts WHERE kind = 'register'");
    $t->app->pg->db->query("UPDATE users SET role = ? WHERE username = ?", $role, $name);
    return $t->post_ok('/api/auth/login' => json => { username => $name, password => 'pw123456' })
      ->status_is(200)->tx->res->json->{token};
}

my $admin_token = make_user('admin', 'admin');

# Create category — response contains public_hash
# $t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
#     name => 'Books', type => 'book',
# })->status_is(200)->json_has('/category/public_hash');

$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Books', type => 'book',
})->or(sub { diag shift->tx->res->body })
  ->status_is(200)->json_has('/category/public_hash');

my $cat = $t->tx->res->json->{category};
my $cat_hash = $cat->{public_hash};
my $cat_id   = $cat->{id};

like $cat_hash, qr/^[0-9a-f]{20}$/, 'category public_hash is 20 hex chars';

# Fetch by hash
$t->get_ok("/api/library/categories/$cat_hash" => { Authorization => "Bearer $admin_token" })
   ->status_is(200)
   ->json_is('/category/name' => 'Books');

# Fetch by numeric id (backwards compat)
$t->get_ok("/api/library/categories/$cat_id" => { Authorization => "Bearer $admin_token" })
   ->status_is(200)
   ->json_is('/category/name' => 'Books');

# Upload item using category hash in body
my $temp = path('/tmp/cipherbox-libhash.txt');
$temp->spew("hello library hash\n");

$t->post_ok('/api/library/items' => { Authorization => "Bearer $admin_token" } => form => {
    title       => 'Test Item',
    category_id => $cat_hash,
    file        => { file => $temp->to_string, filename => 'x.txt', 'content-type' => 'text/plain' },
})->status_is(200)->json_has('/item/public_hash');
my $item = $t->tx->res->json->{item};
my $item_hash = $item->{public_hash};
my $item_id   = $item->{id};

# Download by hash
$t->get_ok("/api/library/items/$item_hash/download" => { Authorization => "Bearer $admin_token" })
   ->status_is(200);
my $got = $t->tx->res->content->asset->slurp;
utf8::encode($got) if utf8::is_utf8($got);
is $got, "hello library hash\n", 'download by hash works';

# Download by numeric id
$t->get_ok("/api/library/items/$item_id/download" => { Authorization => "Bearer $admin_token" })
   ->status_is(200);

# Rename by hash
$t->patch_ok("/api/library/items/$item_hash" => { Authorization => "Bearer $admin_token" } => json => {
    title => 'Renamed',
})->status_is(200);

# List items includes public_hash
$t->get_ok("/api/library/categories/$cat_hash/items" => { Authorization => "Bearer $admin_token" })
   ->status_is(200)
   ->json_is('/items/0/title' => 'Renamed')
   ->json_is('/items/0/public_hash', $item_hash);

# Delete by hash
$t->delete_ok("/api/library/items/$item_hash" => { Authorization => "Bearer $admin_token" })
   ->status_is(200);

# Delete category by hash
$t->delete_ok("/api/library/categories/$cat_hash" => { Authorization => "Bearer $admin_token" })
   ->status_is(200);

$temp->remove;
$t->app->home->child('storage', 'library')->list->each('remove');
teardown_test_db($t->app);
done_testing();
