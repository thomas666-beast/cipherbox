use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

# Unauthenticated — admin gate returns 403
$t->get_ok('/api/admin/users')->status_is(403);

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

# Regular user cannot access admin endpoints
$t->get_ok('/api/admin/users' => { Authorization => "Bearer $alice_token" })
   ->status_is(403);

# Admin can list users
$t->get_ok('/api/admin/users' => { Authorization => "Bearer $admin_token" })
   ->status_is(200);
my $list = $t->tx->res->json;
ok scalar(@{ $list->{users} }) >= 2, 'at least 2 users listed';
ok exists $list->{total}, 'total present';
ok !exists $list->{users}[0]{password_hash}, 'no password hashes exposed';

# Admin creates a user (invite)
$t->post_ok('/api/admin/users' => { Authorization => "Bearer $admin_token" } => json => {
    username => 'carol', password => 'pw123456',
})->status_is(200)->json_has('/user/id')->json_is('/user/username' => 'carol');

# Duplicate create fails
$t->post_ok('/api/admin/users' => { Authorization => "Bearer $admin_token" } => json => {
    username => 'carol', password => 'pw123456',
})->status_is(409);

# Created user can log in
$t->post_ok('/api/auth/login' => json => {
    username => 'carol', password => 'pw123456',
})->status_is(200)->json_has('/token');

# Admin creates another admin
$t->post_ok('/api/admin/users' => { Authorization => "Bearer $admin_token" } => json => {
    username => 'admin2', password => 'pw123456', role => 'admin',
})->status_is(200);
my $admin2_id = $t->tx->res->json->{user}{id};

# admin2 can access admin endpoints
my $admin2_token = $t->post_ok('/api/auth/login' => json => {
    username => 'admin2', password => 'pw123456',
})->status_is(200)->tx->res->json->{token};

$t->get_ok('/api/admin/users' => { Authorization => "Bearer $admin2_token" })
   ->status_is(200);

# Admin cannot remove themselves
$t->delete_ok("/api/admin/users/$admin_id" => { Authorization => "Bearer $admin_token" })
   ->status_is(400);

# Admin removes alice
$t->delete_ok("/api/admin/users/$alice_id" => { Authorization => "Bearer $admin_token" })
   ->status_is(200);

# Alice is gone
$t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'pw123456',
})->status_is(401);

# Cannot remove the last admin
my $other_admin_id = $t->app->pg->db->query(
    "SELECT id FROM users WHERE username = 'carol'"
)->array->[0];
$t->app->pg->db->query("UPDATE users SET role = 'admin' WHERE id = ?", $other_admin_id);
$t->delete_ok("/api/admin/users/$other_admin_id" => { Authorization => "Bearer $admin_token" })
   ->status_is(200);

teardown_test_db($t->app);
done_testing();
