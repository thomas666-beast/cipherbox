package Cipherbox::Controller::Paste;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::File 'path';
use Encode qw(encode decode);
use UUID::Tiny qw(create_uuid_as_string UUID_V4);
use Crypt::AuthEnc::GCM;
use MIME::Base64 ();
use Mojo::JSON qw(encode_json);
use Crypt::PRNG qw(random_bytes);

my $MAX_SIZE = 50 * 1024 * 1024;
my $MAX_TEXT = 1024 * 1024;

sub _storage_dir ($self) {
    my $dir = path($self->app->home, 'storage', 'pastes');
    $dir->make_path unless -d $dir;
    return $dir;
}

sub _resolve_room ($self, $param) {
    return $self->rooms->find_by_hash_or_id($param);
}

sub _secure_wipe ($path) {
    return unless -e $path;
    my $size = -s $path;
    if ($size > 0) {
        # Overwrite with random data
        CORE::open(my $fh, '>:raw', $path) or return;
        print $fh random_bytes($size);
        close $fh;
    }
    unlink $path;
}

sub _paste_json ($paste) {
    return {
        id          => $paste->{id},
        public_hash => $paste->{public_hash},
        title       => $paste->{title},
        kind        => $paste->{kind},
        message_id  => $paste->{message_id},
        file_name   => $paste->{file_name},
        file_size   => $paste->{file_size},
        mime_type   => $paste->{mime_type},
        opened_by   => $paste->{opened_by},
        opened_at   => $paste->{opened_at},
        deleted_at  => $paste->{deleted_at},
    };
}

sub _decrypt_text_content ($self, $paste) {
    my $paste_key = $self->crypto->unwrap_room_key($paste->{file_key_encrypted});
    my $raw_key   = MIME::Base64::decode_base64($paste_key);
    my $iv  = MIME::Base64::decode_base64($paste->{content_iv});
    my $tag = MIME::Base64::decode_base64($paste->{content_tag});
    my $ct  = MIME::Base64::decode_base64($paste->{content_encrypted});
    my $ae = Crypt::AuthEnc::GCM->new('AES', $raw_key, $iv);
    my $pt = eval { $ae->decrypt_add($ct) };
    $ae->decrypt_done($tag);
    return decode('UTF-8', $pt);
}

sub create ($self) {
    my $user = $self->current_user;
    my $room_param = $self->param('room_id');
    my $room = $self->_resolve_room($room_param);
    return $self->render(json => { error => 'room not found' }, status => 404)
        unless $room;

    my $role = $self->rooms->member_role($room->{id}, $user->{id});
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $role;

    my $title = $self->param('title') // '';
    return $self->render(json => { error => 'missing title' }, status => 400)
        unless length $title;

    my $file = $self->param('file');
    my $text = $self->param('text');

    if ($file) {
        return $self->_create_file_paste($user, $room, $title, $file);
    }
    if (defined $text and length $text) {
        return $self->_create_text_paste($user, $room, $title, $text);
    }
    return $self->render(json => { error => 'no text or file' }, status => 400);
}

sub _create_text_paste ($self, $user, $room, $title, $text) {
    return $self->render(json => { error => 'text too large (max 1 MB)' }, status => 400)
        if length($text) > $MAX_TEXT;

    my $plaintext = encode('UTF-8', $text);

    my $paste_key = $self->crypto->generate_room_key;
    my $wrapped   = $self->crypto->wrap_room_key($paste_key);
    my $enc = $self->crypto->encrypt_bytes($paste_key, $plaintext);

    my $enc_ct  = MIME::Base64::encode_base64($enc->{data}, '');
    my $enc_iv  = MIME::Base64::encode_base64($enc->{iv}, '');
    my $enc_tag = MIME::Base64::encode_base64($enc->{tag}, '');

    my $paste = $self->pastes->create_text(
        room_id            => $room->{id},
        sender_id          => $user->{id},
        title              => $title,
        content_encrypted  => $enc_ct,
        content_iv         => $enc_iv,
        content_tag        => $enc_tag,
        file_key_encrypted => $wrapped,
    );

    $self->_post_paste_message($user, $room, $paste);

    $self->render(json => { paste => _paste_json($paste) });
}

sub _create_file_paste ($self, $user, $room, $title, $file) {
    my $size = $file->size // 0;
    return $self->render(json => { error => 'file too large (max 50 MB)' }, status => 400)
        if $size > $MAX_SIZE;

    my $plaintext = $file->slurp;
    $plaintext = encode('UTF-8', $plaintext) if utf8::is_utf8($plaintext);

    my $uuid = create_uuid_as_string(UUID_V4);
    my $paste_key = $self->crypto->generate_room_key;
    my $wrapped   = $self->crypto->wrap_room_key($paste_key);
    my $enc = $self->crypto->encrypt_bytes($paste_key, $plaintext);

    my $payload = $enc->{iv} . $enc->{tag} . $enc->{data};
    $payload = encode('UTF-8', $payload) if utf8::is_utf8($payload);

    my $stored_path = $self->_storage_dir->child("$uuid.bin");
    $stored_path->spew($payload);

    my $mime = $file->headers->content_type // 'application/octet-stream';
    my $fname = $file->filename // 'file';

    my $paste = $self->pastes->create_file(
        room_id            => $room->{id},
        sender_id          => $user->{id},
        title              => $title,
        mime_type          => $mime,
        file_name          => $fname,
        file_size          => $size,
        file_path          => "$uuid.bin",
        file_key_encrypted => $wrapped,
    );

    $self->_post_paste_message($user, $room, $paste);

    $self->render(json => { paste => _paste_json($paste) });
}

sub _post_paste_message ($self, $user, $room, $paste) {
    my $room_key = $self->crypto->unwrap_room_key($room->{room_key_encrypted});

    my $message_plain = encode_json({
        _type      => 'paste',
        paste_hash => $paste->{public_hash},
        title      => $paste->{title},
        kind       => $paste->{kind},
    });

    my $enc = $self->crypto->encrypt_message($room_key, $message_plain);

    my $row = $self->pg->db->query(
        'INSERT INTO messages (room_id, sender_id, content_encrypted, content_iv, content_tag)
         VALUES (?, ?, ?, ?, ?) RETURNING id, created_at',
        $room->{id}, $user->{id}, $enc->{ct}, $enc->{iv}, $enc->{tag},
    )->hash;

    $self->pastes->attach_message($paste->{id}, $row->{id});
    $paste->{message_id} = $row->{id};

    Cipherbox::Controller::Chat::broadcast_room(
        $self, $room->{id}, {
            type       => 'chat.recv',
            room_id    => $room->{id},
            sender_id  => $user->{id},
            message_id => $row->{id},
            ct         => $enc->{ct},
            iv         => $enc->{iv},
            tag        => $enc->{tag},
            ts         => "$row->{created_at}",
        },
    );

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $room->{id}, {
            type            => 'room.updated',
            room_id         => $room->{id},
            last_message_at => "$row->{created_at}",
            last_sender     => $user->{username},
        },
    );
}

sub info ($self) {
    my $user = $self->current_user;
    my $hash = $self->param('hash');
    my $paste = $self->pastes->find_by_hash($hash);
    return $self->render(json => { error => 'not found' }, status => 404)
        unless $paste;

    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $self->rooms->is_member($paste->{room_id}, $user->{id});

    my $opened_username;
    if ($paste->{opened_by}) {
        my $u = $self->users->find_by_id($paste->{opened_by});
        $opened_username = $u ? $u->{username} : undef;
    }

    my $sender = $self->users->find_by_id($paste->{sender_id});
    my $is_sender = $paste->{sender_id} == $user->{id};

    $self->render(json => {
        paste => {
            %{ _paste_json($paste) },
            opened_username => $opened_username,
            sender_username => $sender ? $sender->{username} : undef,
            is_sender       => $is_sender ? 1 : 0,
            can_open        => (!$paste->{opened_at} && !$paste->{deleted_at}) ? 1 : 0,
            can_done        => ($paste->{opened_by} && $paste->{opened_by} == $user->{id}
                                && !$paste->{deleted_at}) ? 1 : 0,
            can_download    => ($paste->{kind} eq 'file' && !$paste->{deleted_at}
                                && ($paste->{sender_id} == $user->{id}
                                    || ($paste->{opened_by} && $paste->{opened_by} == $user->{id}))
                               ) ? 1 : 0,
        },
    });
}

sub open ($self) {
    my $user = $self->current_user;
    my $hash = $self->param('hash');
    my $paste = $self->pastes->find_by_hash($hash);
    return $self->render(json => { error => 'not found' }, status => 404)
        unless $paste;

    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $self->rooms->is_member($paste->{room_id}, $user->{id});

    return $self->render(json => { error => 'paste has been deleted' }, status => 410)
        if $paste->{deleted_at};

    my $is_sender = $paste->{sender_id} == $user->{id};

    # Sender peek: return content without consuming
    if ($is_sender) {
        if ($paste->{kind} eq 'text') {
            return $self->render(json => {
                paste => {
                    %{ _paste_json($paste) },
                    content => _decrypt_text_content($self, $paste),
                    peek    => 1,
                },
            });
        }
        return $self->render(json => {
            paste => {
                %{ _paste_json($paste) },
                download_url => "/api/pastes/$paste->{public_hash}/download",
                peek         => 1,
            },
        });
    }

    return $self->render(json => { error => 'paste already opened' }, status => 409)
        if $paste->{opened_at};

    my $claimed = $self->pg->db->query(
        'UPDATE pastes SET opened_by = ?, opened_at = now()
         WHERE id = ? AND opened_at IS NULL AND deleted_at IS NULL
         RETURNING *',
        $user->{id}, $paste->{id},
    )->hash;
    return $self->render(json => { error => 'paste already opened' }, status => 409)
        unless $claimed;

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $paste->{room_id}, {
            type       => 'paste.opened',
            room_id    => $paste->{room_id},
            paste_hash => $paste->{public_hash},
            opened_by  => $user->{username},
        },
    );

    if ($paste->{kind} eq 'text') {
        return $self->render(json => {
            paste => {
                %{ _paste_json($claimed) },
                content => _decrypt_text_content($self, $paste),
            },
        });
    }

    $self->render(json => {
        paste => {
            %{ _paste_json($claimed) },
            download_url => "/api/pastes/$paste->{public_hash}/download",
        },
    });
}

sub download ($self) {
    my $user = $self->current_user;
    my $hash = $self->param('hash');
    my $paste = $self->pastes->find_by_hash($hash);
    return $self->render(json => { error => 'not found' }, status => 404)
        unless $paste;

    my $is_sender = $paste->{sender_id} == $user->{id};
    my $is_opener = $paste->{opened_by} && $paste->{opened_by} == $user->{id};
    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $is_sender || $is_opener;

    return $self->render(json => { error => 'paste has been deleted' }, status => 410)
        if $paste->{deleted_at};

    return $self->render(json => { error => 'not a file paste' }, status => 400)
        unless $paste->{kind} eq 'file';

    my $stored_path = $self->_storage_dir->child($paste->{file_path});
    return $self->render(json => { error => 'file missing' }, status => 500)
        unless -e $stored_path;

    my $file_key = $self->crypto->unwrap_room_key($paste->{file_key_encrypted});
    my $raw_key  = MIME::Base64::decode_base64($file_key);

    CORE::open(my $fh1, '<:raw', $stored_path->to_string) or
        return $self->render(json => { error => 'open failed' }, status => 500);
    my ($iv, $tag, $ct_off, $ct_len) = $self->crypto->read_enc_header($fh1);
    close $fh1;

    my $verify_ok = eval {
        CORE::open(my $fhv, '<:raw', $stored_path->to_string) or die "open: $!";
        seek($fhv, $ct_off, 0) or die "seek: $!";
        my $ae = Crypt::AuthEnc::GCM->new('AES', $raw_key, $iv);
        my $buf;
        my $remaining = $ct_len;
        while ($remaining > 0) {
            my $want = $remaining > 65536 ? 65536 : $remaining;
            my $got  = read($fhv, $buf, $want);
            die "short read" unless defined $got and $got > 0;
            $ae->decrypt_add($buf);
            $remaining -= $got;
        }
        $ae->decrypt_done($tag);
        close $fhv;
        1;
    };
    unless ($verify_ok) {
        return $self->render(json => { error => 'decrypt failed', detail => "$@" }, status => 500);
    }

    CORE::open(my $fh2, '<:raw', $stored_path->to_string) or
        return $self->render(json => { error => 'open failed' }, status => 500);
    seek($fh2, $ct_off, 0) or do {
        close $fh2;
        return $self->render(json => { error => 'seek failed' }, status => 500);
    };

    $self->res->headers->content_type($paste->{mime_type} // 'application/octet-stream');
    my $safe = ($paste->{file_name} // 'file') =~ s/"/\\"/gr;
    $self->res->headers->content_disposition('attachment; filename="' . $safe . '"');
    $self->res->headers->content_length($ct_len);
    $self->res->code(200);

    my $ae = Crypt::AuthEnc::GCM->new('AES', $raw_key, $iv);
    $self->res->body('');
    my $remaining = $ct_len;
    my $buf;
    while ($remaining > 0) {
        my $want = $remaining > 65536 ? 65536 : $remaining;
        my $got  = read($fh2, $buf, $want);
        last unless $got;
        my $pt = $ae->decrypt_add($buf);
        $self->write($pt);
        $remaining -= $got;
    }
    close $fh2;
    $self->finish;
}

sub done ($self) {
    my $user = $self->current_user;
    my $hash = $self->param('hash');
    my $paste = $self->pastes->find_by_hash($hash);
    return $self->render(json => { error => 'not found' }, status => 404)
        unless $paste;

    return $self->render(json => { error => 'forbidden' }, status => 403)
        unless $paste->{opened_by} && $paste->{opened_by} == $user->{id};

    return $self->render(json => { ok => 1, already_deleted => 1 })
        if $paste->{deleted_at};

    if ($paste->{kind} eq 'file' && $paste->{file_path}) {
        my $stored = $self->_storage_dir->child($paste->{file_path});
        _secure_wipe($stored->to_string);
    }

    $self->pastes->mark_deleted($paste->{id});

    Cipherbox::Controller::Chat::notify_room_members(
        $self, $paste->{room_id}, {
            type       => 'paste.deleted',
            room_id    => $paste->{room_id},
            paste_hash => $paste->{public_hash},
        },
    );

    $self->render(json => { ok => 1 });
}

1;
