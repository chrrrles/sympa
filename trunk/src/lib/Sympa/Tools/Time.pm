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

=encoding utf-8

=head1 NAME

Sympa::Tools::Time - Time-related functions

=head1 DESCRIPTION

This package provides time-related functions.

=cut

package Sympa::Tools::Time;

use strict;

use DateTime;
use Time::Local qw();

use Sympa::Logger;

=head1 FUNCTIONS

=over

=item adate($timestamp)

Convert a date, as a timestamp, into a formatted string.

Parameters:

=over

=item * I<$timestamp>: the date, as a timestamp

=back

=cut

sub adate {
    my ($timestamp) = @_;

    my $time = DateTime->from_epoch(epoch => $timestamp, time_zone => 'local');
    return $time->strftime("%e %a %b %Y  %H h %M min %S s");
}

=item get_midnight_time($timestamp)

Return the date, as a timestamp, corresponding to the last midnight before the given date.

Parameters:

=over

=item * I<$timestamp>: the date, as a timestamp

=back

=cut

sub get_midnight_time {
    my ($timestamp) = @_;

    my $time = DateTime->from_epoch(epoch => $timestamp, time_zone => 'local');
    return $time->truncate(to => 'day')->epoch();
}

=item epoch_conv($a, $b)

FIXME.

=cut

sub epoch_conv {

    my $arg = $_[0];             # argument date to convert
    my $time = $_[1] || time;    # the epoch current date

    $main::logger->do_log(Sympa::Logger::DEBUG3, 'Sympa::Tools::Time::epoch_conv(%s, %d)',
        $arg, $time);

    my $result;

    # decomposition of the argument date
    my $date;
    my $duration;
    my $op;

    if ($arg =~ /^(.+)(\+|\-)(.+)$/) {
        $date     = $1;
        $duration = $3;
        $op       = $2;
    } else {
        $date     = $arg;
        $duration = '';
        $op       = '+';
    }

    #conversion
    $date = date_conv($date, $time);
    $duration = duration_conv($duration, $date);

    if   ($op eq '+') { $result = $date + $duration; }
    else              { $result = $date - $duration; }

    return $result;
}

=item date_conv($a)

FIXME.

=cut

sub date_conv {

    my $arg  = $_[0];

    if (($arg eq 'execution_date')) {    # execution date
        return time;
    }

    if ($arg =~ /^\d+$/) {               # already an epoch date
        return $arg;
    }

    if ($arg =~ /^(\d\d\d\dy)(\d+m)?(\d+d)?(\d+h)?(\d+min)?(\d+sec)?$/) {

        # absolute date

        my @date = ($6, $5, $4, $3, $2, $1);
        foreach my $part (@date) {
            $part =~ s/[a-z]+$// if $part;
            $part ||= 0;
            $part += 0;
        }
        $date[3] = 1 if $date[3] == 0;
        $date[4]-- if $date[4] != 0;
        $date[5] -= 1900;

        return Time::Local::timelocal(@date);
    }

    return time;
}

=item duration_conv($a, $b)

FIXME.

=cut

sub duration_conv {

    my $arg        = $_[0];
    my $start_date = $_[1];

    return 0 unless $arg;

    $arg =~ /
        (?:(\d+) y)  ?
        (?:(\d+) m)  ?
        (?:(\d+) w)  ?
        (?:(\d+) d)  ?
        (?:(\d+) h)  ?
        (?:(\d+) min)?
        (?:(\d+) sec)?
        $/xi;
    my $years   = $1 || 0,
    my $monthes = $2 || 0;
    my $weeks   = $3 || 0;
    my $days    = $4 || 0;
    my $hours   = $5 || 0;
    my $minutes = $6 || 0;
    my $seconds = $7 || 0;

    my $duration =
        $seconds +
        $minutes * 60 +
        $hours   * 60  * 60 +
        $days    * 24  * 60 * 60 +
        $weeks   * 7   * 24 * 60 * 60 +
        $years   * 365 * 24 * 60 * 60;

    # specific processing for the months because their duration varies
    my @months = (
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    );
    my $start_month = (localtime($start_date))[4];
    for (my $i = 0; $i < $monthes; $i++) {
        $duration += $months[$start_month + $i] * 60 * 60 * 24;
    }

    return $duration;
}

=back

=cut

1;
