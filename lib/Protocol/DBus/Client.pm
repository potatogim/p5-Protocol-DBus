package Protocol::DBus::Client;

use strict;
use warnings;

use parent 'Protocol::DBus::Peer';

use Protocol::DBus::Authn;
use Protocol::DBus::Connect;
use Protocol::DBus::Path;

sub system {
    my $addr = Protocol::DBus::Path::system_message_bus();
    my $socket = Protocol::DBus::Connect::create_socket($addr);

    return __PACKAGE__->new(
        socket => $socket,
        authn_mechanism => 'EXTERNAL',
    );
}

#----------------------------------------------------------------------

sub new {
    my ($class, %opts) = @_;

    my $authn = Protocol::DBus::Authn->new(
        socket => $opts{'socket'},
        mechanism => $opts{'authn_mechanism'},
    );

    my $self = bless { _socket => $opts{'socket'}, _authn => $authn }, $class;

    $self->_set_up_peer_io( $opts{'socket'} );

    return $self;
}

sub authn_pending_send {
    my ($self) = @_;

    return $self->{'_authn'}->pending_send();
}

sub receive {
    if ( my $msg = $_[0]->SUPER::get_message() ) {

        no warnings 'redefine';
        *receive = Protocol::DBus::Peer->can('receive');

        return $_[0]->receive();
    }

    return undef;
}

sub do_authn {
    my ($self) = @_;

    if ($self->{'_authn'}->go()) {
        $self->{'_sent_hello'} ||= do {
            $self->send_call(
                path => '/org/freedesktop/DBus',
                interface => 'org.freedesktop.DBus',
                destination => 'org.freedesktop.DBus',
                member => 'Hello',
                on_return => sub {
                    $self->{'_connection_name'} = $_[0]->get_body()->[0];
                },
            );
        };

        return 1;
    }

    return 0;
}

1;
