package Cipherbox::Controller::Health;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub check ($self) {
    my $ok = eval { $self->pg->db->query('SELECT 1')->array->[0] };
    if ($ok) {
        $self->render(json => { status => 'ok', db => 1 });
    }
    else {
        $self->render(json => { status => 'error', reason => "$@" }, status => 500);
    }
}

1;
