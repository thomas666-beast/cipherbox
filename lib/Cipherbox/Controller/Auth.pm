package Cipherbox::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Crypt::JWT qw(encode_jwt decode_jwt);

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
        return $self->render(
            json   => { error => 'too many registrations, try again later' },
            status => 429,
        );
    }

    my $body     = $self->req->json;
    my $username = $body->{username} // '';
    my $password = $body->{password} // '';

    return $self->render(json => { error => 'missing fields' }, status => 400)
        unless length $username and length $password;

    my $exists = eval { $self->users->find_by_username($username) };
    return $self->render(json => { error => 'username taken' }, status => 409)
        if $exists;

    my $user = eval { $self->users->create($username, $password) };
    if ($@) {
        return $self->render(json => { error => "$@" }, status => 500);
    }

    $self->auth_attempts->record_registration($ip);

    $self->render(json => { id => $user->{id}, username => $user->{username} });
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

1;
