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

Sympa::Tools::DKIM - DKIM-related functions

=head1 DESCRIPTION

This package provides some DKIM-related functions.

=cut

package Sympa::Tools::DKIM;

use strict;
use warnings;

use English qw(-no_match_vars);
use MIME::Parser;

use Sympa::Logger;
use Sympa::Message;

=head1 FUNCTIONS

=over

=item verifier($msg_as_string)

Input a msg as string, output the dkim status.

Parameters:

=over

=item * I<$msg_as_string>: FIXME

=back

=cut

sub verifier {
    my $msg_as_string = shift;
    my $dkim;

    $main::logger->do_log(Sympa::Logger::DEBUG, "DKIM verifier");
    unless (eval "require Mail::DKIM::Verifier") {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Failed to load Mail::DKIM::Verifier Perl module, ignoring DKIM signature"
        );
        return undef;
    }

    unless ($dkim = Mail::DKIM::Verifier->new()) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Could not create Mail::DKIM::Verifier');
        return undef;
    }

    # this documented method is pretty but dont validate signatures, why ?
    # $dkim->load(\*MSGDUMP);
    open (MSGDUMP, '<', \$msg_as_string);
    while (<MSGDUMP>) {
        chomp;
        s/\015$//;
        $dkim->PRINT("$_\015\012");
    }

    $dkim->CLOSE;
    close(MSGDUMP);

    foreach my $signature ($dkim->signatures) {
        if ($signature->result_detail eq "pass") {
            $main::logger->do_log(
                Sympa::Logger::DEBUG,
                'Verification of signature from domain %s issued result "pass"',
                $signature->domain,
            );
            return 1;
        } else {
            $main::logger->do_log(Sympa::Logger::DEBUG,
                'Verification of signature from domain %s issued result %s',
                $signature->domain, $signature->result_detail);
        }
    }
    return undef;
}

=item remove_invalid_signature($msg_as_string)

Input a msg as string, output idem without signature if invalid.

Parameters:

=over

=item * I<$msg_as_string>: FIXME

=back

=cut

sub remove_invalid_signature {
    $main::logger->do_log(Sympa::Logger::DEBUG, "removing invalid DKIM signature");
    my $msg_as_string = shift;

    unless (verifier($msg_as_string)) {
        my $body_as_string =
            Sympa::Message::get_body_from_msg_as_string($msg_as_string);

        my $parser = MIME::Parser->new();
        $parser->output_to_core(1);
        my $entity = $parser->parse_data($msg_as_string);
        unless ($entity) {
            $main::logger->do_log(Sympa::Logger::ERR, 'could not parse message');
            return $msg_as_string;
        }
        $entity->head->delete('DKIM-Signature');
        $main::logger->do_log(Sympa::Logger::DEBUG,
            'Removing invalid DKIM signature header');
        return $entity->head->as_string() . "\n" . $body_as_string;
    } else {
        return ($msg_as_string);    # sgnature is valid.
    }
}

=item sign($msg_as_string, $data, $tmpdir)

Input object msg and listname, output signed message object.

Parameters:

=over

=item * I<$msg_as_string>: FIXME

=item * I<$data>: FIXME

=item * I<$tmpdir>: FIXME

=back

=cut

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

    $main::logger->do_log(
        Sympa::Logger::DEBUG2,
        'sign(msg:%s,dkim_d:%s,dkim_i%s,dkim_selector:%s,dkim_privatekey:%s)',
        substr($msg_as_string, 0, 30),
        $dkim_d,
        $dkim_i,
        $dkim_selector,
        substr($dkim_privatekey, 0, 30)
    );

    unless ($dkim_selector) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "DKIM selector is undefined, could not sign message");
        return $msg_as_string;
    }
    unless ($dkim_privatekey) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "DKIM key file is undefined, could not sign message");
        return $msg_as_string;
    }
    unless ($dkim_d) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "DKIM d= tag is undefined, could not sign message");
        return $msg_as_string;
    }

    my $temporary_keyfile = $tmpdir . "/dkimkey." . $PID;
    if (!open(MSGDUMP, "> $temporary_keyfile")) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Can\'t store key in file %s',
            $temporary_keyfile);
        return $msg_as_string;
    }
    print MSGDUMP $dkim_privatekey;
    close(MSGDUMP);

    unless (eval "require Mail::DKIM::Signer") {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Failed to load Mail::DKIM::Signer Perl module, ignoring DKIM signature"
        );
        return ($msg_as_string);
    }
    unless (eval "require Mail::DKIM::TextWrap") {
        $main::logger->do_log(Sympa::Logger::ERR,
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
        $main::logger->do_log(Sympa::Logger::ERR, 'Can\'t create Mail::DKIM::Signer');
        return ($msg_as_string);
    }
    my $temporary_file = $tmpdir . "/dkim." . $PID;
    if (!open(MSGDUMP, "> $temporary_file")) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Can\'t store message in file %s',
            $temporary_file);
        return ($msg_as_string);
    }
    print MSGDUMP $msg_as_string;
    close(MSGDUMP);

    unless (open(MSGDUMP, $temporary_file)) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Can\'t read temporary file %s',
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
        $main::logger->do_log(Sympa::Logger::ERR, 'Cannot sign (DKIM) message');
        return ($msg_as_string);
    }
    my $message = Sympa::Message->new(
        'file'       => $temporary_file,
        'noxsympato' => 'noxsympato'
    );
    unless ($message) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to parse %s', $temporary_file);
        return ($msg_as_string);
    }
    unless ($message->has_valid_sender()) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Message from %s has no valid sender',
            $temporary_file);
        return ($msg_as_string);
    }

    if ($main::options{'debug'}) {
        $main::logger->do_log(Sympa::Logger::DEBUG, 'Temporary file is %s',
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

=back

=cut

1;
