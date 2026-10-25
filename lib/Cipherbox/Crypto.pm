package Cipherbox::Crypto;
use Mojo::Base -base, -signatures;
use Crypt::AuthEnc::GCM;
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 qw(encode_base64 decode_base64);
use Encode qw(encode decode);

has master_key => undef;

# master_key is a plain string (>= 16 bytes). We derive a 32-byte AES key via SHA-256.
sub _master_key_bytes ($self) {
    require Digest::SHA;
    return Digest::SHA::sha256($self->master_key);
}

sub generate_room_key ($self) {
    return encode_base64(random_bytes(32), '');
}

sub wrap_room_key ($self, $room_key_b64) {
    my $key = $self->_master_key_bytes;
    my $iv  = random_bytes(12);
    my $ae  = Crypt::AuthEnc::GCM->new('AES', $key, $iv);
    my $ct  = $ae->encrypt_add(decode_base64($room_key_b64));
    my $tag = $ae->encrypt_done;
    return join ':', encode_base64($iv, ''), encode_base64($tag, ''), encode_base64($ct, '');
}

sub unwrap_room_key ($self, $wrapped) {
    my ($iv_b64, $tag_b64, $ct_b64) = split /:/, $wrapped;
    my $key = $self->_master_key_bytes;
    my $ae  = Crypt::AuthEnc::GCM->new('AES', $key, decode_base64($iv_b64));
    my $pt  = $ae->decrypt_add(decode_base64($ct_b64));
    $ae->decrypt_done(decode_base64($tag_b64));
    return encode_base64($pt, '');
}

sub encrypt_message ($self, $room_key_b64, $plaintext) {
    my $key = decode_base64($room_key_b64);
    my $iv  = random_bytes(12);
    my $ae  = Crypt::AuthEnc::GCM->new('AES', $key, $iv);
    my $ct  = $ae->encrypt_add(encode('UTF-8', $plaintext));
    my $tag = $ae->encrypt_done;
    return {
        ct  => encode_base64($ct, ''),
        iv  => encode_base64($iv, ''),
        tag => encode_base64($tag, ''),
    };
}

sub decrypt_message ($self, $room_key_b64, $ct_b64, $iv_b64, $tag_b64) {
    my $key = decode_base64($room_key_b64);
    my $ae  = Crypt::AuthEnc::GCM->new('AES', $key, decode_base64($iv_b64));
    my $pt  = $ae->decrypt_add(decode_base64($ct_b64));
    $ae->decrypt_done(decode_base64($tag_b64));
    return decode('UTF-8', $pt);
}

# Encrypt raw bytes with a given key (base64), return { data, iv, tag }
sub encrypt_bytes ($self, $key_b64, $plaintext) {
    my $key = decode_base64($key_b64);
    my $iv  = random_bytes(12);
    my $ae  = Crypt::AuthEnc::GCM->new('AES', $key, $iv);
    my $ct  = $ae->encrypt_add($plaintext);
    my $tag = $ae->encrypt_done;
    return { data => $ct, iv => $iv, tag => $tag };
}

sub decrypt_bytes ($self, $key_b64, $ct, $iv, $tag) {
    my $key = decode_base64($key_b64);
    my $ae  = Crypt::AuthEnc::GCM->new('AES', $key, $iv);
    my $pt  = $ae->decrypt_add($ct);
    $ae->decrypt_done($tag);
    return $pt;
}

# Streaming decrypt: takes a file handle positioned at the start of the file.
# Expected file layout: iv(12) || tag(16) || ciphertext(N).
# Returns (iv, tag, ciphertext_offset, ciphertext_length) after reading headers.
sub read_enc_header ($self, $fh) {
    my $header = '';
    my $got = read($fh, $header, 28);
    die "read failed" unless defined $got;
    die "file too short" if $got < 28;
    my $iv  = substr($header, 0,  12);
    my $tag = substr($header, 12, 16);
    my $file_size = -s $fh;
    return ($iv, $tag, 28, $file_size - 28);
}

1;
