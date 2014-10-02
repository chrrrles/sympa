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

use Sympa::Spool::File::Message;
use Sympa::Logger::Memory;

plan tests => 13;

our $logger = Sympa::Logger::Memory->new();

my $spool;

$spool = Sympa::Spool::File::Message->new();
ok(! defined $spool, 'spool is not defined');
like($logger->{messages}->[-1], qr/Missing name parameter$/, 'missing name parameter');

$spool = Sympa::Spool::File::Message->new(
    name => 'foo'
);
ok(! defined $spool, 'spool is not defined');
like($logger->{messages}->[-1], qr/Missing directory parameter$/, 'missing directory parameter');

my $dir = File::Temp->newdir();

$spool = Sympa::Spool::File::Message->new(
    name => 'foo', directory => $dir . '/bar'
);
ok($spool, 'spool is defined');
ok(-d $dir . '/bar', 'spool directory has been created');
is($spool->get_id(), 'foo/ok', 'spool identifier');

$spool = Sympa::Spool::File::Message->new(
    name => 'foo', directory => $dir . '/baz', status => 'bad'
);
ok($spool, 'spool is defined');
ok(-d $dir . '/baz/bad', 'spool subdirectory has been created');
is($spool->get_id(), 'foo/bad', 'spool identifier');

ok($spool->count() == 0, 'spool is empty');
ok(
    $spool->store("test message", { filename => 'test' }),
    'storing content works'
);
ok($spool->count() == 0, 'spool is still empty');
