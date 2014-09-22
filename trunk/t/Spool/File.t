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

plan tests => 6;

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
