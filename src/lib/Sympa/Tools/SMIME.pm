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

Sympa::Tools::SMIME - S/MIME-related functions

=head1 DESCRIPTION

This package provides S/MIME-related functions.

=cut

package Sympa::Tools::SMIME;

use strict;
use warnings;

use English qw(-no_match_vars);

use Sympa::Logger;

=head1 FUNCTIONS

=over

=item find_keys($directory, $operation)

Find the appropriate S/MIME key and certificate files for given operation in
given directory.

=over

=item * I<$directory>: FIXME

=item * I<$operation>: one of the following values:

=over

=item - sign: return the preferred signing key/cert

=item - decrypt: return a list of possible decryption keys/certs

=item - encrypt: return the preferred encryption key/cert

=back

=back

Returns a pair of two strings, corresponding to the absolute file names of
certificate and key.

=cut

sub find_keys {
    my ($dir, $oper) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG,
        'Sympa::Tools::find_keys(%s, %s)',
        $dir, $oper);

    my (%certs, %keys);
    my $ext = ($oper eq 'sign' ? 'sign' : 'enc');

    unless (opendir(D, $dir)) {
        $main::logger->do_log(Sympa::Logger::ERR, "unable to opendir $dir: $ERRNO");
        return undef;
    }

    while (my $fn = readdir(D)) {
        if ($fn =~ /^cert\.pem/) {
            $certs{"$dir/$fn"} = 1;
        } elsif ($fn =~ /^private_key/) {
            $keys{"$dir/$fn"} = 1;
        }
    }
    closedir(D);

    foreach my $c (keys %certs) {
        my $k = $c;
        $k =~ s/\/cert\.pem/\/private_key/;
        unless ($keys{$k}) {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                "$c exists, but matching $k doesn't");
            delete $certs{$c};
        }
    }

    foreach my $k (keys %keys) {
        my $c = $k;
        $c =~ s/\/private_key/\/cert\.pem/;
        unless ($certs{$c}) {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                "$k exists, but matching $c doesn't");
            delete $keys{$k};
        }
    }

    my ($certs, $keys);
    if ($oper eq 'decrypt') {
        $certs = [sort keys %certs];
        $keys  = [sort keys %keys];
    } else {
        if ($certs{"$dir/cert.pem.$ext"}) {
            $certs = "$dir/cert.pem.$ext";
            $keys  = "$dir/private_key.$ext";
        } elsif ($certs{"$dir/cert.pem"}) {
            $certs = "$dir/cert.pem";
            $keys  = "$dir/private_key";
        } else {
            $main::logger->do_log(Sympa::Logger::INFO,
                "$dir: no certs/keys found for $oper");
            return undef;
        }
    }

    return ($certs, $keys);
}

=item parse_cert(%parameters)

FIXME.

=over

=item * I<file>: the certificat, as a file

=item * I<string>: the certificat, as a string

=item * I<openssl>: path to openssl binary (default: 'openssl')

=item * I<tmpdir>: path to temporary file directory (default: '/tmp')

=back

Returns an hashref with the following keys:

=over

=item * I<email>: email address from cert

=item * I<subject>: distinguished name

=item * I<purpose>: hashref with following keys:

=over

=item - enc: true if v3 purpose is encryption

=item - sign: true if v3 purpose is signing

=back

=back

=cut

sub parse_cert {
    my (%params) = @_;

    my $file   = $params{file};
    my $string = $params{string};
    my $tmpdir  = $params{tmpdir} || '/tmp';
    my $openssl = $params{openssl} || 'openssl';

    $main::logger->do_log(
        Sympa::Logger::DEBUG,
        'Sympa::Tools::parse_cert(%s)',
        join('/', %params)
    );

    ## Load certificate
    my $cert_string;
    if ($string) {
        $cert_string = $string;
    } elsif ($file) {
        eval {
            $cert_string = Sympa::Tools::File::slurp_file($file);
        };
        if ($EVAL_ERROR) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                "unable to read certificate file: %s", $EVAL_ERROR
            );
            return undef;
        }
    } else {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'neither "string" nor "file" given'
        );
        return undef;
    }

    ## Extract information from cert
    my ($tmpfile) = $tmpdir . "/parse_cert.$PID";
    my $cmd = sprintf '%s x509 -email -subject -purpose -noout', $openssl;
    unless (open(PSC, "| $cmd > $tmpfile")) {
        $main::logger->do_log(Sympa::Logger::ERR, 'open |openssl: %s', $ERRNO);
        return undef;
    }
    print PSC $cert_string;

    unless (close(PSC)) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "parse_cert: close openssl: $ERRNO, $EVAL_ERROR");
        return undef;
    }

    unless (open(PSC, "$tmpfile")) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "parse_cert: open $tmpfile: $ERRNO");
        return undef;
    }

    my (%res, $purpose_section);

    while (<PSC>) {
        ## First lines before subject are the email address(es)

        if (/^subject=\s+(\S.+)\s*$/) {
            $res{'subject'} = $1;

        } elsif (!$res{'subject'} && /\@/) {
            my $email_address = lc($_);
            chomp $email_address;
            $res{'email'}{$email_address} = 1;

            ## Purpose section appears at the end of the output
            ## because options order matters for openssl
        } elsif (/^Certificate purposes:/) {
            $purpose_section = 1;
        } elsif ($purpose_section) {
            if (/^S\/MIME signing : (\S+)/) {
                $res{purpose}->{sign} = ($1 eq 'Yes');

            } elsif (/^S\/MIME encryption : (\S+)/) {
                $res{purpose}->{enc} = ($1 eq 'Yes');
            }
        }
    }

    ## OK, so there's CAs which put the email in the subjectAlternateName only
    ## and ones that put it in the DN only...
    if (!$res{email} && ($res{subject} =~ /\/email(address)?=([^\/]+)/)) {
        $res{email} = $1;
    }
    close(PSC);
    unlink($tmpfile);
    return \%res;
}

=item extract_certs(%parameters)

FIXME.

=over

=item * I<entity>: FIXME

=item * I<file>: FIXME

=item * I<openssl>: path to openssl binary (default: 'openssl')

=back

=cut

sub extract_certs {
    my (%params) = @_;

    my $mime    = $params{entity};
    my $outfile = $params{file};
    my $openssl = $params{openssl} || 'openssl';

    $main::logger->do_log(Sympa::Logger::DEBUG2,
        "Sympa::Tools::extract_certs(%s)",
        $mime->mime_type);

    if ($mime->mime_type =~ /application\/(x-)?pkcs7-/) {
        my $cmd = sprintf '%s pkcs7 -print_certs -inform der', $openssl;
        unless (open(MSGDUMP, "| $cmd > $outfile")) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'unable to run openssl pkcs7: %s', $ERRNO);
            return 0;
        }
        print MSGDUMP $mime->bodyhandle->as_string();
        close(MSGDUMP);
        if ($CHILD_ERROR) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                "openssl pkcs7 returned an error: ",
                $CHILD_ERROR / 256
            );
            return 0;
        }
        return 1;
    }
}

=back

=cut

1;
