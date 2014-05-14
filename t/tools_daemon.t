#!/usr/bin/perl
# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: tools_daemon.t 9132 2013-04-18 07:25:16Z rousse $

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../src/lib";

use English qw(-no_match_vars);
use File::Temp;
use Test::More;

use Sympa::Tools::Daemon;

plan tests => 23;

my $piddir  = File::Temp->newdir(CLEANUP => $ENV{TEST_DEBUG} ? 0 : 1);
my $name    = 'test';
my $pidfile = $piddir . '/' . $name . '.pid';

ok(
    Sympa::Tools::Daemon::write_pid(
        piddir => $piddir,
        name   => $name,
        pid    => 666,
    ),
    'new pid file',
);

ok(-f $pidfile, 'pid file presence');
is(slurp_file($pidfile), '666', 'pid file content');
is_deeply(
    Sympa::Tools::Daemon::get_pids_in_pid_file(
        piddir => $piddir,
        name   => $name,
    ),
    [666],
    'pids list'
);

ok(
    Sympa::Tools::Daemon::write_pid(
        piddir => $piddir,
        name   => $name,
        pid    => 667,
    ),
    'pid file overwrite',
);

ok(-f $pidfile, 'pid file presence');
is(slurp_file($pidfile), '667', 'pid file content');
is_deeply(
    Sympa::Tools::Daemon::get_pids_in_pid_file(
        piddir => $piddir,
        name   => $name,
    ),
    [667],
    'pids list'
);

ok(
    Sympa::Tools::Daemon::write_pid(
        piddir           => $piddir,
        name             => $name,
        pid              => 668,
        multiple_process => 1
    ),
    'pid file appending',
);
ok(-f $pidfile, 'pid file presence');
is(slurp_file($pidfile), '667 668', 'pid file content');
is_deeply(
    Sympa::Tools::Daemon::get_pids_in_pid_file(
        piddir => $piddir,
        name   => $name,
    ),
    [667, 668],
    'pids list'
);

ok(
    Sympa::Tools::Daemon::remove_pid(
        piddir           => $piddir,
        name             => $name,
        pid              => 668,
        multiple_process => 1
    ),
    'pid removal, existing pid',
);
ok(-f $pidfile, 'pid file presence');
is(slurp_file($pidfile), '667', 'pid file content');
is_deeply(
    Sympa::Tools::Daemon::get_pids_in_pid_file(
        piddir => $piddir,
        name   => $name,
    ),
    [667],
    'pids list'
);

ok(
    Sympa::Tools::Daemon::remove_pid(
        piddir           => $piddir,
        name             => $name,
        pid              => 668,
        multiple_process => 1
    ),
    'pid removal, unexisting pid',
);
ok(-f $pidfile, 'pid file presence');
is(slurp_file($pidfile), '667', 'pid file content');
is_deeply(
    Sympa::Tools::Daemon::get_pids_in_pid_file(
        piddir => $piddir,
        name   => $name,
    ),
    [667],
    'pids list'
);

ok(
    Sympa::Tools::Daemon::remove_pid(
        piddir           => $piddir,
        name             => $name,
        pid              => 667,
        multiple_process => 1
    ),
    'pid removal, last pid',
);
ok(!-f $pidfile, 'pid file presence');
is_deeply(
    Sympa::Tools::Daemon::get_pids_in_pid_file(
        piddir => $piddir,
        name   => $name,
    ),
    undef,
    'pids list'
);

sub slurp_file {
    my ($file) = @_;

    open(my $handle, '<', $file) or die "can't open $file: $ERRNO";
    my $content = <$handle>;
    close ($handle);

    chomp $content;
    return $content;
}
