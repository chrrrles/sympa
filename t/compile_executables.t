#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: compile_executables.t 8606 2013-02-06 08:44:02Z rousse $

use strict;
use warnings;

use lib 'src/lib';

use English qw(-no_match_vars);
use Test::More;

eval {
    require Test::Compile;
    Test::Compile->import();
};
if ($EVAL_ERROR) {
    my $msg = 'Test::Compile required';
    plan(skip_all => $msg);
}

all_pl_files_ok(
	<src/sbin/*.pl>,
	<src/bin/*.pl>,
	<src/libexec/*.pl>,
	'src/cgi/wwsympa.fcgi',
	'src/cgi/sympa_soap_server.fcgi',
);
