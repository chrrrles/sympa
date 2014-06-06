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

package Sympa::Tools::DKIM;

use strict;
use warnings;

use English qw(-no_match_vars);
use MIME::Parser;

use Sympa::Log::Syslog;
use Sympa::Message;

# input a msg as string, output the dkim status
sub verifier {
    my $msg_as_string = shift;
    my $tmpdir = shift;
    my $dkim;

    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG, "DKIM verifier");
    unless (eval "require Mail::DKIM::Verifier") {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "Failed to load Mail::DKIM::Verifier Perl module, ignoring DKIM signature"
        );
        return undef;
    }

    unless ($dkim = Mail::DKIM::Verifier->new()) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            'Could not create Mail::DKIM::Verifier');
        return undef;
    }

    my $temporary_file = $tmpdir . "/dkim." . $PID;
    if (!open(MSGDUMP, "> $temporary_file")) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'Can\'t store message in file %s',
            $temporary_file);
        return undef;
    }
    print MSGDUMP $msg_as_string;

    unless (close(MSGDUMP)) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "unable to dump message in temporary file $temporary_file");
        return undef;
    }

    unless (open(MSGDUMP, "$temporary_file")) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'Can\'t read message in file %s',
            $temporary_file);
        return undef;
    }

    # this documented method is pretty but dont validate signatures, why ?
    # $dkim->load(\*MSGDUMP);
    while (<MSGDUMP>) {
        chomp;
        s/\015$//;
        $dkim->PRINT("$_\015\012");
    }

    $dkim->CLOSE;
    close(MSGDUMP);
    unlink($temporary_file);

    foreach my $signature ($dkim->signatures) {
        if ($signature->result_detail eq "pass") {
            Sympa::Log::Syslog::do_log(
                Sympa::Log::Syslog::DEBUG,
                'Verification of signature from domain %s issued result "pass"',
                $signature->domain,
            );
            return 1;
        } else {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG,
                'Verification of signature from domain %s issued result %s',
                $signature->domain, $signature->result_detail);
        }
    }
    return undef;
}

# input a msg as string, output idem without signature if invalid
sub remove_invalid_signature {
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG, "removing invalid DKIM signature");
    my $msg_as_string = shift;

    unless (verifier($msg_as_string)) {
        my $body_as_string =
            Sympa::Message::get_body_from_msg_as_string($msg_as_string);

        my $parser = MIME::Parser->new();
        $parser->output_to_core(1);
        my $entity = $parser->parse_data($msg_as_string);
        unless ($entity) {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'could not parse message');
            return $msg_as_string;
        }
        $entity->head->delete('DKIM-Signature');
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG,
            'Removing invalid DKIM signature header');
        return $entity->head->as_string() . "\n" . $body_as_string;
    } else {
        return ($msg_as_string);    # sgnature is valid.
    }
}

# input object msg and listname, output signed message object
sub sign {

    # in case of any error, this proc MUST return $msg_as_string NOT undef ;
    # this would cause Sympa to send empty mail
    my $msg_as_string   = shift;
    my $data            = shift;
    my $tmpdir          = shift;
    my $dkim_d          = $data->{'dkim_d'};
    my $dkim_i          = $data->{'dkim_i'};
    my $dkim_selector   = $data->{'dkim_selector'};
    my $dkim_privatekey = $data->{'dkim_privatekey'};

    Sympa::Log::Syslog::do_log(
        Sympa::Log::Syslog::DEBUG2,
        'sign(msg:%s,dkim_d:%s,dkim_i%s,dkim_selector:%s,dkim_privatekey:%s)',
        substr($msg_as_string, 0, 30),
        $dkim_d,
        $dkim_i,
        $dkim_selector,
        substr($dkim_privatekey, 0, 30)
    );

    unless ($dkim_selector) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "DKIM selector is undefined, could not sign message");
        return $msg_as_string;
    }
    unless ($dkim_privatekey) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "DKIM key file is undefined, could not sign message");
        return $msg_as_string;
    }
    unless ($dkim_d) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "DKIM d= tag is undefined, could not sign message");
        return $msg_as_string;
    }

    my $temporary_keyfile = $tmpdir . "/dkimkey." . $PID;
    if (!open(MSGDUMP, "> $temporary_keyfile")) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'Can\'t store key in file %s',
            $temporary_keyfile);
        return $msg_as_string;
    }
    print MSGDUMP $dkim_privatekey;
    close(MSGDUMP);

    unless (eval "require Mail::DKIM::Signer") {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "Failed to load Mail::DKIM::Signer Perl module, ignoring DKIM signature"
        );
        return ($msg_as_string);
    }
    unless (eval "require Mail::DKIM::TextWrap") {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "Failed to load Mail::DKIM::TextWrap Perl module, signature will not be pretty"
        );
    }
    my $dkim;
    if ($dkim_i) {

        # create a signer object
        $dkim = Mail::DKIM::Signer->new(
            Algorithm => "rsa-sha1",
            Method    => "relaxed",
            Domain    => $dkim_d,
            Identity  => $dkim_i,
            Selector  => $dkim_selector,
            KeyFile   => $temporary_keyfile,
        );
    } else {
        $dkim = Mail::DKIM::Signer->new(
            Algorithm => "rsa-sha1",
            Method    => "relaxed",
            Domain    => $dkim_d,
            Selector  => $dkim_selector,
            KeyFile   => $temporary_keyfile,
        );
    }
    unless ($dkim) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'Can\'t create Mail::DKIM::Signer');
        return ($msg_as_string);
    }
    my $temporary_file = $tmpdir . "/dkim." . $PID;
    if (!open(MSGDUMP, "> $temporary_file")) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'Can\'t store message in file %s',
            $temporary_file);
        return ($msg_as_string);
    }
    print MSGDUMP $msg_as_string;
    close(MSGDUMP);

    unless (open(MSGDUMP, $temporary_file)) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'Can\'t read temporary file %s',
            $temporary_file);
        return undef;
    }

    while (<MSGDUMP>) {

        # remove local line terminators
        chomp;
        s/\015$//;

        # use SMTP line terminators
        $dkim->PRINT("$_\015\012");
    }
    close MSGDUMP;
    unless ($dkim->CLOSE) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'Cannot sign (DKIM) message');
        return ($msg_as_string);
    }
    my $message = Sympa::Message->new(
        'file'       => $temporary_file,
        'noxsympato' => 'noxsympato'
    );
    unless ($message) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            'Unable to load %s as a message object',
            $temporary_file);
        return ($msg_as_string);
    }

    if ($main::options{Sympa::Log::Syslog::DEBUG}) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG, 'Temporary file is %s',
            $temporary_file);
    } else {
        unlink $temporary_file;
    }
    unlink $temporary_keyfile;

    $message->as_entity()
        ->head->add('DKIM-signature', $dkim->signature->as_string());

    return $message->as_entity()->head->as_string() . "\n"
        . Sympa::Message::get_body_from_msg_as_string($msg_as_string);
}

1;
