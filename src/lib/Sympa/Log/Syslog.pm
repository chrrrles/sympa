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

use constant {
    ERR    => 0,
    INFO   => 1,
    NOTICE => 2,
    TRACE  => 3,
    DEBUG  => 4,
    DEBUG2 => 5,
    DEBUG3 => 6,
};

use English qw(-no_match_vars);

#use Carp; # currently not used
use Sys::Syslog;

my ($log_facility, $log_service);

# When logs are not available, period of time to wait before sending another
# warning to listmaster.
my $warning_timeout = 600;

# Date of the last time a message was sent to warn the listmaster that the
# logs are unavailable.
my $warning_date = 0;

my $log_level = undef;

# map internal constants against sympa 'log_level' directive
my %sympa_levels = (
    ERR    => 0,
    INFO   => 0,
    NOTICE => 0,
    TRACE  => 0,
    DEBUG  => 1,
    DEBUG2 => 2,
    DEBUG3 => 3,
);

# map internal constants against syslog levels
my %syslog_levels = (
    ERR    => Sys::Syslog::LOG_ERR,
    INFO   => Sys::Syslog::LOG_INFO,
    NOTICE => Sys::Syslog::LOG_NOTICE,
    TRACE  => Sys::Syslog::LOG_NOTICE,
    DEBUG  => Sys::Syslog::LOG_DEBUG,
    DEBUG2 => Sys::Syslog::LOG_DEBUG,
    DEBUG3 => Sys::Syslog::LOG_DEBUG,
);

##sub import {
##my @call = caller(1);
##printf "Import from $call[3]\n";
##Log->export_to_level(1, @_);
##}
##
sub fatal_err {
    my $m     = shift;

    syslog('err', $m, @_);
    syslog('err', "Exiting.");
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

    # do not log if log level is too high regarding the log requested by user
    return if defined $log_level  and $sympa_levels{$level} > $log_level;
    return if !defined $log_level and $sympa_levels{$level} > 0;

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
    if (defined $log_level and $level == ERR) {
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

    ## Output to STDERR if needed
    if (   !defined $log_level
        or ($main::options{'foreground'} and $main::options{'log_to_stderr'})
        or (    $main::options{'foreground'}
            and $main::options{'batch'}
            and $level == ERR)
        ) {
        $message =~ s/%m/$ERRNO/g;
        printf STDERR "$message\n", @param;
    }

    return unless defined $log_level;
    syslog($syslog_levels{$level}, $message, @param);
}

sub do_openlog {
    my ($fac, $service) = @_;
    $service ||= 'sympa';

    ($log_facility, $log_service) =
        ($fac, $service);

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
