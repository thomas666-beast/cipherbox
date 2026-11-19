package Cipherbox::Page;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
our @EXPORT_OK = qw(page_limit page_offset id_cursor);

sub page_limit ($value, $default, $max) {
    $value //= $default;
    return undef unless $value =~ /\A[0-9]{1,9}\z/;
    return $value < 1 ? 1 : $value > $max ? $max : 0 + $value;
}

sub page_offset ($value) {
    $value //= 0;
    return $value =~ /\A[0-9]{1,9}\z/ ? 0 + $value : undef;
}

sub id_cursor ($value) {
    return defined($value) && $value =~ /\A[1-9][0-9]{0,18}\z/
        && (length($value) < 19 || $value le '9223372036854775807');
}

1;
