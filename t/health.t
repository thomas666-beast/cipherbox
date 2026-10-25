use Mojo::Base -strict;
use Test::Mojo;
use Test::More;
use lib 't/lib';
use TestSetup;

my $t = Test::Mojo->new('Cipherbox');
setup_test_db($t->app);

$t->get_ok('/health')
   ->status_is(200)
   ->json_is('/status' => 'ok')
   ->json_is('/db' => 1);

teardown_test_db($t->app);
done_testing();
