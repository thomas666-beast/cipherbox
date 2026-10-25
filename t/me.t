use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

# Unauthenticated FIRST
$t->get_ok('/api/me')->status_is(401);

# Register
$t->post_ok('/api/auth/register' => json => { username => 'alice', password => 'pw123456' })
  ->status_is(200);

# Login and grab token
my $token = $t->post_ok('/api/auth/login' => json => { username => 'alice', password => 'pw123456' })
  ->status_is(200)->tx->res->json->{token};

# Me returns profile (using Authorization header)
$t->get_ok('/api/me' => { Authorization => "Bearer $token" })
   ->status_is(200)
   ->json_is('/username' => 'alice')
   ->json_is('/role' => 'user')
   ->json_has('/id');

# Admin role reflected
$t->app->pg->db->query("UPDATE users SET role = 'admin' WHERE username = 'alice'");
$token = $t->post_ok('/api/auth/login' => json => { username => 'alice', password => 'pw123456' })
  ->status_is(200)->tx->res->json->{token};
$t->get_ok('/api/me' => { Authorization => "Bearer $token" })
   ->status_is(200)
   ->json_is('/role' => 'admin');

teardown_test_db($t->app);
done_testing();
