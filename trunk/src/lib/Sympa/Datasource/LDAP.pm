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

use Carp;
use Net::LDAP;

use Sympa::Logger;

=head1 CLASS METHODS

=over

=item Sympa::Datasource::LDAP->new(%parameters)

Creates a new L<Sympa::Datasource::LDAP> object.

Parameters:

=over 4

=item * I<timeout>: connection timeout

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
        async              => 1,
        timeout            => $params{timeout} || 3,
        ldap_bind_dn       => $params{'user'},
        ldap_bind_password => $params{'passwd'},
        ldap_host          => $params{'host'},
        ldap_use_ssl       => $params{'use_ssl'},
        ldap_start_tls     => $params{'use_start_tls'},
        ldap_ssl_version   => $params{'ssl_version'},
        ldap_ssl_ciphers   => $params{'ssl_ciphers'},
        ssl_cert           => $params{'ssl_cert'},
        ssl_key            => $params{'ssl_key'},
        ca_verify          => $params{'ca_verify'} || "optional",
        ca_path            => $params{'ca_path'},
        ca_file            => $params{'ca_file'},
    };
    bless $self, $class;

    return $self;
}

############################################################
#  connect
############################################################
#  Connect to an LDAP directory. This could be called as
#  a LDAPSource object member, or as a static sub.
#
# IN : -$options : ref to a hash. Options for the connection process.
#         currently accepts 'keep_trying' : wait and retry until
#         db connection is ok (boolean) ; 'warn' : warn
#         listmaster if connection fails (boolean)
# OUT : $self->{'ldap_handler'}
#     | undef
#
##############################################################
sub connect {
    my $self    = shift;
    my $options = shift;

    my $host_entry;
    ## There might be multiple alternate hosts defined
    foreach $host_entry (split(/,/, $self->{'ldap_host'})) {

        ## Remove leading and trailing spaces
        $host_entry =~ s/^\s*(\S.*\S)\s*$/$1/;
        my ($host, $port) = split(/:/, $host_entry);
        ## If port a 'port' entry was defined, use it as default
        $self->{'port'} ||= $port if (defined $port);

        ## value may be '1' or 'yes' depending on the context
        if (   $self->{'ldap_use_ssl'} eq 'yes'
            || $self->{'ldap_use_ssl'} eq '1') {
            $self->{'sslversion'} = $self->{'ldap_ssl_version'}
                if ($self->{'ldap_ssl_version'});
            $self->{'ciphers'} = $self->{'ldap_ssl_ciphers'}
                if ($self->{'ldap_ssl_ciphers'});

            unless (eval "require Net::LDAPS") {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Unable to use LDAPS library, Net::LDAPS required");
                return undef;
            }
            require Net::LDAPS;

            $self->{'ldap_handler'} =
                Net::LDAPS->new($host, port => $port, %{$self});
        } else {
            $self->{'ldap_handler'} = Net::LDAP->new($host, %{$self});
        }

        next unless (defined $self->{'ldap_handler'});

        ## if $self->{'ldap_handler'} is defined, skip alternate hosts
        last;
    }

    unless (defined $self->{'ldap_handler'}) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unable to connect to the LDAP server '%s'",
            $self->{'ldap_host'});
        return undef;
    }

    if ($self->{'use_start_tls'}) {
        $self->{'ldap_handler'}->start_tls(
            verify     => $self->{'ca_verify'},
            capath     => $self->{'ca_path'},
            cafile     => $self->{'ca_file'},
            sslversion => $self->{'ssl_version'},
            ciphers    => $self->{'ssl_ciphers'},
            clientcert => $self->{'ssl_cert'},
            clientkey  => $self->{'ssl_key'},
        );
    }

    my $cnx;
    ## Not always anonymous...
    if (   defined($self->{'ldap_bind_dn'})
        && defined($self->{'ldap_bind_password'})) {
        $cnx = $self->{'ldap_handler'}->bind($self->{'ldap_bind_dn'},
            password => $self->{'ldap_bind_password'});
    } else {
        $cnx = $self->{'ldap_handler'}->bind;
    }

    unless (defined($cnx) && ($cnx->code() == 0)) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            "Failed to bind to LDAP server : '%s', LDAP server error : '%s'",
            $host_entry,
            $cnx->error,
            $cnx->server_error
        );
        $self->{'ldap_handler'}->unbind;
        return undef;
    }
    $main::logger->do_log(Sympa::Logger::DEBUG, "Bound to LDAP host '$host_entry'");

    return $self->{'ldap_handler'};

}

sub disconnect {
    my $self = shift;
    $self->{'ldap_handler'}->unbind if $self->{'ldap_handler'};
}

1;
