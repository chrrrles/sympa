# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: Syslog.pm 10492 2014-03-31 12:43:45Z rousse $

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

Sympa::Logger::Stderr - A stderr-based logger

=head1 DESCRIPTION

This is a logger implementation sending every message to STDERR.

=cut

package Sympa::Logger::Stderr;

use strict;
use base qw(Sympa::Logger);

use English qw(-no_match_vars);

=head1 CLASS METHODS

=over

=item Sympa::Logger::Stderr->new(%params)

Creates a new L<Sympa::Logger::Stderr> object.

Parameters:

=over 4

=item * I<level>: FIXME

=back

Returns a new L<Sympa::Logger::Stderr> object, or I<undef> for failure.

=cut

sub new {
    my ($class, %params) = @_;

    return $class->_new(%params);
}

sub _do_log {
    my ($self, $level, $message, @args) = @_;

    $message =~ s/%m/$ERRNO/g;
    printf STDERR $message . "\n", @args;
}

=back

=cut

1;
