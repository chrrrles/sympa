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

package Sympa::Tools::Password;

use strict;
use warnings;

use Digest::MD5;
use English qw(-no_match_vars);

use Sympa::Log::Syslog;

## global var to store a CipherSaber object
my $cipher;

sub tmp_passwd {
    my $email = shift;

    return (
        'init'
            . substr(
            Digest::MD5::md5_hex(join('/', Sympa::Site->cookie, $email)), -8
            )
    );
}

# create a cipher
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

## encrypt a password
sub crypt_password {
    my $inpasswd = shift;

    ciphersaber_installed();
    return $inpasswd unless $cipher;
    return ("crypt." . MIME::Base64::encode($cipher->encrypt($inpasswd)));
}

## decrypt a password
sub decrypt_password {
    my $inpasswd = shift;
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2,
        'Sympa::Tools::Password::decrypt_password (%s)', $inpasswd);

    return $inpasswd unless ($inpasswd =~ /^crypt\.(.*)$/);
    $inpasswd = $1;

    ciphersaber_installed();
    unless ($cipher) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
            'password seems encrypted while CipherSaber is not installed !');
        return $inpasswd;
    }
    return ($cipher->decrypt(MIME::Base64::decode($inpasswd)));
}

1;
