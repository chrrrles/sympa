#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: tools_smime.t 8874 2013-03-14 18:59:35Z rousse $

use strict;

use lib 'src/lib';

use English qw(-no_match_vars);
use Test::More;

use Sympa::Logger::Memory;
use Sympa::Tools::File;
use Sympa::Tools::DKIM;

my %tests = (
    error2 => undef,
    error3 => undef,
    error7 => 1
);

plan tests => scalar keys %tests;

our $logger = Sympa::Logger::Memory->new();

foreach my $test (keys %tests) {
    is (
        Sympa::Tools::DKIM::verifier(
            Sympa::Tools::File::slurp_file("t/samples/$test.eml")
        ),
        $tests{$test},
        "DKIM verifier: $test sample"
    );
}
