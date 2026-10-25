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
my $user_token  = make_user('alice', 'user');

# Admin creates category and uploads item
$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Books', type => 'book',
})->status_is(200);
my $cat_id = $t->tx->res->json->{category}{id};

my $temp = path('/tmp/cipherbox-rename-test.txt');
$temp->spew("dummy content\n");

$t->post_ok('/api/library/items' => { Authorization => "Bearer $admin_token" } => form => {
    title       => 'Old Title',
    category_id => $cat_id,
    file        => { file => $temp->to_string, filename => 'x.txt', 'content-type' => 'text/plain' },
})->status_is(200);
my $item_id = $t->tx->res->json->{item}{id};

# Non-admin cannot rename
$t->patch_ok("/api/library/items/$item_id" => { Authorization => "Bearer $user_token" } => json => {
    title => 'Hacked',
})->status_is(403);

# Admin renames
$t->patch_ok("/api/library/items/$item_id" => { Authorization => "Bearer $admin_token" } => json => {
    title => 'New Title',
})->status_is(200)->json_is('/title' => 'New Title');

# Confirm in list
$t->get_ok("/api/library/categories/$cat_id/items" => { Authorization => "Bearer $admin_token" })
   ->status_is(200)
   ->json_is('/items/0/title' => 'New Title');

# Missing title → 400
$t->patch_ok("/api/library/items/$item_id" => { Authorization => "Bearer $admin_token" } => json => {})
   ->status_is(400);

# Non-existent item → 404
$t->patch_ok('/api/library/items/999999' => { Authorization => "Bearer $admin_token" } => json => {
    title => 'X',
})->status_is(404);

$temp->remove;
$t->app->home->child('storage', 'library')->list->each('remove');
teardown_test_db($t->app);
done_testing();
