#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: tools_data.t 8606 2013-02-06 08:44:02Z rousse $

use strict;
use warnings;

use lib 'src/lib';

use English qw(-no_match_vars);
use File::Temp;
use Test::More;

use Sympa::Logger;
use Sympa::Logger::Memory;
use Sympa::Task;

my @sanitization_tests = (
    [ 'foo',               'foo',       'scalar sanitization'  ],
    [ [ 'foo' ],          '[...]',      'array ref sanitization' ],
    [ { arg1 => 'foo' }, '{arg1}',      'hash ref sanitization' ],
    [ qr/^foo$/,
        $PERL_VERSION ge v5.14 ? '(?^:^foo$)' : '(?-xism:^foo$)',
        'regexp ref sanitization' ],
    [ Sympa::Task->new(model => 'foo', flavour => 'bar'),
        'Sympa::Task::Global <foo.bar>', 'sympa object sanitization' ],
);

plan tests => 
    scalar @sanitization_tests + 26;

my $logger = Sympa::Logger::Memory->new();
ok($logger, 'logger is defined');
isa_ok($logger, 'Sympa::Logger');

cmp_ok($logger->get_level(), '==', 0, 'default log level');

$logger->do_log(Sympa::Logger::ERR, 'err');
like($logger->{messages}->[-1], qr/err$/, 'ERR message has been logged');

$logger->do_log(Sympa::Logger::INFO, 'info');
like($logger->{messages}->[-1], qr/info$/, 'INFO message has been logged');

$logger->do_log(Sympa::Logger::NOTICE, 'notice');
like($logger->{messages}->[-1], qr/notice$/, 'NOTICE message has been logged');

$logger->do_log(Sympa::Logger::TRACE, 'trace');
like($logger->{messages}->[-1], qr/trace$/, 'TRACE message has been logged');

$logger->do_log(Sympa::Logger::DEBUG, 'debug');
like($logger->{messages}->[-1], qr/trace$/, 'DEBUG message has not been logged');

$logger->do_log(Sympa::Logger::DEBUG2, 'debug2');
like($logger->{messages}->[-1], qr/trace$/, 'DEBUG2 message has not been logged');

$logger->do_log(Sympa::Logger::DEBUG3, 'debug3');
like($logger->{messages}->[-1], qr/trace$/, 'DEBUG3 message has not been logged');

$logger->set_level(1);
cmp_ok($logger->get_level(), '==', 1, 'log level set to 1');

$logger->do_log(Sympa::Logger::ERR, 'err');
like($logger->{messages}->[-1], qr/err$/, 'ERR message has been logged');

$logger->do_log(Sympa::Logger::INFO, 'info');
like($logger->{messages}->[-1], qr/info$/, 'INFO message has been logged');

$logger->do_log(Sympa::Logger::NOTICE, 'notice');
like($logger->{messages}->[-1], qr/notice$/, 'NOTICE message has been logged');

$logger->do_log(Sympa::Logger::TRACE, 'trace');
like($logger->{messages}->[-1], qr/trace$/, 'TRACE message has been logged');

$logger->do_log(Sympa::Logger::DEBUG, 'debug');
like($logger->{messages}->[-1], qr/debug$/, 'DEBUG message has been logged');

$logger->do_log(Sympa::Logger::DEBUG2, 'debug2');
like($logger->{messages}->[-1], qr/debug$/, 'DEBUG2 message has not been logged');

$logger->do_log(Sympa::Logger::DEBUG3, 'debug3');
like($logger->{messages}->[-1], qr/debug$/, 'DEBUG3 message has not been logged');

$logger->set_level(2);
cmp_ok($logger->get_level(), '==', 2, 'log level set to 2');

$logger->do_log(Sympa::Logger::ERR, 'err');
like($logger->{messages}->[-1], qr/err$/, 'ERR message has been logged');

$logger->do_log(Sympa::Logger::INFO, 'info');
like($logger->{messages}->[-1], qr/info$/, 'INFO message has been logged');

$logger->do_log(Sympa::Logger::NOTICE, 'notice');
like($logger->{messages}->[-1], qr/notice$/, 'NOTICE message has been logged');

$logger->do_log(Sympa::Logger::TRACE, 'trace');
like($logger->{messages}->[-1], qr/trace$/, 'TRACE message has been logged');

$logger->do_log(Sympa::Logger::DEBUG, 'debug');
like($logger->{messages}->[-1], qr/debug$/, 'DEBUG message has been logged');

$logger->do_log(Sympa::Logger::DEBUG2, 'debug2');
like($logger->{messages}->[-1], qr/debug2$/, 'DEBUG2 message has been logged');

$logger->do_log(Sympa::Logger::DEBUG3, 'debug3');
like($logger->{messages}->[-1], qr/debug2$/, 'DEBUG3 message has not been logged');

foreach my $test (@sanitization_tests) {
    is(Sympa::Logger::_sanitize_arg($test->[0]), $test->[1], $test->[2]);
}
