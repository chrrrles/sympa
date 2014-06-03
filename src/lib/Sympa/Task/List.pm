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

package Sympa::Task::List;

use strict;
use base qw(Sympa::Task);

use Carp qw(croak);

use Sympa::Log::Syslog;

sub new {
    my ($class, %params) = @_;

    croak "missing parameter list"
        unless $params{'list'};

    croak "invalid parameter list: should be a Sympa::List instance"
        unless $params{'list'}->isa('Sympa::List');

    my $self = $class->_new(%params);

    $self->{'list'}        = $params{'list'};
    $self->{'id'}          = $params{'list'}->{'domain'} ?
        $params{'list'}->{'name'} . '@' . $params{'list'}->{'domain'} :
        $params{'list'}->{'name'};
    $self->{'description'} .= sprintf(' (list %s)', $self->{'id'});

    return $self;
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


    unless ($self->{'template'} =
        $self->{'list'}->get_etc_filename("list_task_models/$self->{'model_name'}")) {
        Sympa::Log::Syslog::do_log(
            'err',
            'Unable to find task model %s for list %s. Creation aborted',
            $self->{'model_name'},
            $self->{'list'}->get_list_id()
        );
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
        'list'         => $self->{'list'}{'name'},
        'domain'       => $self->{'list'}{'domain'},
    );

    return %meta;
}

sub check_validity {
    my ($self) = @_;

    my $list  = $self->{'list'};
    my $model = $self->{'model'};

    ## Skip closed lists
    if ($list->status ne 'open') {
        Sympa::Log::Syslog::do_log(
            'notice',
            'Removing task %s, label %s (messageid = %s) because list %s is closed',
            $model,
            $self->{'label'},
            $self->{'messagekey'},
            $self->{'id'}
        );
        return 0;
    }

    ## Skip if parameter is not defined
    if ($model eq 'sync_include') {
        if ($list->has_include_data_sources()) {
            return 1;
        } else {
            Sympa::Log::Syslog::do_log(
                'notice',
                'Removing task %s, label %s (messageid = %s) because list does not use any inclusion',
                $model,
                $self->{'label'},
                $self->{'messagekey'},
                $self->{'id'}
            );
            return 0;
        }
    } else {
        unless (%{$list->$model} and defined $list->$model->{'name'}) {
            Sympa::Log::Syslog::do_log(
                'notice',
                'Removing task %s, label %s (messageid = %s) because it is not defined in list %s configuration',
                $model,
                $self->{'label'},
                $self->{'messagekey'},
                $self->{'id'}
            );
            return 0;
        }
    }

    return 1;
}

1;
