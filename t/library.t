use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use Mojo::File 'path';
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

$t->get_ok('/api/library/items/999999/download')->status_is(401);

# Clean storage from any previous run
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

# Non-admin cannot create category
$t->post_ok('/api/library/categories' => { Authorization => "Bearer $user_token" } => json => {
    name => 'Books', type => 'book',
})->status_is(403);

# Admin creates categories
$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Books', type => 'book',
})->status_is(200)->json_has('/category/id');
my $books_id = $t->tx->res->json->{category}{id};

$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Maths', type => 'book', parent_id => $books_id,
})->status_is(200);
my $maths_id = $t->tx->res->json->{category}{id};

# List top-level
$t->get_ok('/api/library/categories' => { Authorization => "Bearer $user_token" })
   ->status_is(200);
my $cats = $t->tx->res->json->{categories};
is scalar(@$cats), 1, 'one top-level category';
is $cats->[0]{name}, 'Books', 'top-level name correct';

# List children
$t->get_ok("/api/library/categories?parent_id=$books_id" => { Authorization => "Bearer $user_token" })
   ->status_is(200);
my $children = $t->tx->res->json->{categories};
is scalar(@$children), 1, 'one child';
is $children->[0]{name}, 'Maths', 'child name correct';

# Upload
my $content = "Hello from the library\n";
my $temp = path('/tmp/cipherbox-test-upload.txt');
$temp->spew($content);

my $upload = $t->post_ok('/api/library/items' => { Authorization => "Bearer $admin_token" } => form => {
    title       => 'Trigonometry Basics',
    category_id => $maths_id,
    file        => { file => $temp->to_string, filename => 'trig.txt', 'content-type' => 'text/plain' },
});
diag "UPLOAD STATUS: " . $upload->tx->res->code;
diag "UPLOAD BODY:   " . $upload->tx->res->body;
$upload->status_is(200)->json_has('/item/id');
my $item_id = $t->tx->res->json->{item}{id};

# Non-admin cannot upload
$t->post_ok('/api/library/items' => { Authorization => "Bearer $user_token" } => form => {
    title       => 'Hack',
    category_id => $maths_id,
    file        => { file => $temp->to_string, filename => 'hack.txt', 'content-type' => 'text/plain' },
})->status_is(403);

# List items
$t->get_ok("/api/library/categories/$maths_id/items" => { Authorization => "Bearer $user_token" })
   ->status_is(200);
my $items = $t->tx->res->json->{items};
is scalar(@$items), 1, 'one item';
is $items->[0]{title}, 'Trigonometry Basics', 'item title';

# Download
my $dl = $t->get_ok("/api/library/items/$item_id/download" => { Authorization => "Bearer $user_token" });
diag "DL STATUS: " . $dl->tx->res->code;
diag "DL BODY:   " . $dl->tx->res->body;
$dl->status_is(200);

if ($dl->tx->res->code == 200) {
    my $got = $dl->tx->res->content->asset->slurp;
    utf8::encode($got) if utf8::is_utf8($got);
    is $got, $content, 'downloaded content matches original';
}

# Non-admin cannot delete category
$t->delete_ok("/api/library/categories/$maths_id" => { Authorization => "Bearer $user_token" })
   ->status_is(403);

# Admin deletes category
$t->delete_ok("/api/library/categories/$maths_id" => { Authorization => "Bearer $admin_token" })
   ->status_is(200);

# Cleanup
$temp->remove;
$t->app->home->child('storage', 'library')->list->each('remove');
teardown_test_db($t->app);
done_testing();
