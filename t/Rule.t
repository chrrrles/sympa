#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: tools_data.t 8606 2013-02-06 08:44:02Z rousse $

use strict;
use warnings;

use lib 'src/lib';

use English qw(-no_match_vars);
use Test::Exception;
use Test::More;

use Sympa::Rule;

plan tests => 7;

my $rule;

throws_ok {
    $rule = Sympa::Rule->new();
} qr /^missing 'test' parameter/,
'missing test parameter';

throws_ok {
    $rule = Sympa::Rule->new(
        test => 'foo'
    );
} qr /^missing 'auth_methods' parameter/,
'missing auth_methods parameter';

throws_ok {
    $rule = Sympa::Rule->new(
        test         => 'foo',
        auth_methods => 'bar',
    );
} qr /^missing 'decision' parameter/,
'missing decision parameter';

lives_ok {
    $rule = Sympa::Rule->new(
        test         => 'foo',
        auth_methods => 'bar',
        decision     => 'baz'
    );
} 'everything OK';

ok($rule->get_test(), 'foo');
ok($rule->get_auth_methods(), 'bar');
ok($rule->get_decision(), 'baz');
