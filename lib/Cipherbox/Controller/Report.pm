package Cipherbox::Controller::Report;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub create ($self) {
    my $user = $self->current_user;
    my $body = $self->req->json;
    my $message_id = $self->param('message_id');
    my $reason = $body->{reason} // '';

    return $self->render(json => { error => 'missing reason' }, status => 400)
        unless length $reason;

    my $message = $self->rooms->find_message_full($message_id);
    return $self->render(json => { error => 'message not found' }, status => 404)
        unless $message;

    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $self->rooms->is_member($message->{room_id}, $user->{id});

    # Prevent duplicate open reports for the same message by the same user
    my $existing = $self->pg->db->query(
        "SELECT id FROM reports WHERE message_id = ? AND reporter_id = ? AND status = 'open'",
        $message_id, $user->{id},
    )->array;
    return $self->render(json => { error => 'already reported' }, status => 409)
        if $existing;

    my $report = $self->reports->create(
        $user->{id}, $message_id, $message->{room_id}, $reason,
    );

    $self->render(json => { report => { id => $report->{id} } });
}

1;
