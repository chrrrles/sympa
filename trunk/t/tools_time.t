#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: tools_time.t 8606 2013-02-06 08:44:02Z rousse $

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../src/lib";

use POSIX qw(setlocale LC_ALL LC_CTYPE);
use Test::More;

use Sympa::Tools::Time;

setlocale(LC_ALL, 'C');

my @epoch2yyyymmjj_hhmmss_tests = (
    [ 1350544367, '2012-10-18  09:12:47' ],
    [ 1250544367, '2009-08-17  23:26:07' ],
);

my @adate_tests = (
    [ 1350544367, '18 Thu Oct 2012  09 h 12 min 47 s' ],
    [ 1250544367, '17 Mon Aug 2009  23 h 26 min 07 s' ],
);

my @get_midnight_time_tests = (
    [ 1350544367, 1350511200 ],
    [ 1250544367, 1250460000 ],
);

my @date_conv_tests = (
    [ [ 1350544367                , undef ] => 1350544367 ],
    [ [ '2012y10m18d09h12min47sec', undef ] => 1350511967 ],
    [ [ '2012y10m18d09h12min',      undef ] => 1350511920 ],
    [ [ '2012y10m18d09h',           undef ] => 1350511200 ],
    [ [ '2012y10m18d',              undef ] => 1350511200 ],
    [ [ '2012y10m',                 undef ] => 1349042400 ],
    [ [ '2012y',                    undef ] => 1325372400 ],
);

my @duration_conv_tests = (
    [ [ 0                   , 0 ] =>        0 ],
    [ [ '1sec'              , 0 ] =>        1 ],
    [ [ '1min'              , 0 ] =>       60 ],
    [ [ '1h'                , 0 ] =>     3600 ],
    [ [ '1d'                , 0 ] =>    86400 ],
    [ [ '1w'                , 0 ] =>   604800 ],
    [ [ '1m'                , 0 ] =>  2678400 ],
    [ [ '2m'                , 0 ] =>  5097600 ],
    [ [ '1y'                , 0 ] => 31536000 ],
    [ [ '1y1m1w1d1h1min1sec', 0 ] => 34909261 ],
);

my @epoch_conv_tests = (
);

my @parse_date_tests = (
    [ 'Sun, 28 Oct 2012 10:53:21 +0100' =>
        [ 0, 28, 9, 2012, 10, 53, 21, '+0100' ] ],
    [ 'Sat, 27 Nov 2010 18:11:27 +0100 (MET)' =>
        [ 6, 27, 10, 2010, 18, 11, 27, '+0100' ] ]
);

plan tests =>
    @epoch2yyyymmjj_hhmmss_tests +
    @adate_tests                 +
    @get_midnight_time_tests     +
    @date_conv_tests             +
    @duration_conv_tests         +
    @epoch_conv_tests            +
    @parse_date_tests            ;

foreach my $test (@epoch2yyyymmjj_hhmmss_tests) {
    is(
        Sympa::Tools::Time::epoch2yyyymmjj_hhmmss($test->[0]),
        $test->[1],
        "epoch2yyyymmjj_hhmmss $test->[0]"
    );
}

foreach my $test (@adate_tests) {
    is(
        Sympa::Tools::Time::adate($test->[0]),
        $test->[1],
        "adate $test->[0]"
    );
}

foreach my $test (@get_midnight_time_tests) {
    is(
        Sympa::Tools::Time::get_midnight_time($test->[0]),
        $test->[1],
        "get_midnight_time $test->[0]"
    );
}

foreach my $test (@date_conv_tests) {
    is(
        Sympa::Tools::Time::date_conv(@{$test->[0]}),
        $test->[1],
        "date_conv $test->[0]"
    );
}

foreach my $test (@duration_conv_tests) {
    is(
        Sympa::Tools::Time::duration_conv(@{$test->[0]}),
        $test->[1],
        "duration_conv $test->[0]"
    );
}

foreach my $test (@epoch_conv_tests) {
    is(
        Sympa::Tools::Time::epoch_conv(@{$test->[0]}),
        $test->[1],
        "epoch_conv $test->[0]"
    );
}

foreach my $test (@parse_date_tests) {
    is_deeply(
        [ Sympa::Tools::Time::parse_date($test->[0]) ],
        $test->[1],
        "parse_date $test->[0]"
    ) or print Dumper(
        [ Sympa::Tools::Time::parse_date($test->[0]) ]);
    use Data::Dumper;
}
