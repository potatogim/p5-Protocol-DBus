package Protocol::DBus::Authn;

use strict;
use warnings;

use Module::Load ();

use IO::Framed ();

use Protocol::DBus::Authn::IO ();

use constant _CRLF => "\x0d\x0a";

sub new {
    my ($class, %opts) = @_;

    my @missing = grep { !$opts{$_} } qw( socket  mechanism );
    die "Need: @missing" if @missing;

    my $module = __PACKAGE__ . "::Mechanism::$opts{'mechanism'}";
    Module::Load::load($module);

    @opts{map { "_$_" } keys %opts} = delete @opts{ keys %opts };

    $opts{'_io'} = IO::Framed->new( $opts{'_socket'} )->enable_write_queue();

    $opts{'_mechanism_module'} = $module;

    return bless \%opts, $class;
}

sub negotiate_unix_fd {
    my ($self) = @_;

    $self->{'_negotiate_unix_fd'} = 1;

    return $self;
}

sub _create_xaction {
    my ($self) = @_;

    # 0 = send; 1 = receive
    my @xaction = (
        [ 0 => 'AUTH', $self->{'_mechanism'}, $opts{'_mechanism_module'}->INITIAL_RESPONSE() ],
        $opts{'_mechanism_module'}->AFTER_AUTH(),

        [ 1 => 'OK', \&_consume_ok ],
    );

    if ( $self->{'_negotiate_unix_fd'} ) {
        push @xaction, (
            [ 0 => 'NEGOTIATE_UNIX_FD' ],
            [ 1 => \&_consume_agree_unix_fd ],
        );
    }

    push @xaction, [ 0 => 'BEGIN' ];

    return \@xaction;
}

sub _consume_ok {
    my ($self, $line) = @_;

    if (index($line, 'OK ') == 0) {
        $self->{'_server_guid'} = substr($line, 3);
    }
    else {
        die "Unrecognized response: $line";
    }

    return;
}

sub _consume_agree_unix_fd {
    my ($self, $line) = @_;

    if ($line eq 'AGREE_UNIX_FD') {
        $self->{'_can_pass_unix_fd'} = 1;
    }
    elsif (index($line, 'ERROR ') == 0) {
        warn "Server rejected unix fd passing: " . substr($line, 6) . $/;
    }

    return;
}

sub go {
    my ($self) = @_;

    my $s = $self->{'_socket'};

    $self->{'_xaction'} ||= $self->_create_xaction();

    $self->{'_sent_initial'} ||= do {
        $opts{'_mechanism_module'}->send_initial($s);
    }

    if ($self->{'_sent_initial'}) {
      LINES:
        {
            if ( $self->{'_io'}->get_write_queue_count() ) {
                $self->{'_io'}->flush_write_queue() or last LINES;
            }

            while ( my $cur = $self->{'_xaction'}[0] ) {
                if ($cur->[0]) {
                    my $line = $self->_read_line() or last LINES;
                    $cur->[1]->($self, $line);
                }
                else {
                    $self->_send_line(join(' ', @{$cur}[ 1 .. $#$cur ])) or last LINES;
                }

                shift @{ $self->{'_xaction'} };
            }

            return 1;
        }
    }

    return undef;
}

sub cancel {
    my ($self) = @_;

    die 'unimplemented';
}

sub _send_line {
    my ($self) = @_;

    my $ok = $self->{'_io'}->enqueue_write( $_[1] . _CRLF() );
    return $self->{'_io'}->flush_write_queue();
}

sub _read_line {
    my $line;

    if ($line = $_[0]->{'_io'}->read_until("\x0d\x0a")) {
        chop $line;
        chop $line;
    }

    return $line;
}

#----------------------------------------------------------------------

package Protocol::DBus::Authn::Mechanism;

use constant INITIAL_RESPONSE => ();
use constant AFTER_AUTH => ();

#----------------------------------------------------------------------

package Protocol::DBus::Authn::Mechanism::EXTERNAL;

use parent -norequire => 'Protocol::DBus::Authn::Mechanism';

use Socket ();
use Socket::MsgHdr ();

sub send_initial {
    my ($class, $s) = @_;

    my $msg = Socket::MsgHdr->new( buf => "\0" );

    my $ok;

    if (Socket->can('SCM_CREDENTIALS')) {
        my $ucred = pack( 'I*', $$, $>, (split m< >, $))[0]);

        $msg->cmsghdr( Socket::SOL_SOCKET(), Socket::SCM_CREDENTIALS(), $ucred );

        $ok = Socket::MsgHdr::sendmsg($s, $msg, Socket::MSG_NOSIGNAL() );

        if (!$ok && $!{'EAGAIN'}) {
            die "sendmsg($s): $!";
        }
    }
    else {
        die "Unsupported OS: $^O";
    }

    return $ok;
}

1;
