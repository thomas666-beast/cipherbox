use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);
$t->app->pg->db->query("TRUNCATE auth_attempts RESTART IDENTITY");

# Register a user
$t->post_ok('/api/auth/register' => json => {
    username => 'alice', password => 'pw123456',
})->status_is(200);

$t->app->pg->db->query("DELETE FROM auth_attempts WHERE kind = 'register'");

# 5 wrong password attempts — each returns 401
for my $i (1 .. 5) {
    $t->post_ok('/api/auth/login' => json => {
        username => 'alice', password => 'wrong',
    })->status_is(401);
}

# 6th attempt is blocked with 429
$t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'wrong',
})->status_is(429);

# Even correct password blocked
$t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'pw123456',
})->status_is(429);

# Clear and confirm successful login resets the counter
$t->app->pg->db->query("DELETE FROM auth_attempts WHERE kind = 'login_fail'");

for my $i (1 .. 4) {
    $t->post_ok('/api/auth/login' => json => {
        username => 'alice', password => 'wrong',
    })->status_is(401);
}
$t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'pw123456',
})->status_is(200);

for my $i (1 .. 5) {
    $t->post_ok('/api/auth/login' => json => {
        username => 'alice', password => 'wrong',
    })->status_is(401);
}
$t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'pw123456',
})->status_is(429);

teardown_test_db($t->app);
done_testing();
