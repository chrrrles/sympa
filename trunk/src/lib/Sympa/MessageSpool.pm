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

package Sympa::MessageSpool;

use SympaspoolClassic;
use Sympa::Log;

our @ISA = qw(SympaspoolClassic);

sub new {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s)', @_);
    my $pkg = shift;
    return $pkg->SUPER::new(
        'msg', shift,
        'sortby'   => 'priority',
        'selector' => {'priority' => ['z', 'ne']},
    );
}

sub is_relevant {
    Sympa::Log::Syslog::do_log('debug3', '(%s, %s)', @_);
    my $self = shift;
    my $key  = shift;

    ## z and Z are a null priority, so file stay in queue and are processed
    ## only if renamed by administrator
    return 0 unless $key =~ /$filename_regexp/;

    ## Don't process temporary files created by queue (T.xxx)
    return 0 if $key =~ /^T\./;

    return 1;
}

1;
