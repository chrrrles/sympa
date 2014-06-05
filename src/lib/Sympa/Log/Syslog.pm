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

package Sympa::Log::Syslog;

use strict;
use English qw(-no_match_vars);

#use Carp; # currently not used
use Sys::Syslog;

my ($log_facility, $log_socket_type, $log_service);

# When logs are not available, period of time to wait before sending another
# warning to listmaster.
my $warning_timeout = 600;

# Date of the last time a message was sent to warn the listmaster that the
# logs are unavailable.
my $warning_date = 0;

my $log_level = undef;

my %levels = (
    err    => 0,
    info   => 0,
    notice => 0,
    trace  => 0,
    debug  => 1,
    debug2 => 2,
    debug3 => 3,
);

##sub import {
##my @call = caller(1);
##printf "Import from $call[3]\n";
##Log->export_to_level(1, @_);
##}
##
sub fatal_err {
    my $m     = shift;

    eval {
        syslog('err', $m, @_);
        syslog('err', "Exiting.");
    };
    if ($EVAL_ERROR && ($warning_date < time - $warning_timeout)) {
        $warning_date = time + $warning_timeout;
        unless (Sympa::Site->send_notify_to_listmaster('logs_failed', [$EVAL_ERROR])) {
            print STDERR "No logs available, can't send warning message";
        }
    }
    $m =~ s/%m/$ERRNO/g;

    my $full_msg = sprintf $m, @_;

    ## Notify listmaster
    Sympa::Site->send_notify_to_listmaster('sympa_died', [$full_msg]);

    eval { Sympa::Site->send_notify_to_listmaster(undef, undef, undef, 1); };
    eval { Sympa::DatabaseManager::db_disconnect(); };    # unlock database
    Sys::Syslog::closelog();           # flush log

    printf STDERR "$m\n", @_;
    exit(1);
}

sub do_log {
    my $level = shift;

    unless (defined $levels{$level}) {
        do_log('err', 'Invalid $level: "%s"', $level);
        $level = 'info';
    }

    # do not log if log level is too high regarding the log requested by user
    return if defined $log_level  and $levels{$level} > $log_level;
    return if !defined $log_level and $levels{$level} > 0;

    my $message = shift;
    my @param   = ();

    ## Do not display variables which are references.
    my @n = ($message =~ /(%[^%])/g);
    for (my $i = 0; $i < scalar @n; $i++) {
        my $p = $_[$i];
        unless (defined $p) {

            # prevent 'Use of uninitialized value' warning
            push @param, '';
        } elsif (ref $p) {
            if (ref $p eq 'ARRAY') {
                push @param, '[...]';
            } elsif (ref $p eq 'HASH') {
                push @param, sprintf('{%s}', join('/', keys %{$p}));
            } elsif (ref $p eq 'Regexp' or ref $p eq uc ref $p) {

                # other unblessed references
                push @param, ref $p;
            } elsif ($p->can('get_id')) {
                push @param, sprintf('%s <%s>', ref $p, $p->get_id);
            } else {
                push @param, ref $p;
            }
        } else {
            push @param, $p;
        }
    }

    ## Determine calling function
    my $caller_string;

    ## If in 'err' level, build a stack trace,
    ## except if syslog has not been setup yet.
    if (defined $log_level and $level eq 'err') {
        my $go_back = 1;
        my @calls;

        my @f = caller($go_back);
        if ($f[3] =~ /wwslog$/) {   ## If called via wwslog, go one step ahead
            @f = caller(++$go_back);
        }
        @calls = ('#' . $f[2]);
        while (@f = caller(++$go_back)) {
            $calls[0] = $f[3] . $calls[0];
            unshift @calls, '#' . $f[2];
        }
        $calls[0] = '(top-level)' . $calls[0];

        $caller_string = join(' > ', @calls);
    } else {
        my @call = caller(1);

        ## If called via wwslog, go one step ahead
        if ($call[3] and $call[3] =~ /wwslog$/) {
            @call = caller(2);
        }

        $caller_string = ($call[3] || '') . '()';
    }

    $message = $caller_string . ' ' . $message if ($caller_string);

    ## Add facility to log entry
    $message = $level . ' ' . $message;

    # map to standard syslog facility if needed
    if ($level eq 'trace') {
        $message = "###### TRACE MESSAGE ######:  " . $message;
        $level   = 'notice';
    } elsif ($level eq 'debug2' || $level eq 'debug3') {
        $level = 'debug';
    }

    ## Output to STDERR if needed
    if (   !defined $log_level
        or ($main::options{'foreground'} and $main::options{'log_to_stderr'})
        or (    $main::options{'foreground'}
            and $main::options{'batch'}
            and $level eq 'err')
        ) {
        $message =~ s/%m/$ERRNO/g;
        printf STDERR "$message\n", @param;
    }

    return unless defined $log_level;
    syslog($level, $message, @param);
}

sub do_openlog {
    my ($fac, $socket_type, $service) = @_;
    $service ||= 'sympa';

    ($log_facility, $log_socket_type, $log_service) =
        ($fac, $socket_type, $service);

    if ($log_socket_type =~ /^(unix|inet)$/i) {
        Sys::Syslog::setlogsock(lc($log_socket_type));
    }

    # close log may be usefull : if parent processus did open log child
    # process inherit the openlog with parameters from parent process
    closelog;
    eval { openlog("$log_service\[$PID\]", 'ndelay,nofatal', $log_facility) };
    if ($EVAL_ERROR && ($warning_date < time - $warning_timeout)) {
        $warning_date = time + $warning_timeout;
        unless (Sympa::Site->send_notify_to_listmaster('logs_failed', [$EVAL_ERROR])) {
            print STDERR "No logs available, can't send warning message";
        }
    }
}

sub set_log_level {
    $log_level = shift;
}

sub get_log_level {
    return $log_level;
}

1;
