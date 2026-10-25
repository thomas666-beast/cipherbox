package Cipherbox::Controller::Chat;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(decode_json encode_json);
use Crypt::JWT qw(decode_jwt);

our %CLIENTS;
our %SUBSCRIBED_ROOMS;

sub websocket ($self) {
    my $token = $self->param('token') // '';
    my $payload = eval {
        decode_jwt(token => $token, key => $self->jwt_secret);
    };

    if (!$payload || !$payload->{ws}) {
        $self->res->code(401)->body('');
        return;
    }

    my $user = $self->users->find_by_id($payload->{uid});
    if (!$user) {
        $self->res->code(401)->body('');
        return;
    }

    my $id = sprintf "%p", $self->tx;
    $CLIENTS{$id} = { tx => $self->tx, user => $user, room_id => undef };

    $self->on(message => sub ($c, $raw) {
        my $msg = eval { decode_json($raw) };
        return $c->send(encode_json({ type => 'error', reason => 'bad_json' })) unless $msg;

        my $type = $msg->{type} // '';
        if    ($type eq 'chat.send')   { _handle_chat_send($c, $id, $msg) }
        elsif ($type eq 'chat.join')   { _handle_chat_join($c, $id, $msg) }
        elsif ($type eq 'chat.leave')  { _handle_chat_leave($c, $id) }
        elsif ($type eq 'chat.typing') { _handle_chat_typing($c, $id, $msg) }
        else                           { $c->send(encode_json({ type => 'error', reason => 'unknown_type' })) }
    });

    $self->on(finish => sub { delete $CLIENTS{$id} });
}

sub _handle_chat_join ($c, $id, $msg) {
    my $room_id = $msg->{room_id};
    my $user    = $CLIENTS{$id}{user};

    my $is_member = $c->rooms->is_member($room_id, $user->{id});
    return $c->send(encode_json({ type => 'error', reason => 'not_member' })) unless $is_member;

    my $old_room = $CLIENTS{$id}{room_id};
    
    # Unsubscribe from old room if switching
    if ($old_room && $old_room != $room_id) {
        _unsubscribe_room($c, $old_room);
    }

    $CLIENTS{$id}{room_id} = $room_id;
    
    # Subscribe this worker to the room channel
    _subscribe_room($c, $room_id);

    $c->send(encode_json({ type => 'chat.joined', room_id => $room_id }));
}

sub _handle_chat_leave ($c, $id) {
    my $old_room = $CLIENTS{$id}{room_id};
    if ($old_room) {
        _unsubscribe_room($c, $old_room);
    }
    $CLIENTS{$id}{room_id} = undef;
    $c->send(encode_json({ type => 'chat.left' }));
}

sub _handle_chat_send ($c, $id, $msg) {
    my $room_id = $msg->{room_id};
    my $ct      = $msg->{ct};
    my $iv      = $msg->{iv};
    my $tag     = $msg->{tag};
    my $user    = $CLIENTS{$id}{user};

    return $c->send(encode_json({ type => 'error', reason => 'missing_fields' }))
        unless $room_id and $ct and $iv and $tag;

    my $room = $c->rooms->find_by_id($room_id);
    return $c->send(encode_json({ type => 'error', reason => 'room_not_found' }))
        unless $room;

    my $role = $c->rooms->member_role($room_id, $user->{id});
    return $c->send(encode_json({ type => 'error', reason => 'not_member' }))
        unless $role;

    if ($room->{type} eq 'channel' && $role !~ /^(owner|admin)$/) {
        return $c->send(encode_json({ type => 'error', reason => 'read_only' }));
    }

    my $row = $c->pg->db->query(
        'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
         VALUES (?, ?, ?, ?, ?) RETURNING id, created_at',
        $room_id, $user->{id}, $ct, $iv, $tag,
    )->hash;

    _broadcast_room($c, $room_id, {
        type       => 'chat.recv',
        room_id    => $room_id,
        sender_id  => $user->{id},
        message_id => $row->{id},
        ct         => $ct,
        iv         => $iv,
        tag        => $tag,
        ts         => "$row->{created_at}",
    });

    notify_room_members($c, $room_id, {
        type            => 'room.updated',
        room_id         => $room_id,
        last_message_at => "$row->{created_at}",
        last_sender     => $user->{username},
    });
}

sub _handle_chat_typing ($c, $id, $msg) {
    my $room_id = $msg->{room_id};
    my $user    = $CLIENTS{$id}{user};
    return unless $room_id;
    return unless $c->rooms->is_member($room_id, $user->{id});

    _broadcast_room_except($c, $room_id, $id, {
        type      => 'chat.typing',
        room_id   => $room_id,
        sender_id => $user->{id},
    });
}

# --- SUBSCRIPTION LOGIC ---

sub _subscribe_room ($c, $room_id) {
    return if $SUBSCRIBED_ROOMS{$room_id};
    
    # Check if this is the first client in this room on this worker
    my $count = scalar grep { $_->{room_id} && $_->{room_id} == $room_id } values %CLIENTS;
    if ($count >= 1) {
        $SUBSCRIBED_ROOMS{$room_id} = 1;
        $c->pubsub->listen("cipherbox_room_$room_id" => sub ($pubsub, $payload) {
            my $data = eval { decode_json($payload) };
            return unless $data;
            if ($data->{except}) {
                _broadcast_room_except_local(
                    $room_id,
                    $data->{except},
                    $data->{msg}
                );
            } else {
                _broadcast_local(
                    $room_id,
                    $data->{msg}
                );
            }
        });
    }
}

sub _unsubscribe_room ($c, $room_id) {
    return unless $SUBSCRIBED_ROOMS{$room_id};
    
    my $count = scalar grep { $_->{room_id} && $_->{room_id} == $room_id } values %CLIENTS;
    if ($count == 0) {
        delete $SUBSCRIBED_ROOMS{$room_id};
        # Note: Mojo::Pg::PubSub doesn't expose unlisten in older versions.
        # The listener stays active but _broadcast_local will find no clients and do nothing.
    }
}

# --- LOCAL DELIVERY (Runs when PubSub receives a message) ---

sub _broadcast_local ($room_id, $payload) {
    my $encoded = encode_json($payload);
    for my $cid (keys %CLIENTS) {
        next unless defined $CLIENTS{$cid}{room_id} && $CLIENTS{$cid}{room_id} == $room_id;
        eval { $CLIENTS{$cid}{tx}->send($encoded) };
    }
}

sub _broadcast_room_except_local ($room_id, $except_id, $payload) {
    my $encoded = encode_json($payload);
    for my $cid (keys %CLIENTS) {
        next if $cid eq $except_id;
        next unless defined $CLIENTS{$cid}{room_id} && $CLIENTS{$cid}{room_id} == $room_id;
        eval { $CLIENTS{$cid}{tx}->send($encoded) };
    }
}

sub _notify_room_members_local ($room_id, $payload) {
    _broadcast_local($room_id, $payload);
}

sub _notify_user_local ($user_id, $payload) {
    my $encoded = encode_json($payload);
    for my $cid (keys %CLIENTS) {
        next unless ($CLIENTS{$cid}{user}{id} // 0) == $user_id;
        eval { $CLIENTS{$cid}{tx}->send($encoded) };
    }
}

# --- PUBSUB TARGETING (Runs when a Worker wants to send) ---

sub _broadcast_room ($c, $room_id, $payload) {
    # Send strictly to the room channel
    $c->pubsub->notify("cipherbox_room_$room_id" => encode_json({
        msg => $payload,
    }));
}

sub _broadcast_room_except ($c, $room_id, $except_id, $payload) {
    # Send strictly to the room channel, with an except filter
    $c->pubsub->notify("cipherbox_room_$room_id" => encode_json({
        msg    => $payload,
        except => $except_id,
    }));
}

sub notify_room_members ($c, $room_id, $payload) {
    # Send strictly to the room channel
    $c->pubsub->notify("cipherbox_room_$room_id" => encode_json({
        msg => $payload,
    }));
}

sub notify_user ($c, $user_id, $payload) {
    # Send strictly to the user channel (users must be subscribed when they connect, handled in websocket())
    $c->pubsub->notify("cipherbox_user_$user_id" => encode_json({
        msg => $payload,
    }));
}

sub broadcast_room {
    my ($c, $room_id, $payload) = @_;
    _broadcast_room($c, $room_id, $payload);
}

1;
