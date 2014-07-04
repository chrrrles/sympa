#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: tools_data.t 8606 2013-02-06 08:44:02Z rousse $

use strict;
use warnings;

use lib 'src/lib';

use English qw(-no_match_vars);
use Test::More;

use Sympa::Datasource::LDAP;
use Sympa::Logger::Memory;

plan tests => 4;

our $logger = Sympa::Logger::Memory->new();

my $source;

$source = Sympa::Datasource::LDAP->new();
ok(!defined $source, 'source is not defined');
like($logger->{messages}->[-1], qr/missing 'host' parameter$/, 'missing host parameter');

$source = Sympa::Datasource::LDAP->new(host => 'localhost');
ok(defined $source, 'source is defined');
isa_ok($source, 'Sympa::Datasource::LDAP');
