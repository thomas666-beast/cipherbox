package Cipherbox;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::Pg;
use Mojo::Pg::PubSub;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;
use Mojo::File 'path';
use Crypt::JWT qw(decode_jwt);
use Cipherbox::Crypto;
use Cipherbox::Model::User;
use Cipherbox::Model::Room;
use Cipherbox::Model::Library;
use Cipherbox::Model::AuthAttempts;
use Cipherbox::Model::Paste;
use Cipherbox::Model::Report;
use Cipherbox::Model::MessageEdit;
use Cipherbox::Model::Settings;
use Cipherbox::Model::AuditLog;

my $COOKIE_NAME = 'cipherbox_token';

sub startup ($self) {
    my $config = $self->plugin('Config');

    my $env     = $ENV{CIPHERBOX_ENV} // 'development';
    my $section = $env eq 'test' ? $config->{test} : $config;

    my $jwt_secret = $section->{secrets}[0]
        // die "secrets missing from config\n";
    my $master_key = $section->{master_key}
        // die "master_key missing from config\n";
    my $dsn = $section->{pg}{dsn}
        // die "pg.dsn missing from config\n";

    my $pagination = $section->{pagination}
        // { default_limit => 100, max_limit => 200 };

    my $auth_limits = $section->{auth_limits}
        // { login_failures_per_15min => 5, registrations_per_hour => 3 };

    $self->secrets([$jwt_secret]);

    $self->helper(jwt_secret  => sub { $jwt_secret });
    $self->helper(pagination  => sub { $pagination });
    $self->helper(auth_limits => sub { $auth_limits });

    my $pg = Mojo::Pg->new($dsn);
    $self->helper(pg => sub { $pg });

    # --- PUBSUB SETUP ---
    my $pubsub = Mojo::Pg::PubSub->new(pg => $pg);
    $self->helper(pubsub => sub { $pubsub });

    # Listen for room-level notifications (invites, removes, renames, paste events)
    $pubsub->listen(cipherbox_chat => sub ($pubsub, $payload) {
        my $data = eval { decode_json($payload) };
        return unless $data;
        if ($data->{except}) {
            Cipherbox::Controller::Chat::_broadcast_room_except_local(
                $data->{room_id},
                $data->{except},
                $data->{msg}
            );
        } else {
            Cipherbox::Controller::Chat::_broadcast_local(
                $data->{room_id},
                $data->{msg}
            );
        }
    });

    $pubsub->listen(cipherbox_room => sub ($pubsub, $payload) {
        my $data = eval { decode_json($payload) };
        return unless $data;
        if ($data->{target_user_id}) {
            Cipherbox::Controller::Chat::_notify_user_local(
                $data->{target_user_id},
                $data->{msg}
            );
        } else {
            Cipherbox::Controller::Chat::_notify_room_members_local(
                $data->{room_id},
                $data->{msg}
            );
        }
    });
    # --------------------

    $self->helper(crypto => sub ($c) {
        Cipherbox::Crypto->new(master_key => $master_key);
    });

    $self->helper(users => sub ($c) {
        Cipherbox::Model::User->new(pg => $c->pg);
    });

    $self->helper(rooms => sub ($c) {
        Cipherbox::Model::Room->new(pg => $c->pg);
    });

    $self->helper(library => sub ($c) {
        Cipherbox::Model::Library->new(pg => $c->pg);
    });

    $self->helper(pastes => sub ($c) {
        Cipherbox::Model::Paste->new(pg => $c->pg);
    });

    $self->helper(reports => sub ($c) {
        Cipherbox::Model::Report->new(pg => $c->pg);
    });

    $self->helper(message_edits => sub ($c) {
        Cipherbox::Model::MessageEdit->new(pg => $c->pg);
    });

    $self->helper(auth_attempts => sub ($c) {
        Cipherbox::Model::AuthAttempts->new(pg => $c->pg);
    });

    $self->helper(settings => sub ($c) {
        Cipherbox::Model::Settings->new(pg => $c->pg);
    });

    $self->helper(audit_logs => sub ($c) {
        Cipherbox::Model::AuditLog->new(pg => $c->pg);
    });

    $self->helper(client_ip => sub ($c) {
        return $c->req->headers->header('X-Forwarded-For')
            // $c->tx->remote_address
            // '0.0.0.0';
    });

    $self->helper(current_user => sub ($c) {
        return $c->stash('current_user') if $c->stash('current_user');

        my $token;
        my $auth = $c->req->headers->authorization // '';
        ($token) = $auth =~ /^Bearer\s+(.+)$/;
        $token //= $c->cookie($COOKIE_NAME);
        return undef unless $token;

        my $payload = eval {
            decode_jwt(token => $token, key => $jwt_secret);
        };
        return undef unless $payload;

        my $user = $c->users->find_by_id($payload->{uid});
        $c->stash(current_user => $user) if $user;
        return $user;
    });

    $self->helper(require_admin => sub ($c) {
        my $user = $c->current_user;
        return $user && ($user->{role} // '') eq 'admin';
    });

    my $r = $self->routes;

    $r->get('/health')->to('health#check');
    $r->post('/api/auth/register')->to('auth#register');
    $r->post('/api/auth/login')->to('auth#login');
    $r->post('/api/auth/logout')->to('auth#logout');
    $r->websocket('/chat')->to('chat#websocket');

    my $api = $r->under('/api' => sub ($c) {
        return 1 if $c->current_user;
        $c->render(json => { error => 'unauthorized' }, status => 401);
        return 0;
    });

    $api->get('/me')->to('auth#me');
    $api->get('/ws-token')->to('auth#ws_token');

    $api->get('/rooms/discover')->to('room#discover');

    $api->get('/rooms')->to('room#list');
    $api->post('/rooms')->to('room#create');
    $api->get('/rooms/:id/messages')->to('room#messages');
    $api->post('/rooms/:id/invite')->to('room#invite');
    $api->post('/rooms/:id/remove')->to('room#remove');
    $api->post('/rooms/:id/leave')->to('room#leave');
    $api->delete('/rooms/:id')->to('room#delete');
    $api->get('/rooms/:id/members')->to('room#members');
    $api->get('/rooms/:id/key')->to('room#key');
    $api->delete('/rooms/:id/messages/:message_id')->to('room#delete_message');
    $api->patch('/rooms/:id/messages/:message_id')->to('room#edit_message');
    $api->patch('/rooms/:id')->to('room#rename');
    $api->post('/rooms/:id/read')->to('room#mark_read');
    $api->post('/rooms/:id/join')->to('room#join');
    $api->delete('/rooms/:id/ban/:user_id')->to('room#unban');
    $api->get('/rooms/:id/bans')->to('room#bans');
    $api->get('/rooms/:id')->to('room#find_by_id_public');

    $api->post('/messages/:message_id/report')->to('report#create');

    $api->post('/rooms/:room_id/pastes')->to('paste#create');
    $api->get('/pastes/:hash')->to('paste#info');
    $api->post('/pastes/:hash/open')->to('paste#open');
    $api->get('/pastes/:hash/download')->to('paste#download');
    $api->post('/pastes/:hash/done')->to('paste#done');

    $api->get('/users')->to('user#search');

    $api->get('/library/tree')->to('library#tree');
    $api->get('/library/categories')->to('library#list_categories');
    $api->get('/library/categories/:id')->to('library#get_category');
    $api->get('/library/categories/:id/items')->to('library#list_items');
    $api->get('/library/items/:id/download')->to('library#download_item');
    $api->post('/library/categories')->to('library#create_category');
    $api->delete('/library/categories/:id')->to('library#delete_category');
    $api->post('/library/items')->to('library#upload_item');
    $api->delete('/library/items/:id')->to('library#delete_item');
    $api->patch('/library/items/:id')->to('library#rename_item');

    my $admin = $r->under('/api/admin' => sub ($c) {
        return 1 if $c->require_admin;
        $c->render(json => { error => 'forbidden' }, status => 403);
        return 0;
    });

    $admin->get('/users')->to('admin#list_users');
    $admin->post('/users')->to('admin#create_user');
    $admin->delete('/users/:id')->to('admin#remove_user');
    $admin->patch('/users/:id')->to('admin#update_user');
    $admin->get('/settings')->to('admin#get_settings');
    $admin->patch('/settings')->to('admin#update_settings');
    $admin->get('/reports')->to('admin#list_reports');
    $admin->get('/reports/:id')->to('admin#get_report');
    $admin->post('/reports/:id/resolve')->to('admin#resolve_report');
    $admin->get('/rooms/:hash/view')->to('admin#view_room');

    if (($ENV{CIPHERBOX_ENV} // '') ne 'test') {
        Mojo::IOLoop->recurring(60 => sub {
            my $db = $pg->db;
            my $rows = $db->query(
                "SELECT id, public_hash, room_id, file_path
                 FROM pastes
                 WHERE opened_at IS NOT NULL
                   AND deleted_at IS NULL
                   AND opened_at < now() - interval '1 hour'"
            )->hashes;
            for my $row (@$rows) {
                if ($row->{file_path}) {
                    my $f = path($self->home, 'storage', 'pastes', $row->{file_path});
                    $f->remove if -e $f;
                }
                $db->query(
                    "UPDATE pastes SET
                        deleted_at = now(),
                        content_encrypted = NULL,
                        content_iv = NULL,
                        content_tag = NULL,
                        file_key_encrypted = NULL
                     WHERE id = ?",
                    $row->{id},
                );

                if ($row->{file_path}) {
                    my $f = path($self->home, 'storage', 'pastes', $row->{file_path});
                    Cipherbox::Controller::Paste::_secure_wipe($f->to_string);
                }

                eval {
                    Cipherbox::Controller::Chat::notify_room_members(
                        $self, $row->{room_id}, {
                            type       => 'paste.deleted',
                            room_id    => $row->{room_id},
                            paste_hash => $row->{public_hash},
                        },
                    );
                };
            }
        });
    }

    # --- SECURITY HEADERS (CSP + HSTS) ---
    $self->hook(before_dispatch => sub ($c) {
        # Strict CSP: Only allow scripts from same origin. No inline scripts.
        # Note: Vite in dev mode might need 'unsafe-inline' for styles, so we allow style-src 'unsafe-inline'.
        $c->res->headers->header(
            'Content-Security-Policy' =>
                "default-src 'self'; " .
                "script-src 'self'; " .
                "style-src 'self' 'unsafe-inline'; " .
                "img-src 'self' data: blob:; " .
                "connect-src 'self' ws: wss:; " .
                "font-src 'self'; " .
                "object-src 'none'; " .
                "base-uri 'self'; " .
                "form-action 'self';"
        );
        $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
        $c->res->headers->header('X-Frame-Options' => 'DENY');
        $c->res->headers->header('Referrer-Policy' => 'strict-origin-when-cross-origin');
        # $c->res->headers->header('Strict-Transport-Security' => 'max-age=31536000; includeSubDomains');
    });
}

1;
