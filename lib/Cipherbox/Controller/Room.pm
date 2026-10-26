package Cipherbox::Controller::Room;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub _resolve_room ($self, $param) {
    return $self->rooms->find_by_hash_or_id($param);
}

sub _check_ephemeral_destruction ($self, $room) {
    return unless $room->{is_ephemeral};
    
    my $remaining = $self->pg->db->query(
        'SELECT count(*) FROM room_members WHERE room_id = ?', $room->{id}
    )->array->[0];
    
    if ($remaining == 0) {
        # Destroy the room and all its data
        $self->rooms->delete($room->{id});
        
        Cipherbox::Controller::Chat::broadcast_room(
            $self, $room->{id}, { type => 'room.deleted', room_id => $room->{id} }
        );
    }
}

sub list ($self) {
    my $user  = $self->current_user;
    my $rooms = $self->rooms->list_for_user($user->{id});
    $self->render(json => { rooms => $rooms });
}

sub create ($self) {
    my $user = $self->current_user;
    my $body = $self->req->json;
    my $name = $body->{name} // '';
    my $type = $body->{type} // 'room';
    my $member_id = $body->{member_id};
    my $owner_ciphertext = $body->{owner_kyber_ciphertext}; 
    my $plaintext_key = $body->{plaintext_room_key};
    my $is_invite_only = $body->{is_invite_only} ? 1 : 0;
    my $is_ephemeral = $body->{is_ephemeral} ? 1 : 0; # <-- NEW

    return $self->render(json => { error => 'missing name' }, status => 400)
        unless length $name;

    my $room_key_encrypted = undef;

    if ($is_invite_only) {
        return $self->render(json => { error => 'missing ciphertext' }, status => 400)
            unless $owner_ciphertext;
        
        if ($type eq 'private') {
            return $self->render(json => { error => 'member_id required for private' }, status => 400)
                unless $member_id;
            return $self->render(json => { error => 'user not found' }, status => 404)
                unless $self->users->find_by_id($member_id);
            return $self->render(json => { error => 'cannot invite yourself' }, status => 400)
                if $member_id == $user->{id};

            my $existing = $self->rooms->find_private_room($user->{id}, $member_id);
            if ($existing) {
                return $self->render(json => { room => $existing, reused => 1 });
            }
        }
    } else {
        return $self->render(json => { error => 'missing plaintext_room_key' }, status => 400)
            unless $plaintext_key;
        $room_key_encrypted = $self->crypto->wrap_room_key($plaintext_key);
    }

    my $room = $self->rooms->create($name, $type, $user->{id}, $is_invite_only, $room_key_encrypted, $is_ephemeral);
    $self->rooms->add_member($room->{id}, $user->{id}, 'owner', $owner_ciphertext);

    if ($type eq 'private' and $member_id) {
        my $member_ciphertext = $body->{member_kyber_ciphertext};
        $self->rooms->add_member($room->{id}, $member_id, 'member', $member_ciphertext);
    }

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, { type => 'room.created', room_id => $room->{id} }
    );

    $self->render(json => { room => $room });
}

sub join ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    return $self->render(json => { error => 'private rooms are invite-only' }, status => 403)
        if $room->{type} eq 'private';
    return $self->render(json => { error => 'invite only' }, status => 403)
        if $room->{is_invite_only};
    return $self->render(json => { error => 'banned from this room' }, status => 403)
        if $self->rooms->is_banned($room->{id}, $user->{id});

    return $self->render(json => { ok => 1, already_member => 1 })
        if $self->rooms->is_member($room->{id}, $user->{id});

    # For public rooms/channels, server wraps the key automatically
    my $kyber_ciphertext = undef;
    if ($room->{room_key_encrypted}) {
        my $user_row = $self->pg->db->query(
            'SELECT kyber_public_key FROM users WHERE id = ?', $user->{id}
        )->hash;

        if ($user_row && $user_row->{kyber_public_key}) {
            my $room_key = $self->crypto->unwrap_room_key($room->{room_key_encrypted});
            my $wrap_bin = $self->app->home->child('bin', 'cipherbox-pqc-wrap')->to_string;
            
            my $cmd = join(' ', map { my $s = $_; $s =~ s/'/'\\''/g; "'$s'" }
                ($wrap_bin, $user_row->{kyber_public_key}, $room_key));
            
            my $out = qx{$cmd 2>/dev/null};
            my $exit = $? >> 8;
            if ($exit == 0 && $out =~ /^\{.*\}$/) {
                chomp $out;
                $kyber_ciphertext = $out;
            }
        }
    }

    $self->rooms->add_member($room->{id}, $user->{id}, 'member', $kyber_ciphertext);

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, { type => 'room.updated', room_id => $room->{id} }
    );

    $self->render(json => { ok => 1 });
}

sub key ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');
    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    # If it's NOT invite-only (Public), return the plaintext key
    if (!$room->{is_invite_only}) {
        return $self->render(json => { error => 'server key missing from DB' }, status => 500)
            unless $room->{room_key_encrypted};

        my $room_key = $self->crypto->unwrap_room_key($room->{room_key_encrypted});
        return $self->render(json => { plaintext_room_key => $room_key });
    }

    # If it IS invite-only (Private), return the Kyber ciphertext
    my $member = $self->pg->db->query(
        'SELECT kyber_ciphertext FROM room_members WHERE room_id = ? AND user_id = ?',
        $room->{id}, $user->{id}
    )->hash;

    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $member;

    $self->render(json => { kyber_ciphertext => $member->{kyber_ciphertext} });
}

sub invite ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');
    my $body    = $self->req->json;
    my $target  = $body->{user_id};
    my $target_ciphertext = $body->{target_kyber_ciphertext};

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    my $role = $self->rooms->member_role($room->{id}, $user->{id});
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $role and $role =~ /^(owner|admin)$/;

    return $self->render(json => { error => 'user not found' }, status => 404)
        unless $self->users->find_by_id($target);

    return $self->render(json => { error => 'missing ciphertext' }, status => 400)
        unless $target_ciphertext;

    $self->rooms->add_member($room->{id}, $target, 'member', $target_ciphertext);

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, { type => 'room.updated', room_id => $room->{id} }
    );
    Cipherbox::Controller::Chat::notify_user(
        $self, $target, { type => 'room.created', room_id => $room->{id} }
    );

    $self->render(json => { ok => 1 });
}

sub remove ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');
    my $body    = $self->req->json;
    my $target  = $body->{user_id};

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    my $role = $self->rooms->member_role($room->{id}, $user->{id});
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $role and $role =~ /^(owner|admin)$/;

    return $self->render(json => { error => 'cannot remove owner' }, status => 400)
        if $target == $room->{owner_id};

    $self->rooms->remove_member($room->{id}, $target);
    $self->rooms->ban_user($room->{id}, $target, $user->{id});

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, { type => 'room.updated', room_id => $room->{id} }
    );

    Cipherbox::Controller::Chat::notify_user(
        $self, $target, { type => 'room.removed', room_id => $room->{id} }
    );

    $self->_check_ephemeral_destruction($room); # <-- NEW

    $self->render(json => { ok => 1 });
}

sub leave ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    my $role = $self->rooms->member_role($room->{id}, $user->{id});
    return $self->render(json => { error => 'not a member' }, status => 403)
        unless $role;

    my $member_count = $self->pg->db->query(
        'SELECT count(*) FROM room_members WHERE room_id = ?', $room->{id}
    )->array->[0];

    if ($role eq 'owner') {
        if ($room->{is_ephemeral}) {
            if ($member_count == 1) {
                # Owner is the last one — destroy the room
                $self->rooms->delete($room->{id});
                Cipherbox::Controller::Chat::broadcast_room(
                    $self, $room->{id}, { type => 'room.deleted', room_id => $room->{id} }
                );
                return $self->render(json => { ok => 1, destroyed => 1 });
            } else {
                return $self->render(
                    json => { error => 'you must wait for all members to leave first' },
                    status => 400,
                );
            }
        } else {
            return $self->render(json => { error => 'owner cannot leave, delete instead' }, status => 400);
        }
    }

    # Regular member leaving
    $self->rooms->remove_member($room->{id}, $user->{id});

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, { type => 'room.updated', room_id => $room->{id} }
    );

    # Ephemeral room: destroy if empty
    if ($room->{is_ephemeral}) {
        my $remaining = $self->pg->db->query(
            'SELECT count(*) FROM room_members WHERE room_id = ?', $room->{id}
        )->array->[0];
        
        if ($remaining == 0) {
            $self->rooms->delete($room->{id});
            Cipherbox::Controller::Chat::broadcast_room(
                $self, $room->{id}, { type => 'room.deleted', room_id => $room->{id} }
            );
        }
    }

    $self->render(json => { ok => 1 });
}

sub delete ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $room->{owner_id} == $user->{id};

    # Notify everyone currently in the room
    Cipherbox::Controller::Chat::broadcast_room(
        $self, $room->{id}, { type => 'room.deleted', room_id => $room->{id} }
    );

    $self->rooms->delete($room->{id});
    $self->render(json => { ok => 1 });
}

sub messages ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $self->rooms->is_member($room->{id}, $user->{id});
    return $self->render(json => { error => 'banned' }, status => 403)
        if $self->rooms->is_banned($room->{id}, $user->{id});

    my $before = $self->param('before');
    my $limit  = $self->param('limit');
    my $cfg    = $self->pagination;

    my $msgs = $self->rooms->list_messages(
        $room->{id}, $before, $limit,
        $cfg->{max_limit}, $cfg->{default_limit},
    );
    my @ordered = reverse @$msgs;

    $self->render(json => {
        messages => [
            map {
                {
                    id              => $_->{id},
                    sender_id       => $_->{sender_id},
                    sender_username => $_->{sender_username},
                    ct              => $_->{content_encrypted},
                    iv              => $_->{content_iv},
                    tag             => $_->{content_tag},
                    ts              => "$_->{created_at}",
                    edit_count      => $_->{edit_count} + 0,
                    deleted_at      => $_->{deleted_at} ? "$_->{deleted_at}" : undef,
                }
            } @ordered
        ],
    });
}

sub members ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');
    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $self->rooms->is_member($room->{id}, $user->{id});
    
    my $limit  = $self->param('limit') // 50;
    my $offset = $self->param('offset') // 0;
    my $q      = $self->param('q');
    $limit = 100 if $limit > 100;

    my $members = $self->rooms->list_members($room->{id}, $limit, $offset, $q);
    my $total   = $self->rooms->count_members($room->{id}, $q);

    $self->render(json => { 
        members => $members,
        total => $total,
        limit => $limit,
        offset => $offset
    });
}

sub delete_message ($self) {
    my $user       = $self->current_user;
    my $param      = $self->param('id');
    my $message_id = $self->param('message_id');

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    my $role = $self->rooms->member_role($room->{id}, $user->{id});
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $role;

    my $message = $self->rooms->find_message($message_id);
    return $self->render(json => { error => 'message not found' }, status => 404)
        unless $message;
    return $self->render(json => { error => 'wrong room' }, status => 400)
        unless $message->{room_id} == $room->{id};

    my $is_sender  = $message->{sender_id} == $user->{id};
    my $is_manager = $role =~ /^(owner|admin)$/;
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $is_sender || $is_manager;

    $self->rooms->soft_delete_message($message_id, $user->{id});

    Cipherbox::Controller::Chat::broadcast_room(
        $self, $room->{id}, {
            type       => 'chat.deleted',
            room_id    => $room->{id},
            message_id => $message_id,
        },
    );

    $self->render(json => { ok => 1 });
}

sub edit_message ($self) {
    my $user       = $self->current_user;
    my $param      = $self->param('id');
    my $message_id = $self->param('message_id');
    my $body       = $self->req->json;
    my $ct         = $body->{ct};
    my $iv         = $body->{iv};
    my $tag        = $body->{tag};
    return $self->render(json => { error => 'missing fields' }, status => 400)
        unless $ct and $iv and $tag;

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    my $role = $self->rooms->member_role($room->{id}, $user->{id});
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $role;

    my $message = $self->rooms->find_message_full($message_id);
    return $self->render(json => { error => 'message not found' }, status => 404)
        unless $message;
    return $self->render(json => { error => 'wrong room' }, status => 400)
        unless $message->{room_id} == $room->{id};
    return $self->render(json => { error => 'message is deleted' }, status => 400)
        if $message->{deleted_at};

    my $is_sender  = $message->{sender_id} == $user->{id};
    my $is_manager = $role =~ /^(owner|admin)$/;
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $is_sender || $is_manager;

    $self->message_edits->record(
        $message_id, $user->{id},
        $message->{content_encrypted}, $message->{content_iv}, $message->{content_tag},
    );

    $self->rooms->update_message($message_id, $ct, $iv, $tag);

    # Get the new edit count
    my $edit_count = $self->message_edits->count_for_message($message_id);

    Cipherbox::Controller::Chat::broadcast_room(
        $self, $room->{id}, {
            type       => 'chat.edited',
            room_id    => $room->{id},
            message_id => $message_id,
            ct         => $ct, 
            iv         => $iv, 
            tag        => $tag,
            edit_count => $edit_count, # <-- Send the new count
        },
    );

    $self->render(json => { ok => 1 });
}

sub rename ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');
    my $body    = $self->req->json;
    my $name    = $body->{name} // '';
    return $self->render(json => { error => 'missing name' }, status => 400)
        unless length $name;
    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $room->{owner_id} == $user->{id};
    $self->rooms->update_name($room->{id}, $name);
    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, { type => 'room.updated', room_id => $room->{id} }
    );
    $self->render(json => { ok => 1, name => $name });
}

sub mark_read ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');
    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $self->rooms->is_member($room->{id}, $user->{id});
    $self->rooms->mark_read($room->{id}, $user->{id});
    $self->render(json => { ok => 1 });
}

sub find_by_id_public ($self) {
    my $param = $self->param('id');
    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    my $user = $self->current_user;
    my $is_member = $user ? $self->rooms->is_member($room->{id}, $user->{id}) : 0;
    my $banned    = $user ? $self->rooms->is_banned($room->{id}, $user->{id}) : 0;
    
    my $member_count = $self->pg->db->query(
        'SELECT count(*) FROM room_members WHERE room_id = ?', $room->{id}
    )->array->[0];

    my $my_role = $is_member ? $self->rooms->member_role($room->{id}, $user->{id}) : undef;
    my $is_public = $room->{is_invite_only} ? 0 : 1;

    $self->render(json => {
        room => {
            id             => $room->{id},
            public_hash    => $room->{public_hash},
            name           => $room->{name},
            type           => $room->{type},
            owner_id       => $room->{owner_id},
            is_invite_only => $room->{is_invite_only} ? 1 : 0,
            is_public      => $is_public,
            is_member      => $is_member ? 1 : 0,
            my_role        => $my_role,
            member_count   => $member_count + 0,
            joinable       => ($room->{type} ne 'private' && !$room->{is_invite_only} && !$banned) ? 1 : 0,
            banned         => $banned ? 1 : 0,
            is_ephemeral   => $room->{is_ephemeral} ? 1 : 0,
        },
    });
}

sub discover ($self) {
    my $user = $self->current_user;
    my $cfg  = $self->pagination;

    my $limit  = $self->param('limit')  // $cfg->{default_limit};
    my $offset = $self->param('offset') // 0;
    my $q      = $self->param('q');

    $limit = $cfg->{max_limit} if $limit > $cfg->{max_limit};
    $limit = 1 if $limit < 1;
    $offset = 0 if $offset < 0;

    my ($rooms, $total);
    eval {
        $rooms = $self->rooms->discover($user->{id}, $limit, $offset, $q);
        $total = $self->rooms->count_discover($user->{id}, $q);
        1;
    } or do {
        my $err = $@;
        return $self->render(json => { error => "discover failed: $err" }, status => 500);
    };

    $self->render(json => {
        rooms  => $rooms,
        total  => $total,
        limit  => $limit,
        offset => $offset,
    });
}

1;
