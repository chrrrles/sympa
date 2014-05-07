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

package Sympa::Tools::SMIME;

use strict;
use warnings;

use English qw(-no_match_vars);

use Sympa::Log::Syslog;

## find the appropriate S/MIME keys/certs for $oper in $dir.
## $oper can be:
## 'sign' -> return the preferred signing key/cert
## 'decrypt' -> return a list of possible decryption keys/certs
## 'encrypt' -> return the preferred encryption key/cert
## returns ($certs, $keys)
## for 'sign' and 'encrypt', these are strings containing the absolute file
## name
## for 'decrypt', these are arrayrefs containing absolute file names
sub find_keys {
    my ($dir, $oper) = @_;
    Sympa::Log::Syslog::do_log('debug',
        'Sympa::Tools::find_keys(%s, %s)',
        $dir, $oper);

    my (%certs, %keys);
    my $ext = ($oper eq 'sign' ? 'sign' : 'enc');

    unless (opendir(D, $dir)) {
        Sympa::Log::Syslog::do_log('err', "unable to opendir $dir: $ERRNO");
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
            Sympa::Log::Syslog::do_log('notice',
                "$c exists, but matching $k doesn't");
            delete $certs{$c};
        }
    }

    foreach my $k (keys %keys) {
        my $c = $k;
        $c =~ s/\/private_key/\/cert\.pem/;
        unless ($certs{$c}) {
            Sympa::Log::Syslog::do_log('notice',
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
            Sympa::Log::Syslog::do_log('info',
                "$dir: no certs/keys found for $oper");
            return undef;
        }
    }

    return ($certs, $keys);
}

# IN: hashref:
# file => filename
# text => PEM-encoded cert
# OUT: hashref
# email => email address from cert
# subject => distinguished name
# purpose => hashref
#  enc => true if v3 purpose is encryption
#  sign => true if v3 purpose is signing
sub parse_cert {
    my (%params) = @_;

    my $file   = $params{file};
    my $text   = $params{text};
    my $tmpdir  = $params{tmpdir};
    my $openssl = $params{openssl};

    Sympa::Log::Syslog::do_log(
        'debug',
        'Sympa::Tools::parse_cert(%s)',
        join('/', %params)
    );

    ## Load certificate
    my @cert;
    if ($text) {
        @cert = ($text);
    } elsif ($file) {
        unless (open(PSC, "$file")) {
            Sympa::Log::Syslog::do_log('err',
                "parse_cert: open %s: $ERRNO",
                $file);
            return undef;
        }
        @cert = <PSC>;
        close(PSC);
    } else {
        Sympa::Log::Syslog::do_log('err',
            'parse_cert: neither "text" nor "file" given');
        return undef;
    }

    ## Extract information from cert
    my ($tmpfile) = $tmpdir . "/parse_cert.$PID";
    my $cmd = sprintf '%s x509 -email -subject -purpose -noout', $openssl;
    unless (open(PSC, "| $cmd > $tmpfile")) {
        Sympa::Log::Syslog::do_log('err', 'open |openssl: %s', $ERRNO);
        return undef;
    }
    print PSC join('', @cert);

    unless (close(PSC)) {
        Sympa::Log::Syslog::do_log('err',
            "parse_cert: close openssl: $ERRNO, $EVAL_ERROR");
        return undef;
    }

    unless (open(PSC, "$tmpfile")) {
        Sympa::Log::Syslog::do_log('err',
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

sub extract_certs {
    my ($mime, $outfile, $openssl) = @_;
    Sympa::Log::Syslog::do_log('debug2',
        "Sympa::Tools::extract_certs(%s)",
        $mime->mime_type);

    if ($mime->mime_type =~ /application\/(x-)?pkcs7-/) {
        my $cmd = sprintf '%s pkcs7 -print_certs -inform der', $openssl;
        unless (open(MSGDUMP, "| $cmd > $outfile")) {
            Sympa::Log::Syslog::do_log('err',
                'unable to run openssl pkcs7: %s', $ERRNO);
            return 0;
        }
        print MSGDUMP $mime->bodyhandle->as_string();
        close(MSGDUMP);
        if ($CHILD_ERROR) {
            Sympa::Log::Syslog::do_log(
                'err',
                "openssl pkcs7 returned an error: ",
                $CHILD_ERROR / 256
            );
            return 0;
        }
        return 1;
    }
}

1;
