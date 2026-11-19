package Cipherbox::Controller::Room;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Cipherbox::Page qw(page_limit page_offset id_cursor);

sub _resolve_room ($self, $param) {
    return $self->rooms->find_by_hash_or_id($param);
}

sub list ($self) {
    my $user  = $self->current_user;
    my $cfg = $self->pagination;
    my $limit = page_limit($self->param('limit'), $cfg->{default_limit}, $cfg->{max_limit});
    my $filter = $self->param('type') // 'all';
    my ($activity, $id);
    if (defined(my $cursor = $self->param('cursor'))) {
        ($activity, $id) = $cursor =~ /\A(-?[0-9]{1,18}):([0-9]{1,19})\z/;
        return $self->render(json => { error => 'invalid room cursor' }, status => 400)
            unless defined($activity) && id_cursor($id);
    }
    return $self->render(json => { error => 'invalid room pagination or type' }, status => 400)
        unless defined($limit) && $filter =~ /\A(?:all|room|channel|private)\z/;

    my $rooms = $self->rooms->list_for_user($user->{id}, $limit + 1, $filter, $activity, $id);
    my $next;
    if (@$rooms > $limit) {
        pop @$rooms;
        $next = "$rooms->[-1]{activity_us}:$rooms->[-1]{id}";
    }
    delete @{$_}{qw(activity_us last_sender_id)} for @$rooms;
    $self->render(json => { rooms => $rooms, next_cursor => $next });
}

sub create ($self) {
    my $user = $self->current_user;
    my $body = $self->req->json;
    my $name = $body->{name} // '';
    my $type = $body->{type} // 'room';
    my $member_id = $body->{member_id};
    my $is_invite_only = $body->{is_invite_only} ? 1 : 0;

    return $self->render(json => { error => 'missing name' }, status => 400)
        unless length $name;
    return $self->render(json => { error => 'bad type' }, status => 400)
        unless $type =~ /^(private|channel|room)$/;

    if ($type eq 'private') {
        return $self->render(json => { error => 'member_id required for private' }, status => 400)
            unless $member_id;
        return $self->render(json => { error => 'user not found' }, status => 404)
            unless $self->users->find_by_id($member_id);
        return $self->render(json => { error => 'cannot invite yourself' }, status => 400)
            if $member_id == $user->{id};
        $is_invite_only = 1;

        my $existing = $self->rooms->find_private_room($user->{id}, $member_id);
        if ($existing) {
            return $self->render(json => { room => $existing, reused => 1 });
        }
    }

    my $room_key = $self->crypto->generate_room_key;
    my $wrapped  = $self->crypto->wrap_room_key($room_key);

    my $room = $self->rooms->create($name, $type, $user->{id}, $wrapped, $is_invite_only);

    if ($type eq 'private') {
        $self->rooms->add_member($room->{id}, $member_id, 'member');
    }

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, { type => 'room.created', room_id => $room->{id} }
    );
    Cipherbox::Controller::Chat::notify_user(
        $self, $member_id, { type => 'room.created', room_id => $room->{id} }
    ) if $member_id;

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

    $self->rooms->add_member($room->{id}, $user->{id}, 'member');

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
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $self->rooms->is_member($room->{id}, $user->{id});
    return $self->render(json => { error => 'banned' }, status => 403)
        if $self->rooms->is_banned($room->{id}, $user->{id});
    my $room_key = $self->crypto->unwrap_room_key($room->{room_key_encrypted});
    $self->render(json => { room_key => $room_key });
}

sub invite ($self) {
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

    return $self->render(json => { error => 'user not found' }, status => 404)
        unless $self->users->find_by_id($target);

    return $self->render(json => { error => 'user is banned, unban first' }, status => 400)
        if $self->rooms->is_banned($room->{id}, $target);

    if ($room->{type} eq 'private') {
        my $count = $self->pg->db->query(
            'SELECT count(*) FROM room_members WHERE room_id = ?', $room->{id}
        )->array->[0];
        return $self->render(json => { error => 'private room is full' }, status => 400)
            if $count >= 2;
    }

    $self->rooms->add_member($room->{id}, $target, 'member');

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

    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $room->{owner_id} == $user->{id};

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

    $self->render(json => { ok => 1 });
}

sub unban ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');
    my $target  = $self->param('user_id');

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $room->{owner_id} == $user->{id};

    $self->rooms->unban_user($room->{id}, $target);
    $self->render(json => { ok => 1 });
}

sub bans ($self) {
    my $user    = $self->current_user;
    my $param   = $self->param('id');

    my $room = $self->_resolve_room($param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $room->{owner_id} == $user->{id};

    my $bans = $self->rooms->list_bans($room->{id});
    $self->render(json => { bans => $bans });
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
    return $self->render(json => { error => 'owner cannot leave, delete instead' }, status => 400)
        if $role eq 'owner';

    $self->rooms->remove_member($room->{id}, $user->{id});

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, { type => 'room.updated', room_id => $room->{id} }
    );

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

    Cipherbox::Controller::Chat::notify_room_members(
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
    my $cfg    = $self->pagination;
    my $limit = page_limit($self->param('limit'), $cfg->{default_limit}, $cfg->{max_limit});
    return $self->render(json => { error => 'invalid message pagination' }, status => 400)
        unless defined($limit) && (!defined($before) || id_cursor($before));

    my $msgs = $self->rooms->list_messages(
        $room->{id}, $before, $limit + 1, $cfg->{max_limit} + 1,
    );
    my $next;
    if (@$msgs > $limit) {
        pop @$msgs;
        $next = "$msgs->[-1]{id}";
    }
    my @ordered = reverse @$msgs;

    $self->render(json => {
        next_cursor => $next,
        messages => [
            map {
                {
                    id         => $_->{id},
                    sender_id  => $_->{sender_id},
                    ct         => $_->{content_encrypted},
                    iv         => $_->{content_iv},
                    tag        => $_->{content_tag},
                    ts         => "$_->{created_at}",
                    edit_count => $_->{edit_count} + 0,
                    deleted_at => $_->{deleted_at} ? "$_->{deleted_at}" : undef,
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

    my $limit  = page_limit($self->param('limit'), 100, 200);
    my $offset = page_offset($self->param('offset'));
    my $q      = $self->param('q');

    return $self->render(json => { error => 'invalid member pagination' }, status => 400)
        unless defined($limit) && defined($offset);

    my $members = $self->rooms->list_members($room->{id}, $limit, $offset, $q);
    my $total   = $self->rooms->count_members($room->{id}, $q);

    $self->render(json => {
        members => $members,
        total   => $total,
        limit   => $limit,
        offset  => $offset,
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

    # Delete any attached paste blob before soft-deleting the message
    my $paste = $self->pg->db->query(
        'SELECT * FROM pastes WHERE message_id = ? AND deleted_at IS NULL',
        $message_id,
    )->hash;
    if ($paste) {
        if ($paste->{kind} eq 'file' && $paste->{file_path}) {
            my $stored = path($self->app->home, 'storage', 'pastes', $paste->{file_path});
            $stored->remove if -e $stored;
        }
        $self->pastes->mark_deleted($paste->{id});
    }

    $self->rooms->soft_delete_message($message_id, $user->{id});

    Cipherbox::Controller::Chat::broadcast_room(
        $self, $room->{id}, {
            type       => 'chat.deleted',
            room_id    => $room->{id},
            message_id => $message_id,
        },
    );

    if ($paste) {
        Cipherbox::Controller::Chat::notify_room_members(
            $self, $room->{id}, {
                type       => 'paste.deleted',
                room_id    => $room->{id},
                paste_hash => $paste->{public_hash},
            },
        );
    }

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

    Cipherbox::Controller::Chat::broadcast_room(
        $self, $room->{id}, {
            type       => 'chat.edited',
            room_id    => $room->{id},
            message_id => $message_id,
            ct         => $ct, iv => $iv, tag => $tag,
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

    $self->render(json => {
        room => {
            id             => $room->{id},
            public_hash    => $room->{public_hash},
            name           => $room->{name},
            type           => $room->{type},
            owner_id       => $room->{owner_id},
            is_invite_only => $room->{is_invite_only} ? 1 : 0,
            is_member      => $is_member ? 1 : 0,
            joinable       => ($room->{type} ne 'private' && !$room->{is_invite_only} && !$banned) ? 1 : 0,
            banned         => $banned ? 1 : 0,
        },
    });
}

sub discover ($self) {
    my $user = $self->current_user;
    my $cfg  = $self->pagination;

    my $limit = page_limit($self->param('limit'), $cfg->{default_limit}, $cfg->{max_limit});
    my $offset = page_offset($self->param('offset'));
    my $q      = $self->param('q');

    return $self->render(json => { error => 'invalid discovery pagination' }, status => 400)
        unless defined($limit) && defined($offset);

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
