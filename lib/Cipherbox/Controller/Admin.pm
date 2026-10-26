package Cipherbox::Controller::Admin;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub list_users ($self) {
    my $cfg    = $self->pagination;
    my $limit  = $self->param('limit')  // $cfg->{default_limit};
    my $offset = $self->param('offset') // 0;

    $limit = $cfg->{max_limit} if $limit > $cfg->{max_limit};
    $limit = 1 if $limit < 1;
    $offset = 0 if $offset < 0;

    my $users = $self->users->list_all($limit, $offset);
    my $total = $self->users->count;

    $self->render(json => {
        users  => $users,
        total  => $total,
        limit  => $limit,
        offset => $offset,
    });
}

sub create_user ($self) {
    my $body     = $self->req->json;
    my $username = $body->{username} // '';
    my $dsa_key  = $body->{dilithium_public_key};
    my $kem_key  = $body->{kyber_public_key};
    my $role     = $body->{role} // 'user';

    return $self->render(json => { error => 'missing fields' }, status => 400)
        unless length $username and $dsa_key and $kem_key;
    return $self->render(json => { error => 'bad role' }, status => 400)
        unless $role =~ /^(admin|user)$/;

    my $exists = eval { $self->users->find_by_username($username) };
    return $self->render(json => { error => 'username taken' }, status => 409)
        if $exists;

    my $user = eval { $self->users->create_pqc($username, $dsa_key, $kem_key, $role) };
    return $self->render(json => { error => "$@" }, status => 500) if $@;

    $self->render(json => { user => $user });
}

sub remove_user ($self) {
    my $current = $self->current_user;
    my $id      = $self->param('id');

    return $self->render(json => { error => 'cannot remove yourself' }, status => 400)
        if $id == $current->{id};

    my $target = $self->users->find_by_id($id);
    return $self->render(json => { error => 'user not found' }, status => 404)
        unless $target;

    # Don't allow removing the last admin
    if (($target->{role} // '') eq 'admin') {
        my $admin_count = $self->users->count_admins;
        return $self->render(json => { error => 'cannot remove last admin' }, status => 400)
            if $admin_count <= 1;
    }

    $self->users->delete($id);
    $self->render(json => { ok => 1 });
}

1;
