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
    my $password = $body->{password} // '';
    my $role     = $body->{role} // 'user';

    return $self->render(json => { error => 'missing fields' }, status => 400)
        unless length $username and length $password;
    return $self->render(json => { error => 'bad role' }, status => 400)
        unless $role =~ /^(admin|user)$/;

    my $exists = eval { $self->users->find_by_username($username) };
    return $self->render(json => { error => 'username taken' }, status => 409)
        if $exists;

    my $user = eval { $self->users->create($username, $password, $role) };
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

    if (($target->{role} // '') eq 'admin') {
        my $admin_count = $self->users->count_admins;
        return $self->render(json => { error => 'cannot remove last admin' }, status => 400)
            if $admin_count <= 1;
    }

    $self->users->delete($id);
    $self->render(json => { ok => 1 });
}

sub update_user ($self) {
    my $admin = $self->current_user;
    my $current = $self->current_user;
    my $id      = $self->param('id');
    my $body    = $self->req->json;
    my $role    = $body->{role} // '';

    return $self->render(json => { error => 'bad role' }, status => 400)
        unless $role =~ /^(admin|user)$/;

    my $target = $self->users->find_by_id($id);
    return $self->render(json => { error => 'user not found' }, status => 404)
        unless $target;

    if ($role eq 'user' && ($target->{role} // '') eq 'admin') {
        my $admin_count = $self->users->count_admins;
        return $self->render(json => { error => 'cannot demote last admin' }, status => 400)
            if $admin_count <= 1;
    }

    $self->users->update_role($id, $role);

    # AUDIT LOG
    $self->audit_logs->record(
        $admin->{id}, 'update_role', "user:$id", { new_role => $role }, $self->client_ip
    );

    $self->render(json => { ok => 1, user => { id => $id, role => $role } });
}

sub get_settings ($self) {
    my $registration_enabled = $self->settings->bool('registration_enabled', 1);
    $self->render(json => {
        settings => {
            registration_enabled => $registration_enabled ? 1 : 0,
        },
    });
}

sub update_settings ($self) {
    my $body = $self->req->json;
    if (exists $body->{registration_enabled}) {
        my $val = $body->{registration_enabled} ? 'true' : 'false';
        $self->settings->set('registration_enabled', $val);
    }
    my $registration_enabled = $self->settings->bool('registration_enabled', 1);
    $self->render(json => {
        ok => 1,
        settings => {
            registration_enabled => $registration_enabled ? 1 : 0,
        },
    });
}

sub list_reports ($self) {
    my $cfg    = $self->pagination;
    my $limit  = $self->param('limit')  // 50;
    my $offset = $self->param('offset') // 0;
    $limit = 100 if $limit > 100;
    $limit = 1 if $limit < 1;
    $offset = 0 if $offset < 0;

    my $reports = $self->reports->list_open($limit, $offset);
    my $total   = $self->reports->count_open;

    $self->render(json => {
        reports => $reports,
        total   => $total,
        limit   => $limit,
        offset  => $offset,
    });
}

sub get_report ($self) {
    my $admin = $self->current_user;
    my $id = $self->param('id');
    my $report = $self->reports->find_by_id($id);
    return $self->render(json => { error => 'not found' }, status => 404)
        unless $report;

    # AUDIT LOG
    $self->audit_logs->record(
        $admin->{id}, 'view_report', "report:$id", undef, $self->client_ip
    );

    my $room = $self->rooms->find_by_id($report->{room_id});
    my $reporter = $self->users->find_by_id($report->{reporter_id});
    my $message = $self->rooms->find_message_full($report->{message_id});

    my $edits = $self->message_edits->list_for_message($report->{message_id});

    my $room_key;
    if ($room) {
        $room_key = eval { $self->crypto->unwrap_room_key($room->{room_key_encrypted}) };
    }

    my $decrypted_message = $message;
    if ($message && $room_key) {
        my $text = eval {
            $self->crypto->decrypt_message(
                $room_key,
                $message->{content_encrypted},
                $message->{content_iv},
                $message->{content_tag},
            );
        };
        $decrypted_message = { %$message, text => $text // '[decrypt failed]' };
    }

    my @decrypted_edits;
    for my $e (@$edits) {
        my $text = $room_key ? eval {
            $self->crypto->decrypt_message(
                $room_key,
                $e->{content_encrypted},
                $e->{content_iv},
                $e->{content_tag},
            );
        } : undef;
        push @decrypted_edits, { %$e, text => $text // '[decrypt failed]' };
    }

    $self->render(json => {
        report => {
            id         => $report->{id},
            reason     => $report->{reason},
            status     => $report->{status},
            created_at => "$report->{created_at}",
            reporter   => $reporter ? $reporter->{username} : undef,
        },
        room => $room ? {
            id          => $room->{id},
            public_hash => $room->{public_hash},
            name        => $room->{name},
            type        => $room->{type},
        } : undef,
        message => $decrypted_message ? {
            id              => $decrypted_message->{id},
            sender_username => $decrypted_message->{sender_username},
            text            => $decrypted_message->{text},
            created_at      => "$decrypted_message->{created_at}",
            deleted_at      => $decrypted_message->{deleted_at} ? "$decrypted_message->{deleted_at}" : undef,
            deleted_by      => $decrypted_message->{deleted_by_username},
        } : undef,
        edits => [
            map {
                {
                    text      => $_->{text},
                    editor    => $_->{editor_username},
                    edited_at => "$_->{edited_at}",
                }
            } @decrypted_edits
        ],
    });
}

sub resolve_report ($self) {
    my $admin = $self->current_user;
    my $id = $self->param('id');
    my $body = $self->req->json;
    my $resolution = $body->{resolution} // '';

    my $report = $self->reports->find_by_id($id);
    return $self->render(json => { error => 'not found' }, status => 404)
        unless $report;
    return $self->render(json => { error => 'already resolved' }, status => 400)
        if $report->{status} eq 'resolved';

    $self->reports->resolve($id, $admin->{id}, $resolution);

    # AUDIT LOG
    $self->audit_logs->record(
        $admin->{id}, 'resolve_report', "report:$id", { resolution => $resolution }, $self->client_ip
    );

    $self->render(json => { ok => 1 });
}

sub view_room ($self) {
    my $admin = $self->current_user;
    my $room_hash = $self->param('hash');

    my $room = $self->rooms->find_by_hash($room_hash);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    # Gate: only allow if there's an open report for this room
    my $open_report = $self->reports->open_for_room($room->{id});
    return $self->render(json => { error => 'no open report for this room' }, status => 403)
        unless $open_report;

    # Fetch messages
    my $cfg    = $self->pagination;
    my $limit  = $self->param('limit')  // $cfg->{default_limit};
    my $before = $self->param('before');
    $limit = $cfg->{max_limit} if $limit > $cfg->{max_limit};
    $limit = 1 if $limit < 1;

    my $msgs = $self->rooms->list_messages(
        $room->{id}, $before, $limit,
        $cfg->{max_limit}, $cfg->{default_limit},
    );
    my @ordered = reverse @$msgs;

    # Decrypt for the admin (they have access via the room key, since they're the platform admin
    # and the backend already unwraps the room key server-side)
    my $room_key = $self->crypto->unwrap_room_key($room->{room_key_encrypted});

    my @out;
    for my $m (@ordered) {
        my $text;
        my @edits;
        my $deleted = $m->{deleted_at} ? 1 : 0;

        # Decrypt current content
        if (!$deleted) {
            $text = eval {
                $self->crypto->decrypt_message(
                    $room_key,
                    $m->{content_encrypted},
                    $m->{content_iv},
                    $m->{content_tag},
                );
            };
        } else {
            $text = $m->{content_encrypted};  # ciphertext; will not be decrypted for content display
        }

        # Decrypt edit history if any
        if ($m->{edit_count}) {
            my $hist = $self->message_edits->list_for_message($m->{id});
            for my $h (@$hist) {
                my $h_text = eval {
                    $self->crypto->decrypt_message(
                        $room_key,
                        $h->{content_encrypted},
                        $h->{content_iv},
                        $h->{content_tag},
                    );
                };
                push @edits, {
                    text      => $h_text // '[decrypt failed]',
                    editor    => $h->{editor_username},
                    edited_at => "$h->{edited_at}",
                };
            }
        }

        # For deleted messages, still decrypt current content so admin can see what was deleted
        if ($deleted) {
            $text = eval {
                $self->crypto->decrypt_message(
                    $room_key,
                    $m->{content_encrypted},
                    $m->{content_iv},
                    $m->{content_tag},
                );
            } // '[decrypt failed]';
        }

        push @out, {
            id          => $m->{id},
            sender_id   => $m->{sender_id},
            text        => $text,
            ts          => "$m->{created_at}",
            edit_count  => $m->{edit_count} + 0,
            deleted_at  => $m->{deleted_at} ? "$m->{deleted_at}" : undef,
            edits       => \@edits,
        };
    }

    # Sender names
    my $members = $self->rooms->list_members($room->{id});
    my %member_names = map { $_->{user_id} => $_->{username} } @$members;

    for my $m (@out) {
        $m->{sender_username} = $member_names{ $m->{sender_id} } // "user#$m->{sender_id}";
    }

    # AUDIT LOG
    $self->audit_logs->record(
        $admin->{id}, 'view_room_messages', "room:$room_hash", undef, $self->client_ip
    );

    $self->render(json => {
        room => {
            id          => $room->{id},
            public_hash => $room->{public_hash},
            name        => $room->{name},
            type        => $room->{type},
        },
        messages => \@out,
        report   => {
            id     => $open_report->{id},
            reason => $open_report->{reason},
        },
    });
}

1;
