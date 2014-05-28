#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: tools_data.t 8606 2013-02-06 08:44:02Z rousse $

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../src/lib";

use Test::More;
use Test::Exception;

use Sympa::Instruction;

my @tests_nok = (
    [ 'foo'      ,     qr/syntax error/        ],
    [ 'foo()'    ,     qr/unknown command foo/ ],
    [ 'next(foo)',     qr/wrong number of arguments/ ],
    [ 'next(foo,bar)', qr/argument 'foo' is not a valid date/ ],
    [ 'next(execution date,bar)', qr/argument 'executiondate' is not a valid date/ ],
    [ '@foo=bar'                , qr/invalid assignment bar/ ],
);

my @tests_ok_nocontent = (
    [ ''             , 'empty line' ],
    [ '#foo'         , 'comment'    ],
    [ ' #foo'        , 'comment'    ],
);

my @tests_ok_content = (
    [ 'title...foo'     , 'title'  , 'title', 'foo'  ],
    [ ' title...foo'    , 'title'  , 'title', 'foo'  ],
    [ 'title... foo'    , 'title'  , 'title', 'foo'  ],
    [ ' title... foo'   , 'title'  , 'title', 'foo'  ],
    [ '/foo'            , 'label'  , 'label', 'foo'  ],
    [ ' /foo'           , 'label'  , 'label', 'foo'  ],
    [ '/ foo'           , 'label'  , 'label', 'foo'  ],
    [ ' / foo'          , 'label'  , 'label', 'foo'  ],
    [ 'next(333,bar)'   , 'command', 'command', 'next' ],
    [ 'next (333,bar)'  , 'command', 'command', 'next' ],
    [ ' next(333,bar)'  , 'command', 'command', 'next' ],
    [ ' next (333,bar)' , 'command', 'command', 'next' ],
    [ ' next(execution_date,bar)' , 'command', 'command', 'next' ],
    [ ' next(1y1m1d1h1min1sec,bar)' , 'command', 'command', 'next' ],
    [ ' next(33+1y1m1d1h1min1sec,bar)' , 'command', 'command', 'next' ],
    [ ' next(33-1y1m1d1h1min1sec,bar)' , 'command', 'command', 'next' ],
    [ '@foo=select_subs(bar)'          , 'assignment', 'var', '@foo' ],
    [ ' @foo=select_subs(bar)'         , 'assignment', 'var', '@foo' ],
    [ '@foo = select_subs(bar)'        , 'assignment', 'var', '@foo' ],
    [ ' @foo = select_subs(bar)'       , 'assignment', 'var', '@foo' ],
);

plan tests =>
    scalar @tests_nok              +
    scalar @tests_ok_nocontent * 2 +
    scalar @tests_ok_content   * 3;

foreach my $test (@tests_nok) {
    my $instruction;
    throws_ok {
        $instruction = Sympa::Instruction->new(
            line_as_string => $test->[0],
            line_number    => 1
        );
    } $test->[1],
    "'$test->[0]' is not a valid instruction"
}

foreach my $test (@tests_ok_nocontent) {
    my $instruction;
    lives_ok {
        $instruction = Sympa::Instruction->new(
            line_as_string => $test->[0],
            line_number    => 1
        );
    } "'$test->[0]' is a valid instruction";
    is(
        $instruction->{nature},
        $test->[1],
        "'$test->[0]' is a $test->[1]"
    );
}

foreach my $test (@tests_ok_content) {
    my $instruction;
    lives_ok {
        $instruction = Sympa::Instruction->new(
            line_as_string => $test->[0],
            line_number    => 1
        );
    } "'$test->[0]' is a valid instruction";
    is(
        $instruction->{nature},
        $test->[1],
        "'$test->[0]' is a $test->[1]"
    );
    is(
        $instruction->{$test->[2]},
        $test->[3],
        "'$test->[0]' has '$test->[3]' value as '$test->[2]' attribute"
    );
}
