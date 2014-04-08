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
use DateTime;
use Encode qw();
use English;
use HTML::TreeBuilder;
use Mail::Address;
use MIME::EncWords;
use MIME::Charset;
use MIME::Decoder;
use MIME::Parser;
use Time::Local qw();

use Sympa::HTML::MyFormatText;
use Sympa::Language;
use Sympa::Log::Syslog;
use Sympa::Template;
use Sympa::Tools;
use Sympa::Tools::Text;

=head1 FUNCTIONS

=over

=item as_singlepart($message, $preferred_type, $loops)

Make a multipart/alternative, a singlepart.

=cut

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

=item split_mail($message, $path, $directory)

FIXME: missing description.

=cut

sub split_mail {
    my $message  = shift;
    my $pathname = shift;
    my $dir      = shift;

    my $head     = $message->head;
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

=item virus_infectd($message)

FIXME: missing description

=cut

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
            unlink("$work_dir/$_");
        }
        rmdir($work_dir);
    }

    return $virusfound;

}

=item decode_header($message, $tag, $separator)

Return header value, decoded to UTF-8. trailing newline will be
removed. If sep is given, return all occurrences joined by it.

Parameters:

=over

=item * I<$message>: FIXME

=item * I<$tag>: FIXME

=item * I<$separator>: FIXME

=back

Returns decoded header(s), with hostile characters (newline, nul) removed.

=cut

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

=item plain_body_as_string($entity)

Returns a plain text version of an email # message, suitable for use in plain
text digests.

Most attachments are stripped out and replaced with a note that they've been
stripped. text/plain parts are # retained.

An attempt to convert text/html parts to plain text is made if there is no
text/plain alternative.

All messages are converted from their original character set to UTF-8 

Parts of type message/rfc822 are recursed through in the same way, with brief
headers included.

Any line consisting only of 30 hyphens has the first character changed to
space (see RFC 1153). Lines are wrapped at 80 characters.

Copyright (C) 2004-2008 Chris Hastie

=cut

sub plain_body_as_string {
    my ($topent, @paramlist) = @_;
    my %params = @paramlist;

    my $string = _do_toplevel($topent);

    # clean up after ourselves
    $topent->purge;

    return Sympa::Tools::Text::wrap_text($string, '', '');
}

sub _do_toplevel {

    my $topent = shift;
    if (   $topent->effective_type =~ /^text\/plain$/i
        || $topent->effective_type =~ /^text\/enriched/i) {
       return _do_text_plain($topent);
    } elsif ($topent->effective_type =~ /^text\/html$/i) {
       return _do_text_html($topent);
    } elsif ($topent->effective_type =~ /^multipart\/.*/i) {
       return  _do_multipart($topent);
    } elsif ($topent->effective_type =~ /^message\/rfc822$/i) {
       return _do_message($topent);
    } elsif ($topent->effective_type =~ /^message\/delivery\-status$/i) {
       return _do_dsn($topent);
    } else {
       return _do_other($topent);
    }
    return 1;
}

sub _do_multipart {
    my $topent = shift;
    my $string = '';

    # cycle through each part and process accordingly
    foreach my $subent ($topent->parts) {
        if (   $subent->effective_type =~ /^text\/plain$/i
            || $subent->effective_type =~ /^text\/enriched/i) {
            $string .= _do_text_plain($subent);
        } elsif ($subent->effective_type =~ /^multipart\/related$/i) {
            if (   $topent->effective_type =~ /^multipart\/alternative$/i
                && _hasTextPlain($topent)) {

                # this is a rare case - /related nested inside /alternative.
                # If there's also a text/plain alternative just ignore it
                next;
            } else {

                # just treat like any other multipart
                $string .= _do_multipart($subent);
            }
        } elsif ($subent->effective_type =~ /^multipart\/.*/i) {
            $string .= _do_multipart($subent);
        } elsif ($subent->effective_type =~ /^text\/html$/i) {
            if ($topent->effective_type =~ /^multipart\/alternative$/i
                && _hasTextPlain($topent)) {

                # there's a text/plain alternive, so don't warn
                # that the text/html part has been scrubbed
                next;
            }
            $string .= _do_text_html($subent);
        } elsif ($subent->effective_type =~ /^message\/rfc822$/i) {
            $string .= _do_message($subent);
        } elsif ($subent->effective_type =~ /^message\/delivery\-status$/i) {
            $string .= _do_dsn($subent);
        } else {

            # something else - just scrub it and add a message to say what was
            # there
            $string .= _do_other($subent);
        }
    }

    return $string;
}

sub _do_message {
    my $topent = shift;
    my $msgent = $topent->parts(0);
    my $string;

    unless ($msgent) {
        return Sympa::Language::gettext("----- Malformed message ignored -----\n\n");
    }

    my $from = decode_headerr($msgent, 'From');
    $from = Sympa::Language::gettext("[Unknown]") unless defined $from and length $from;
    my $subject = decode_headerr($msgent, 'Subject');
    $subject = '' unless defined $subject;
    my $date = decode_headerr($msgent, 'Date');
    $date = '' unless defined $date;
    my $to = decode_headerr($msgent, 'To', ', ');
    $to = '' unless defined $to;
    my $cc = decode_headerr($msgent, 'Cc', ', ');
    $cc = '' unless defined $cc;

    my @fromline = Mail::Address->parse($msgent->head->get('From'));
    my $name;
    if ($fromline[0]) {
        $name = MIME::EncWords::decode_mimewords($fromline[0]->name(),
            Charset => 'utf8');
        $name = $fromline[0]->address()
            unless defined $name and $name =~ /\S/;
        chomp $name if $name;
    }
    $name = $from unless defined $name and length $name;

    $string .=
        Sympa::Language::gettext("\n[Attached message follows]\n-----Original message-----\n");
    my $headers = '';
    $headers .= sprintf(Sympa::Language::gettext("Date: %s\n"),    $date)
        if $date;
    $headers .= sprintf(Sympa::Language::gettext("From: %s\n"),    $from)
        if $from;
    $headers .= sprintf(Sympa::Language::gettext("To: %s\n"),      $to)
        if $to;
    $headers .= sprintf(Sympa::Language::gettext("Cc: %s\n"),      $cc)
        if $cc;
    $headers .= sprintf(Sympa::Language::gettext("Subject: %s\n"), $subject)
        if $subject;
    $headers .= "\n";
    $string .= Sympa::Tools::Text::wrap_text($headers, '', '    ');

    $string .= _do_toplevel($msgent);

    $string .= sprintf(
        Sympa::Language::gettext("-----End of original message from %s-----\n\n"),
        $name
    );
    return $string;
}

sub _do_text_plain {
    my $entity = shift;
    my $string;

    if (($entity->head->get('Content-Disposition') || '') =~ /attachment/) {
        return _do_other($entity);
    }

    my $thispart = $entity->bodyhandle->as_string();

    # deal with CR/LF left over - a problem from Outlook which
    # qp encodes them
    $thispart =~ s/\r\n/\n/g;

    ## normalise body to UTF-8
    # get charset
    my $charset = _getCharset($entity);
    eval {
        $charset->encoder('utf8');
        $thispart = $charset->encode($thispart);
    };
    if ($EVAL_ERROR) {

        # mmm, what to do if it fails?
        $string .= sprintf Sympa::Language::gettext(
            "** Warning: A message part using unrecognized character set %s\n    Some characters may be lost or incorrect **\n\n"
        ), $charset->as_string();
        $thispart =~ s/[^\x00-\x7F]/?/g;
    }

    # deal with 30 hyphens (RFC 1153)
    $thispart =~ s/\n-{30}(\n|$)/\n -----------------------------\n/g;

    # leading and trailing lines (RFC 1153)
    $thispart =~ s/^\n*//;
    $thispart =~ s/\n+$/\n/;

    $string .= $thispart;

    return $string;
}

# just add a note that attachment was stripped.
sub _do_other {
    my $entity = shift;

    return sprintf(
        Sympa::Language::gettext("\n[An attachment of type %s was included here]\n"),
        $entity->mime_type
    );
}

sub _do_dsn {
    my $entity = shift;
    my $string = '';

    $string .= Sympa::Language::gettext("\n-----Delivery Status Report-----\n");
    $string .= _do_text_plain($entity);
    $string .= Sympa::Language::gettext("\n-----End of Delivery Status Report-----\n");

    return $string;
}

# get a plain text representation of an HTML part
sub _do_text_html {
    my $entity = shift;
    my $string;
    my $text;

    unless (defined $entity->bodyhandle) {
        return 
            Sympa::Language::gettext("\n[** Unable to process HTML message part **]\n");
    }

    my $body = $entity->bodyhandle->as_string();

    # deal with CR/LF left over - a problem from Outlook which
    # qp encodes them
    $body =~ s/\r\n/\n/g;

    my $charset = _getCharset($entity);

    eval {

        # normalise body to internal unicode
        if ($charset->decoder) {
            $body = $charset->decode($body);
        } else {

            # mmm, what to do if it fails?
            $string .= sprintf Sympa::Language::gettext(
                "** Warning: A message part using unrecognized character set %s\n    Some characters may be lost or incorrect **\n\n"
            ), $charset->as_string();
            $body =~ s/[^\x00-\x7F]/?/g;
        }
        my $tree = HTML::TreeBuilder->new->parse($body);
        $tree->eof();
        my $formatter =
            Sympa::HTML::MyFormatText->new(leftmargin => 0, rightmargin => 72);
        $text = $formatter->format($tree);
        $tree->delete();
        $text = Encode::encode_utf8($text);
    };
    if ($EVAL_ERROR) {
        $string .=
            Sympa::Language::gettext("\n[** Unable to process HTML message part **]\n");
        return 1;
    }

    $string .= Sympa::Language::gettext("[ Text converted from HTML ]\n");

    # deal with 30 hyphens (RFC 1153)
    $text =~ s/\n-{30}(\n|$)/\n -----------------------------\n/g;

    # leading and trailing lines (RFC 1153)
    $text =~ s/^\n*//;
    $text =~ s/\n+$/\n/;

    $string .= $text;

    return $string;
}

sub _hasTextPlain {

    # tell if an entity has text/plain children
    my $topent  = shift;
    my @subents = $topent->parts;
    foreach my $subent (@subents) {
        if ($subent->effective_type =~ /^text\/plain$/i) {
            return 1;
        }
    }
    return undef;
}

sub _getCharset {
    my $entity = shift;

    my $charset =
          $entity->head->mime_attr('content-type.charset')
        ? $entity->head->mime_attr('content-type.charset')
        : 'us-ascii';

    # malformed mail with single quotes around charset?
    if ($charset =~ /'([^']*)'/i) { $charset = $1; }

    # get charset object.
    return MIME::Charset->new($charset);
}

=item parse_tt2_messageasstring($robot, $file, $recipient, $data)

Creates a message from a template.

Parameters:

=over

=item * B<$robot>: FIXME

=item * B<$file>: template file

=item * B<$recipient>: message recipient

=item * B<$parameters>: data passed to the template

=back

Returns the message as a string on success, I<undef> on failure.

=cut

sub parse_tt2_messageasstring {
    my $robot    = shift;
    my $filename = shift;
    my $rcpt     = shift;
    my $data     = shift;

    my $header_possible = $data->{'header_possible'};
    my $sign_mode       = $data->{'sign_mode'};
    Sympa::Log::Syslog::do_log('debug2',
        '(%s, %s, %s, header_possible=%s, sign_mode=%s)',
        $robot, $filename, $rcpt, $header_possible, $sign_mode);
    my ($to, $message_as_string);

    ## boolean
    $header_possible = 0 unless (defined $header_possible);
    my %header_ok;    # hash containing no missing headers
    my $existing_headers = 0;    # the message already contains headers

    ## We may receive a list of recipients
    if (ref($rcpt)) {
        unless (ref($rcpt) eq 'ARRAY') {
            Sympa::Log::Syslog::do_log('notice',
                'Wrong type of reference for rcpt');
            return undef;
        }
    }

    ## Charset for encoding
    Sympa::Language::PushLang($data->{'lang'}) if defined $data->{'lang'};
    $data->{'charset'} ||= Sympa::Language::GetCharset();
    Sympa::Language::PopLang() if defined $data->{'lang'};

    if ($filename =~ /\.tt2$/) {

        # TT2 file parsing
        my $output;
        my @path = split /\//, $filename;

        Sympa::Language::PushLang($data->{'lang'}) if defined $data->{'lang'};
        Sympa::Template::parse_tt2($data, $path[$#path], \$output);
        Sympa::Language::PopLang() if defined $data->{'lang'};

        $message_as_string .= join('', $output);
        $header_possible = 1;
    } else {    # or not
        $message_as_string .= $data->{'body'};
    }

    ## ## Does the message include headers ?
    if ($header_possible) {
        foreach my $line (split(/\n/, $message_as_string)) {
            last if ($line =~ /^\s*$/);
            if ($line =~ /^[\w-]+:\s*/) {    ## A header field
                $existing_headers = 1;
            } elsif ($existing_headers && ($line =~ /^\s/)) {
                ## Following of a header field
                next;
            } else {
                last;
            }

            foreach my $header (
                qw(message-id date to from subject reply-to
                mime-version content-type content-transfer-encoding)
                ) {
                if ($line =~ /^$header\s*:/i) {
                    $header_ok{$header} = 1;
                    last;
                }
            }
        }
    }

    ## ADD MISSING HEADERS
    my $headers = "";

    unless ($header_ok{'message-id'}) {
        $headers .=
            sprintf("Message-Id: %s\n", Sympa::Tools::get_message_id($robot));
    }

    unless ($header_ok{'date'}) {
        ## Format current time.
        ## If setting local timezone fails, fallback to UTC.
        my $date = (
            eval { DateTime->now(time_zone => 'local') } || DateTime->now
        )->strftime('%a, %{day} %b %Y %H:%M:%S %z');
        $headers .= sprintf "Date: %s\n", $date;
    }

    unless ($header_ok{'to'}) {

        # Currently, bare e-mail address is assumed.  Complex ones such as
        # "phrase" <email> won't be allowed.
        if (ref($rcpt)) {
            if ($data->{'to'}) {
                $to = $data->{'to'};
            } else {
                $to = join(",\n   ", @{$rcpt});
            }
        } else {
            $to = $rcpt;
        }
        $headers .= "To: $to\n";
    }
    unless ($header_ok{'from'}) {
        if (   !defined $data->{'from'}
            or $data->{'from'} eq 'sympa'
            or $data->{'from'} eq $data->{'conf'}{'sympa'}) {
            $headers .= 'From: '
                . Sympa::Tools::addrencode(
                $data->{'conf'}{'sympa'},
                $data->{'conf'}{'email_gecos'},
                $data->{'charset'}
                ) . "\n";
        } else {
            $headers .= "From: "
                . MIME::EncWords::encode_mimewords(
                Encode::decode('utf8', $data->{'from'}),
                'Encoding' => 'A',
                'Charset'  => $data->{'charset'},
                'Field'    => 'From'
                ) . "\n";
        }
    }
    unless ($header_ok{'subject'}) {
        $headers .= "Subject: "
            . MIME::EncWords::encode_mimewords(
            Encode::decode('utf8', $data->{'subject'}),
            'Encoding' => 'A',
            'Charset'  => $data->{'charset'},
            'Field'    => 'Subject'
            ) . "\n";
    }
    unless ($header_ok{'reply-to'}) {
        $headers .= "Reply-to: "
            . MIME::EncWords::encode_mimewords(
            Encode::decode('utf8', $data->{'replyto'}),
            'Encoding' => 'A',
            'Charset'  => $data->{'charset'},
            'Field'    => 'Reply-to'
            )
            . "\n"
            if ($data->{'replyto'});
    }
    if ($data->{'headers'}) {
        foreach my $field (keys %{$data->{'headers'}}) {
            $headers .=
                $field . ': '
                . MIME::EncWords::encode_mimewords(
                Encode::decode('utf8', $data->{'headers'}{$field}),
                'Encoding' => 'A',
                'Charset'  => $data->{'charset'},
                'Field'    => $field
                ) . "\n";
        }
    }
    unless ($header_ok{'mime-version'}) {
        $headers .= "MIME-Version: 1.0\n";
    }
    unless ($header_ok{'content-type'}) {
        $headers .=
            "Content-Type: text/plain; charset=" . $data->{'charset'} . "\n";
    }
    unless ($header_ok{'content-transfer-encoding'}) {
        $headers .= "Content-Transfer-Encoding: 8bit\n";
    }

    ## Determine what value the Auto-Submitted header field should take
    ## See http://www.tools.ietf.org/html/draft-palme-autosub-01
    ## the header field can have one of the following values :
    ## auto-generated, auto-replied, auto-forwarded
    ## The header should not be set when wwsympa sends a command/mail to
    ## sympa.pl through its spool
    unless ($data->{'not_auto_submitted'} || $header_ok{'auto_submitted'}) {
        ## Default value is 'auto-generated'
        my $header_value = $data->{'auto_submitted'} || 'auto-generated';
        $headers .= "Auto-Submitted: $header_value\n";
    }

    unless ($existing_headers) {
        $headers .= "\n";
    }

    ## All these data provide mail attachements in service messages
    my @msgs = ();
    if (ref($data->{'msg_list'}) eq 'ARRAY') {
        @msgs =
            map { $_->{'msg'} || $_->{'full_msg'} } @{$data->{'msg_list'}};
    } elsif ($data->{'spool'}) {
        @msgs = @{$data->{'spool'}};
    } elsif ($data->{'msg'}) {
        push @msgs, $data->{'msg'};
    } elsif ($data->{'msg_path'} and open IN, '<' . $data->{'msg_path'}) {
        push @msgs, join('', <IN>);
        close IN;
    } elsif ($data->{'file'} and open IN, '<' . $data->{'file'}) {
        push @msgs, join('', <IN>);
        close IN;
    }

    unless (
        $message_as_string = _reformat_message(
            "$headers" . "$message_as_string",
            \@msgs, $data->{'charset'}
        )
        ) {
        Sympa::Log::Syslog::do_log('err', 'Failed to reformat message');
    }

    return $message_as_string;
}

# _reformat_message($message, $attachments, $defcharset)
#
# Reformat bodies of text parts contained in the message using
# recommended encoding schema and/or charsets defined by MIME::Charset.
#
# MIME-compliant headers are appended / modified. And custom X-Mailer: header
# is appended :).
#
# Some paths of message processing in Sympa can't recognize Unicode strings.
# At least MIME::Parser::parse_data() and Template::proccess(): these
# methods occationalily break strings containing Unicode characters.
#
# Sub-messages to be attached (into digests, moderation notices etc.) will
# passed to _reformat_message() separately then attached to reformatted parent
# message again. As a result, sub-messages won't be broken.
# Since they won't cause mixture of Unicode string (parent message generated
# by Sympa::Template::parse_tt2()) and byte string (sub-messages).
#
# Note: For compatibility with old style, data passed to _reformat_message()
# already includes sub-message(s). Then:
# - When a part has an `X-Sympa-Attach:' header field for internal use, new
#   style, Sympa::Mail::reformat_message() attaches raw sub-message to
#   reformatted parent message again;
# - When a part doesn't have any `X-Sympa-Attach:' header fields,
#   sub-messages generated by [% INSERT %] directive(s) in the template
#   will be used.
#
# Latter behavior above will give expected result only if contents of
# sub-messages are US-ASCII or ISO-8859-1. In other cases customized templates
# (if any) should be modified so that they have appropriate `X-Sympa-Attach:'
# header fileds.
#
# Sub-messages are gathered from template context parameters.
#
# IN : $msg: ref(MIME::Entity) | string - message to reformat
#      $attachments: ref(ARRAY) - messages to be attached as subparts.
# OUT : string

sub _reformat_message($;$$) {
    my $message     = shift;
    my $attachments = shift || [];
    my $defcharset  = shift;
    my $msg;

    my $parser = MIME::Parser->new();
    unless (defined $parser) {
        Sympa::Log::Syslog::do_log('err',
            "Sympa::Mail::reformat_message: Failed to create MIME parser");
        return undef;
    }
    $parser->output_to_core(1);

    if (ref($message) eq 'MIME::Entity') {
        $msg = $message;
    } else {
        eval { $msg = $parser->parse_data($message); };
        if ($EVAL_ERROR) {
            Sympa::Log::Syslog::do_log('err',
                "Sympa::Mail::reformat_message: Failed to parse MIME data");
            return undef;
        }
    }
    $msg->head->delete("X-Mailer");
    $msg = _fix_part($msg, $parser, $attachments, $defcharset);
    $msg->head->add("X-Mailer", sprintf "Sympa %s",
        Sympa::Constants::VERSION);
    return $msg->as_string();
}

sub _fix_part {
    my $part        = shift;
    my $parser      = shift;
    my $attachments = shift || [];
    my $defcharset  = shift;
    return $part unless $part;

    my $enc = $part->head->mime_encoding;

    # Parts with nonstandard encodings aren't modified.
    if ($enc and $enc !~ /^(?:base64|quoted-printable|[78]bit|binary)$/i) {
        return $part;
    }
    my $eff_type = $part->effective_type;

    # Signed or encrypted parts aren't modified.
    if ($eff_type =~ m{^multipart/(signed|encrypted)$}) {
        return $part;
    }

    if ($part->head->get('X-Sympa-Attach')) {    # Need re-attaching data.
        my $data = shift @{$attachments};
        if (ref($data) ne 'MIME::Entity') {
            eval { $data = $parser->parse_data($data); };
            if ($EVAL_ERROR) {
                Sympa::Log::Syslog::do_log('notice',
                    "Failed to parse MIME data");
                $data = $parser->parse_data('');
            }
        }
        $part->head->delete('X-Sympa-Attach');
        $part->parts([$data]);
    } elsif ($part->parts) {
        my @newparts = ();
        foreach ($part->parts) {
            push @newparts, _fix_part($_, $parser, $attachments, $defcharset);
        }
        $part->parts(\@newparts);
    } elsif ($eff_type =~ m{^(?:multipart|message)(?:/|\Z)}i) {

        # multipart or message types without subparts.
        return $part;
    } elsif (MIME::Tools::textual_type($eff_type)) {
        my $bodyh = $part->bodyhandle;

        # Encoded body or null body won't be modified.
        return $part if !$bodyh or $bodyh->is_encoded;

        my $head = $part->head;
        my $body = $bodyh->as_string();
        my $wrap = $body;
        if ($head->get('X-Sympa-NoWrap')) {    # Need not wrapping
            $head->delete('X-Sympa-NoWrap');
        } elsif ($eff_type eq 'text/plain'
            and lc($head->mime_attr('Content-type.Format') || '') ne 'flowed')
        {
            $wrap = Sympa::Tools::Text::wrap_text($body);
        }
        my $charset = $head->mime_attr("Content-Type.Charset") || $defcharset;

        my ($newbody, $newcharset, $newenc) =
            MIME::Charset::body_encode(Encode::decode('utf8', $wrap),
            $charset, Replacement => 'FALLBACK');
        if (    $newenc eq $enc
            and $newcharset eq $charset
            and $newbody eq $body) {
            $head->add("MIME-Version", "1.0")
                unless $head->get("MIME-Version");
            return $part;
        }

        ## normalize newline to CRLF if transfer-encoding is BASE64.
        $newbody =~ s/\r\n|\r|\n/\r\n/g
            if $newenc and $newenc eq 'BASE64';

        # Fix headers and body.
        $head->mime_attr("Content-Type", "TEXT/PLAIN")
            unless $head->mime_attr("Content-Type");
        $head->mime_attr("Content-Type.Charset",      $newcharset);
        $head->mime_attr("Content-Transfer-Encoding", $newenc);
        $head->add("MIME-Version", "1.0") unless $head->get("MIME-Version");
        my $io = $bodyh->open("w");

        unless (defined $io) {
            Sympa::Log::Syslog::do_log('err',
                "Sympa::Mail::reformat_message: Failed to save message : $ERRNO");
            return undef;
        }

        $io->print($newbody);
        $io->close;
        $part->sync_headers(Length => 'COMPUTE');
    } else {

        # Binary or text with long lines will be suggested to be BASE64.
        $part->head->mime_attr("Content-Transfer-Encoding",
            $part->suggest_encoding);
        $part->sync_headers(Length => 'COMPUTE');
    }
    return $part;
}

=back

=cut

1;
