#!/usr/bin/perl
# -*- indent-tabs-mode: t; -*-
# vim:ft=perl:et:sw=4
# $Id: message.t 8875 2013-03-14 19:00:00Z rousse $

use strict;

use FindBin qw($Bin);
use lib "$Bin/../src/lib";

use Test::More;

use Sympa::Logger::Memory;
use Sympa::Message;

plan tests => 30;

our $logger = Sympa::Logger::Memory->new();

my $message;

# String source
my $string = <<'EOF';
Date: Mon, 25 Feb 2013 17:10:38 +0100
From: Guillaume Rousse <Guillaume.Rousse@sympa.org>
MIME-Version: 1.0
To: sympa-developpers@listes.renater.fr
Subject: unsigned test message
Content-Type: text/plain; charset=ISO-8859-1; format=flowed
Content-Transfer-Encoding: 7bit

This is an unsigned test message.
EOF

my $file = 't/samples/unsigned.eml';


# no source
$message = Sympa::Message->new();
ok(!$message, 'no source');

$message = Sympa::Message->new(
    file => $file
);
ok($message, 'file source');
isa_ok($message, 'Sympa::Message');
ok(!defined $message->get_envelope_sender(), 'envelope sender value');
is($message->get_sender_email(), 'guillaume.rousse@sympa.org', 'sender email value');
is($message->get_sender_gecos(), 'Guillaume Rousse', 'sender gecos value');
ok($message->has_valid_sender(), 'message has valid sender');
is($message->get_decoded_subject(), 'unsigned test message', 'subject value');
is($message->get_subject_charset(), 'US-ASCII', 'subject charset value');
cmp_ok($message->get_size, '==', 620, 'size value');
is($message->as_file(), $file, 'mail as file');
isa_ok($message->as_entity(), 'MIME::Entity');
ok(!$message->is_authenticated(), 'message is not authenticated');
ok(!$message->is_signed(), 'message is not signed');
ok(!$message->is_encrypted(), 'message is not encrypted');

$message = Sympa::Message->new(
    messageasstring => $string,
);
ok($message, 'string source');
isa_ok($message, 'Sympa::Message');
ok(!defined $message->get_envelope_sender(), 'envelope sender value');
is($message->get_sender_email(), 'guillaume.rousse@sympa.org', 'sender email value');
is($message->get_sender_gecos(), 'Guillaume Rousse', 'sender gecos value');
ok($message->has_valid_sender(), 'message has valid sender');
is($message->get_decoded_subject(), 'unsigned test message', 'subject value');
is($message->get_subject_charset(), 'US-ASCII', 'subject charset value');
cmp_ok($message->get_size, '==', 306, 'size value');
ok(!defined $message->as_file(), 'mail as file');
is($message->as_string(), $string, 'mail as string');
isa_ok($message->as_entity(), 'MIME::Entity');
ok(!$message->is_authenticated(), 'message is not authenticated');
ok(!$message->is_signed(), 'message is not signed');
ok(!$message->is_encrypted(), 'message is not encrypted');
