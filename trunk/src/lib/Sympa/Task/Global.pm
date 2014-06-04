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

Sympa::Task::Global - A global background task

=head1 DESCRIPTION

This class implements a global background task, such as cleaning the expired
sessions for instance.

=cut

package Sympa::Task::Global;

use strict;
use base qw(Sympa::Task);

use Sympa::Log::Syslog;
use Sympa::Site;

sub new {
    my ($class, %params) = @_;

    return $class->_new(%params);
}

# returns the path to template used to generate the
# task as string.
sub _get_template {
    my ($self, $model_name) = @_;

    return Sympa::Site->get_etc_filename(
        "global_task_models/$model_name"
    );
}

sub get_metadata {
    my ($self) = @_;

    my %meta = (
        'task_date'    => $self->{'date'},
        'date'         => $self->{'date'},
        'task_label'   => $self->{'label'},
        'task_model'   => $self->{'model'},
        'task_flavour' => $self->{'flavour'},
    );

    return %meta;
}

sub check_validity {
    return 1;
}

1;
