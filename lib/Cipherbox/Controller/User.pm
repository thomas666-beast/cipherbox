package Cipherbox::Controller::User;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub search ($self) {
    my $q     = $self->param('q') // '';
    my $cfg   = $self->pagination;
    my $limit = $cfg->{default_limit};

    my $results = $self->users->search($q, $limit);
    $self->render(json => { users => $results });
}

1;
