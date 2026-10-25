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
    return $t->post_ok('/api/auth/login' => json => { username => $name, password => 'pw123456' })
      ->status_is(200)->tx->res->json->{token};
}

my $admin_token = make_user('admin', 'admin');

# Build: Metal -> Thrash Metal -> Metallica
#        Metal -> Symphonic Metal -> Nightwish
$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Metal', type => 'book',
})->status_is(200);
my $metal_hash = $t->tx->res->json->{category}{public_hash};

$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Thrash Metal', type => 'book', parent_id => $metal_hash,
})->status_is(200);
my $thrash_hash = $t->tx->res->json->{category}{public_hash};

$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Metallica', type => 'book', parent_id => $thrash_hash,
})->status_is(200);

$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Symphonic Metal', type => 'book', parent_id => $metal_hash,
})->status_is(200);
my $symphonic_hash = $t->tx->res->json->{category}{public_hash};

$t->post_ok('/api/library/categories' => { Authorization => "Bearer $admin_token" } => json => {
    name => 'Nightwish', type => 'book', parent_id => $symphonic_hash,
})->status_is(200);

# Fetch tree
$t->get_ok('/api/library/tree' => { Authorization => "Bearer $admin_token" })
   ->status_is(200);

my $tree = $t->tx->res->json->{tree};
is scalar(@$tree), 1, 'one top-level category';
is $tree->[0]{name}, 'Metal', 'top-level is Metal';
is scalar(@{ $tree->[0]{children} }), 2, 'Metal has 2 children';

my ($thrash) = grep { $_->{name} eq 'Thrash Metal' } @{ $tree->[0]{children} };
ok $thrash, 'Thrash Metal child exists';
is scalar(@{ $thrash->{children} }), 1, 'Thrash Metal has 1 child';
is $thrash->{children}[0]{name}, 'Metallica', 'grandchild is Metallica';

my ($symphonic) = grep { $_->{name} eq 'Symphonic Metal' } @{ $tree->[0]{children} };
is $symphonic->{children}[0]{name}, 'Nightwish', 'Symphonic child is Nightwish';

teardown_test_db($t->app);
done_testing();
