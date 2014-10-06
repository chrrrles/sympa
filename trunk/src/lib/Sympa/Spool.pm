# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: File.pm 11467 2014-09-29 16:09:33Z rousse $

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
# along with this program.  If not, see <http://www.gnu.org/licenses>.

=encoding utf-8

=head1 NAME

Sympa::Spool - An abstract spool

=head1 DESCRIPTION

This class implements an abstract spool.

=cut

package Sympa::Spool;

use strict;
use warnings;

=head1 INSTANCE METHODS

=over

=item $spool->get_id()

Return spool identifier.

=cut

sub get_id {
    my $self = shift;
    return sprintf '%s/%s', $self->{name}, $self->{status};
}

=back

=cut

1;
