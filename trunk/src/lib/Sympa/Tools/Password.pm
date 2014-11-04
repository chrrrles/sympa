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

Sympa::Tools::Password - Password-related functions

=head1 DESCRIPTION

This package provides some password-related functions.

=cut

package Sympa::Tools::Password;

use strict;
use warnings;

use Digest::MD5;
use English qw(-no_match_vars);

use Sympa::Logger;

## global var to store a CipherSaber object
my $cipher;

=head1 FUNCTIONS

=over

=item ciphersaber_installed()

Create a cipher.

=cut

sub ciphersaber_installed {
    return $cipher if defined $cipher;

    eval { require Crypt::CipherSaber; };
    unless ($EVAL_ERROR) {
        $cipher = Crypt::CipherSaber->new(Sympa::Site->cookie);
    } else {
        $cipher = '';
    }
    return $cipher;
}

=item decrypt_password($inpasswd)

Decrypt a password.

=cut

sub decrypt_password {
    my $inpasswd = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Sympa::Tools::Password::decrypt_password (%s)', $inpasswd);

    return $inpasswd unless ($inpasswd =~ /^crypt\.(.*)$/);
    $inpasswd = $1;

    ciphersaber_installed();
    unless ($cipher) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'password seems encrypted while CipherSaber is not installed !');
        return $inpasswd;
    }
    return ($cipher->decrypt(MIME::Base64::decode($inpasswd)));
}

=back

=cut

1;
