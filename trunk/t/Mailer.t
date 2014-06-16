#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: tools_data.t 8606 2013-02-06 08:44:02Z rousse $

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../src/lib";

use English qw(-no_match_vars);
use Test::More;

use Sympa::Mailer;

plan tests => 3;

my $mailer = Sympa::Mailer->new();
ok($mailer, 'mailer is defined');
isa_ok($mailer, 'Sympa::Mailer');
cmp_ok($mailer->{max_length}, '==', 500, 'default maximum size');
