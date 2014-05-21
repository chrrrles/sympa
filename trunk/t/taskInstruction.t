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

use Sympa::TaskInstruction;

my @tests_nok = (
    [ 'foo'      , qr/syntax error/        ],
    [ 'foo()'    , qr/unknown command foo/ ],
    [ 'next(333)', qr/wrong number of arguments/ ]
);

my @tests_ok_nocontent = (
    [ ''             , 'empty line' ],
    [ '#foo'         , 'comment'    ],
    [ ' #foo'        , 'comment'    ],
);

my @tests_ok_content = (
    [ 'title...foo'     , 'title'  , 'foo'  ],
    [ ' title...foo'    , 'title'  , 'foo'  ],
    [ 'title... foo'    , 'title'  , 'foo'  ],
    [ ' title... foo'   , 'title'  , 'foo'  ],
    [ '/foo'            , 'label'  , 'foo'  ],
    [ ' /foo'           , 'label'  , 'foo'  ],
    [ '/ foo'           , 'label'  , 'foo'  ],
    [ ' / foo'          , 'label'  , 'foo'  ],
    [ 'next(333,bar)'   , 'command', 'next' ],
    [ 'next (333,bar)'  , 'command', 'next' ],
    [ ' next(333,bar)'  , 'command', 'next' ],
    [ ' next (333,bar)' , 'command', 'next' ],
);

plan tests =>
    scalar @tests_nok              +
    scalar @tests_ok_nocontent * 2 +
    scalar @tests_ok_content   * 3;

foreach my $test (@tests_nok) {
    my $instruction;
    throws_ok {
        $instruction = Sympa::TaskInstruction->new(
            line_as_string => $test->[0],
            line_number    => 1
        );
    } $test->[1],
    "'$test->[0]' is not a valid instruction"
}

foreach my $test (@tests_ok_nocontent) {
    my $instruction;
    lives_ok {
        $instruction = Sympa::TaskInstruction->new(
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
        $instruction = Sympa::TaskInstruction->new(
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
        $instruction->{$test->[1]},
        $test->[2],
        "'$test->[0]' has '$test->[2]' as content"
    );
}
