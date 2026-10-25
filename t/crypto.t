use Mojo::Base -strict;
use Test::More;
use lib 'lib';
use Cipherbox::Crypto;

my $crypto = Cipherbox::Crypto->new(
    master_key => 'cipherbox-dev-master-key-change-in-production'
);

my $room_key = $crypto->generate_room_key;
ok length $room_key, 'room key generated';

my $wrapped = $crypto->wrap_room_key($room_key);
my $unwrapped = $crypto->unwrap_room_key($wrapped);
is $unwrapped, $room_key, 'room key wraps/unwraps';

my $enc = $crypto->encrypt_message($room_key, 'hello world');
my $dec = $crypto->decrypt_message($room_key, $enc->{ct}, $enc->{iv}, $enc->{tag});
is $dec, 'hello world', 'message encrypts/decrypts';

done_testing();
