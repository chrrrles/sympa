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

plan tests => 47;

our $logger = Sympa::Logger::Memory->new();

my $message;

# no source
$message = Sympa::Message->new();
ok(!$message, 'no source');

# unsigned file source
my $file = 't/samples/unsigned.eml';

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
ok(!defined$message->check_signature(), 'can not check signature');

# unsigned string souce
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
ok(!defined$message->check_signature(), 'can not check signature');

# signed file source
my $signed_file = 't/samples/signed.eml';

$message = Sympa::Message->new(
    file => $signed_file
);
ok($message, 'file source');
isa_ok($message, 'Sympa::Message');
ok(!defined $message->get_envelope_sender(), 'envelope sender value');
is($message->get_sender_email(), 'guillaume.rousse@sympa.org', 'sender email value');
is($message->get_sender_gecos(), 'Guillaume Rousse', 'sender gecos value');
ok($message->has_valid_sender(), 'message has valid sender');
is($message->get_decoded_subject(), 'signed test message', 'subject value');
is($message->get_subject_charset(), 'US-ASCII', 'subject charset value');
cmp_ok($message->get_size, '==', 3779, 'size value');
is($message->as_file(), $signed_file, 'mail as file');
isa_ok($message->as_entity(), 'MIME::Entity');
ok(!$message->is_authenticated(), 'message is not authenticated');
ok($message->is_signed(), 'message is signed');
ok(!$message->is_encrypted(), 'message is not encrypted');

my $cert_dir = File::Temp->newdir(CLEANUP => $ENV{TEST_DEBUG} ? 0 : 1);
my $cert_file = $cert_dir . '/guillaume.rousse@sympa.org';
ok(
    $message->check_signature(
        cafile       => 't/pki/crt/ca.pem',
        openssl      => 'openssl',
        tmpdir       => $ENV{TMPDIR},
        ssl_cert_dir => $cert_dir
    ),
    'message signature is OK'
);
