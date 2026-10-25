use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

# Unauthenticated FIRST — before any login cookie is set
$t->get_ok('/api/users?q=bob')->status_is(401);

sub make_user {
    my ($name) = @_;
    $t->post_ok('/api/auth/register' => json => {
        username => $name, password => 'pw123456',
    })->status_is(200);
    return $t->post_ok('/api/auth/login' => json => {
        username => $name, password => 'pw123456',
    })->status_is(200)->tx->res->json->{token};
}

my $alice_token = make_user('alice');
make_user('bob');
make_user('bobby');
make_user('carol');

# Search for "bob" as alice
$t->get_ok('/api/users?q=bob' => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
my $users = $t->tx->res->json->{users};
is scalar(@$users), 2, 'found 2 bobs';
is $users->[0]{username}, 'bob', 'ordered by username';
is $users->[1]{username}, 'bobby', 'second is bobby';

# Empty query returns empty list
$t->get_ok('/api/users?q=' => { Authorization => "Bearer $alice_token" })
   ->status_is(200);
is scalar(@{ $t->tx->res->json->{users} }), 0, 'empty query returns no results';

# Search returns only safe fields (no password hash)
my $first = $users->[0];
ok exists $first->{id}, 'id present';
ok exists $first->{username}, 'username present';
ok !exists $first->{password_hash}, 'password_hash not exposed';

teardown_test_db($t->app);
done_testing();
