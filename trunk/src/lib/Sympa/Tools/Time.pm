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

package Sympa::Tools::Time;

use strict;

use POSIX qw();
use Time::Local qw();

use Sympa::Log::Syslog;

my %Month2Num = (
    'jan', 0, 'feb', 1, 'mar', 2, 'apr', 3, 'may', 4, 'jun', 5, 'jul', 6,
    'aug', 7, 'sep', 8, 'oct', 9, 'nov', 10, 'dec', 11,
    'january', 0, 'february', 1, 'march', 2, 'april', 3,
    'may', 4, 'june', 5, 'july', 6, 'august', 7,
    'september', 8, 'october', 9, 'november', 10, 'december', 11,
);
my %WDay2Num = (
    'sun', 0, 'mon', 1, 'tue', 2, 'wed', 3, 'thu', 4, 'fri', 5, 'sat', 6,
    'sunday', 0, 'monday', 1, 'tuesday', 2, 'wednesday', 3, 'thursday', 4,
    'friday', 5, 'saturday', 6,
);

## The following used in parse_date() regexes
my $p_weekdays = 'Mon|Tue|Wed|Thu|Fri|Sat|Sun';
my $p_Weekdays = 'Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday';
my $p_months   = 'Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec';
my $p_Months   = 'January|February|March|April|May|June|July|August'.
		 '|September|October|November|December';
my $p_hrminsec = '\d{1,2}:\d\d:\d\d';
my $p_hrmin    = '\d{1,2}:\d\d';
my $p_day      = '\d{1,2}';
my $p_year     = '\d\d\d\d|\d\d';

## convert an epoch date into a readable date scalar
sub epoch2yyyymmjj_hhmmss {

    my $epoch = $_[0];
    my @date  = localtime($epoch);
    my $date  = POSIX::strftime("%Y-%m-%d  %H:%M:%S", @date);

    return $date;
}

## convert an epoch date into a readable date scalar
sub adate {

    my $epoch = $_[0];
    my @date  = localtime($epoch);
    my $date  = POSIX::strftime("%e %a %b %Y  %H h %M min %S s", @date);

    return $date;
}

## Return the epoch date corresponding to the last midnight before date given
## as argument.
sub get_midnight_time {

    my $epoch = $_[0];
    Sympa::Log::Syslog::do_log('debug3', 'Getting midnight time for: %s',
        $epoch);
    my @date = localtime($epoch);
    return $epoch - $date[0] - $date[1] * 60 - $date[2] * 3600;
}

## convert a human format date into an epoch date
sub epoch_conv {

    my $arg = $_[0];             # argument date to convert
    my $time = $_[1] || time;    # the epoch current date

    Sympa::Log::Syslog::do_log('debug3', 'Sympa::Tools::Time::epoch_conv(%s, %d)',
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

        my @date = ("$6", "$5", "$4", "$3", "$2", "$1");
        for (my $i = 0; $i < 6; $i++) {
            chop($date[$i]);
            if (($i == 1) || ($i == 2)) { chop($date[$i]); chop($date[$i]); }
            $date[$i] = 0 unless ($date[$i]);
        }
        $date[3] = 1 if ($date[3] == 0);
        $date[4]-- if ($date[4] != 0);
        $date[5] -= 1900;

        return Time::Local::timelocal(@date);
    }

    return time;
}

sub duration_conv {

    my $arg        = $_[0];
    my $start_date = $_[1];

    return 0 unless $arg;

    $arg =~ /(\d+y)?(\d+m)?(\d+w)?(\d+d)?(\d+h)?(\d+min)?(\d+sec)?$/i;
    my @date = ("$1", "$2", "$3", "$4", "$5", "$6", "$7");
    for (my $i = 0; $i < 7; $i++) {
        $date[$i] =~ s/[a-z]+$//;    ## Remove trailing units
    }

    my $duration =
        $date[6] + 60 *
        ($date[5] +
            60 * ($date[4] + 24 * ($date[3] + 7 * $date[2] + 365 * $date[0]))
        );

    # specific processing for the months because their duration varies
    my @months = (
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    );
    my $start = (localtime($start_date))[4];
    for (my $i = 0; $i < $date[1]; $i++) {
        $duration += $months[$start + $i] * 60 * 60 * 24;
    }

    return $duration;
}

## parse_date takes a string date specified like the output of
## date(1) into its components.  Parsing a string for a date is
## ugly since we have to watch out for differing formats.
##
## The following date formats are looked for:
##
##     Wdy DD Mon YY HH:MM:SS Zone
##     DD Mon YY HH:MM:SS Zone
##     Wdy Mon DD HH:MM:SS Zone YYYY
##     Wdy Mon DD HH:MM:SS YYYY
##
## The routine keys off of the day of time field "HH:MM:SS" and
## scans realtive to its location.
##
## If the parse fails, a null array is returned. Thus the routine
## may be used as follows:
##
##          if ( (@x = parse_date($date)) ) { Success }
##          else { Fail }
##
## If success the array contents are as follows:
##
##     (Weekday (0-6), Day of the month (1-31), Month (0-11),
##      Year, Hour, Minutes, Seconds, Time Zone)
##
## Copyright (C) 1996-1999 Earl Hood, mhonarc@mhonarc.org
## Contributer(s): Frank J. Manion <FJ_Manion@fccc.edu>
##
sub parse_date {
    my($date) = $_[0];
    my($wday, $mday, $mon, $yr, $time, $hr, $min, $sec, $zone);
    my(@array);
    my($start, $rest);

    # Try to find the date by focusing on the "\d\d:\d\d" field.
    # All parsing is then done relative to this location.
    #
    $date =~ s/^\s+//;  $time = "";  $rest = "";
    # Don't use $p_hrmin(sec) vars in split due to bug in perl 5.003.
    ($start, $time, $rest) = split(/(\b\d{1,2}:\d\d:\d\d)/o, $date, 2);
    ($start, $time, $rest) = split(/(\b\d{1,2}:\d\d)/o, $date, 2)
        if !defined($time) or $time eq "";
    return ()
        unless defined($time) and $time ne "";

    ($hr, $min, $sec) = split(/:/, $time);
    $sec = 0  unless $sec;          # Sometimes seconds not defined

    # Strip $start of all but the last 4 tokens,
    # and stuff all tokens in $rest into @array
    #
    @array = split(' ', $start);
    $start = join(' ', ($#array-3 < 0) ? @array[0..$#array] :
                                         @array[$#array-3..$#array]);
    @array = split(' ', $rest);
    $rest  = join(' ', ($#array  >= 1) ? @array[0..1] :
                                         $array[0]);
    # Wdy DD Mon YY HH:MM:SS Zone
    if ( $start =~
        /($p_weekdays),*\s+($p_day)\s+($p_months)\s+($p_year)$/io ) {

        ($wday, $mday, $mon, $yr, $zone) = ($1, $2, $3, $4, $array[0]);

    # DD Mon YY HH:MM:SS Zone
    } elsif ( $start =~ /($p_day)\s+($p_months)\s+($p_year)$/io ) {
        ($mday, $mon, $yr, $zone) = ($1, $2, $3, $array[0]);

    # Wdy Mon DD HH:MM:SS Zone YYYY
    # Wdy Mon DD HH:MM:SS YYYY
    } elsif ( $start =~ /($p_weekdays),?\s+($p_months)\s+($p_day)$/io ) {
        ($wday, $mon, $mday) = ($1, $2, $3);
        if ( $rest =~ /^(\S+)\s+($p_year)/o ) { # Zone YYYY
            ($zone, $yr) = ($1, $2);
        } elsif ( $rest =~ /^($p_year)/o ) {    # YYYY
            ($yr) = ($1);
        } else {                                # zilch, use current year
            warn "Warning: No year in date ($date), using current\n";
            $yr = (localtime(time))[5];
        }

    # Weekday Month DD YYYY HH:MM Zone
    } elsif ( $start =~
        /($p_Weekdays),?\s+($p_Months)\s+($p_day),?\s+($p_year)$/ ) {
        ($wday, $mon, $mday, $yr, $zone) = ($1, $2, $3, $4, $array[0]);

    # All else fails!
    } else {
        return ();
    }

    # Modify month and weekday for lookup
    $mon  = $Month2Num{lc $mon}  if defined($mon);
    $wday = $WDay2Num{lc $wday}  if defined($wday);

    ($wday, $mday, $mon, $yr, $hr, $min, $sec, $zone);
}

1;
