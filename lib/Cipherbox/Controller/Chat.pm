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
        return $c->send(encode_json({ t => 9, reason => 'bad_json' })) unless $msg;

        my $type = $msg->{t} // '';
        if    ($type eq '0') { _handle_chat_send($c, $id, $msg) }   # chat.send
        elsif ($type eq '3') { _handle_chat_join($c, $id, $msg) }   # chat.join
        elsif ($type eq '4') { _handle_chat_leave($c, $id) }        # chat.leave
        elsif ($type eq '2') { _handle_chat_typing($c, $id, $msg) } # chat.typing
        else                 { $c->send(encode_json({ t => 9, reason => 'unknown_type' })) }
    });

    $self->on(finish => sub ($c, @args) { 
        my $room_id = $CLIENTS{$id}{room_id};
        my $user_id = $CLIENTS{$id}{user}{id} if $CLIENTS{$id}{user};
        delete $CLIENTS{$id}; 
        
        if ($room_id) {
            my $app = $c->app;
            Mojo::IOLoop->timer(5 => sub {
                my $db = $app->pg->db;
                my $reconnected = 0;
                for my $cid (keys %CLIENTS) {
                    next unless $CLIENTS{$cid}{user} && $CLIENTS{$cid}{user}{id} == $user_id;
                    next unless ($CLIENTS{$cid}{room_id} // 0) == $room_id;
                    $reconnected = 1;
                    last;
                }
                return if $reconnected;
                
                my $room = $db->query('SELECT id, is_ephemeral FROM rooms WHERE id = ?', $room_id)->hash;
                return unless $room;
                
                $app->pubsub->notify("cipherbox_room_$room_id" => Mojo::JSON::encode_json({
                    t => 7, r => $room_id
                }));
                
                if ($room->{is_ephemeral}) {
                    my $still_connected = 0;
                    for my $cid (keys %CLIENTS) {
                        next unless ($CLIENTS{$cid}{room_id} // 0) == $room_id;
                        $still_connected = 1;
                        last;
                    }
                    if ($still_connected == 0) {
                        my $remaining = $db->query(
                            'SELECT count(*) FROM room_members WHERE room_id = ?', $room_id
                        )->array->[0];
                        if ($remaining == 0) {
                            $db->query('DELETE FROM rooms WHERE id = ?', $room_id);
                            $app->pubsub->notify("cipherbox_room_$room_id" => Mojo::JSON::encode_json({
                                t => 8, r => $room_id
                            }));
                        }
                    }
                }
            });
        }
    });
}

sub _handle_chat_join ($c, $id, $msg) {
    my $room_id = $msg->{r};
    my $user    = $CLIENTS{$id}{user};

    return $c->send(encode_json({ t => 9, reason => 'missing_room_id' }))
        unless $room_id;

    my $is_member = $c->rooms->is_member($room_id, $user->{id});
    return $c->send(encode_json({ t => 9, reason => 'not_member' })) unless $is_member;

    my $old_room = $CLIENTS{$id}{room_id};
    if ($old_room && $old_room != $room_id) {
        _unsubscribe_room($c, $old_room);
    }

    $CLIENTS{$id}{room_id} = $room_id;
    _subscribe_room($c, $room_id);

    $c->send(encode_json({ t => 3, r => $room_id })); # chat.joined
}

sub _handle_chat_leave ($c, $id) {
    my $old_room = $CLIENTS{$id}{room_id};
    if ($old_room) {
        _unsubscribe_room($c, $old_room);
    }
    $CLIENTS{$id}{room_id} = undef;
    $c->send(encode_json({ t => 4 })); # chat.left
}

sub _handle_chat_send ($c, $id, $msg) {
    my $room_id = $msg->{r};
    my $ct      = $msg->{c};
    my $iv      = $msg->{i};
    my $tag     = $msg->{g};
    my $user    = $CLIENTS{$id}{user};

    return $c->send(encode_json({ t => 9, reason => 'missing_fields' }))
        unless $room_id and $ct and $iv and $tag;

    my $room = $c->rooms->find_by_id($room_id);
    return $c->send(encode_json({ t => 9, reason => 'room_not_found' }))
        unless $room;

    my $role = $c->rooms->member_role($room_id, $user->{id});
    return $c->send(encode_json({ t => 9, reason => 'not_member' }))
        unless $role;

    if ($room->{type} eq 'channel' && $role !~ /^(owner|admin)$/) {
        return $c->send(encode_json({ t => 9, reason => 'read_only' }));
    }

    my $row = $c->pg->db->query(
        'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
         VALUES (?, ?, ?, ?, ?) RETURNING id, created_at',
        $room_id, $user->{id}, $ct, $iv, $tag,
    )->hash;

    # Broadcast to everyone EXCEPT the sender
    _broadcast_room($c, $room_id, {
        t               => 1,
        r               => $room_id,
        u               => $user->{id},
        sender_username => $user->{username},
        m               => $row->{id},
        c               => $ct,
        i               => $iv,
        g               => $tag,
        s               => "$row->{created_at}",
    });

    notify_room_members($c, $room_id, {
        t               => 7,
        r               => $room_id,
        last_message_at => "$row->{created_at}",
        last_sender     => $user->{username},
    });
}

sub _handle_chat_typing ($c, $id, $msg) {
    my $room_id = $msg->{r};
    my $user    = $CLIENTS{$id}{user};
    return unless $room_id;
    return unless $c->rooms->is_member($room_id, $user->{id});

    _broadcast_room_except($c, $room_id, $id, {
        t => 2,
        r => $room_id,
        u => $user->{id},
    });
}

# --- SUBSCRIPTION LOGIC ---
sub _subscribe_room ($c, $room_id) {
    return if $SUBSCRIBED_ROOMS{$room_id};
    my $count = scalar grep { $_->{room_id} && $_->{room_id} == $room_id } values %CLIENTS;
    if ($count >= 1) {
        $SUBSCRIBED_ROOMS{$room_id} = 1;
        $c->pubsub->listen("cipherbox_room_$room_id" => sub ($pubsub, $payload) {
            my $data = eval { decode_json($payload) };
            return unless $data;
            if ($data->{except}) {
                _broadcast_room_except_local($room_id, $data->{except}, $data->{msg});
            } else {
                _broadcast_local($room_id, $data->{msg});
            }
        });
    }
}

sub _unsubscribe_room ($c, $room_id) {
    return unless $SUBSCRIBED_ROOMS{$room_id};
    my $count = scalar grep { $_->{room_id} && $_->{room_id} == $room_id } values %CLIENTS;
    if ($count == 0) {
        delete $SUBSCRIBED_ROOMS{$room_id};
    }
}

# --- LOCAL DELIVERY ---
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

sub _notify_room_members_local ($room_id, $payload) { _broadcast_local($room_id, $payload); }
sub _notify_user_local ($user_id, $payload) {
    my $encoded = encode_json($payload);
    for my $cid (keys %CLIENTS) {
        next unless ($CLIENTS{$cid}{user}{id} // 0) == $user_id;
        eval { $CLIENTS{$cid}{tx}->send($encoded) };
    }
}

# --- PUBSUB TARGETING ---
sub _broadcast_room ($c, $room_id, $payload) {
    $c->pubsub->notify("cipherbox_room_$room_id" => encode_json({ msg => $payload }));
}

sub _broadcast_room_except ($c, $room_id, $except_id, $payload) {
    $c->pubsub->notify("cipherbox_room_$room_id" => encode_json({ msg => $payload, except => $except_id }));
}

sub notify_room_members ($c, $room_id, $payload) {
    $c->pubsub->notify("cipherbox_room_$room_id" => encode_json({ msg => $payload }));
}

sub notify_user ($c, $user_id, $payload) {
    $c->pubsub->notify("cipherbox_user_$user_id" => encode_json({ msg => $payload }));
}

sub broadcast_room { my ($c, $room_id, $payload) = @_; _broadcast_room($c, $room_id, $payload); }

1;
