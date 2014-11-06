# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997-1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997-2011 Comite Reseau des Universites
# Copyright (c) 2011-2014 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::Datasource::LDAP;

use strict;
use base qw(Sympa::Datasource);

use Carp qw(croak);
use Net::LDAP;

use Sympa::Logger;

=head1 CLASS METHODS

=over

=item Sympa::Datasource::LDAP->new(%parameters)

Creates a new L<Sympa::Datasource::LDAP> object.

Parameters:

=over 4

=item * I<timeout>: connection timeout (default: 3)

=item * I<user>: connection user

=item * I<passwd>: connection password

=item * I<host>: ldap server hostname

=item * I<use_ssl>: wether to use SSL/TLS on dedicated port

=item * I<use_start_tls>: wether to use SSL/TLS on standard port, through start_tls command

=item * I<ssl_version>: SSL/TLS version to use

=item * I<ssl_ciphers>: SSL/TLS ciphers to use

=item * I<ssl_cert>: client certificate, for authentication

=item * I<ssl_key>: client key, for authentication

=item * I<ca_verify>: server certificate checking policy (default: optional)

=item * I<ca_path>: CA indexed certificates directory

=item * I<ca_file>: CA bundled certificates file

=back

Returns a new L<Sympa::Datasource::LDAP> object, or I<undef> for failure.

=cut

sub new {
    my ($class, %params) = @_;
    
    unless ($params{'host'}) {
        $main::logger->do_log(Sympa::Logger::ERR, "missing 'host' parameter");
        return undef;
    }

    my $self = {
        timeout       => $params{timeout} || 3,
        bind_dn       => $params{'user'},
        bind_password => $params{'passwd'},
        host          => $params{'host'},
        use_ssl       => $params{'use_ssl'},
        start_tls     => $params{'use_start_tls'},
        ssl_version   => $params{'ssl_version'},
        ssl_ciphers   => $params{'ssl_ciphers'},
        ssl_cert      => $params{'ssl_cert'},
        ssl_key       => $params{'ssl_key'},
        ca_verify     => $params{'ca_verify'} || "optional",
        ca_path       => $params{'ca_path'},
        ca_file       => $params{'ca_file'},
    };
    bless $self, $class;

    return $self;
}

=back

=head1 INSTANCE METHODS

=over

=item $datasource->connect()

Connect to an LDAP directory.

Returns a L<Net::LDAP> instance on success, I<undef> otherwise.

=cut

sub connect {
    my ($self) = @_;

    ## There might be multiple alternate hosts defined
    my $host;
    foreach $host (split(/,/, $self->{'host'})) {

        ## Remove leading and trailing spaces
        $host =~ s/^\s*//;
        $host =~ s/\s*$//;

        $self->{'handler'} = Net::LDAP->new(
            $host,
            port       => $self->{'port'},
            timeout    => $self->{'timeout'},
            scheme     => $self->{'use_ssl'} ? 'ldaps' : 'ldap',
            sslversion => $self->{'ssl_version'},
            ciphers    => $self->{'ssl_ciphers'},
        );

        # skip alternate hosts as soon as connection succeed
        last if $self->{'handler'};
    }

    unless ($self->{'handler'}) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unable to connect to any LDAP server '%s'",
            $self->{'host'});
        return undef;
    }

    if ($self->{'use_start_tls'}) {
        $self->{'handler'}->start_tls(
            verify     => $self->{'ca_verify'},
            capath     => $self->{'ca_path'},
            cafile     => $self->{'ca_file'},
            sslversion => $self->{'ssl_version'},
            ciphers    => $self->{'ssl_ciphers'},
            clientcert => $self->{'ssl_cert'},
            clientkey  => $self->{'ssl_key'},
        );
    }

    if ($self->{'bind_dn'} && $self->{'bind_password'}) {
        my $result = $self->{'handler'}->bind(
            $self->{'bind_dn'},
            password => $self->{'bind_password'}
        );
        if ($result->code != 0) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                "Failed to bind to LDAP server : '%s', LDAP server error : '%s'",
                $host,
                $result->error,
            );
            return undef;
        }
    }

    $main::logger->do_log(Sympa::Logger::DEBUG, "Bound to LDAP host '$host'");

    return $self->{'handler'};
}

=item $datasource->disconnect()

Disconnect from the LDAP directory.

=cut

sub disconnect {
    my $self = shift;
    $self->{'handler'}->unbind if $self->{'handler'};
}

=back

=cut

1;
