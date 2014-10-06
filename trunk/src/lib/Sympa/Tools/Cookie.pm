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

=encoding utf-8

=head1 NAME

Sympa::Tools::Cookie - Cookie-related functions

=head1 DESCRIPTION

This package provides some cookie-related functions.

=cut

package Sympa::Tools::Cookie;

use strict;

use Digest::MD5;
use CGI::Cookie;

use Sympa::Logger;

=head1 FUNCTIONS

=over

=item get_mac($email, $secret)

Returns Message Authentication Check code.

Parameters:

=over

=item * I<$timestamp>: FIXME

=item * I<$secret>: FIXME

=back

=cut

sub get_mac {
    my $email  = shift;
    my $secret = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG3, "get_mac($email, $secret)");

    unless ($secret) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'get_mac : failure missing server secret for cookie MD5 digest');
        return undef;
    }
    unless ($email) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'get_mac : failure missing email adresse or cookie MD5 digest');
        return undef;
    }

    return substr(Digest::MD5::md5_hex($email . $secret), -8);
}

=item set_cookie_extern($secret, $http_domain, %alt_emails)

FIXME.

Parameters:

=over

=item * I<$secret>: FIXME

=item * I<$http_domain>: FIXME

=item * I<$alt_emails>: FIXME

=back

=cut

sub set_cookie_extern {
    my ($secret, $http_domain, %alt_emails) = @_;
    my $cookie;
    my $value;

    my @mails;
    foreach my $mail (keys %alt_emails) {
        my $string = $mail . ':' . $alt_emails{$mail};
        push(@mails, $string);
    }
    my $emails = join(',', @mails);

    $value = sprintf '%s&%s', $emails, get_mac($emails, $secret);

    if ($http_domain eq 'localhost') {
        $http_domain = "";
    }

    $cookie = CGI::Cookie->new(
        -name    => 'sympa_altemails',
        -value   => $value,
        -expires => '+1y',
        -domain  => $http_domain,
        -path    => '/'
    );
    ## Send cookie to the client
    printf "Set-Cookie: %s\n", $cookie->as_string;

    #$main::logger->do_log(Sympa::Logger::NOTICE,"set_cookie_extern : %s",$cookie->as_string);
    return 1;
}

=item generic_get_cookie($http_cookie, $cookie_name)

Generic subroutine to get a cookie value.

Parameters:

=over

=item * I<$http_cookie>: FIXME

=item * I<$cookie_name>: FIXME

=back

=cut

sub generic_get_cookie {
    my $http_cookie = shift;
    my $cookie_name = shift;

    if ($http_cookie =~ /\S+/g) {
        my %cookies = parse CGI::Cookie($http_cookie);
        foreach (keys %cookies) {
            my $cookie = $cookies{$_};
            next unless ($cookie->name eq $cookie_name);
            return ($cookie->value);
        }
    }
    return (undef);
}

=item check_cookie_extern($http_cookie, $secret, $user_email)

FIXME

Parameters:

=over

=item * I<$http_cookie>: FIXME

=item * I<$secret>: FIXME

=item * I<$user_email>: FIXME

=back

=cut

sub check_cookie_extern {
    my ($http_cookie, $secret, $user_email) = @_;

    my $extern_value = generic_get_cookie($http_cookie, 'sympa_altemails');

    if ($extern_value =~ /^(\S+)&(\w+)$/) {
        return undef unless (get_mac($1, $secret) eq $2);

        my %alt_emails;
        foreach my $element (split(/,/, $1)) {
            my @array = split(/:/, $element);
            $alt_emails{$array[0]} = $array[1];
        }

        my $e = lc($user_email);
        unless ($alt_emails{$e}) {
            return undef;
        }
        return (\%alt_emails);
    }
    return undef;
}

=back

=cut

1;
