#!/usr/bin/perl
# -*- indent-tabs-mode: t; -*-
# vim:ft=perl:et:sw=4
# $Id: message.t 8875 2013-03-14 19:00:00Z rousse $

use strict;

use lib 'src/lib';

use File::Copy;
use Test::More;

use Sympa::Logger::Memory;
use Sympa::Message;

plan tests => 70;

our $logger = Sympa::Logger::Memory->new();

my $message;

# parsing test: no source
$message = Sympa::Message->new();
ok(!$message, 'no source');

# parsing test: file source
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

# parsing test: string source
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

# parsing test: signed file source
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

# signature check test

my $cert_dir = File::Temp->newdir(CLEANUP => $ENV{TEST_DEBUG} ? 0 : 1);
my $cert_file = $cert_dir . '/guillaume.rousse@sympa.org';
my $tmpdir = File::Temp->newdir(CLEANUP => $ENV{TEST_DEBUG} ? 0 : 1);
ok(
    $message->check_signature(
        cafile       => 't/pki/crt/ca.pem',
        tmpdir       => $tmpdir,
        ssl_cert_dir => $cert_dir
    ),
    'message signature is OK'
);
ok(-f $cert_file, 'certificate file created');

# signature test: unprotected key
copy('t/pki/crt/rousse.pem', "$cert_dir/cert.pem");
copy('t/pki/key/rousse_nopassword.pem', "$cert_dir/private_key");

$message = Sympa::Message->new(
    file => $file
);
ok(!$message->is_signed(), 'message is not signed');

ok(
    $message->sign(
        tmpdir       => $tmpdir,
        ssl_cert_dir => $cert_dir
    ),
    'signature operation success'
);
ok($message->is_signed(), 'message is signed');

# signature test: password-protected key
copy('t/pki/key/rousse_password.pem', "$cert_dir/private_key");

$message = Sympa::Message->new(
    file => $file
);
ok(!$message->is_signed(), 'message is not signed');

ok(
    $message->sign(
        tmpdir       => $tmpdir,
        ssl_cert_dir => $cert_dir,
        key_password => 'test'
    ),
    'signature operation success'
);
ok($message->is_signed(), 'message is signed');

# encryption test
$message = Sympa::Message->new(
    file => $file
);
ok(!$message->is_encrypted(), 'message is not encrypted');
is(
    $message->as_entity()->body()->[0],
    "This is an unsigned test message.\n",
    'initial message body'
);

ok(
    $message->encrypt(
        email        => 'guillaume.rousse@sympa.org',
        tmpdir       => $tmpdir,
        ssl_cert_dir => $cert_dir,
    ),
    'encryption operation success'
);
ok($message->is_encrypted(), 'message is encrypted');
isnt(
    $message->as_entity()->body()->[0],
    "This is an unsigned test message.\n",
    'message body has been modified'
);

# decryption test: unprotected key
copy('t/pki/crt/rousse.pem', "$cert_dir/cert.pem");
copy('t/pki/key/rousse_nopassword.pem', "$cert_dir/private_key");
ok(
    $message->decrypt(
        tmpdir       => $tmpdir,
        ssl_cert_dir => $cert_dir,
    ),
    'decryption operation success, with a passwordless key'
);
ok(!$message->is_encrypted(), 'message is not encrypted anymore');
is(
    $message->as_entity()->body()->[0],
    "This is an unsigned test message.\n",
    'message body has been restored'
);

# encryption test (again)
$message = Sympa::Message->new(
    file => $file
);
ok(!$message->is_encrypted(), 'message is not encrypted');
is(
    $message->as_entity()->body()->[0],
    "This is an unsigned test message.\n",
    'initial message body'
);

ok(
    $message->encrypt(
        email        => 'guillaume.rousse@sympa.org',
        tmpdir       => $tmpdir,
        ssl_cert_dir => $cert_dir,
    ),
    'encryption operation success'
);
ok($message->is_encrypted(), 'message is encrypted');
isnt(
    $message->as_entity()->body()->[0],
    "This is an unsigned test message.\n",
    'message body has been modified'
);

# decryption test: password-protected key
copy('t/pki/crt/rousse.pem', "$cert_dir/cert.pem");
copy('t/pki/key/rousse_password.pem', "$cert_dir/private_key");
ok(
    $message->decrypt(
        tmpdir       => $tmpdir,
        ssl_cert_dir => $cert_dir,
        key_password => 'test'
    ),
    'decryption operation success, with a password-protectedless key'
);
ok(!$message->is_encrypted(), 'message is not encrypted anymore');
is(
    $message->as_entity()->body()->[0],
    "This is an unsigned test message.\n",
    'message body has been restored'
);
