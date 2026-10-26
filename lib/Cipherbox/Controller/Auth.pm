package Cipherbox::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Crypt::JWT qw(encode_jwt decode_jwt);
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 ();

my $COOKIE_NAME    = 'cipherbox_token';
my $COOKIE_MAX_AGE = 60 * 60 * 24 * 7;

sub _set_token_cookie ($self, $token) {
    $self->cookie(
        $COOKIE_NAME => $token,
        {
            httponly => 1,
            secure   => $self->req->is_secure ? 1 : 0,
            samesite => 'Strict',
            path     => '/',
            max_age  => $COOKIE_MAX_AGE,
        },
    );
}

sub _clear_token_cookie ($self) {
    $self->cookie(
        $COOKIE_NAME => '',
        {
            httponly => 1,
            secure   => $self->req->is_secure ? 1 : 0,
            samesite => 'Strict',
            path     => '/',
            max_age  => 0,
        },
    );
}

sub register ($self) {
    my $enabled = $self->settings->bool('registration_enabled', 1);
    return $self->render(json => { error => 'registration is disabled' }, status => 403)
        unless $enabled;

    my $ip = $self->client_ip;
    $self->auth_attempts->_cleanup;

    my $reg_limit = $self->auth_limits->{registrations_per_hour} // 3;
    my $recent = $self->auth_attempts->recent_registrations($ip);
    if ($recent >= $reg_limit) {
        return $self->render(json => { error => 'too many registrations' }, status => 429);
    }

    my $body     = $self->req->json;
    my $username = $body->{username} // '';
    my $dsa_key  = $body->{dilithium_public_key};
    my $kem_key  = $body->{kyber_public_key};

    return $self->render(json => { error => 'missing fields' }, status => 400)
        unless length $username and $dsa_key and $kem_key;

    my $exists = eval { $self->users->find_by_username($username) };
    return $self->render(json => { error => 'username taken' }, status => 409)
        if $exists;

    my $user_count = $self->pg->db->query('SELECT count(*) FROM users')->array->[0];
    my $role = $user_count == 0 ? 'admin' : 'user';    

    my $user = eval { $self->users->create_pqc($username, $dsa_key, $kem_key, $role) };
    if ($@) {
        return $self->render(json => { error => "$@" }, status => 500);
    }

    $self->auth_attempts->record_registration($ip);

    my $token = eval {
        encode_jwt(
            payload => { uid => $user->{id}, username => $user->{username}, role => $user->{role} },
            alg     => 'HS256',
            key     => $self->jwt_secret,
        );
    };
    if ($@) {
        return $self->render(json => { error => "jwt: $@" }, status => 500);
    }

    $self->_set_token_cookie($token);

    $self->render(json => { 
        ok => 1, 
        id => $user->{id}, 
        username => $user->{username}, 
        role => $user->{role},
        token => $token 
    });
}

sub login ($self) {
    my $ip = $self->client_ip;

    $self->auth_attempts->_cleanup;

    my $body     = $self->req->json;
    my $username = $body->{username} // '';
    my $password = $body->{password} // '';

    my $fail_limit = $self->auth_limits->{login_failures_per_15min} // 5;

    if (length $username) {
        my $failures = $self->auth_attempts->recent_failures($ip, $username);
        if ($failures >= $fail_limit) {
            $self->res->headers->header('Retry-After' => '900');
            return $self->render(
                json   => { error => 'too many attempts, try again later' },
                status => 429,
            );
        }
    }

    my $user = $self->users->find_by_username($username);
    if (!$user or !$self->users->verify_password($user, $password)) {
        $self->auth_attempts->record_failure($ip, $username) if length $username;
        return $self->render(json => { error => 'invalid credentials' }, status => 401);
    }

    $self->auth_attempts->clear_failures($ip, $username);

    my $token = eval {
        encode_jwt(
            payload => {
                uid      => $user->{id},
                username => $user->{username},
                role     => $user->{role},
            },
            alg => 'HS256',
            key => $self->jwt_secret,
        );
    };
    if ($@) {
        return $self->render(json => { error => "jwt: $@" }, status => 500);
    }

    $self->_set_token_cookie($token);

    my $response = {
        ok       => 1,
        username => $user->{username},
        role     => $user->{role},
    };
    if (($ENV{CIPHERBOX_ENV} // '') eq 'test') {
        $response->{token} = $token;
    }

    $self->render(json => $response);
}

sub logout ($self) {
    $self->_clear_token_cookie;
    $self->render(json => { ok => 1 });
}

sub me ($self) {
    my $user = $self->current_user;
    return $self->render(json => { error => 'unauthorized' }, status => 401)
        unless $user;
    $self->render(json => {
        id       => $user->{id},
        username => $user->{username},
        role     => $user->{role},
    });
}

sub ws_token ($self) {
    my $user = $self->current_user;
    return $self->render(json => { error => 'unauthorized' }, status => 401)
        unless $user;

    my $now = time;
    my $token = eval {
        encode_jwt(
            payload => {
                uid      => $user->{id},
                username => $user->{username},
                role     => $user->{role},
                iat      => $now,
                exp      => $now + 60,
                ws       => 1,
            },
            alg => 'HS256',
            key => $self->jwt_secret,
        );
    };
    if ($@) {
        return $self->render(json => { error => "jwt: $@" }, status => 500);
    }

    $self->render(json => { token => $token });
}

sub save_pqc_keys ($self) {
    my $user = $self->current_user;
    return $self->render(json => { error => 'unauthorized' }, status => 401)
        unless $user;

    my $body = $self->req->json;
    my $dilithium_key = $body->{dilithium_public_key};
    my $kyber_key     = $body->{kyber_public_key};

    return $self->render(json => { error => 'missing keys' }, status => 400)
        unless $dilithium_key and $kyber_key;

    $self->pg->db->query(
        'UPDATE users SET dilithium_public_key = ?, kyber_public_key = ? WHERE id = ?',
        $dilithium_key, $kyber_key, $user->{id},
    );

    $self->render(json => { ok => 1 });
}

sub pqc_challenge ($self) {
    my $body = $self->req->json;
    my $username = $body->{username} // '';
    
    my $user = $self->users->find_by_username($username);
    return $self->render(json => { error => 'user not found' }, status => 404)
        unless $user and $user->{dilithium_public_key};

    # Generate 32 raw bytes and Base64-encode for transport
    my $raw_nonce = random_bytes(32);
    my $nonce_b64 = MIME::Base64::encode_base64($raw_nonce, '');
    
    # Save it to the DB
    $self->pg->db->query(
        'UPDATE users SET current_nonce = ? WHERE id = ?',
        $nonce_b64, $user->{id}
    );

    $self->render(json => { nonce => $nonce_b64 });
}

sub pqc_verify ($self) {
    my $body = $self->req->json;
    my $username = $body->{username} // '';
    my $signature_b64 = $body->{signature} // '';

    my $user = $self->users->find_by_username($username);
    return $self->render(json => { error => 'user not found' }, status => 404)
        unless $user and $user->{dilithium_public_key};

    my $nonce_b64 = $user->{current_nonce};
    return $self->render(json => { error => 'no challenge found' }, status => 400)
        unless $nonce_b64;

    # Path to the compiled Rust verifier binary
    my $verifier = $self->app->home->child('bin', 'cipherbox-pqc-verify')->to_string;
    
    # Escape arguments to prevent shell injection
    my @args = ($verifier, $user->{dilithium_public_key}, $nonce_b64, $signature_b64);
    my $cmd = join(' ', map { 
        my $s = $_; 
        $s =~ s/'/'\\''/g; 
        "'$s'" 
    } @args);

    # Call the binary, capture output and exit code
    my $result = qx{$cmd 2>/dev/null};
    my $exit_code = $? >> 8;
    chomp $result;

    if ($exit_code != 0 || $result ne 'true') {
        return $self->render(json => { error => 'invalid signature' }, status => 401);
    }

    # Clear the nonce so it can't be reused
    $self->pg->db->query('UPDATE users SET current_nonce = NULL WHERE id = ?', $user->{id});

    # Issue the JWT cookie
    my $token = eval {
        encode_jwt(
            payload => { uid => $user->{id}, username => $user->{username}, role => $user->{role} },
            alg     => 'HS256',
            key     => $self->jwt_secret,
        );
    };
    if ($@) {
        return $self->render(json => { error => "jwt: $@" }, status => 500);
    }

    $self->_set_token_cookie($token);

    $self->render(json => { ok => 1, username => $user->{username}, role => $user->{role} });
}

1;
