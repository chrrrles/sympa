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

package Sympa::Task::Global;

use strict;
use base qw(Sympa::Task);

use Sympa::Log::Syslog;

sub new {
    my ($class, %params) = @_;

    return $class->_new(%params);
}

## Sets and returns the path to the file that must be used to generate the
## task as string.
sub _get_template {
    my ($self) = @_;

    Sympa::Log::Syslog::do_log('debug2',
        'Computing model file path for task %s',
        $self->get_description);

    unless ($self->{'model'}) {
        Sympa::Log::Syslog::do_log('err',
            'Missing a model name. Impossible to get a template. Aborting.');
        return undef;
    }
    unless ($self->{'flavour'}) {
        Sympa::Log::Syslog::do_log(
            'err',
            'Missing a flavour name for model %s name. Impossible to get a template. Aborting.',
            $self->{'model'}
        );
        return undef;
    }

    $self->{'model_name'} =
        $self->{'model'} . '.' . $self->{'flavour'} . '.' . 'task';


    unless (
        $self->{'template'} = Sympa::Site->get_etc_filename(
            "global_task_models/$self->{'model_name'}")
        ) {
        Sympa::Log::Syslog::do_log('err',
            'Unable to find task model %s. Creation aborted',
            $self->{'model_name'});
        return undef;
    }

    Sympa::Log::Syslog::do_log('debug2', 'Model for task %s is %s',
        $self->get_description, $self->{'template'});

    return $self->{'template'};
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
