package TestSetup;
use strict;
use warnings;

BEGIN {
    $ENV{CIPHERBOX_ENV} = 'test';
}

use Exporter 'import';
our @EXPORT = qw(setup_test_db teardown_test_db);

sub _truncate {
    my $app = shift;
    $app->pg->db->query(
        'TRUNCATE messages, room_members, room_bans, rooms, library_items, library_categories, users, auth_attempts RESTART IDENTITY CASCADE'
    );
}

sub setup_test_db {
    my $app = shift;
    _truncate($app);
}

sub teardown_test_db {
    my $app = shift;
    _truncate($app);
}

1;
