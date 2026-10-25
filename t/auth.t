use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

# Register
$t->post_ok('/api/auth/register' => json => {
    username => 'alice', password => 'secret123',
})->status_is(200)->json_has('/id')->json_is('/username' => 'alice');

# Duplicate registration
$t->post_ok('/api/auth/register' => json => {
    username => 'alice', password => 'secret123',
})->status_is(409);

# Login success
$t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'secret123',
})->status_is(200)->json_is('/ok' => 1)->json_has('/token');

# Cookie was set on the response
my $cookie = $t->tx->res->cookie('cipherbox_token');
ok $cookie, 'auth cookie set on response';
SKIP: {
    skip 'no cookie to inspect', 4 unless $cookie;
    ok length($cookie->value), 'cookie has a value';
    ok $cookie->httponly, 'cookie has HttpOnly flag';
    is $cookie->samesite, 'Strict', 'cookie has SameSite=Strict';
    is $cookie->path, '/', 'cookie path is /';
}

# Login wrong password
$t->post_ok('/api/auth/login' => json => {
    username => 'alice', password => 'wrong',
})->status_is(401);

# Logout clears the cookie
$t->post_ok('/api/auth/logout')->status_is(200);
my $clear = $t->tx->res->cookie('cipherbox_token');
ok $clear, 'logout sets a cookie';
SKIP: {
    skip 'no cookie to inspect', 2 unless $clear;
    is $clear->value, '', 'cookie value empty on logout';
    is $clear->max_age, 0, 'cookie max_age is 0 on logout';
}

teardown_test_db($t->app);
done_testing();
