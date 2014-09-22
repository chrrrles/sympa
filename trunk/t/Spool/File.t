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

use Sympa::Spool::File;
use Sympa::Logger::Memory;

plan tests => 9;

our $logger = Sympa::Logger::Memory->new();

my $spool;

$spool = Sympa::Spool::File->new('foo');
ok(! defined $spool, 'spool is not defined');
like($logger->{messages}->[-1], qr/Missing directory parameter$/, 'missing directory parameter');

my $dir = File::Temp->newdir();

$spool = Sympa::Spool::File->new('foo', $dir . '/bar');
ok($spool, 'spool is defined');
ok(-d $dir . '/bar', 'spool directory has been created');

$spool = Sympa::Spool::File->new('foo', $dir . '/baz', 'bad');
ok($spool, 'spool is defined');
ok(-d $dir . '/baz/bad', 'spool subdirectory has been created');

ok($spool->count() == 0, 'spool is empty');
ok(
    $spool->store("test message", { filename => 'test' }),
    'storing content works'
);
ok($spool->count() == 1, 'spool is not empty anymore');
