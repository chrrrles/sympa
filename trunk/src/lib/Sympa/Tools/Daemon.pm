# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997-1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997-2011 Comite Reseau des Universites
# Copyright (c) 2011-2014 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::Tools::Daemon;

use strict;
use warnings;

use English qw(-no_match_vars);

use Sympa::Constants;
use Sympa::Log::Syslog;

## Remove PID file and STDERR output
sub remove_pid {
    my ($name, $pid, $options) = @_;

    my $piddir  = Sympa::Constants::PIDDIR;
    my $pidfile = $piddir . '/' . $name . '.pid';

    my @pids;

    # Lock pid file
    my $lock_fh = Sympa::LockedFile->new($pidfile, 5, '+<');
    unless ($lock_fh) {
        Sympa::Log::fatal_err(
            'Unable to lock %s file in write mode. Exiting.', $pidfile);
    }

    ## If in multi_process mode (bulk.pl for instance can have child
    ## processes) then the PID file contains a list of space-separated PIDs
    ## on a single line
    if ($options->{'multiple_process'}) {

        # Read pid file
        seek $lock_fh, 0, 0;
        my $l = <$lock_fh>;
        @pids = grep { /^[0-9]+$/ and $_ != $pid } split(/\s+/, $l);

        ## If no PID left, then remove the file
        unless (@pids) {
            ## Release the lock
            unless (unlink $pidfile) {
                Sympa::Log::Syslog::do_log('err', "Failed to remove %s: %s",
                    $pidfile, $!);
                $lock_fh->close;
                return undef;
            }
        } else {
            seek $lock_fh, 0, 0;
            truncate $lock_fh, 0;
            print $lock_fh join(' ', @pids) . "\n";
        }
    } else {
        unless (unlink $pidfile) {
            Sympa::Log::Syslog::do_log('err', "Failed to remove %s: %s", $pidfile,
                $!);
            $lock_fh->close;
            return undef;
        }
        my $err_file = Site->tmpdir . '/' . $pid . '.stderr';
        if (-f $err_file) {
            unless (unlink $err_file) {
                Sympa::Log::Syslog::do_log('err', "Failed to remove %s: %s",
                    $err_file, $!);
                $lock_fh->close;
                return undef;
            }
        }
    }

    $lock_fh->close;
    return 1;
}

sub write_pid {
    my ($name, $pid, $options) = @_;

    my $piddir  = Sympa::Constants::PIDDIR;
    my $pidfile = $piddir . '/' . $name . '.pid';

    ## Create piddir
    mkdir($piddir, 0755) unless (-d $piddir);

    unless (
        Sympa::Tools::File::set_file_rights(
            file  => $piddir,
            user  => Sympa::Constants::USER,
            group => Sympa::Constants::GROUP,
        )
        ) {
        Sympa::Log::fatal_err('Unable to set rights on %s. Exiting.',
            $piddir);
    }

    my @pids;

    # Lock pid file
    my $lock_fh = Sympa::LockedFile->new($pidfile, 5, '+>>');
    unless ($lock_fh) {
        Sympa::Log::fatal_err(
            'Unable to lock %s file in write mode. Exiting.', $pidfile);
    }
    ## If pidfile exists, read the PIDs
    if (-s $pidfile) {

        # Read pid file
        seek $lock_fh, 0, 0;
        my $l = <$lock_fh>;
        @pids = grep {/^[0-9]+$/} split(/\s+/, $l);
    }

    ## If we can have multiple instances for the process.
    ## Print other pids + this one
    if ($options->{'multiple_process'}) {
        ## Print other pids + this one
        push(@pids, $pid);

        seek $lock_fh, 0, 0;
        truncate $lock_fh, 0;
        print $lock_fh join(' ', @pids) . "\n";
    } else {
        ## The previous process died suddenly, without pidfile cleanup
        ## Send a notice to listmaster with STDERR of the previous process
        if (@pids) {
            my $other_pid = $pids[0];
            Sympa::Log::Syslog::do_log('notice',
                "Previous process %s died suddenly ; notifying listmaster",
                $other_pid);
            my $pname = $0;
            $pname =~ s/.*\/(\w+)/$1/;
            send_crash_report(('pid' => $other_pid, 'pname' => $pname));
        }

        seek $lock_fh, 0, 0;
        unless (truncate $lock_fh, 0) {
            ## Unlock pid file
            $lock_fh->close();
            Sympa::Log::fatal_err('Could not truncate %s, exiting.',
                $pidfile);
        }

        print $lock_fh $pid . "\n";
    }

    unless (
        Sympa::Tools::File::set_file_rights(
            file  => $pidfile,
            user  => Sympa::Constants::USER,
            group => Sympa::Constants::GROUP,
        )
        ) {
        ## Unlock pid file
        $lock_fh->close();
        Sympa::Log::fatal_err('Unable to set rights on %s', $pidfile);
    }
    ## Unlock pid file
    $lock_fh->close();

    return 1;
}

sub direct_stderr_to_file {
    my %data = @_;
    ## Error output is stored in a file with PID-based name
    ## Useful if process crashes
    open(STDERR, '>>', Sympa::Site->tmpdir . '/' . $data{'pid'} . '.stderr');
    unless (
        Sympa::Tools::File::set_file_rights(
            file  => Sympa::Site->tmpdir . '/' . $data{'pid'} . '.stderr',
            user  => Sympa::Constants::USER,
            group => Sympa::Constants::GROUP,
        )
        ) {
        Sympa::Log::Syslog::do_log(
            'err',
            'Unable to set rights on %s',
            Sympa::Site->tmpdir . '/' . $data{'pid'} . '.stderr'
        );
        return undef;
    }
    return 1;
}

# Send content of $pid.stderr to listmaster for process whose PID is $pid.
sub send_crash_report {
    my %data = @_;
    Sympa::Log::Syslog::do_log('debug', 'Sending crash report for process %s',
        $data{'pid'}),
        my $err_file = Sympa::Site->tmpdir . '/' . $data{'pid'} . '.stderr';
    my (@err_output, $err_date);
    if (-f $err_file) {
        open ERR, '<', $err_file;
        @err_output = map { chomp $_; $_; } <ERR>;
        close ERR;
        $err_date = Sympa::Language::gettext_strftime(
            "%d %b %Y  %H:%M", localtime((stat($err_file))[9])
        );
    }
    Sympa::Site->send_notify_to_listmaster(
        'crash',
        {   'crashed_process' => $data{'pname'},
            'crash_err'       => \@err_output,
            'crash_date'      => $err_date,
            'pid'             => $data{'pid'}
        }
    );
}

# return a lockname that is a uniq id of a processus (hostname + pid) ;
# hostname (20) and pid(10) are truncated in order to store lockname in
# database varchar(30)
sub get_lockname () {
    return substr(substr(hostname(), 0, 20) . $PID, 0, 30);
}

## Returns the list of pid identifiers in the pid file.
sub get_pids_in_pid_file {
    my $name = shift;

    my $piddir  = Sympa::Constants::PIDDIR;
    my $pidfile = $piddir . '/' . $name . '.pid';

    my $lock_fh = Sympa::LockedFile->new($pidfile, 5, '<');
    unless ($lock_fh) {
        Sympa::Log::Syslog::do_log('err', "unable to open pidfile %s:%s",
            $pidfile, $!);
        return undef;
    }
    my $l = <$lock_fh>;
    my @pids = grep {/^[0-9]+$/} split(/\s+/, $l);
    $lock_fh->close;
    return \@pids;
}

sub get_children_processes_list {
    Sympa::Log::Syslog::do_log('debug3', '');
    my @children;
    for my $p (@{new Proc::ProcessTable->table}) {
        if ($p->ppid == $PID) {
            push @children, $p->pid;
        }
    }
    return @children;
}

1;
