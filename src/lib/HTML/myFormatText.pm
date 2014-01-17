# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4:textwidth=78
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

package HTML::myFormatText;

# This is a subclass of the HTML::FormatText object.
# This subclassing is done to allow internationalisation of some strings

our @ISA = qw(HTML::FormatText);

use Language;
use strict;

sub img_start {
    my ($self, $node) = @_;
    my $alt = $node->attr('alt');
    $self->out(
        defined($alt)
        ? sprintf(gettext("[ Image%s ]"), ": " . $alt)
        : sprintf(gettext("[Image%s]"),   "")
    );
}

1;
