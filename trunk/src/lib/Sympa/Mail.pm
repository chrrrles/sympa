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

package Sympa::Mail;

use strict;
use warnings;

use Carp qw(carp croak);
use English qw(-no_match_vars);
use POSIX qw();

use Sympa::Bulk;
use Sympa::Constants;
use Sympa::Log::Syslog;
use Sympa::Site;

my $opensmtp = 0;
my $fh       = 'fh0000000000';    ## File handle for the stream.

my $max_arg;
eval {
    $max_arg = POSIX::sysconf( &POSIX::_SC_ARG_MAX );
};
if ($EVAL_ERROR) {
    $max_arg = 4096;
}

my %pid = ();

my $send_spool;    ## for calling context

### PUBLIC FUNCTIONS ###

####################################################
# public set_send_spool
####################################################
# set in global $send_spool, the concerned spool for
# sending message when it is not done by smtpto
#
# IN : $spool (+): spool concerned by sending
# OUT :
#
####################################################
sub set_send_spool {
    my $spool = pop;

    $send_spool = $spool;
}

#sub mail_file($that, $filename, $rcpt, $data)
#DEPRECATED: Use parse_tt2_messageastring() & sending().

####################################################
# public mail_message
####################################################
# distribute a message to a list, Crypting if needed
#
# IN : -$message(+) : ref(Message)
#      -$from(+) : message from
#      -$robot(+) : robot
#      -{verp=>[on|off]} : a hash to introduce verp parameters, starting just
#      on or off, later will probably introduce optionnal parameters
#      -@rcpt(+) : recipients
#
####################################################
sub mail_message {

    my %params      = @_;
    my $message     = $params{'message'};
    my $list        = $params{'list'};
    my $verp        = $params{'verp'};
    my @rcpt        = @{$params{'rcpt'} || []};
    my $dkim        = $params{'dkim_parameters'};
    my $tag_as_last = $params{'tag_as_last'};
    my $robot       = $list->robot;

    unless (ref $message and $message->isa('Message')) {
        Sympa::Log::Syslog::do_log('err', 'Invalid message parameter');
        return undef;
    }

    # normal return_path (ie used if verp is not enabled)
    my $from = $list->get_address('return_path');

    Sympa::Log::Syslog::do_log(
        'debug2',
        '(from=%s, message=%s, encrypt=%s, verp=%s, %d rcpt, tag_as_last=%s)',
        $from,
        $message,
        $message->{'smime_crypted'},
        $verp,
        scalar(@rcpt),
        $tag_as_last
    );
    return 0 unless @rcpt;

    my ($i, $j, $nrcpt);
    my $size    = 0;
    my $numsmtp = 0;

    ## If message contain a footer or header added by Sympa  use the object
    ## message else
    ## Extract body from original file to preserve signature
    my $msg_body;
    my $msg_header;
    $msg_header = $message->get_mime_message->head;
    ##if (!($message->{'protected'})) {
    ##$msg_body = $message->get_mime_message->body_as_string;
    ##}elsif ($message->{'smime_crypted'}) {
    ##$msg_body = ${$message->{'msg_as_string'}};
    ##}else{
    ## Get body from original message body
    # convert it as a tab with headers as first element
    my @bodysection = split /\n\n/, $message->get_message_as_string;

    # remove headers
    shift @bodysection;

    # convert it back as string
    $msg_body = join("\n\n", @bodysection);
    ##}
    $message->{'body_as_string'} = $msg_body;

    my %rcpt_by_dom;

    my @sendto;
    my @sendtobypacket;

    my $cmd_size =
        length($robot->sendmail) + 1 +
        length($robot->sendmail_args) +
        length(' -N success,delay,failure -V ') + 32 +
        length(" -f $from ");
    my $db_type = Sympa::Site->db_type;

    while (defined($i = shift(@rcpt))) {
        my @k = reverse split(/[\.@]/, $i);
        my @l = reverse split(/[\.@]/, (defined $j ? $j : '@'));

        my $dom;
        if ($i =~ /\@(.*)$/) {
            $dom = $1;
            chomp $dom;
        }
        $rcpt_by_dom{$dom} += 1;
        Sympa::Log::Syslog::do_log('debug3',
            'domain: %s ; rcpt by dom: %s ; limit for this domain: %s',
            $dom, $rcpt_by_dom{$dom}, Sympa::Site->nrcpt_by_domain->{$dom});

        if (

            # number of recipients by each domain
            (   defined Sympa::Site->nrcpt_by_domain->{$dom}
                and $rcpt_by_dom{$dom} >= Sympa::Site->nrcpt_by_domain->{$dom}
            )
            or

            # number of different domains
            (       $j
                and $#sendto >= $robot->avg
                and lc "$k[0] $k[1]" ne lc "$l[0] $l[1]"
            )
            or

            # number of recipients in general, and ARG_MAX limitation
            (   $#sendto >= 0
                and (  $cmd_size + $size + length($i) + 5 > $max_arg
                    or $nrcpt >= $robot->nrcpt)
            )
            or

            # length of recipients field stored into bulkmailer table
            # (these limits might be relaxed by future release of Sympa)
            ($db_type eq 'mysql' and $size + length($i) + 5 > 65535)
            or
            ($db_type !~ /^(mysql|SQLite)$/ and $size + length($i) + 5 > 500)
            ) {
            undef %rcpt_by_dom;

            # do not replace this line by "push @sendtobypacket, \@sendto" !!!
            my @tab = @sendto;
            push @sendtobypacket, \@tab;
            $numsmtp++;
            $nrcpt = $size = 0;
            @sendto = ();
        }

        $nrcpt++;
        $size += length($i) + 5;
        push(@sendto, $i);
        $j = $i;
    }

    if ($#sendto >= 0) {
        $numsmtp++;
        my @tab = @sendto;

        # do not replace this line by push @sendtobypacket, \@sendto !!!
        push @sendtobypacket, \@tab;
    }

    unless (
        sendto(
            'message'       => $message,
            'from'          => $from,
            'rcpt'          => \@sendtobypacket,
            'listname'      => $list->name,
            'priority'      => $list->priority,
            'delivery_date' => $list->get_next_delivery_date,
            'robot'         => $robot,
            'use_bulk'      => 1,
            'verp'          => $verp,
            'dkim'          => $dkim,
            'merge'         => $list->merge_feature,
            'tag_as_last'   => $tag_as_last
        )
        ) {
        Sympa::Log::Syslog::do_log('err', 'Failed to send message to list %s',
            $list);
        return undef;
    }

    return $numsmtp;
}

####################################################
# public mail_forward
####################################################
# forward a message.
#
# IN : -$mmessage(+) : ref(Message)
#      -$from(+) : message from
#      -$rcpt(+) : ref(SCALAR) | ref(ARRAY)  - recipients
#      -$robot(+) : ref(Robot)
# OUT : 1 | undef
#
####################################################
sub mail_forward {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s, %s, %s)', @_);
    my $message = shift;
    my $from    = shift;
    my $rcpt    = shift;
    my $robot   = Sympa::Robot::clean_robot(shift, 1);    #FIXME: may be Site?

    unless (ref $message and $message->isa('Message')) {
        Sympa::Log::Syslog::do_log('err', 'Unexpected parameter type: %s',
            ref $message);
        return undef;
    }
    ## Add an Auto-Submitted header field according to
    ## http://www.tools.ietf.org/html/draft-palme-autosub-01
    $message->get_mime_message->head->add('Auto-Submitted', 'auto-forwarded');
    $message->{'rcpt'} = $rcpt;                    #FIXME: no effect
                                                   #FIXME:
    $message->set_message_as_string($message->get_mime_message->as_string());
    unless (
        defined sending(
            'message'  => $message,
            'rcpt'     => $rcpt,
            'from'     => $from,
            'robot'    => $robot,
            'priority' => $robot->request_priority,
        )
        ) {
        Sympa::Log::Syslog::do_log('err',
            'Impossible to send message %s from %s',
            $message, $from);
        return undef;
    }
    return 1;
}

#####################################################################
# public reaper
#####################################################################
# Non blocking function called by : Sympa::Mail::smtpto(), sympa::main_loop
#  task_manager::INFINITE_LOOP scanning the queue,
#  bounced::infinite_loop scanning the queue,
# just to clean the defuncts list by waiting to any processes and
#  decrementing the counter.
#
# IN : $block
# OUT : $i
#####################################################################
sub reaper {
    my $block = shift;
    my $i;

    $block = 1 unless (defined($block));
    while (($i = waitpid(-1, $block ? POSIX::WNOHANG : 0)) > 0) {
        $block = 1;
        if (!defined($pid{$i})) {
            Sympa::Log::Syslog::do_log('debug2',
                "Reaper waited $i, unknown process to me");
            next;
        }
        $opensmtp--;
        delete($pid{$i});
    }
    Sympa::Log::Syslog::do_log(
        'debug2',
        "Reaper unwaited PIDs : %s\nOpen = %s\n",
        join(' ', sort keys %pid), $opensmtp
    );
    return $i;
}

### PRIVATE FUNCTIONS ###

####################################################
# sendto
####################################################
# send messages, S/MIME encryption if needed,
# grouped sending (or not if encryption)
#
# IN: $message (+): Message object
#     $from (+): message from
#     $rcpt(+) : ref(SCALAR) | ref(ARRAY) - message recipients
#     $listname : use only to format return_path if VERP on
#     $robot(+) : ref(Robot)
#     $encrypt : 'smime_crypted' | undef
#     $verp : 1| undef
#     $use_bulk : if defined,  send message using bulk
#
# OUT : 1 - call to sending
#
####################################################
sub sendto {
    my %params = @_;

    my $message     = $params{'message'};
    my $msg_header  = $message->get_mime_message->head;
    my $msg_body    = $message->{'body_as_string'};
    my $from        = $params{'from'};
    my $rcpt        = $params{'rcpt'};
    my $listname    = $params{'listname'};
    my $robot       = Sympa::Robot::clean_robot($params{'robot'});  # may not be Site
    my $priority    = $params{'priority'};
    my $verp        = $params{'verp'};
    my $merge       = $params{'merge'};
    my $dkim        = $params{'dkim'};
    my $use_bulk    = $params{'use_bulk'};
    my $tag_as_last = $params{'tag_as_last'};

    Sympa::Log::Syslog::do_log(
        'debug2',
        'Sympa::Mail::sendto(from : %s,listname: %s, encrypt : %s, verp : %s, priority = %s, last: %s, use_bulk: %s',
        $from,
        $listname,
        $message->is_crypted,
        $verp,
        $priority,
        $tag_as_last,
        $use_bulk
    );

    my $delivery_date = $params{'delivery_date'};

    # if not specified, delivery tile is right now (used for sympa messages
    # etc)
    $delivery_date = time()
        unless $delivery_date;

    if ($message->is_crypted) {

        # encrypt message for each rcpt and send the message
        # this MUST be moved to the bulk mailer. This way, merge will be
        # applied after the SMIME encryption is applied ! This is a bug !
        foreach my $bulk_of_rcpt (@{$rcpt}) {

            # trace foreach my $unique_rcpt (@{$bulk_of_rcpt}) {
            foreach my $email (@{$bulk_of_rcpt}) {
                if ($email !~ /@/) {
                    Sympa::Log::Syslog::do_log('err',
                        "incorrect call for encrypt with incorrect number of recipient"
                    );
                    return undef;
                }
                unless ($message->smime_encrypt($email)) {
                    Sympa::Log::Syslog::do_log('err',
                        "Failed to encrypt message");
                    return undef;
                }
                unless (
                    sending(
                        'message'       => $message,
                        'rcpt'          => $email,
                        'from'          => $from,
                        'listname'      => $listname,
                        'robot'         => $robot,
                        'priority'      => $priority,
                        'delivery_date' => $delivery_date,
                        'use_bulk'      => $use_bulk,
                        'tag_as_last'   => $tag_as_last
                    )
                    ) {
                    Sympa::Log::Syslog::do_log('err',
                        "Failed to send encrypted message");
                    return undef;
                }
                $tag_as_last = 0;
            }
        }
    } else {
        $message->{'msg_as_string'} =
            $msg_header->as_string() . "\n" . $msg_body;
        my $result = sending(
            'message'       => $message,
            'rcpt'          => $rcpt,
            'from'          => $from,
            'listname'      => $listname,
            'robot'         => $robot,
            'priority'      => $priority,
            'delivery_date' => $delivery_date,
            'verp'          => $verp,
            'merge'         => $merge,
            'use_bulk'      => $use_bulk,
            'dkim'          => $dkim,
            'tag_as_last'   => $tag_as_last
        );
        return $result;

    }
    return 1;
}

####################################################
# sending
####################################################
# send a message using smpto function or puting it
# in spool according to the context
# Signing if needed
#
#
# IN : -$msg(+) : ref(MIME::Entity) | string - message to send
#      -$rcpt(+) : ref(SCALAR) | ref(ARRAY) - recipients
#       (for SMTP : "RCPT To:" field)
#      -$from(+) : for SMTP "MAIL From:" field , for
#        spool sending : "X-Sympa-From" field
#      -$robot(+) : ref(Robot) | "Site"
#      -$listname : listname | ''
#      -$sign_mode(+) : 'smime' | 'none' for signing
#      -$verp
#      -dkim : a hash for dkim parameters
#
# OUT : 1 - call to smtpto (sendmail) | 0 - push in spool
#           | undef
#
####################################################
sub sending {
    my %params      = @_;
    my $message     = $params{'message'};
    my $rcpt        = $params{'rcpt'};
    my $from        = $params{'from'};
    my $robot       = Sympa::Robot::clean_robot($params{'robot'}, 1);   # May be Site
    my $listname    = $params{'listname'};
    my $sign_mode   = $params{'sign_mode'};
    my $sympa_email = $params{'sympa_email'};
    my $priority_message = $params{'priority'};
    my $priority_packet  = $robot->sympa_packet_priority;
    my $delivery_date    = $params{'delivery_date'};
    $delivery_date = time() unless ($delivery_date);
    my $verp        = $params{'verp'};
    my $merge       = $params{'merge'};
    my $use_bulk    = $params{'use_bulk'};
    my $dkim        = $params{'dkim'};
    my $tag_as_last = $params{'tag_as_last'};
    my $sympa_file;
    my $fh;
    my $signed_msg;    # if signing

    if ($sign_mode and $sign_mode eq 'smime') {
        Sympa::Log::Syslog::do_log('debug2', 'Will sign message');
        unless ($message->smime_sign()) {
            Sympa::Log::Syslog::do_log('err',
                'Unable to sign message from %s', $listname);
            return undef;
        }
    }
    my $verpfeature =
        ($verp and ($verp eq 'on' or $verp eq 'mdn' or $verp eq 'dsn'));
    my $trackingfeature;
    if ($verp and ($verp eq 'mdn' or $verp eq 'dsn')) {
        $trackingfeature = $verp;
    } else {
        $trackingfeature = '';
    }
    my $mergefeature = ($merge and $merge eq 'on');
    if ($use_bulk or defined $send_spool) {

        # in that case use bulk tables to prepare message distribution
        unless ($use_bulk) {

            # in context wwsympa.fcgi store directly to spool.
            Sympa::Log::Syslog::do_log(
                'info',
                'USING BULK AS OUTGOING SPOOL: rcpt: %s, from: %s, message: %s',
                $rcpt,
                $from,
                $message
            );
        }

        ##Bulk package determine robots or site.
        my $bulk_code = Sympa::Bulk::store(
            'message'          => $message,
            'rcpts'            => $rcpt,
            'from'             => $from,
            'robot'            => $robot,
            'listname'         => $listname,
            'priority_message' => $priority_message,
            'priority_packet'  => $priority_packet,
            'delivery_date'    => $delivery_date,
            'verp'             => $verpfeature,
            'tracking'         => $trackingfeature,
            'merge'            => $mergefeature,
            'dkim'             => $dkim,
            'tag_as_last'      => $tag_as_last,
        );

        unless (defined $bulk_code) {
            Sympa::Log::Syslog::do_log('err',
                'Failed to store message for list %s', $listname);
            $robot->send_notify_to_listmaster('bulk_error',
                {'listname' => $listname});
            return undef;
        }
    } else {

        # send it now
        Sympa::Log::Syslog::do_log('info', 'NOT USING BULK');

        # Get message as string without meta information.
        my $string_to_send;
        if ($message->is_signed) {
            $string_to_send = $message->as_string();
        } else {
            $string_to_send = $message->get_mime_message->as_string();  #FIXME
        }

        *SMTP = smtpto($from, $rcpt, $robot);
        print SMTP $string_to_send;
        unless (close SMTP) {
            Sympa::Log::Syslog::do_log('err',
                'could not close safefork to sendmail');
            return undef;
        }
    }
    return 1;
}

##############################################################################
# smtpto
##############################################################################
# Makes a sendmail ready for the recipients given as argument, uses a file
# descriptor in the smtp table which can be imported by other parties.
# Before, waits for number of children process < number allowed by sympa.conf
#
# IN : $from :(+) for SMTP "MAIL From:" field
#      $rcpt :(+) ref(SCALAR)|ref(ARRAY)- for SMTP "RCPT To:" field
#      $robot :(+) ref(Robot) | "Site"
#      $msgkey : a id of this message submission in notification table
# OUT : Sympa::Mail::$fh - file handle on opened file for ouput, for SMTP "DATA"
# field
#       | undef
#
##############################################################################
sub smtpto {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s, %s, %s, %s)', @_);
    my $from      = shift;
    my $rcpt      = shift;
    my $robot     = Sympa::Robot::clean_robot(shift, 1);
    my $msgkey    = shift;
    my $sign_mode = shift;

    unless ($from) {
        Sympa::Log::Syslog::do_log('err',
            'Missing Return-Path in Sympa::Mail::smtpto()');
    }

    if (ref($rcpt) eq 'SCALAR') {
        Sympa::Log::Syslog::do_log('debug2', 'Sympa::Mail::smtpto(%s, %s, %s )',
            $from, $$rcpt, $sign_mode);
    } elsif (ref($rcpt) eq 'ARRAY') {
        Sympa::Log::Syslog::do_log('debug2', 'Sympa::Mail::smtpto(%s, %s, %s)',
            $from, join(',', @{$rcpt}), $sign_mode);
    }

    ## Escape "-" at beginning of recipient addresses
    ## prevent sendmail from taking it as argument

    if (ref($rcpt) eq 'SCALAR') {
        $$rcpt =~ s/^-/\\-/;
    } elsif (ref($rcpt) eq 'ARRAY') {
        my @emails = @$rcpt;
        foreach my $i (0 .. $#emails) {
            $rcpt->[$i] =~ s/^-/\\-/;
        }
    }

    ## Check how many open smtp's we have, if too many wait for a few
    ## to terminate and then do our job.

    Sympa::Log::Syslog::do_log('debug3', "Open = $opensmtp");
    while ($opensmtp > $robot->maxsmtp) {
        Sympa::Log::Syslog::do_log('debug3',
            "Sympa::Mail::smtpto: too many open SMTP ($opensmtp), calling reaper");
        last if (reaper(0) == -1);    ## Blocking call to the reaper.
    }

    *IN  = ++$fh;
    *OUT = ++$fh;

    if (!pipe(IN, OUT)) {
        croak sprintf('Unable to create a channel in smtpto: %s', $ERRNO);
        ## No return
    }
    my $pid = safefork();
    $pid{$pid} = 0;

    my $sendmail = $robot->sendmail;
    my @sendmail_args = split /\s+/, $robot->sendmail_args;
    if ($msgkey) {
        push @sendmail_args, '-N', 'success,delay,failure';

        # Postfix clone of sendmail command doesn't allow spaces between
        # "-V" and envid.
        push @sendmail_args, "-V$msgkey";
    }
    if ($pid == 0) {

        close(OUT);
        open(STDIN, "<&IN");

        $from = '' if $from eq '<>';    # null sender
        if (!ref($rcpt)) {
            exec $sendmail, @sendmail_args, '-f', $from, $rcpt;
        } elsif (ref($rcpt) eq 'SCALAR') {
            exec $sendmail, @sendmail_args, '-f', $from, $$rcpt;
        } elsif (ref($rcpt) eq 'ARRAY') {
            exec $sendmail, @sendmail_args, '-f', $from, @$rcpt;
        }

        exit 1;                         ## Should never get there.
    }
    if ($main::options{'mail'}) {
        my $r;
        if (!ref $rcpt) {
            $r = $rcpt;
        } elsif (ref $rcpt eq 'SCALAR') {
            $r = $$rcpt;
        } else {
            $r = join(' ', @$rcpt);
        }
        Sympa::Log::Syslog::do_log(
            'debug3', 'safefork: %s %s -f \'%s\' %s',
            $sendmail, join(' ', @sendmail_args),
            $from, $r
        );
    }
    unless (close(IN)) {
        Sympa::Log::Syslog::do_log('err',
            "Sympa::Mail::smtpto: could not close safefork");
        return undef;
    }
    $opensmtp++;
    select(undef, undef, undef, 0.3) if $opensmtp < $robot->maxsmtp;
    return ("Sympa::Mail::$fh");    ## Symbol for the write descriptor.
}

#sub send_in_spool($rcpt,$robot,$sympa_email,$XSympaFrom)
#DEPRECATED: not used at all

## Safefork does several tries before it gives up.
## Do 3 trials and wait 10 seconds * $i between each.
## Exit with a fatal error is fork failed after all
## tests have been exhausted.
sub safefork {
    my $err;
    for (my $i = 1; $i < 4; $i++) {
        my ($pid) = fork;
        return $pid if (defined($pid));

        $err = $ERRNO;
        Sympa::Log::Syslog::do_log('warn',
            'Cannot create new process in safefork: %s', $err);
        ## FIXME:should send a mail to the listmaster
        sleep(10 * $i);
    }
    croak sprintf('Exiting because cannot create new process in safefork: %s',
        $err);
    ## No return.
}

1;
