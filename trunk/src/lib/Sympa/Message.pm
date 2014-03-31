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

Message - mail message embedding for internal use in Sympa

=head1 DESCRIPTION 

While processing a message in Sympa, we need to link information to the
message, modify headers and such.  This was quite a problem when a message was
signed, as modifying anything in the message body would alter its MD5
footprint.  And probably make the message to be rejected by clients verifying
its identity (which is somehow a good thing as it is the reason why people use
MD5 after all).  With such messages, the process was complex.  We then decided
to embed any message treated in a "Message" object, thus making the process
easier.

=cut 

package Sympa::Message;

use strict;
use warnings;

use Carp qw(croak);
use English qw(-no_match_vars);

use HTML::Entities qw(encode_entities);
use Mail::Address;
use MIME::Charset;
use MIME::EncWords;
use MIME::Entity;
use MIME::Parser;
use MIME::Tools;
use POSIX qw();
use Storable qw(dclone);
use URI::Escape;

use Sympa::Language;
use Sympa::Log::Syslog;
use Sympa::Site;
use Sympa::Template;
use Sympa::Tools;
use Sympa::Tools::DKIM;
use Sympa::Tools::Message;
use Sympa::Tools::SMIME;
use Sympa::Tools::WWW;

my %openssl_errors = (
    1 => 'an error occurred parsing the command options',
    2 => 'one of the input files could not be read',
    3 =>
        'an error occurred creating the PKCS#7 file or when reading the MIME message',
    4 => 'an error occurred decrypting or verifying the message',
    5 =>
        'the message was verified correctly but an error occurred writing out the signers certificates',
);

=head1 CLASS METHODS

=over 4

=item Sympa::Message->new(%parameters)

Creates a new L<Sympa::Message> object.

Parameters:

=over 4

=item * I<file>: the message, as a file

=item * I<messageasstring>: the message, as a string

=item * I<noxsympato>: FIXME

=item * I<messagekey>: FIXME

=item * I<spoolname>: FIXME

=item * I<robot>: FIXME

=item * I<robot_object>: FIXME

=item * I<list>: FIXME

=item * I<list_object>: FIXME

=item * I<authkey>: FIXME

=item * I<priority>: FIXME

=item * I<type>: FIXME

=back 

Return:

A new L<Sympa::Message> object, or I<undef>, if something went wrong.

=cut 

sub new {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s)', @_);
    my ($class, %params) = @_;

    my $self = bless {
        'noxsympato' => $params{'noxsympato'},
        'messagekey' => $params{'messagekey'},
        'spoolname'  => $params{'spoolname'},
        'robot_id'   => $params{'robot'},
        'filename'   => $params{'file'},
        'listname'   => $params{'list'},       #++
        'authkey'    => $params{'authkey'},    #FIXME: needed only by KeySpool.
        'priority'   => $params{'priority'},   #++
    } => $class;

    # set date from filename, if relevant
    if ($params{'file'}) {
        my $file = $params{'file'};
        $file =~ s/^.*\/([^\/]+)$/$1/;
        if ($file =~ /^(\S+)\.(\d+)\.\w+$/) {
            $self->{'date'} = $2;
        }
    }

    unless ($self->{'list'} or $self->{'robot'}) {
        if ($params{'list_object'}) {
            $self->{'list'} = $params{'list_object'};
        } elsif ($params{'robot_object'}) {
            $self->{'robot'} = $params{'robot_object'};
        }
        $self->{'listtype'} = $params{'type'} if $params{'type'};    #++
    }

    ## Load content

    my $messageasstring;
    if ($params{'file'}) {
        eval {
            $messageasstring = Sympa::Tools::File::slurp_file($params{'file'});
        };
        if ($EVAL_ERROR) {
            Sympa::Log::Syslog::do_log('err', $EVAL_ERROR);
            return undef;
        }
    } elsif ($params{'messageasstring'}) {
        $messageasstring = $params{'messageasstring'};
    }

    return undef
        unless $self->_load($messageasstring);

    return $self;
}

=back

=head1 INSTANCE METHODS

=over

=item $message->get_family()

Gets the family context of this message.

=cut

sub get_family {
    my $self = shift;

    return $self->{'family'};
}

=item $message->get_list()

Gets the list context of this message, as a L<Sympa::List> object.

=cut

sub get_list {
    my $self = shift;

    return $self->{'list'};
}

=item $message->get_robot()

Gets the robot context of this message, as a L<Sympa::Robot> object.

=cut

sub get_robot {
    my $self = shift;

    return 
        $self->{'robot'} ? $self->{'robot'}         :
        $self->{'list'}  ? $self->{'list'}->robot() :
                           undef;
}

sub _load {
    my $self            = shift;
    my $messageasstring = shift;

    if (ref $messageasstring) {
        Sympa::Log::Syslog::do_log('err',
            'deprecated: $messageasstring must be string, not %s',
            $messageasstring);
        return undef;
    }

    # Get metadata

    unless ($self->{'noxsympato'}) {
        pos($messageasstring) = 0;
        while ($messageasstring =~ /\G(X-Sympa-\w+): (.*?)\n(?![ \t])/cgs) {
            my ($k, $v) = ($1, $2);
            next unless length $v;

            if ($k eq 'X-Sympa-To') {    # obsoleted; for migration
                $self->{'rcpt'} = join ',', split(/\s*,\s*/, $v);
            } elsif ($k eq 'X-Sympa-Checksum') {    # obsoleted; for migration
                $self->{'checksum'} = $v;
            } elsif ($k eq 'X-Sympa-Family') {
                $self->{'family'} = $v;
            } elsif ($k eq 'X-Sympa-From') {
                $self->{'envelope_sender'} = $v;
            } elsif ($k eq 'X-Sympa-Authenticated') {
                $self->{'authenticated'} = $v;
            } elsif ($k eq 'X-Sympa-Sender') {
                $self->{'sender'} = $v;
            } elsif ($k eq 'X-Sympa-Gecos') {
                $self->{'gecos'} = $v;
            } elsif ($k eq 'X-Sympa-Spam-Status') {
                $self->{'spam_status'} = $v;
            } else {
                Sympa::Log::Syslog::do_log('warn',
                    'Unknown meta information: "%s: %s"',
                    $k, $v);
            }
        }

        # Strip meta information
        substr($messageasstring, 0, pos $messageasstring) = '';
    }

    $self->{'msg_as_string'} = $messageasstring;
    $self->{'size'}          = length $messageasstring;

    my $parser = MIME::Parser->new();
    $parser->output_to_core(1);
    my $msg = $parser->parse_data(\$messageasstring);
    $self->{'msg'} = $msg;

    # Get envelope sender, actual sender according to sender_headers site
    # parameter and spam status according to spam_status scenario.
    # FIXME: These processes are needed for incoming messages only.
    $self->get_envelope_sender;
    return undef unless $self->get_sender_email;
    $self->check_spam_status;

    $self->get_subject;

    #    $self->get_recipient;
    $self->check_dkim_signature;

    ## S/MIME
    if (Sympa::Site->openssl) {
        return undef unless $self->decrypt;
        $self->check_smime_signature;
    }
    ## TOPICS
    $self->set_topic;

    return $self;
}

=over 4

=item to_string

I<Serializer>.
Returns serialized data of Message object.

=back

=cut

sub to_string {
    my $self = shift;

    my $str = '';
    if (ref $self->{'rcpt'} eq 'ARRAY' and @{$self->{'rcpt'}}) {
        $str .= sprintf "X-Sympa-To: %s\n", join(',', @{$self->{'rcpt'}});
    } elsif (defined $self->{'rcpt'} and length $self->{'rcpt'}) {
        $str .= sprintf "X-Sympa-To: %s\n",
            join(',', split(/\s*,\s*/, $self->{'rcpt'}));
    }
    if (defined $self->{'checksum'}) {
        $str .= sprintf "X-Sympa-Checksum: %s\n", $self->{'checksum'};
    }
    if (defined $self->{'family'}) {
        $str .= sprintf "X-Sympa-Family: %s\n", $self->{'family'};
    }
    if (defined $self->{'envelope_sender'}) {
        $str .= sprintf "X-Sympa-From: %s\n", $self->{'envelope_sender'};
    }
    if (defined $self->{'authenticated'}) {
        $str .= sprintf "X-Sympa-Authenticated: %s\n",
            $self->{'authenticated'};
    }
    if (defined $self->{'sender'}) {
        $str .= sprintf "X-Sympa-Sender: %s\n", $self->{'sender'};
    }
    if (defined $self->{'gecos'} and length $self->{'gecos'}) {
        $str .= sprintf "X-Sympa-Gecos: %s\n", $self->{'gecos'};
    }
    if ($self->{'spam_status'}) {
        $str .= sprintf "X-Sympa-Spam-Status: %s\n", $self->{'spam_status'};
    }

    $str .= $self->{'msg_as_string'};

    return $str;
}

=over 4

=item get_header ( FIELD, [ SEP ] )

I<Instance method>.
Gets value(s) of header field FIELD, stripping trailing newline.

B<In scalar context> without SEP, returns first occurrence or C<undef>.
If SEP is defined, returns all occurrences joined by it, or C<undef>.
Otherwise B<in array context>, returns an array of all occurrences or C<()>.

Note:
Folding newlines will not be removed.

=back

=cut

sub get_header {
    my $self  = shift;
    my $field = shift;
    my $sep   = shift;

    my $hdr = $self->as_entity()->head;

    if (defined $sep or wantarray) {
        my @values = grep {s/\A$field\s*:\s*//i}
            split /\n(?![ \t])/, $hdr->as_string();
        if (defined $sep) {
            return undef unless @values;
            return join $sep, @values;
        }
        return @values;
    } else {
        my $value = $hdr->get($field, 0);
        chomp $value if defined $value;
        return $value;
    }
}

sub get_envelope_sender {
    my $self = shift;

    unless (exists $self->{'envelope_sender'}) {
        ## We trust in Return-Path: header field at the top of message.
        ## To add it to messages by MDA:
        ## - Sendmail:   Add 'P' in the 'F=' flags of local mailer line (such
        ##               as 'Mlocal').
        ## - Postfix:
        ##   - local(8): Available by default.
        ##   - pipe(8):  Add 'R' in the 'flags=' attributes of master.cf.
        ## - Exim:       Set 'return_path_add' to true with pipe_transport.
        ## - qmail:      Use preline(1).
        my $headers = $self->as_entity()->head->header();
        my $i       = 0;
        $i++ while $headers->[$i] and $headers->[$i] =~ /^X-Sympa-/;
        if ($headers->[$i] and $headers->[$i] =~ /^Return-Path:\s*(.+)$/) {
            my $addr = $1;
            if ($addr =~ /<>/) {
                $self->{'envelope_sender'} = '<>';
            } else {
                my @addrs = Mail::Address->parse($addr);
                if (@addrs and Sympa::Tools::valid_email($addrs[0]->address)) {
                    $self->{'envelope_sender'} = $addrs[0]->address;
                }
            }
        }
    }
    return $self->{'envelope_sender'};
}

## Get sender of the message according to header fields specified by
## 'sender_headers' parameter.
## FIXME: S/MIME signer may not be same as sender given by this method.
sub get_sender_email {
    my $self = shift;

    unless ($self->{'sender'}) {
        my $hdr    = $self->as_entity()->head;
        my $sender = undef;
        my $gecos  = undef;
        foreach my $field (split /[\s,]+/, Sympa::Site->sender_headers) {
            if (lc $field eq 'from_') {
                ## Try to get envelope sender
                if (    $self->get_envelope_sender
                    and $self->get_envelope_sender ne '<>') {
                    $sender = $self->get_envelope_sender;
                    last;
                }
            } elsif ($hdr->get($field)) {
                ## Try to get message header
                ## On "Resent-*:" headers, the first occurrence must be used.
                ## Though "From:" can occur multiple times, only the first
                ## one is detected.
                my @sender_hdr = Mail::Address->parse($hdr->get($field));
                if (scalar @sender_hdr and $sender_hdr[0]->address) {
                    $sender = lc($sender_hdr[0]->address);
                    my $phrase = $sender_hdr[0]->phrase;
                    if (defined $phrase and length $phrase) {
                        $gecos = MIME::EncWords::decode_mimewords($phrase,
                            Charset => 'UTF-8');
                    }
                    last;
                }
            }
        }
        unless (defined $sender) {
            Sympa::Log::Syslog::do_log('err', 'No valid sender address');
            return undef;
        }
        unless (Sympa::Tools::valid_email($sender)) {
            Sympa::Log::Syslog::do_log('err', 'Invalid sender address "%s"',
                $sender);
            return undef;
        }
        $self->{'sender'} = $sender;
        $self->{'gecos'}  = $gecos;
    }
    return $self->{'sender'};
}

sub get_sender_gecos {
    my $self = shift;
    $self->get_sender_email unless exists $self->{'gecos'};
    return $self->{'gecos'};
}

sub get_subject {
    my $self = shift;

    unless ($self->{'decoded_subject'}) {
        my $hdr = $self->as_entity()->head;
        ## Store decoded subject and its original charset
        my $subject = $hdr->get('Subject');
        if (defined $subject and $subject =~ /\S/) {
            my @decoded_subject = MIME::EncWords::decode_mimewords($subject);
            $self->{'subject_charset'} = 'US-ASCII';
            foreach my $token (@decoded_subject) {
                unless ($token->[1]) {

                    # don't decode header including raw 8-bit bytes.
                    if ($token->[0] =~ /[^\x00-\x7F]/) {
                        $self->{'subject_charset'} = undef;
                        last;
                    }
                    next;
                }
                my $cset = MIME::Charset->new($token->[1]);

                # don't decode header encoded with unknown charset.
                unless ($cset->decoder) {
                    $self->{'subject_charset'} = undef;
                    last;
                }
                unless ($cset->output_charset eq 'US-ASCII') {
                    $self->{'subject_charset'} = $token->[1];
                }
            }
        } else {
            $self->{'subject_charset'} = undef;
        }
        if ($self->{'subject_charset'}) {
            $self->{'decoded_subject'} =
                Sympa::Tools::Message::decode_header($self, 'Subject');
        } else {
            if ($subject) {
                chomp $subject;
                $subject =~ s/(\r\n|\r|\n)([ \t])/$2/g;
            }
            $self->{'decoded_subject'} = $subject;
        }
    }
    return $self->{'decoded_subject'};
}


#FIXME: This should be moved to Messagespool.
sub check_spam_status {
    my $self = shift;

    return $self->{'spam_status'} if $self->{'spam_status'};

    return undef unless ref $self->robot eq 'Sympa::Robot';

    my $spam_status =
        Sympa::Scenario::request_action($self->robot, 'spam_status', 'smtp',
        {'message' => $self});
    $self->{'spam_status'} = 'unknown';
    if (defined $spam_status) {
        if (ref $spam_status eq 'HASH') {
            $self->{'spam_status'} = $spam_status->{'action'};
        } else {
            $self->{'spam_status'} = $spam_status;
        }
    }
    return $self->{'spam_status'};
}

## This should be moved to Messagespool.
sub check_dkim_signature {
    my $self = shift;

    # verify DKIM signature
    if (ref($self->robot) eq 'Sympa::Robot'
        and $self->robot->dkim_feature eq 'on') {
        $self->{'dkim_pass'} =
            Sympa::Tools::DKIM::verifier($self->{'msg_as_string'});
    }
    return 1;
}

sub authenticated {
    return shift->{'authenticated'};
}

sub decrypt {
    my $self = shift;
    ## Decrypt messages
    my $hdr = $self->get_mime_message->head;
    if (   ($hdr->get('Content-Type') =~ /application\/(x-)?pkcs7-mime/i)
        && ($hdr->get('Content-Type') !~ /signed-data/i)) {
        unless (defined $self->smime_decrypt()) {
            Sympa::Log::Syslog::do_log('err',
                "Message %s could not be decrypted", $self);
            return undef;
            ## We should warn the sender and/or the listmaster
        }
        Sympa::Log::Syslog::do_log('notice', "message %s has been decrypted",
            $self);
    }
    return 1;
}

sub check_smime_signature {
    my $self = shift;
    my $hdr  = $self->get_mime_message->head;
    Sympa::Log::Syslog::do_log('debug',
        'Checking S/MIME signature for message %s, from user %s',
        $self->get_msg_id, $self->get_sender_email);
    ## Check S/MIME signatures
    if ($hdr->get('Content-Type') =~ /multipart\/signed/
        || (   $hdr->get('Content-Type') =~ /application\/(x-)?pkcs7-mime/i
            && $hdr->get('Content-Type') =~ /signed-data/i)
        ) {
        ## Messages that should not be altered (no footer)
        $self->{'protected'} = 1;

        $self->smime_sign_check();
        if ($self->{'smime_signed'}) {
            Sympa::Log::Syslog::do_log('notice',
                'message %s is signed, signature is checked', $self);
        }
        ## TODO: Handle errors (0 different from undef)
    }
}

=over 4

=item dump

I<Instance method>.
Dump a Message object to a stream.

Arguments:

=over 4

=item * I<$self>, the Message object to dump

=item * I<$output>, the stream to which dump the object

=back 

Return:

=over 4

=item * I<1>, if everything's alright

=back 

=back

=cut 

## Dump the Message object
sub dump {
    my ($self, $output) = @_;

    #    my $output ||= \*STDERR;

    my $old_output = select;
    select $output;

    foreach my $key (keys %{$self}) {
        if (ref($self->{$key}) eq 'MIME::Entity') {
            printf "%s =>\n", $key;
            $self->{$key}->print;
        } else {
            printf "%s => %s\n", $key, $self->{$key};
        }
    }

    select $old_output;

    return 1;
}

=over 4

=item add_topic

I<Instance method>.
Add topic and put header X-Sympa-Topic.

Arguments:

=over 4

=item * I<$self>, the Message object to which add a topic

=item * I<$output>, the string containing the topic to add

=back 

Return:

=over 4

=item * I<1>, if everything's alright

=back 

=back

=cut 

## Add topic and put header X-Sympa-Topic
sub add_topic {
    my ($self, $topic) = @_;

    $self->{'topic'} = $topic;
    my $hdr = $self->as_entity()->head;
    $hdr->add('X-Sympa-Topic', $topic);

    return 1;
}

# Internal use.
sub set_topic {
    my $self = shift;
    my $topics;
    if ($topics = $self->get_mime_message->head->get('X-Sympa-Topic')) {
        $self->{'topic'} = $topics;
    }
}

=over 4

=item get_topic

I<Instance method>.
Get topic.

Arguments:

=over 4

=item * I<$self>, the Message object whose topic is retrieved

=back 

Return:

=over 4

=item * I<the topic>, if it exists

=item * I<empty string>, otherwise

=back 

=back

=cut 

## Get topic
sub get_topic {
    my ($self) = @_;

    if (defined $self->{'topic'}) {
        return $self->{'topic'};

    } else {
        return '';
    }
}

sub clean_html {
    my $self  = shift;
    my $robot = shift;
    my $new_msg;
    if ($new_msg = _fix_html_part($self->as_entity(), $robot)) {
        $self->{'msg'}           = $new_msg;
        $self->{'msg_as_string'} = $new_msg->as_string();
        return 1;
    }
    return 0;
}

sub _fix_html_part {
    my $part  = shift;
    my $robot = shift;
    return $part unless $part;

    my $eff_type = $part->head->mime_attr("Content-Type");
    if ($part->parts) {
        my @newparts = ();
        foreach ($part->parts) {
            push @newparts, _fix_html_part($_, $robot);
        }
        $part->parts(\@newparts);
    } elsif ($eff_type =~ /^text\/html/i) {
        my $bodyh = $part->bodyhandle;

        # Encoded body or null body won't be modified.
        return $part if !$bodyh or $bodyh->is_encoded;

        my $body = $bodyh->as_string();

        # Re-encode parts to UTF-8, since StripScripts cannot handle texts
        # with some charsets (ISO-2022-*, UTF-16*, ...) correctly.
        my $cset =
            MIME::Charset->new($part->head->mime_attr('Content-Type.Charset')
                || '');
        unless ($cset->decoder) {

            # Charset is unknown.  Detect 7-bit charset.
            my (undef, $charset) =
                MIME::Charset::body_encode($body, '', Detect7Bit => 'YES');
            $cset = MIME::Charset->new($charset)
                if $charset;
        }
        if (    $cset->decoder
            and $cset->as_string() ne 'UTF-8'
            and $cset->as_string() ne 'US-ASCII') {
            $cset->encoder('UTF-8');
            $body = $cset->encode($body);
            $part->head->mime_attr('Content-Type.Charset', 'UTF-8');
        }

        my $filtered_body =
            Sympa::Tools::sanitize_html('string' => $body, 'robot' => $robot);

        my $io = $bodyh->open("w");
        unless (defined $io) {
            Sympa::Log::Syslog::do_log('err', 'Failed to save message : %s',
                $ERRNO);
            return undef;
        }
        $io->print($filtered_body);
        $io->close;
        $part->sync_headers(Length => 'COMPUTE');
    }
    return $part;
}

# extract body as string from msg_as_string
# do NOT use Mime::Entity in order to preserveB64 encoding form and so
# preserve S/MIME signature
sub get_body_from_msg_as_string {
    my $msg = shift;

    # convert it as a tab with headers as first element
    my @bodysection = split "\n\n", $msg;
    shift @bodysection;    # remove headers
    return (join("\n\n", @bodysection));    # convert it back as string
}

# input : msg object for a list, return a new message object decrypted
sub smime_decrypt {
    my $self = shift;
    my $from = $self->get_header('From');
    my $list = $self->{'list'};

    Sympa::Log::Syslog::do_log('debug2', 'Decrypting message from %s, %s',
        $from, $list);

    ## an empty "list" parameter means mail to sympa@, listmaster@...
    my $dir;
    if ($list) {
        $dir = $list->dir;
    } else {
        $dir = Sympa::Site->home . '/sympa';
    }
    my ($certs, $keys) = Sympa::Tools::SMIME::find_keys($dir, 'decrypt');
    unless (defined $certs && @$certs) {
        Sympa::Log::Syslog::do_log('err',
            "Unable to decrypt message : missing certificate file");
        return undef;
    }

    my $temporary_file = Sympa::Site->tmpdir . "/" . $list->get_list_id() . "." . $PID;
    my $temporary_pwd  = Sympa::Site->tmpdir . '/pass.' . $PID;

    ## dump the incoming message.
    if (!open(MSGDUMP, "> $temporary_file")) {
        Sympa::Log::Syslog::do_log('info', 'Can\'t store message in file %s',
            $temporary_file);
        return undef;
    }
    $self->as_entity()->print(\*MSGDUMP);
    close(MSGDUMP);

    my $pass_option;
    $self->{'decrypted_msg_as_string'} = '';
    if (Sympa::Site->key_passwd ne '') {

        # if password is defined in sympa.conf pass the password to OpenSSL
        $pass_option = "-passin file:$temporary_pwd";
    }

    ## try all keys/certs until one decrypts.
    while (my $certfile = shift @$certs) {
        my $keyfile = shift @$keys;
        Sympa::Log::Syslog::do_log('debug', 'Trying decrypt with %s, %s',
            $certfile, $keyfile);
        if (Sympa::Site->key_passwd ne '') {
            unless (POSIX::mkfifo($temporary_pwd, 0600)) {
                Sympa::Log::Syslog::do_log('err',
                    'Unable to make fifo for %s',
                    $temporary_pwd);
                return undef;
            }
        }
        my $cmd = sprintf '%s smime -decrypt -in %s -recip %s -inkey %s %s',
            Sympa::Site->openssl, $temporary_file, $certfile, $keyfile,
            $pass_option;
        Sympa::Log::Syslog::do_log('debug3', '%s', $cmd);
        open(NEWMSG, "$cmd |");

        if (defined Sympa::Site->key_passwd and Sympa::Site->key_passwd ne '') {
            unless (open(FIFO, "> $temporary_pwd")) {
                Sympa::Log::Syslog::do_log('err',
                    'Unable to open fifo for %s',
                    $temporary_pwd);
                return undef;
            }
            print FIFO Sympa::Site->key_passwd;
            close FIFO;
            unlink($temporary_pwd);
        }

        while (<NEWMSG>) {
            $self->{'decrypted_msg_as_string'} .= $_;
        }
        close NEWMSG;
        my $status = $CHILD_ERROR >> 8;
        if ($status) {
            Sympa::Log::Syslog::do_log(
                'err', 'Unable to decrypt S/MIME message: (%d) %s',
                $status, ($openssl_errors{$status} || 'unknown reason')
            );
            next;
        }

        unlink($temporary_file) unless ($main::options{'debug'});

        my $parser = MIME::Parser->new();
        $parser->output_to_core(1);
        unless ($self->{'decrypted_msg'} =
            $parser->parse_data($self->{'decrypted_msg_as_string'})) {
            Sympa::Log::Syslog::do_log('err', 'Unable to parse message');
            last;
        }
    }

    unless (defined $self->{'decrypted_msg'}) {
        Sympa::Log::Syslog::do_log('err', 'Message could not be decrypted');
        return undef;
    }

    ## Now remove headers from $self->{'decrypted_msg_as_string'}
    my @msg_tab = split(/\n/, $self->{'decrypted_msg_as_string'});
    my $line;
    do { $line = shift(@msg_tab) } while ($line !~ /^\s*$/);
    $self->{'decrypted_msg_as_string'} = join("\n", @msg_tab);

    ## foreach header defined in the incoming message but undefined in the
    ## decrypted message, add this header in the decrypted form.
    my $predefined_headers;
    foreach my $header ($self->{'decrypted_msg'}->head->tags) {
        if ($self->{'decrypted_msg'}->head->get($header)) {
            $predefined_headers->{lc $header} = 1;
        }
    }
    foreach my $header (split /\n(?![ \t])/,
        $self->as_entity()->head->as_string()) {
        next unless $header =~ /^([^\s:]+)\s*:\s*(.*)$/s;
        my ($tag, $val) = ($1, $2);
        unless ($predefined_headers->{lc $tag}) {
            $self->{'decrypted_msg'}->head->add($tag, $val);
        }
    }
    ## Some headers from the initial message should not be restored
    ## Content-Disposition and Content-Transfer-Encoding if the result is
    ## multipart
    $self->{'decrypted_msg'}->head->delete('Content-Disposition')
        if ($self->{'decrypted_msg'}->head->get('Content-Disposition'));
    if ($self->{'decrypted_msg'}->head->get('Content-Type') =~ /multipart/) {
        $self->{'decrypted_msg'}->head->delete('Content-Transfer-Encoding')
            if (
            $self->{'decrypted_msg'}->head->get('Content-Transfer-Encoding'));
    }

    ## Now add headers to message as string
    $self->{'decrypted_msg_as_string'} =
          $self->{'decrypted_msg'}->head->as_string() . "\n"
        . $self->{'decrypted_msg_as_string'};

    $self->{'smime_crypted'} = 'smime_crypted';

    return 1;
}

# input : msg object, return a new message object encrypted
sub smime_encrypt {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s, %s)', @_);
    my $self  = shift;
    my $email = shift;

    my $usercert;

    my $base = Sympa::Site->ssl_cert_dir . '/' . Sympa::Tools::escape_chars($email);
    if (-f "$base\@enc") {
        $usercert = "$base\@enc";
    } else {
        $usercert = "$base";
    }

    if (-r $usercert) {
        my $temporary_file = Sympa::Site->tmpdir . "/" . $email . "." . $PID;

        ## encrypt the incoming message parse it.
        my $cmd = sprintf '%s smime -encrypt -out %s -des3 %s',
            Sympa::Site->openssl, $temporary_file, $usercert;
        Sympa::Log::Syslog::do_log('debug3', '%s', $cmd);
        if (!open(MSGDUMP, "| $cmd")) {
            Sympa::Log::Syslog::do_log('info',
                'Can\'t encrypt message for recipient %s', $email);
        }
        ## don't; cf RFC2633 3.1. netscape 4.7 at least can't parse encrypted
        ## stuff
        ## that contains a whole header again... since MIME::Tools has got no
        ## function
        ## for this, we need to manually extract only the MIME headers...
        ##	$self->head->print(\*MSGDUMP);
        ##	printf MSGDUMP "\n%s", $self->body;
        my $mime_hdr = $self->get_mime_message->head->dup();
        foreach my $t ($mime_hdr->tags()) {
            $mime_hdr->delete($t) unless ($t =~ /^(mime|content)-/i);
        }
        $mime_hdr->print(\*MSGDUMP);

        printf MSGDUMP "\n";
        foreach (@{$self->get_mime_message->body}) {
            printf MSGDUMP '%s', $_;
        }
        ##$self->get_mime_message->bodyhandle->print(\*MSGDUMP);
        close MSGDUMP;
        my $status = $CHILD_ERROR >> 8;
        if ($status) {
            Sympa::Log::Syslog::do_log(
                'err', 'Unable to S/MIME encrypt message: (%d) %s',
                $status, ($openssl_errors{$status} || 'unknown reason')
            );
            return undef;
        }

        ## Get as MIME object
        open(NEWMSG, $temporary_file);
        my $parser = MIME::Parser->new();
        $parser->output_to_core(1);
        unless ($self->{'crypted_message'} = $parser->read(\*NEWMSG)) {
            Sympa::Log::Syslog::do_log('notice', 'Unable to parse message');
            return undef;
        }
        close NEWMSG;

        ## Get body
        open(NEWMSG, $temporary_file);
        my $in_header = 1;
        while (<NEWMSG>) {
            if (!$in_header) {
                $self->{'encrypted_body'} .= $_;
            } else {
                $in_header = 0 if (/^$/);
            }
        }
        close NEWMSG;

        unlink($temporary_file) unless ($main::options{'debug'});

        ## foreach header defined in  the incomming message but undefined in
        ## the
        ## crypted message, add this header in the crypted form.
        my $predefined_headers;
        foreach my $header ($self->{'crypted_message'}->head->tags) {
            $predefined_headers->{lc $header} = 1
                if ($self->{'crypted_message'}->head->get($header));
        }
        foreach my $header (split /\n(?![ \t])/,
            $self->get_mime_message->head->as_string()) {
            next unless $header =~ /^([^\s:]+)\s*:\s*(.*)$/s;
            my ($tag, $val) = ($1, $2);
            $self->{'crypted_message'}->head->add($tag, $val)
                unless $predefined_headers->{lc $tag};
        }
        $self->{'msg'} = $self->{'crypted_message'};
        $self->set_message_as_string($self->{'crypted_message'}->as_string());
        $self->{'smime_crypted'} = 1;
    } else {
        Sympa::Log::Syslog::do_log('err',
            'unable to encrypt message to %s (missing certificate %s)',
            $email, $usercert);
        return undef;
    }

    return 1;
}

# input object msg and listname, output signed message object
sub smime_sign {
    my $self = shift;
    my $list = $self->{'list'};
    Sympa::Log::Syslog::do_log('debug2', '(%s, list=%s)', $self, $list);

    my ($cert, $key) = Sympa::Tools::SMIME::find_keys($list->dir, 'sign');
    my $temporary_file = Sympa::Site->tmpdir . '/' . $list->get_id . "." . $PID;
    my $temporary_pwd  = Sympa::Site->tmpdir . '/pass.' . $PID;

    my ($signed_msg, $pass_option);
    $pass_option = "-passin file:$temporary_pwd" if (Sympa::Site->key_passwd ne '');

    ## Keep a set of header fields ONLY
    ## OpenSSL only needs content type & encoding to generate a
    ## multipart/signed msg
    my $dup_msg = $self->get_mime_message->dup;
    foreach my $field ($dup_msg->head->tags) {
        next if ($field =~ /^(content-type|content-transfer-encoding)$/i);
        $dup_msg->head->delete($field);
    }

    ## dump the incomming message.
    if (!open(MSGDUMP, "> $temporary_file")) {
        Sympa::Log::Syslog::do_log('info', 'Can\'t store message in file %s',
            $temporary_file);
        return undef;
    }
    $dup_msg->print(\*MSGDUMP);
    close(MSGDUMP);

    if (Sympa::Site->key_passwd ne '') {
        unless (POSIX::mkfifo($temporary_pwd, 0600)) {
            Sympa::Log::Syslog::do_log('notice', 'Unable to make fifo for %s',
                $temporary_pwd);
        }
    }
    my $cmd = sprintf
        '%s smime -sign -rand %s/rand -signer %s %s -inkey %s -in %s',
        Sympa::Site->openssl, Sympa::Site->tmpdir, $cert, $pass_option, $key,
        $temporary_file;
    Sympa::Log::Syslog::do_log('debug2', '%s', $cmd);
    unless (open NEWMSG, "$cmd |") {
        Sympa::Log::Syslog::do_log('notice',
            'Cannot sign message (open pipe)');
        return undef;
    }

    if (Sympa::Site->key_passwd ne '') {
        unless (open(FIFO, "> $temporary_pwd")) {
            Sympa::Log::Syslog::do_log('notice', 'Unable to open fifo for %s',
                $temporary_pwd);
        }

        print FIFO Sympa::Site->key_passwd;
        close FIFO;
        unlink($temporary_pwd);
    }

    my $new_message_as_string = '';
    while (<NEWMSG>) {
        $new_message_as_string .= $_;
    }

    my $parser = MIME::Parser->new();

    $parser->output_to_core(1);
    unless ($signed_msg = $parser->parse_data($new_message_as_string)) {
        Sympa::Log::Syslog::do_log('notice', 'Unable to parse message');
        return undef;
    }
    unlink($temporary_file) unless ($main::options{'debug'});

    ## foreach header defined in  the incoming message but undefined in the
    ## crypted message, add this header in the crypted form.
    my $predefined_headers;
    foreach my $header ($signed_msg->head->tags) {
        $predefined_headers->{lc $header} = 1
            if ($signed_msg->head->get($header));
    }
    foreach my $header (split /\n(?![ \t])/,
        $self->get_mime_message->head->as_string()) {
        next unless $header =~ /^([^\s:]+)\s*:\s*(.*)$/s;
        my ($tag, $val) = ($1, $2);
        $signed_msg->head->add($tag, $val)
            unless $predefined_headers->{lc $tag};
    }
    ## Keeping original message string in addition to updated headers.
    my @new_message = split /\n\n/, $new_message_as_string, 2;
    $new_message_as_string =
        $signed_msg->head->as_string() . '\n\n' . $new_message[1];

    $self->{'msg'}           = $signed_msg;
    $self->{'msg_as_string'} = $new_message_as_string;    #FIXME
    $self->check_smime_signature;
    return 1;
}

sub smime_sign_check {
    my $message = shift;
    Sympa::Log::Syslog::do_log('debug2', '(sender=%s, filename=%s)',
        $message->{'sender'}, $message->{'filename'});

    my $is_signed = {};
    $is_signed->{'body'}    = undef;
    $is_signed->{'subject'} = undef;

    ## first step is the msg signing OK ; /tmp/sympa-smime.$PID is created
    ## to store the signer certificat for step two. I known, that's dirty.

    my $temporary_file     = Sympa::Site->tmpdir . "/" . 'smime-sender.' . $PID;
    my $trusted_ca_options = '';
    $trusted_ca_options = "-CAfile " . Sympa::Site->cafile . " " if Sympa::Site->cafile;
    $trusted_ca_options .= "-CApath " . Sympa::Site->capath . " " if Sympa::Site->capath;
    my $cmd = sprintf '%s smime -verify %s -signer %s',
        Sympa::Site->openssl, $trusted_ca_options, $temporary_file;
    Sympa::Log::Syslog::do_log('debug2', '%s', $cmd);

    unless (open MSGDUMP, "| $cmd > /dev/null") {
        Sympa::Log::Syslog::do_log('err',
            'Unable to run command %s to check signature from %s: %s',
            $cmd, $message->{'sender'}, $ERRNO);
        return undef;
    }

    $message->get_mime_message->head->print(\*MSGDUMP);
    print MSGDUMP "\n";
    print MSGDUMP $message->get_message_as_string;
    close MSGDUMP;
    my $status = $CHILD_ERROR >> 8;
    if ($status) {
        Sympa::Log::Syslog::do_log(
            'err', 'Unable to check S/MIME signature: (%d) %s',
            $status, ($openssl_errors{$status} || 'unknown reason')
        );
        return undef;
    }
    ## second step is the message signer match the sender
    ## a better analyse should be performed to extract the signer email.
    my $signer = Sympa::Tools::SMIME::parse_cert({file => $temporary_file});

    unless ($signer->{'email'}{lc($message->{'sender'})}) {
        unlink($temporary_file) unless ($main::options{'debug'});
        Sympa::Log::Syslog::do_log(
            'err',
            "S/MIME signed message, sender(%s) does NOT match signer(%s)",
            $message->{'sender'},
            join(',', keys %{$signer->{'email'}})
        );
        return undef;
    }

    Sympa::Log::Syslog::do_log(
        'debug',
        "S/MIME signed message, signature checked and sender match signer(%s)",
        join(',', keys %{$signer->{'email'}})
    );
    ## store the signer certificat
    unless (-d Sympa::Site->ssl_cert_dir) {
        if (mkdir(Sympa::Site->ssl_cert_dir, 0775)) {
            Sympa::Log::Syslog::do_log('info', 'creating spool %s',
                Sympa::Site->ssl_cert_dir);
        } else {
            Sympa::Log::Syslog::do_log('err',
                'Unable to create user certificat directory %s',
                Sympa::Site->ssl_cert_dir);
        }
    }

    ## It gets a bit complicated now. openssl smime -signer only puts
    ## the _signing_ certificate into the given file; to get all included
    ## certs, we need to extract them from the signature proper, and then
    ## we need to check if they are for our user (CA and intermediate certs
    ## are also included), and look at the purpose:
    ## "S/MIME signing : Yes/No"
    ## "S/MIME encryption : Yes/No"
    my $certbundle = Sympa::Site->tmpdir . "/certbundle.$PID";
    my $tmpcert    = Sympa::Site->tmpdir . "/cert.$PID";
    my $nparts     = $message->get_mime_message->parts;
    my $extracted  = 0;
    Sympa::Log::Syslog::do_log('debug3', 'smime_sign_check: parsing %d parts',
        $nparts);
    if ($nparts == 0) {    # could be opaque signing...
        $extracted += Sympa::Tools::SMIME::extract_certs($message->get_mime_message,
            $certbundle);
    } else {
        for (my $i = 0; $i < $nparts; $i++) {
            my $part = $message->get_mime_message->parts($i);
            $extracted += Sympa::Tools::SMIME::extract_certs($part, $certbundle);
            last if $extracted;
        }
    }

    unless ($extracted) {
        Sympa::Log::Syslog::do_log('err',
            "No application/x-pkcs7-* parts found");
        return undef;
    }

    unless (open(BUNDLE, $certbundle)) {
        Sympa::Log::Syslog::do_log('err', "Can't open cert bundle %s: %s",
            $certbundle, $ERRNO);
        return undef;
    }

    ## read it in, split on "-----END CERTIFICATE-----"
    my $cert = '';
    my (%certs);
    while (<BUNDLE>) {
        $cert .= $_;
        if (/^-----END CERTIFICATE-----$/) {
            my $workcert = $cert;
            $cert = '';
            unless (open(CERT, ">$tmpcert")) {
                Sympa::Log::Syslog::do_log('err', "Can't create %s: %s",
                    $tmpcert, $ERRNO);
                return undef;
            }
            print CERT $workcert;
            close(CERT);
            my ($parsed) = Sympa::Tools::SMIME::parse_cert({file => $tmpcert});
            unless ($parsed) {
                Sympa::Log::Syslog::do_log('err',
                    'No result from parse_cert');
                return undef;
            }
            unless ($parsed->{'email'}) {
                Sympa::Log::Syslog::do_log('debug',
                    'No email in cert for %s, skipping',
                    $parsed->{subject});
                next;
            }

            Sympa::Log::Syslog::do_log(
                'debug2',
                "Found cert for <%s>",
                join(',', keys %{$parsed->{'email'}})
            );
            if ($parsed->{'email'}{lc($message->{'sender'})}) {
                if (   $parsed->{'purpose'}{'sign'}
                    && $parsed->{'purpose'}{'enc'}) {
                    $certs{'both'} = $workcert;
                    Sympa::Log::Syslog::do_log('debug',
                        'Found a signing + encryption cert');
                } elsif ($parsed->{'purpose'}{'sign'}) {
                    $certs{'sign'} = $workcert;
                    Sympa::Log::Syslog::do_log('debug',
                        'Found a signing cert');
                } elsif ($parsed->{'purpose'}{'enc'}) {
                    $certs{'enc'} = $workcert;
                    Sympa::Log::Syslog::do_log('debug',
                        'Found an encryption cert');
                }
            }
            last if (($certs{'both'}) || ($certs{'sign'} && $certs{'enc'}));
        }
    }
    close(BUNDLE);
    if (!($certs{both} || ($certs{sign} || $certs{enc}))) {
        Sympa::Log::Syslog::do_log(
            'err',
            "Could not extract certificate for %s",
            join(',', keys %{$signer->{'email'}})
        );
        return undef;
    }
    ## OK, now we have the certs, either a combined sign+encryption one
    ## or a pair of single-purpose. save them, as email@addr if combined,
    ## or as email@addr@sign / email@addr@enc for split certs.
    foreach my $c (keys %certs) {
        my $fn = Sympa::Site->ssl_cert_dir . '/'
            . Sympa::Tools::escape_chars(lc($message->{'sender'}));
        if ($c ne 'both') {
            unlink($fn);    # just in case there's an old cert left...
            $fn .= "\@$c";
        } else {
            unlink("$fn\@enc");
            unlink("$fn\@sign");
        }
        Sympa::Log::Syslog::do_log('debug', 'Saving %s cert in %s', $c, $fn);
        unless (open(CERT, ">$fn")) {
            Sympa::Log::Syslog::do_log('err',
                'Unable to create certificate file %s: %s',
                $fn, $ERRNO);
            return undef;
        }
        print CERT $certs{$c};
        close(CERT);
    }

    unless ($main::options{'debug'}) {
        unlink($temporary_file);
        unlink($tmpcert);
        unlink($certbundle);
    }

    $is_signed->{'body'} = 'smime';

    # future version should check if the subject was part of the SMIME
    # signature.
    $is_signed->{'subject'} = $signer;

    if ($is_signed->{'body'}) {
        $message->{'smime_signed'}  = 1;
        $message->{'smime_subject'} = $is_signed->{'subject'};
    }

    return 1;
}

sub get_mime_message {
    my $self = shift;
    if ($self->{'smime_crypted'}) {
        return $self->{'decrypted_msg'};
    }
    return $self->{'msg'};
}

=over 4

=item as_entity

I<Instance method>.
Returns message content as a L<MIME::Entity> object.

=back

=cut

sub as_entity {
    my $self = shift;
    return $self->{'msg'};
}

sub get_message_as_string {
    my $self = shift;
    if ($self->{'smime_crypted'}) {
        return $self->{'decrypted_msg_as_string'};
    }
    return $self->{'msg_as_string'};
}

sub set_message_as_string {
    my $self = shift;

    $self->{'msg_as_string'} = shift;
}

# Internal use.
sub reset_message_from_entity {
    my $self   = shift;
    my $entity = shift;

    unless (ref($entity) =~ /^MIME/) {
        Sympa::Log::Syslog::do_log('err',
            'Can not reset a message by starting from object %s',
            ref $entity);
        return undef;
    }
    $self->{'msg'}           = $entity;
    $self->{'msg_as_string'} = $entity->as_string();
    if ($self->is_crypted) {
        $self->{'decrypted_msg'}           = $entity;
        $self->{'decrypted_msg_as_string'} = $entity->as_string();
    }
    return 1;
}

=over 4

=item as_string

I<Instance method>.
Returns message content as a string.

=back

=cut

sub as_string {
    my $self = shift;
    return $self->{'msg_as_string'};
}

sub get_msg_id {
    my $self = shift;
    unless ($self->{'id'}) {
        $self->{'id'} = $self->get_mime_message->head->get('Message-Id');
        chomp $self->{'id'} if $self->{'id'};
    }
    return $self->{'id'};
}

sub is_signed {
    my $self = shift;
    return $self->{'protected'};
}

sub is_crypted {
    my $self = shift;
    unless (defined $self->{'smime_crypted'}) {
        $self->decrypt;
    }
    return $self->{'smime_crypted'};
}

sub has_html_part {
    my $self = shift;
    $self->check_message_structure
        unless ($self->{'structure_already_checked'});
    return $self->{'has_html_part'};
}

sub has_text_part {
    my $self = shift;
    $self->check_message_structure
        unless ($self->{'structure_already_checked'});
    return $self->{'has_text_part'};
}

sub has_attachments {
    my $self = shift;
    $self->check_message_structure
        unless ($self->{'structure_already_checked'});
    return $self->{'has_attachments'};
}

## Make a multipart/alternative, a singlepart
sub check_message_structure {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s)', @_);
    my $self = shift;
    my $msg  = shift;
    $msg ||= $self->get_mime_message->dup;
    $self->{'structure_already_checked'} = 1;
    if ($msg->effective_type() =~ /^multipart\/alternative/) {
        foreach my $part ($msg->parts) {
            if (($part->effective_type() =~ /^text\/html$/)
                || (   ($part->effective_type() =~ /^multipart\/related$/)
                    && $part->parts
                    && ($part->parts(0)->effective_type() =~ /^text\/html$/))
                ) {
                Sympa::Log::Syslog::do_log('debug3', 'Found html part');
                $self->{'has_html_part'} = 1;
            } elsif ($part->effective_type() =~ /^text\/plain$/) {
                Sympa::Log::Syslog::do_log('debug3', 'Found text part');
                $self->{'has_text_part'} = 1;
            } else {
                Sympa::Log::Syslog::do_log('debug3', 'Found attachment: %s',
                    $part->effective_type());
                $self->{'has_attachments'} = 1;
            }
        }
    } elsif ($msg->effective_type() =~ /multipart\/signed/) {
        my @parts = $msg->parts();
        ## Only keep the first part
        $msg->parts([$parts[0]]);
        $msg->make_singlepart();
        $self->check_message_structure($msg);

    } elsif ($msg->effective_type() =~ /^multipart/) {
        Sympa::Log::Syslog::do_log('debug3', 'Found multipart: %s',
            $msg->effective_type());
        foreach my $part ($msg->parts) {
            next unless (defined $part);    ## Skip empty parts
            if ($part->effective_type() =~ /^multipart\/alternative/) {
                $self->check_message_structure($part);
            } else {
                Sympa::Log::Syslog::do_log('debug3', 'Found attachment: %s',
                    $part->effective_type());
                $self->{'has_attachments'} = 1;
            }
        }
    }
}

## Add footer/header to a message
sub add_parts {
    my $self = shift;
    unless ($self->{'list'}) {
        Sympa::Log::Syslog::do_log('err',
            'The message %s has no list context; No header/footer to add',
            $self);
        return undef;
    }
    Sympa::Log::Syslog::do_log('debug3', '(%s, list=%s, type=%s)',
        $self, $self->{'list'}, $self->{'list'}->footer_type);

    my $msg      = $self->get_mime_message;
    my $type     = $self->{'list'}->footer_type;
    my $listdir  = $self->{'list'}->dir;
    my $eff_type = $msg->effective_type || 'text/plain';

    ## Signed or encrypted messages won't be modified.
    if ($eff_type =~ /^multipart\/(signed|encrypted)$/i) {
        return $msg;
    }

    my $header;
    foreach my $file (
        "$listdir/message.header",
        "$listdir/message.header.mime",
        Sympa::Site->etc . '/mail_tt2/message.header',
        Sympa::Site->etc . '/mail_tt2/message.header.mime'
        ) {
        if (-f $file) {
            unless (-r $file) {
                Sympa::Log::Syslog::do_log('notice', 'Cannot read %s', $file);
                next;
            }
            $header = $file;
            last;
        }
    }

    my $footer;
    foreach my $file (
        "$listdir/message.footer",
        "$listdir/message.footer.mime",
        Sympa::Site->etc . '/mail_tt2/message.footer',
        Sympa::Site->etc . '/mail_tt2/message.footer.mime'
        ) {
        if (-f $file) {
            unless (-r $file) {
                Sympa::Log::Syslog::do_log('notice', 'Cannot read %s', $file);
                next;
            }
            $footer = $file;
            last;
        }
    }

    ## No footer/header
    unless (($footer and -s $footer) or ($header and -s $header)) {
        return undef;
    }

    if ($type eq 'append') {
        ## append footer/header
        my ($footer_msg, $header_msg);
        if ($header and -s $header) {
            open HEADER, $header;
            $header_msg = join '', <HEADER>;
            close HEADER;
            $header_msg = '' unless $header_msg =~ /\S/;
        }
        if ($footer and -s $footer) {
            open FOOTER, $footer;
            $footer_msg = join '', <FOOTER>;
            close FOOTER;
            $footer_msg = '' unless $footer_msg =~ /\S/;
        }
        if (length $header_msg or length $footer_msg) {
            if (_append_parts($msg, $header_msg, $footer_msg)) {
                $msg->sync_headers(Length => 'COMPUTE')
                    if $msg->head->get('Content-Length');
            }
        }
    } else {
        ## MIME footer/header
        my $parser = MIME::Parser->new();
        $parser->output_to_core(1);

        if (   $eff_type =~ /^multipart\/alternative/i
            || $eff_type =~ /^multipart\/related/i) {
            Sympa::Log::Syslog::do_log('debug3',
                'Making message %s into multipart/mixed', $self);
            $msg->make_multipart("mixed", Force => 1);
        }

        if ($header and -s $header) {
            if ($header =~ /\.mime$/) {
                my $header_part;
                eval { $header_part = $parser->parse_in($header); };
                if ($EVAL_ERROR) {
                    Sympa::Log::Syslog::do_log('err',
                        'Failed to parse MIME data %s: %s',
                        $header, $parser->last_error);
                } else {
                    $msg->make_multipart unless $msg->is_multipart;
                    $msg->add_part($header_part, 0);  ## Add AS FIRST PART (0)
                }
                ## text/plain header
            } else {
                $msg->make_multipart unless $msg->is_multipart;
                my $header_part = build MIME::Entity
                    Path       => $header,
                    Type       => "text/plain",
                    Filename   => undef,
                    'X-Mailer' => undef,
                    Encoding   => "8bit",
                    Charset    => "UTF-8";
                $msg->add_part($header_part, 0);
            }
        }
        if ($footer and -s $footer) {
            if ($footer =~ /\.mime$/) {
                my $footer_part;
                eval { $footer_part = $parser->parse_in($footer); };
                if ($EVAL_ERROR) {
                    Sympa::Log::Syslog::do_log('err',
                        'Failed to parse MIME data %s: %s',
                        $footer, $parser->last_error);
                } else {
                    $msg->make_multipart unless $msg->is_multipart;
                    $msg->add_part($footer_part);
                }
                ## text/plain footer
            } else {
                $msg->make_multipart unless $msg->is_multipart;
                $msg->attach(
                    Path       => $footer,
                    Type       => "text/plain",
                    Filename   => undef,
                    'X-Mailer' => undef,
                    Encoding   => "8bit",
                    Charset    => "UTF-8"
                );
            }
        }
    }

    return $msg;
}

## Append header/footer to text/plain body.
## Note: As some charsets (e.g. UTF-16) are not compatible to US-ASCII,
##   we must concatenate decoded header/body/footer and at last encode it.
## Note: With BASE64 transfer-encoding, newline must be normalized to CRLF,
##   however, original body would be intact.
sub _append_parts {
    my $part       = shift;
    my $header_msg = shift || '';
    my $footer_msg = shift || '';

    my $enc = $part->head->mime_encoding;

    # Parts with nonstandard encodings aren't modified.
    if ($enc and $enc !~ /^(?:base64|quoted-printable|[78]bit|binary)$/i) {
        return undef;
    }
    my $eff_type = $part->effective_type || 'text/plain';
    my $body;
    my $io;

    ## Signed or encrypted parts aren't modified.
    if ($eff_type =~ m{^multipart/(signed|encrypted)$}i) {
        return undef;
    }

    ## Skip attached parts.
    my $disposition = $part->head->mime_attr('Content-Disposition');
    return undef
        if $disposition and uc $disposition ne 'INLINE';

    ## Preparing header and footer for inclusion.
    if ($eff_type eq 'text/plain' or $eff_type eq 'text/html') {
        if (length $header_msg or length $footer_msg) {

            ## Only decodable bodies are allowed.
            my $bodyh = $part->bodyhandle;
            if ($bodyh) {
                return undef if $bodyh->is_encoded;
                $body = $bodyh->as_string();
            } else {
                $body = '';
            }

            $body = _append_footer_header_to_part(
                {   'part'     => $part,
                    'header'   => $header_msg,
                    'footer'   => $footer_msg,
                    'eff_type' => $eff_type,
                    'body'     => $body
                }
            );
            return undef unless defined $body;

            $io = $bodyh->open('w');
            unless (defined $io) {
                Sympa::Log::Syslog::do_log('err',
                    'Failed to save message: %s', $ERRNO);
                return undef;
            }
            $io->print($body);
            $io->close;
            $part->sync_headers(Length => 'COMPUTE')
                if $part->head->get('Content-Length');

            return 1;
        }
    } elsif ($eff_type eq 'multipart/mixed') {
        ## Append to the first part, since other parts will be "attachments".
        if ($part->parts
            and _append_parts($part->parts(0), $header_msg, $footer_msg)) {
            return 1;
        }
    } elsif ($eff_type eq 'multipart/alternative') {
        ## We try all the alternatives
        my $r = undef;
        foreach my $p ($part->parts) {
            $r = 1
                if _append_parts($p, $header_msg, $footer_msg);
        }
        return $r if $r;
    } elsif ($eff_type eq 'multipart/related') {
        ## Append to the first part, since other parts will be "attachments".
        if ($part->parts
            and _append_parts($part->parts(0), $header_msg, $footer_msg)) {
            return 1;
        }
    }

    ## We couldn't find any parts to modify.
    return undef;
}

# Styles to cancel local CSS.
my $div_style =
    'background: transparent; border: none; clear: both; display: block; float: none; position: static';

sub _append_footer_header_to_part {
    my $data = shift;

    my $part       = $data->{'part'};
    my $header_msg = $data->{'header'};
    my $footer_msg = $data->{'footer'};
    my $eff_type   = $data->{'eff_type'};
    my $body       = $data->{'body'};

    my $cset;

    ## Detect charset.  If charset is unknown, detect 7-bit charset.
    my $charset = $part->head->mime_attr('Content-Type.Charset');
    $cset = MIME::Charset->new($charset || 'NONE');
    unless ($cset->decoder) {

        # n.b. detect_7bit_charset() in MIME::Charset prior to 1.009.2 doesn't
        # work correctly.
        my (undef, $charset) =
            MIME::Charset::body_encode($body, '', Detect7Bit => 'YES');
        $cset = MIME::Charset->new($charset)
            if $charset;
    }
    unless ($cset->decoder) {

        #Sympa::Log::Syslog::do_log('err', 'Unknown charset "%s"', $charset);
        return undef;
    }

    ## Decode body to Unicode, since encode_entities() and newline
    ## normalization will break texts with several character sets (UTF-16/32,
    ## ISO-2022-JP, ...).
    eval {
        $body = $cset->decode($body, 1);
        $header_msg = Encode::decode_utf8($header_msg, 1);
        $footer_msg = Encode::decode_utf8($footer_msg, 1);
    };
    return undef if $EVAL_ERROR;

    my $new_body;
    if ($eff_type eq 'text/plain') {
        Sympa::Log::Syslog::do_log('debug3', "Treating text/plain part");

        ## Add newlines. For BASE64 encoding they also must be normalized.
        if (length $header_msg) {
            $header_msg .= "\n" unless $header_msg =~ /\n\z/;
        }
        if (length $footer_msg and length $body) {
            $body .= "\n" unless $body =~ /\n\z/;
        }
        if (uc($part->head->mime_attr('Content-Transfer-Encoding') || '') eq
            'BASE64') {
            $header_msg =~ s/\r\n|\r|\n/\r\n/g;
            $body       =~ s/(\r\n|\r|\n)\z/\r\n/;    # only at end
            $footer_msg =~ s/\r\n|\r|\n/\r\n/g;
        }

        $new_body = $header_msg . $body . $footer_msg;
    } elsif ($eff_type eq 'text/html') {
        Sympa::Log::Syslog::do_log('debug3', "Treating text/html part");

        # Escape special characters.
        $header_msg = encode_entities($header_msg, '<>&"');
        $header_msg =~ s/(\r\n|\r|\n)$//;        # strip the last newline.
        $header_msg =~ s,(\r\n|\r|\n),<br/>,g;
        $footer_msg = encode_entities($footer_msg, '<>&"');
        $footer_msg =~ s/(\r\n|\r|\n)$//;        # strip the last newline.
        $footer_msg =~ s,(\r\n|\r|\n),<br/>,g;

        my @bodydata = split '</body>', $body;
        if (length $header_msg) {
            $new_body = sprintf '<div style="%s">%s</div>',
                $div_style, $header_msg;
        } else {
            $new_body = '';
        }
        my $i = -1;
        foreach my $html_body_bit (@bodydata) {
            $new_body .= $html_body_bit;
            $i++;
            if ($i == $#bodydata and length $footer_msg) {
                $new_body .= sprintf '<div style="%s">%s</div></body>',
                    $div_style, $footer_msg;
            } else {
                $new_body .= '</body>';
            }
        }
    }

    ## Only encodable footer/header are allowed.
    eval { $new_body = $cset->encode($new_body, 1); };
    return undef if $EVAL_ERROR;

    return $new_body;
}

=over 4

=item personalize ( LIST, [ RCPT ] )

I<Instance method>.
Personalize a message with custom attributes of a user.

=over 4

=item LIST

L<List> object.

=item RCPT

Recipient.

=back

Returns modified message itself, or C<undef> if error occurred.
Note that message can be modified in case of error.

=back

=cut

sub personalize {
    my $self = shift;
    my $list = shift;
    my $rcpt = shift || undef;

    my $entity = _personalize_entity($self->as_entity(), $list, $rcpt);
    unless (defined $entity) {
        return undef;
    }
    if ($entity) {
        $self->{'msg_as_string'} = $entity->as_string();
    }
    return $self;
}

sub _personalize_entity {
    my $entity = shift;
    my $list   = shift;
    my $rcpt   = shift;

    my $enc = $entity->head->mime_encoding;

    # Parts with nonstandard encodings aren't modified.
    if ($enc and $enc !~ /^(?:base64|quoted-printable|[78]bit|binary)$/i) {
        return $entity;
    }
    my $eff_type = $entity->effective_type || 'text/plain';

    # Signed or encrypted parts aren't modified.
    if ($eff_type =~ m{^multipart/(signed|encrypted)$}) {
        return $entity;
    }

    if ($entity->parts) {
        foreach my $part ($entity->parts) {
            unless (defined _personalize_entity($part, $list, $rcpt)) {
                Sympa::Log::Syslog::do_log('err',
                    'Failed to personalize message part');
                return undef;
            }
        }
    } elsif ($eff_type =~ m{^(?:multipart|message)(?:/|\Z)}i) {

        # multipart or message types without subparts.
        return $entity;
    } elsif (MIME::Tools::textual_type($eff_type)) {
        my ($charset, $in_cset, $bodyh, $body, $utf8_body);

        # Encoded body or null body won't be modified.
        $bodyh = $entity->bodyhandle;
        if (!$bodyh or $bodyh->is_encoded) {
            return $entity;
        }
        $body = $bodyh->as_string();
        unless (defined $body and length $body) {
            return $entity;
        }

        ## Detect charset.  If charset is unknown, detect 7-bit charset.
        $charset = $entity->head->mime_attr('Content-Type.Charset');
        $in_cset = MIME::Charset->new($charset || 'NONE');
        unless ($in_cset->decoder) {
            $in_cset =
                MIME::Charset->new(MIME::Charset::detect_7bit_charset($body)
                    || 'NONE');
        }
        unless ($in_cset->decoder) {
            Sympa::Log::Syslog::do_log('err', 'Unknown charset "%s"',
                $charset);
            return undef;
        }
        $in_cset->encoder($in_cset);    # no charset conversion

        ## Only decodable bodies are allowed.
        eval { $utf8_body = Encode::encode_utf8($in_cset->decode($body, 1)); };
        if ($EVAL_ERROR) {
            Sympa::Log::Syslog::do_log('err', 'Cannot decode by charset "%s"',
                $charset);
            return undef;
        }

        ## PARSAGE ##
        $utf8_body = personalize_text($utf8_body, $list, $rcpt);
        unless (defined $utf8_body) {
            Sympa::Log::Syslog::do_log('err', 'error personalizing message');
            return undef;
        }

        ## Data not encodable by original charset will fallback to UTF-8.
        my ($newcharset, $newenc);
        ($body, $newcharset, $newenc) =
            $in_cset->body_encode(Encode::decode_utf8($utf8_body),
            Replacement => 'FALLBACK');
        unless ($newcharset) {    # bug in MIME::Charset?
            Sympa::Log::Syslog::do_log('err',
                'Can\'t determine output charset');
            return undef;
        } elsif ($newcharset ne $in_cset->as_string()) {
            $entity->head->mime_attr('Content-Transfer-Encoding' => $newenc);
            $entity->head->mime_attr('Content-Type.Charset' => $newcharset);

            ## normalize newline to CRLF if transfer-encoding is BASE64.
            $body =~ s/\r\n|\r|\n/\r\n/g
                if $newenc
                    and $newenc eq 'BASE64';
        } else {
            ## normalize newline to CRLF if transfer-encoding is BASE64.
            $body =~ s/\r\n|\r|\n/\r\n/g
                if $enc
                    and uc $enc eq 'BASE64';
        }

        ## Save new body.
        my $io = $bodyh->open('w');
        unless ($io
            and $io->print($body)
            and $io->close) {
            Sympa::Log::Syslog::do_log('err', 'Can\'t write in Entity: %s',
                $ERRNO);
            return undef;
        }
        $entity->sync_headers(Length => 'COMPUTE')
            if $entity->head->get('Content-Length');

        return $entity;
    }

    return $entity;
}

=over 4

=item test_personalize ( LIST )

I<Instance method>.
Test if personalization can be performed successfully over all subscribers
of LIST.

Returns C<1> if succeed, or C<undef>.

=back

=cut

sub test_personalize {
    my $self = shift;
    my $list = shift;

    return 1
        unless $list->merge_feature
            and $list->merge_feature eq 'on';

    $list->get_list_members_per_mode($self);
    foreach my $mode (keys %{$self->{'rcpts_by_mode'}}) {
        my $message = dclone $self;
        $message->prepare_message_according_to_mode($mode);

        foreach my $rcpt (
            @{$message->{'rcpts_by_mode'}{$mode}{'verp'}   || []},
            @{$message->{'rcpts_by_mode'}{$mode}{'noverp'} || []}
            ) {
            unless ($message->personalize($list, $rcpt)) {
                return undef;
            }
        }
    }
    return 1;
}

=over 4

=item personalize_text ( BODY, LIST, [ RCPT ] )

I<Function>.
Retrieves the customized data of the
users then parse the text. It returns the
personalized text.

=over 4

=item BODY

Message body with the TT2.

=item LIST

L<List> object

=item RCPT

The recipient email.

=back

Returns customized text, or C<undef> if error occurred.

=back

=cut

sub personalize_text {
    my $body = shift;
    my $list = shift;
    my $rcpt = shift || undef;

    my $options;
    $options->{'is_not_template'} = 1;

    my $user = $list->user('member', $rcpt);
    if ($user) {
        $user->{'escaped_email'} = URI::Escape::uri_escape($rcpt);
        $user->{'friendly_date'} =
            Sympa::Language::gettext_strftime("%d %b %Y  %H:%M", localtime($user->{'date'}));
    }

    # this method as been removed because some users may forward
    # authentication link
    # $user->{'fingerprint'} = Sympa::Tools::get_fingerprint($rcpt);

    my $data = {
        'listname'    => $list->name,
        'robot'       => $list->domain,
        'wwsympa_url' => $list->robot->wwsympa_url,
    };
    $data->{'user'} = $user if $user;

    # Parse the TT2 in the message : replace the tags and the parameters by
    # the corresponding values
    my $output;
    unless (Sympa::Template::parse_tt2($data, \$body, \$output, '', $options)) {
        return undef;
    }

    return $output;
}

sub prepare_message_according_to_mode {
    my $self = shift;
    my $mode = shift;
    Sympa::Log::Syslog::do_log('debug3', '(msg_id=%s, mode=%s)',
        $self->get_msg_id, $mode);
    ##Prepare message for normal reception mode
    if ($mode eq 'mail') {
        $self->prepare_reception_mail;
    } elsif (($mode eq 'nomail')
        || ($mode eq 'summary')
        || ($mode eq 'digest')
        || ($mode eq 'digestplain')) {
        ##Prepare message for notice reception mode
    } elsif ($mode eq 'notice') {
        $self->prepare_reception_notice;
        ##Prepare message for txt reception mode
    } elsif ($mode eq 'txt') {
        $self->prepare_reception_txt;
        ##Prepare message for html reception mode
    } elsif ($mode eq 'html') {
        $self->prepare_reception_html;
        ##Prepare message for urlize reception mode
    } elsif ($mode eq 'url') {
        $self->prepare_reception_urlize;
    } else {
        Sympa::Log::Syslog::do_log('err',
            'Unknown variable/reception mode %s', $mode);
        return undef;
    }

    unless (defined $self) {
        Sympa::Log::Syslog::do_log('err', "Failed to create Message object");
        return undef;
    }
    return 1;

}

sub prepare_reception_mail {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug3',
        'preparing message for mail reception mode');
    ## Add footer and header
    return 0 if ($self->is_signed);
    my $new_msg = $self->add_parts;
    if (defined $new_msg) {
        $self->{'msg'}           = $new_msg;
        $self->{'altered'}       = '_ALTERED_';
        $self->{'msg_as_string'} = $new_msg->as_string();
    } else {
        Sympa::Log::Syslog::do_log('err', 'Part addition failed');
        return undef;
    }
    return 1;
}

sub prepare_reception_notice {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug3',
        'preparing message for notice reception mode');
    my $notice_msg = $self->get_mime_message->dup;
    $notice_msg->bodyhandle(undef);
    $notice_msg->parts([]);
    if ((   $notice_msg->head->get('Content-Type') =~
            /application\/(x-)?pkcs7-mime/i
        )
        && ($notice_msg->head->get('Content-Type') !~ /signed-data/i)
        ) {
        $notice_msg->head->delete('Content-Disposition');
        $notice_msg->head->delete('Content-Description');
        $notice_msg->head->replace('Content-Type',
            'text/plain; charset="US-ASCII"');
        $notice_msg->head->replace('Content-Transfer-Encoding', '7BIT');
    }
    $self->reset_message_from_entity($notice_msg);
    undef $self->{'smime_crypted'};
    return 1;
}

sub prepare_reception_txt {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug3',
        'preparing message for txt reception mode');
    return 0 if ($self->is_signed);
    if (Sympa::Tools::Message::as_singlepart($self->get_mime_message, 'text/plain')) {
        Sympa::Log::Syslog::do_log('notice',
            'Multipart message changed to text singlepart');
    }
    ## Add a footer
    $self->reset_message_from_entity($self->add_parts);
    return 1;
}

sub prepare_reception_html {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug3',
        'preparing message for html reception mode');
    return 0 if ($self->is_signed);
    if (Sympa::Tools::Message::as_singlepart($self->get_mime_message, 'text/html')) {
        Sympa::Log::Syslog::do_log('notice',
            'Multipart message changed to html singlepart');
    }
    ## Add a footer
    $self->reset_message_from_entity($self->add_parts);
    return 1;
}

sub prepare_reception_urlize {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug3',
        'preparing message for urlize reception mode');
    return 0 if ($self->is_signed);
    unless ($self->{'list'}) {
        Sympa::Log::Syslog::do_log('err',
            'The message has no list context; Nowhere to place urlized attachments.'
        );
        return undef;
    }

    my $expl = $self->{'list'}->dir . '/urlized';

    unless ((-d $expl) || (mkdir $expl, 0775)) {
        Sympa::Log::Syslog::do_log('err',
            'Unable to create urlize directory %s', $expl);
        return undef;
    }

    my $dir1 =
        Sympa::Tools::clean_msg_id(
        $self->get_mime_message->head->get('Message-ID'));

    ## Clean up Message-ID
    $dir1 = Sympa::Tools::escape_chars($dir1);
    $dir1 = '/' . $dir1;

    unless (mkdir("$expl/$dir1", 0775)) {
        Sympa::Log::Syslog::do_log('err',
            'Unable to create urlize directory %s/%s',
            $expl, $dir1);
        printf "Unable to create urlized directory %s/%s\n", $expl, $dir1;
        return 0;
    }
    my @parts      = ();
    my $i          = 0;
    foreach my $part ($self->get_mime_message->parts()) {
        my $entity =
            _urlize_part($part, $self->{'list'}, $dir1, $i,
            $self->{'list'}->robot->wwsympa_url);
        if (defined $entity) {
            push @parts, $entity;
        } else {
            push @parts, $part;
        }
        $i++;
    }

    ## Replace message parts
    $self->get_mime_message->parts(\@parts);

    ## Add a footer
    $self->reset_message_from_entity($self->add_parts);
    return 1;
}

sub _urlize_part {
    my $message     = shift;
    my $list        = shift;
    my $expl        = $list->dir . '/urlized';
    my $dir         = shift;
    my $i           = shift;
    my $listname    = $list->name;
    my $wwsympa_url = shift;

    my $head     = $message->head;
    my $encoding = $head->mime_encoding;
    my $eff_type = $message->effective_type || 'text/plain';
    return undef
        if $eff_type =~ /multipart\/alternative/gi
            or $eff_type =~ /text\//gi;
    ##  name of the linked file
    my $fileExt = Sympa::Tools::WWW::get_mime_type($head->mime_type);
    if ($fileExt) {
        $fileExt = '.' . $fileExt;
    }
    my $filename;

    if ($head->recommended_filename) {
        $filename = $head->recommended_filename;
    } else {
        if ($head->mime_type =~ /multipart\//i) {
            my $content_type = $head->get('Content-Type');
            $content_type =~ s/multipart\/[^;]+/multipart\/mixed/g;
            $message->head->replace('Content-Type', $content_type);
            my @parts = $message->parts();
            foreach my $i (0 .. $#parts) {
                my $entity =
                    _urlize_part($message->parts($i), $list, $dir, $i,
                    $list->robot->wwsympa_url);
                if (defined $entity) {
                    $parts[$i] = $entity;
                }
            }
            ## Replace message parts
            $message->parts(\@parts);
        }
        $filename = "msg.$i" . $fileExt;
    }

    ##create the linked file
    ## Store body in file
    if (open OFILE, ">$expl/$dir/$filename") {
        my $ct = $message->effective_type || 'text/plain';
        printf OFILE "Content-type: %s", $ct;
        printf OFILE "; Charset=%s", $head->mime_attr('Content-Type.Charset')
            if $head->mime_attr('Content-Type.Charset') =~ /\S/;
        print OFILE "\n\n";
    } else {
        Sympa::Log::Syslog::do_log('notice', 'Unable to open %s/%s/%s',
            $expl, $dir, $filename);
        return undef;
    }

    if ($encoding =~
        /^(binary|7bit|8bit|base64|quoted-printable|x-uu|x-uuencode|x-gzip64)$/
        ) {
        open TMP, ">$expl/$dir/$filename.$encoding";
        $message->print_body(\*TMP);
        close TMP;

        open BODY, "$expl/$dir/$filename.$encoding";
        my $decoder = MIME::Decoder->($encoding);
        $decoder->decode(\*BODY, \*OFILE);
        unlink "$expl/$dir/$filename.$encoding";
    } else {
        $message->print_body(\*OFILE);
    }
    close(OFILE);
    my $file = "$expl/$dir/$filename";
    my $size = (-s $file);

    ## Only URLize files with a moderate size
    if ($size < Sympa::Site->urlize_min_size) {
        unlink "$expl/$dir/$filename";
        return undef;
    }

    ## Delete files created twice or more (with Content-Type.name and Content-
    ## Disposition.filename)
    $message->purge;

    (my $file_name = $filename) =~ s/\./\_/g;

    # do NOT escape '/' chars
    my $file_url = "$wwsympa_url/attach/$listname"
        . Sympa::Tools::escape_chars("$dir/$filename", '/');

    my $parser = MIME::Parser->new();
    $parser->output_to_core(1);
    my $new_part;

    my $lang    = Sympa::Language::GetLang();
    my $charset = Sympa::Language::GetCharset();

    my $tt2_include_path = $list->get_etc_include_path('mail_tt2', $lang);

    Sympa::Template::parse_tt2(
        {   'file_name' => $file_name,
            'file_url'  => $file_url,
            'file_size' => $size,
            'charset'   => $charset
        },
        'urlized_part.tt2',
        \$new_part,
        $tt2_include_path
    );

    my $entity = $parser->parse_data(\$new_part);

    return $entity;
}

=over 4

=item get_id

I<Instance method>.
Get unique ID for object.

=back

=cut

sub get_id {
    my $self = shift;
    return sprintf 'key=%s;id=%s',
        ($self->{'messagekey'} || ''),
        Sympa::Tools::clean_msg_id($self->get_msg_id || '');
}

1;
