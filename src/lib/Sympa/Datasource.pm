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

Sympa::Datasource - FIXME

=head1 DESCRIPTION

FIXME

=cut

package Sympa::Datasource;

use strict;

use Carp qw(croak);
use Digest::MD5;

use Sympa::Logger;
use Sympa::Tools;

############################################################
#  constructor
############################################################
#  Create a new datasource object. Handle SQL source only
#  at this moment.
#
# IN : -$type (+): the type of datasource to create
#         'SQL' or 'MAIN' for main sympa database
#      -$param_ref (+): ref to a Hash of config data
#
# OUT : instance of Datasource
#     | undef
#
##############################################################
sub new {

    my ($pkg, $param) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG, '');
    my $self = $param;
    ## Bless Message object
    bless $self, $pkg;
    return $self;
}

# Returns a unique ID for an include datasource
sub _get_datasource_id {
    my ($source) = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        "Getting datasource id for source '%s'", $source);
    if (ref($source) eq 'Sympa::Datasource') {
        $source = shift;
    }

    if (ref($source)) {
        ## Ordering values so that order of keys in a hash don't mess the
        ## value comparison
        ## Warning: Only the first level of the hash is ordered. Should a
        ## datasource
        ## be described with a hash containing more than one level (a hash of
        ## hash) we should transform
        ## the following algorithm into something that would be recursive.
        ## Unlikely it happens.
        my @orderedValues;
        foreach my $key (sort (keys %{$source})) {
            @orderedValues = (@orderedValues, $key, $source->{$key});
        }
        return substr(Digest::MD5::md5_hex(join('/', @orderedValues)), -8);
    } else {
        return substr(Digest::MD5::md5_hex($source), -8);
    }

}

sub is_allowed_to_sync {
    my $self   = shift;
    my $ranges = $self->{'nosync_time_ranges'};
    $ranges =~ s/^\s+//;
    $ranges =~ s/\s+$//;
    my $rsre = Sympa::Tools::get_regexp('time_ranges');
    return 1 unless ($ranges =~ /^$rsre$/);

    $main::logger->do_log(Sympa::Logger::DEBUG,
        "Checking whether sync is allowed at current time");

    my (undef, $min, $hour) = localtime(time);
    my $now = 60 * int($hour) + int($min);

    foreach my $range (split(/\s+/, $ranges)) {
        next
            unless ($range =~
            /^([012]?[0-9])(?:\:([0-5][0-9]))?-([012]?[0-9])(?:\:([0-5][0-9]))?$/
            );
        my $start = 60 * int($1) + int($2);
        my $end   = 60 * int($3) + int($4);
        $end += 24 * 60 if ($end < $start);

        $main::logger->do_log(Sympa::Logger::DEBUG,
                  "Checking for range from "
                . sprintf('%02d', $start / 60) . "h"
                . sprintf('%02d', $start % 60) . " to "
                . sprintf('%02d', ($end / 60) % 24) . "h"
                . sprintf('%02d', $end % 60));

        next if ($start == $end);

        if ($now >= $start && $now <= $end) {
            $main::logger->do_log(Sympa::Logger::DEBUG, "Failed, sync not allowed.");
            return 0;
        }

        $main::logger->do_log(Sympa::Logger::DEBUG, "Pass ...");
    }

    $main::logger->do_log(Sympa::Logger::DEBUG, "Sync allowed");
    return 1;
}

1;
