use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

# Reset settings to default
$t->app->pg->db->query(
    "INSERT INTO settings (key, value) VALUES ('registration_enabled', 'true')
     ON CONFLICT (key) DO UPDATE SET value = 'true'"
);

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

# Registration enabled by default — a new user can register
$t->post_ok('/api/auth/register' => json => {
    username => 'alice', password => 'pw123456',
})->status_is(200);

# Admin reads settings
$t->get_ok('/api/admin/settings' => { Authorization => "Bearer $admin_token" })
   ->status_is(200)
   ->json_is('/settings/registration_enabled' => 1);

# Admin disables registration
$t->patch_ok('/api/admin/settings' => { Authorization => "Bearer $admin_token" } => json => {
    registration_enabled => 0,
})->status_is(200)
  ->json_is('/settings/registration_enabled' => 0);

# Now register fails with 403
$t->app->pg->db->query("DELETE FROM auth_attempts WHERE kind = 'register'");
$t->post_ok('/api/auth/register' => json => {
    username => 'bob', password => 'pw123456',
})->status_is(403);

# Login still works for existing users
$t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'pw123456',
})->status_is(200)->json_has('/token');

# Admin re-enables
$t->patch_ok('/api/admin/settings' => { Authorization => "Bearer $admin_token" } => json => {
    registration_enabled => 1,
})->status_is(200);

# Register works again
$t->app->pg->db->query("DELETE FROM auth_attempts WHERE kind = 'register'");
$t->post_ok('/api/auth/register' => json => {
    username => 'bob', password => 'pw123456',
})->status_is(200);

# Non-admin cannot change settings
my $alice_token = $t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'pw123456',
})->status_is(200)->tx->res->json->{token};

$t->patch_ok('/api/admin/settings' => { Authorization => "Bearer $alice_token" } => json => {
    registration_enabled => 0,
})->status_is(403);

# Restore default for other tests
$t->app->pg->db->query(
    "UPDATE settings SET value = 'true' WHERE key = 'registration_enabled'"
);

teardown_test_db($t->app);
done_testing();
