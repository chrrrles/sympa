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

package Sympa::Spool::File::Task;

use strict;
use base qw(Sympa::Spool::File);

use Sympa::Logger;
use Sympa::Task;

our $filename_regexp = '^(\d+)\.([^\.]+)?\.([^\.]+)\.(\S+)$';

sub _get_file_name {
    my ($self, $param) = @_;
    my $filename;
    my $date = $param->{'task_date'} || time();
    $filename =
          $date . '.'
        . $param->{'task_label'} . '.'
        . $param->{'task_model'} . '.'
        . $param->{'task_object'};
    return $filename;
}

sub analyze_file_name {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s)', @_);
    my $self = shift;
    my $key  = shift;
    my $data = shift;

    unless ($key =~ /$filename_regexp/) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'File %s name does not have the proper format', $key);
        return undef;
    }
    $data->{'task_date'}   = $1;
    $data->{'task_label'}  = $2;
    $data->{'task_model'}  = $3;
    $data->{'task_object'} = $4;
    $main::logger->do_log(
        Sympa::Logger::DEBUG3,              'date %s, label %s, model %s, object %s',
        $data->{'task_date'},  $data->{'task_label'},
        $data->{'task_model'}, $data->{'task_object'}
    );
    unless ($data->{'task_object'} eq '_global') {
        ($data->{'list'}, $data->{'robot'}) =
            split /\@/, $data->{'task_object'};
    }

    $data->{'list'}  = lc($data->{'list'});
    $data->{'robot'} = lc($data->{'robot'});
    require Sympa::Robot;
    return undef
        unless $data->{'robot_object'} = Sympa::Robot->new($data->{'robot'});

    my $listname;

    #FIXME: is this needed?
    ($listname, $data->{'type'}) =
        $data->{'robot_object'}->split_listname($data->{'list'});
    if (defined $listname) {
        require Sympa::List;
        $data->{'list_object'} =
            Sympa::List->new($listname, $data->{'robot_object'}, {'just_try' => 1});
    }

    return $data;
}

=head1 INSTANCE METHODS

=cut

sub get_entries {
    my ($self, %params) = @_;

    my @tasks;
    foreach my $task_in_spool ($self->get_raw_entries(%params)) {
        next unless $task_in_spool; # is this really needed ?

        my $list;
        if ($task_in_spool->{'list'}) {
            $list = Sympa::List->new(
                $task_in_spool->{'list'},
                $task_in_spool->{'domain'},
                {'skip_sync_admin' => 1}
            );
        }
            
        my $task = Sympa::Task->new(
            messageasstring => $task_in_spool->{'messageasstring'},
            date            => $task_in_spool->{'task_date'},
            label           => $task_in_spool->{'task_label'},
            model           => $task_in_spool->{'task_model'},
            flavour         => $task_in_spool->{'task_flavour'},
            object          => $task_in_spool->{'task_object'},
            list            => $list
        );
        next unless $task; # is this really needed ?

        push @tasks, $task;
    }

    return @tasks;
}

1;
