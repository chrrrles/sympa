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

Sympa::Logger::Syslog - A syslog-based logger

=head1 DESCRIPTION

This is a logger implementation sending every message to syslog daemon.

=cut

package Sympa::Logger::Syslog;

use strict;

use English qw(-no_match_vars);

use Sys::Syslog;

# map internal constants against syslog levels
my %syslog_levels = (
    Sympa::Logger::ERR    => Sys::Syslog::LOG_ERR,
    Sympa::Logger::INFO   => Sys::Syslog::LOG_INFO,
    Sympa::Logger::NOTICE => Sys::Syslog::LOG_NOTICE,
    Sympa::Logger::TRACE  => Sys::Syslog::LOG_NOTICE,
    Sympa::Logger::DEBUG  => Sys::Syslog::LOG_DEBUG,
    Sympa::Logger::DEBUG2 => Sys::Syslog::LOG_DEBUG,
    Sympa::Logger::DEBUG3 => Sys::Syslog::LOG_DEBUG,
);

=head1 CLASS METHODS

=over

=item Sympa::Logger::Syslog->new(%parameters)

Creates a new L<Sympa::Logger::Syslog> object.

Parameters:

=over 4

=item * I<facility>: FIXME

=item * I<service>: FIXME

=item * I<level>: FIXME

=back

Returns a new L<Sympa::Logger::Syslog> object, or I<undef> for failure.

=cut

sub new {
    my ($class, %params) = @_;

    my $facility = $params{facility};
    my $service  = $params{service} || 'sympa';

    eval { 
        Sys::Syslog::openlog($service, 'ndelay,pid', $facility);
    };
    return undef if $EVAL_ERROR;

    return $class->_new(%params);
}

sub DESTROY {
    # flush log
    Sys::Syslog::closelog();
}

sub _do_log {
    my ($self, $level, $message, @args) = @_;

    Sys::Syslog::syslog($syslog_levels{$level}, $message, @args);
}

=back

=cut

1;
