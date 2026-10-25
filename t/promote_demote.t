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

# Non-admin cannot promote/demote
$t->patch_ok("/api/admin/users/$alice_id" => { Authorization => "Bearer $alice_token" } => json => {
    role => 'admin',
})->status_is(403);

# Admin promotes Alice to admin
$t->patch_ok("/api/admin/users/$alice_id" => { Authorization => "Bearer $admin_token" } => json => {
    role => 'admin',
})->status_is(200)->json_is('/user/role' => 'admin');

my $check = $t->app->pg->db->query('SELECT role FROM users WHERE id = ?', $alice_id)->array->[0];
is $check, 'admin', 'alice is admin in DB';

# Alice can now access admin endpoints
$t->get_ok('/api/admin/users' => { Authorization => "Bearer $alice_token" })
   ->status_is(200);

# Admin demotes Alice back to user
$t->patch_ok("/api/admin/users/$alice_id" => { Authorization => "Bearer $admin_token" } => json => {
    role => 'user',
})->status_is(200);

$check = $t->app->pg->db->query('SELECT role FROM users WHERE id = ?', $alice_id)->array->[0];
is $check, 'user', 'alice demoted to user';

# Cannot demote last admin (self)
# After demoting alice, there's only one admin left (admin_id)
$t->patch_ok("/api/admin/users/$admin_id" => { Authorization => "Bearer $admin_token" } => json => {
    role => 'user',
})->status_is(400);

# Bad role value → 400
$t->patch_ok("/api/admin/users/$alice_id" => { Authorization => "Bearer $admin_token" } => json => {
    role => 'superadmin',
})->status_is(400);

# Non-existent user → 404
$t->patch_ok('/api/admin/users/999999' => { Authorization => "Bearer $admin_token" } => json => {
    role => 'admin',
})->status_is(404);

teardown_test_db($t->app);
done_testing();
