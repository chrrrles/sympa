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

package Sympa::Tools::Message;

use strict;

use Carp qw(croak);
use English;

use MIME::EncWords;
use MIME::Decoder;

use Sympa::Log::Syslog;

## Make a multipart/alternative, a singlepart
sub as_singlepart {
    my ($msg, $preferred_type, $loops) = @_;
    my $done = 0;
    $loops++;

    unless (defined $msg) {
        Sympa::Log::Syslog::do_log('err', "Undefined message parameter");
        return undef;
    }

    if ($loops > 4) {
        Sympa::Log::Syslog::do_log('err',
            'Could not change multipart to singlepart');
        return undef;
    }

    if ($msg->effective_type() =~ /^$preferred_type$/) {
        $done = 1;
    } elsif ($msg->effective_type() =~ /^multipart\/alternative/) {
        foreach my $part ($msg->parts) {
            if (($part->effective_type() =~ /^$preferred_type$/)
                || (   ($part->effective_type() =~ /^multipart\/related$/)
                    && $part->parts
                    && ($part->parts(0)->effective_type() =~
                        /^$preferred_type$/)
                )
                ) {
                ## Only keep the first matching part
                $msg->parts([$part]);
                $msg->make_singlepart();
                $done = 1;
                last;
            }
        }
    } elsif ($msg->effective_type() =~ /multipart\/signed/) {
        my @parts = $msg->parts();
        ## Only keep the first part
        $msg->parts([$parts[0]]);
        $msg->make_singlepart();

        $done ||= as_singlepart($msg, $preferred_type, $loops);

    } elsif ($msg->effective_type() =~ /^multipart/) {
        foreach my $part ($msg->parts) {

            next unless (defined $part);    ## Skip empty parts

            if ($part->effective_type() =~ /^multipart\/alternative/) {
                if (as_singlepart($part, $preferred_type, $loops)) {
                    $msg->parts([$part]);
                    $msg->make_singlepart();
                    $done = 1;
                }
            }
        }
    }

    return $done;
}

sub split_mail {
    my $message  = shift;
    my $pathname = shift;
    my $dir      = shift;

    my $head     = $message->head;
    my $body     = $message->body;
    my $encoding = $head->mime_encoding;

    if ($message->is_multipart
        || ($message->mime_type eq 'message/rfc822')) {

        for (my $i = 0; $i < $message->parts; $i++) {
            split_mail($message->parts($i), $pathname . '.' . $i, $dir);
        }
    } else {
        my $fileExt;

        if ($head->mime_attr("content_type.name") =~ /\.(\w+)\s*\"*$/) {
            $fileExt = $1;
        } elsif ($head->recommended_filename =~ /\.(\w+)\s*\"*$/) {
            $fileExt = $1;
        } else {
            my $mime_types = load_mime_types();

            $fileExt = $mime_types->{$head->mime_type};
            my $var = $head->mime_type;
        }

        ## Store body in file
        unless (open OFILE, ">$dir/$pathname.$fileExt") {
            Sympa::Log::Syslog::do_log('err', 'Unable to create %s/%s.%s: %s',
                $dir, $pathname, $fileExt, $ERRNO);
            return undef;
        }

        if ($encoding =~
            /^(binary|7bit|8bit|base64|quoted-printable|x-uu|x-uuencode|x-gzip64)$/
            ) {
            open TMP, ">$dir/$pathname.$fileExt.$encoding";
            $message->print_body(\*TMP);
            close TMP;

            open BODY, "$dir/$pathname.$fileExt.$encoding";

            my $decoder = MIME::Decoder->new($encoding);
            unless (defined $decoder) {
                Sympa::Log::Syslog::do_log('err',
                    'Cannot create decoder for %s', $encoding);
                return undef;
            }
            $decoder->decode(\*BODY, \*OFILE);
            close BODY;
            unlink "$dir/$pathname.$fileExt.$encoding";
        } else {
            $message->print_body(\*OFILE);
        }
        close(OFILE);
        printf "\t-------\t Create file %s\n", $pathname . '.' . $fileExt;

        ## Delete files created twice or more (with Content-Type.name and
        ## Content-Disposition.filename)
        $message->purge;
    }

    return 1;
}

sub virus_infected {
    my $mail = shift;

    # in, version previous from db spools, $file was the filename of the
    # message
    my $file = int(rand(time));
    Sympa::Log::Syslog::do_log('debug2', 'Scan virus in %s', $file);

    unless (Sympa::Site->antivirus_path) {
        Sympa::Log::Syslog::do_log('debug',
            'Sympa not configured to scan virus in message');
        return 0;
    }
    my @name = split(/\//, $file);
    my $work_dir = Sympa::Site->tmpdir . '/antivirus';

    unless ((-d $work_dir) || (mkdir $work_dir, 0755)) {
        Sympa::Log::Syslog::do_log('err',
            "Unable to create tmp antivirus directory $work_dir");
        return undef;
    }

    $work_dir = Sympa::Site->tmpdir . '/antivirus/' . $name[$#name];

    unless ((-d $work_dir) || mkdir($work_dir, 0755)) {
        Sympa::Log::Syslog::do_log('err',
            "Unable to create tmp antivirus directory $work_dir");
        return undef;
    }

    #$mail->dump_skeleton;

    ## Call the procedure of splitting mail
    unless (split_mail($mail, 'msg', $work_dir)) {
        Sympa::Log::Syslog::do_log('err', 'Could not split mail %s', $mail);
        return undef;
    }

    my $virusfound = 0;
    my $error_msg;
    my $result;

    ## McAfee
    if (Sympa::Site->antivirus_path =~ /\/uvscan$/) {

        # impossible to look for viruses with no option set
        unless (Sympa::Site->antivirus_args) {
            Sympa::Log::Syslog::do_log('err',
                "Missing 'antivirus_args' in sympa.conf");
            return undef;
        }

        my $cmd = sprintf '%s %s %s',
            Sympa::Site->antivirus_path, Sympa::Site->antivirus_args,
            $work_dir;
        open(ANTIVIR, "$cmd |");

        while (<ANTIVIR>) {
            $result .= $_;
            chomp $result;
            if (   (/^\s*Found the\s+(.*)\s*virus.*$/i)
                || (/^\s*Found application\s+(.*)\.\s*$/i)) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR >> 8;

        ## uvscan status =12 or 13 (*256) => virus
        if (($status == 13) || ($status == 12)) {
            $virusfound ||= "unknown";
        }

        ## Meaning of the codes
        ##  12 : The program tried to clean a file, and that clean failed for
        ##  some reason and the file is still infected.
        ##  13 : One or more viruses or hostile objects (such as a Trojan
        ##  horse, joke program,  or  a  test file) were found.
        ##  15 : The programs self-check failed; the program might be infected
        ##  or damaged.
        ##  19 : The program succeeded in cleaning all infected files.

        $error_msg = $result
            if ($status != 0
            && $status != 12
            && $status != 13
            && $status != 19);

        ## Trend Micro
    } elsif (Sympa::Site->antivirus_path =~ /\/vscan$/) {
        my $cmd = sprintf '%s %s %s',
            Sympa::Site->antivirus_path, Sympa::Site->antivirus_args,
            $work_dir;
        open(ANTIVIR, "$cmd |");

        while (<ANTIVIR>) {
            if (/Found virus (\S+) /i) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR >> 8;

        ## uvscan status = 1 | 2 (*256) => virus
        if ((($status == 1) or ($status == 2)) and not($virusfound)) {
            $virusfound = "unknown";
        }

        ## F-Secure
    } elsif (Sympa::Site->antivirus_path =~ /\/fsav$/) {
        my $dbdir = $PREMATCH;

        # impossible to look for viruses with no option set
        unless (Sympa::Site->antivirus_args) {
            Sympa::Log::Syslog::do_log('err',
                "Missing 'antivirus_args' in sympa.conf");
            return undef;
        }
        my $cmd = sprintf '%s --databasedirectory %s %s %s',
            Sympa::Site->antivirus_path, $dbdir, Sympa::Site->antivirus_args,
            $work_dir;
        open(ANTIVIR, "$cmd |");

        while (<ANTIVIR>) {

            if (/infection:\s+(.*)/) {
                $virusfound = $1;
            }
        }

        close ANTIVIR;

        my $status = $CHILD_ERROR >> 8;

        ## fsecure status =3 (*256) => virus
        if (($status == 3) and not($virusfound)) {
            $virusfound = "unknown";
        }
    } elsif (Sympa::Site->antivirus_path =~ /f-prot\.sh$/) {

        Sympa::Log::Syslog::do_log('debug2', 'f-prot is running');
        my $cmd = sprintf '%s %s %s',
            Sympa::Site->antivirus_path, Sympa::Site->antivirus_args,
            $work_dir;
        open(ANTIVIR, "$cmd |");

        while (<ANTIVIR>) {
            if (/Infection:\s+(.*)/) {
                $virusfound = $1;
            }
        }

        close ANTIVIR;

        my $status = $CHILD_ERROR >> 8;

        Sympa::Log::Syslog::do_log('debug2', 'Status: ' . $status);

        ## f-prot status =3 (*256) => virus
        if (($status == 3) and not($virusfound)) {
            $virusfound = "unknown";
        }
    } elsif (Sympa::Site->antivirus_path =~ /kavscanner/) {

        # impossible to look for viruses with no option set
        unless (Sympa::Site->antivirus_args) {
            Sympa::Log::Syslog::do_log('err',
                "Missing 'antivirus_args' in sympa.conf");
            return undef;
        }
        my $cmd = sprintf '%s %s %s',
            Sympa::Site->antivirus_path, Sympa::Site->antivirus_args,
            $work_dir;
        open(ANTIVIR, "$cmd |");

        while (<ANTIVIR>) {
            if (/infected:\s+(.*)/) {
                $virusfound = $1;
            } elsif (/suspicion:\s+(.*)/i) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR >> 8;

        ## uvscan status =3 (*256) => virus
        if (($status >= 3) and not($virusfound)) {
            $virusfound = "unknown";
        }

        ## Sophos Antivirus... by liuk@publinet.it
    } elsif (Sympa::Site->antivirus_path =~ /\/sweep$/) {

        # impossible to look for viruses with no option set
        unless (Sympa::Site->antivirus_args) {
            Sympa::Log::Syslog::do_log('err',
                "Missing 'antivirus_args' in sympa.conf");
            return undef;
        }
        my $cmd = sprintf '%s %s %s',
            Sympa::Site->antivirus_path, Sympa::Site->antivirus_args,
            $work_dir;
        open(ANTIVIR, "$cmd |");

        while (<ANTIVIR>) {
            if (/Virus\s+(.*)/) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR >> 8;

        ## sweep status =3 (*256) => virus
        if (($status == 3) and not($virusfound)) {
            $virusfound = "unknown";
        }

        ## Clam antivirus
    } elsif (Sympa::Site->antivirus_path =~ /\/clamd?scan$/) {
        my $cmd = sprintf '%s %s %s',
            Sympa::Site->antivirus_path, Sympa::Site->antivirus_args,
            $work_dir;
        open(ANTIVIR, "$cmd |");

        my $result;
        while (<ANTIVIR>) {
            $result .= $_;
            chomp $result;
            if (/^\S+:\s(.*)\sFOUND$/) {
                $virusfound = $1;
            }
        }
        close ANTIVIR;

        my $status = $CHILD_ERROR >> 8;

        ## Clamscan status =1 (*256) => virus
        if (($status == 1) and not($virusfound)) {
            $virusfound = "unknown";
        }

        $error_msg = $result
            if ($status != 0 && $status != 1);

    }

    ## Error while running antivir, notify listmaster
    if ($error_msg) {
        Sympa::Site->send_notify_to_listmaster('virus_scan_failed',
            {'filename' => $file, 'error_msg' => $error_msg});
    }

    ## if debug mode is active, the working directory is kept
    unless ($main::options{'debug'}) {
        opendir(DIR, ${work_dir});
        my @list = readdir(DIR);
        closedir(DIR);
        foreach (@list) {
            my $nbre = unlink("$work_dir/$_");
        }
        rmdir($work_dir);
    }

    return $virusfound;

}

#*******************************************
# Function : decode_header
# Description : return header value decoded to UTF-8 or undef.
#               trailing newline will be removed.
#               If sep is given, return all occurrences joined by it.
## IN : msg, tag, [sep]
## OUT : decoded header(s), with hostile characters (newline, nul) removed.
#*******************************************
sub decode_header {
    my $msg = shift;
    my $tag = shift;
    my $sep = shift || undef;

    my $head;
    if (ref $msg and $msg->isa('Message')) {
        $head = $msg->as_entity()->head;
    } elsif (ref $msg eq 'MIME::Entity') {
        $head = $msg->head;
    } elsif (ref $msg eq 'MIME::Head' or ref $msg eq 'Mail::Header') {
        $head = $msg;
    } else {
        croak 'bug in logic.  Ask developer';
    }

    if (defined $sep) {
        my @values = $head->get($tag);
        return undef unless scalar @values;
        foreach my $val (@values) {
            $val = MIME::EncWords::decode_mimewords($val, Charset => 'UTF-8');
            chomp $val;
            $val =~ s/(\r\n|\r|\n)([ \t])/$2/g;    #unfold
            $val =~ s/\0|\r\n|\r|\n//g;            # remove newline & nul
        }
        return join $sep, @values;
    } else {
        my $val = $head->get($tag, 0);
        return undef unless defined $val;
        $val = MIME::EncWords::decode_mimewords($val, Charset => 'UTF-8');
        chomp $val;
        $val =~ s/(\r\n|\r|\n)([ \t])/$2/g;        #unfold
        $val =~ s/\0|\r\n|\r|\n//g;                # remove newline & nul

        return $val;
    }
}

1;
