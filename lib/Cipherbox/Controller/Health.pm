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

sub get_config ($self) {
    my $storage = $self->app->config->{storage} // {};
    
    $self->render(json => {
        max_upload_size => $storage->{max_upload_size} // 104857600,
        max_paste_size  => $storage->{max_paste_size}  // 10485760,
        chunk_size      => $storage->{chunk_size}      // 65536,
    });
}

1;
