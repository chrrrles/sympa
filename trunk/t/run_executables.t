#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: compile_executables.t 8606 2013-02-06 08:44:02Z rousse $

use strict;
use warnings;

use lib 'src/lib';

use English qw(-no_match_vars);
use IPC::Run qw(run);
use Test::More;

my @files = qw(
    src/sbin/archived.pl
    src/sbin/bounced.pl
    src/sbin/bulk.pl
    src/sbin/task_manager.pl
    src/sbin/sympa.pl
    src/bin/p12topem.pl
    src/bin/sympa_manager.pl
    src/bin/sympa_soap_client.pl
    src/libexec/alias_manager.pl
);

plan tests => scalar @files * 3;

foreach my $file (@files) {
     run(
        [ $EXECUTABLE_NAME, '-I', 'src/lib', $file, '--help' ],
        \my ($in, $out, $err)
    );
    my $rc = $CHILD_ERROR >> 8;

    ok($rc == 0, "$file --help exit status");
    is($err, '', "$file --help stderr");
    like($out, qr/^Usage:/, "$file --help stdout");
}
