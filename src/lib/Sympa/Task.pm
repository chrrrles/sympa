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

package Sympa::Task;

use strict;

use Carp qw(croak);
use English qw(-no_match_vars);
use Template;

use Sympa::Log::Syslog;
use Sympa::Site;
use Sympa::Spool::File::Task;
use Sympa::Instruction;
use Sympa::Tools::Time;

=head1 CLASS METHODS

=over 4

=item Sympa::Task->new(%parameters)

Creates a new L<Sympa::Task> object.

Parameters:

=over 4

=item * I<messageasstring>: FIXME

=item * I<date>: FIXME

=item * I<label>: FIXME

=item * I<model>: FIXME

=item * I<flavour>: FIXME

=item * I<object>: FIXME

=item * I<robot>: FIXME

=item * I<list>: FIXME

=back

Returns a new L<Sympa::Task> object, or I<undef> for failure.

=cut

sub new {
    my ($class, %params) = @_;

    Sympa::Log::Syslog::do_log(
        'debug2',
        'Sympa::Task::new  messagekey = %s',
        $params{'messagekey'}
    );

    my $self = bless {
        'messageasstring' => $params{'messageasstring'},
        'date'            => $params{'date'} || time(),
        'label'           => $params{'label'},
        'model'           => $params{'model'},
        'flavour'         => $params{'flavour'},
        'object'          => $params{'object'},
    }, $class;

    if ($params{'list'}) {    # list task
        croak "invalid parameter list: should be a Sympa::List instance"
            unless $params{'list'}->isa('Sympa::List');
        $self->{'list'}        = $params{'list'};
        $self->{'id'}          = $params{'list'}->{'domain'} ?
            $params{'list'}->{'name'} . '@' . $params{'list'}->{'domain'} :
            $params{'list'}->{'name'};
    }

    $self->{'description'} = get_description($self);

    return $self;
}

=item Sympa::Task->create(%parameters)

Creates a new L<Sympa::Task> object, and stores it in a spool.

Parameters:

=over 4

=item * I<creation_date>: FIXME

=item * I<label>: FIXME

=item * I<model>: FIXME

=item * I<flavour>: FIXME

=item * I<data>: FIXME

=back

Returns a new L<Sympa::Task> object, or I<undef> for failure.

## task creation in spool
#
=cut

sub create {
    my ($class, %params) = @_;

    Sympa::Log::Syslog::do_log(
        'notice',
        "create task date: %s label: %s model: %s flavour: %s Rdata :%s",
        $params{'creation_date'},
        $params{'label'},
        $params{'model'},
        $params{'flavour'},
        $params{'data'}
    );

    my $object = $params{'data'}{'list'} ? 'list' : '_global';

    my $self = Sympa::Task->new(
        date    => $params{'creation_date'},
        label   => $params{'label'},
        model   => $params{'model'},
        flavour => $params{'flavour'},
        list    => $params{'data'}{'list'},
        object  => $object,
    );
    unless ($self) {
        Sympa::Log::Syslog::do_log('err', 'Unable to create task object');
        return undef;
    }
    $self->{'Rdata'} = $params{'data'};

    ## model recovery
    return undef unless ($self->get_template);

    ## Task as string generation
    return undef unless ($self->generate_from_template);

    ## In case a label is specified, ensure we won't use anything in the task
    ## prior to this label.
    if ($self->{'label'}) {
        return undef unless ($self->crop_after_label($self->{'label'}));
    }

    # task is accetable, store it in spool
    return undef unless ($self->store);

    return $self;
}

## Sets and returns the path to the file that must be used to generate the
## task as string.
sub get_template {
    my $self = shift;
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

    # for global model
    if ($self->{'object'} eq '_global') {
        unless (
            $self->{'template'} = Sympa::Site->get_etc_filename(
                "global_task_models/$self->{'model_name'}")
            ) {
            Sympa::Log::Syslog::do_log('err',
                'Unable to find task model %s. Creation aborted',
                $self->{'model_name'});
            return undef;
        }
    }

    # for a list
    if ($self->{'object'} eq 'list') {
        my $list = $self->{'list'};
        unless ($self->{'template'} =
            $list->get_etc_filename("list_task_models/$self->{'model_name'}"))
        {
            Sympa::Log::Syslog::do_log(
                'err',
                'Unable to find task model %s for list %s. Creation aborted',
                $self->{'model_name'},
                $self->get_full_listname
            );
            return undef;
        }
    }
    Sympa::Log::Syslog::do_log('debug2', 'Model for task %s is %s',
        $self->get_description, $self->{'template'});
    return $self->{'template'};
}

## Uses the template of this task to generate the task as string.
sub generate_from_template {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug',
        "Generate task content with tt2 template %s",
        $self->{'template'});

    unless ($self->{'template'}) {
        unless ($self->get_template) {
            Sympa::Log::Syslog::do_log('err',
                'Unable to find a suitable template file for task %s',
                $self->get_description);
            return undef;
        }
    }
    ## creation
    my $tt2 = Template->new(
        {   'START_TAG' => quotemeta('['),
            'END_TAG'   => quotemeta(']'),
            'ABSOLUTE'  => 1
        }
    );
    my $messageasstring = '';
    if ($self->{'model'} eq 'sync_include') {
        $self->{'Rdata'}{'list'}{'ttl'} = $self->{'list'}->ttl;
    }
    unless (
        defined $tt2
        && $tt2->process(
            $self->{'template'}, $self->{'Rdata'}, \$messageasstring
        )
        ) {
        Sympa::Log::Syslog::do_log('err',
            "Failed to parse task template '%s' : %s",
            $self->{'template'}, $tt2->error());
        return undef;
    }
    $self->{'messageasstring'} = $messageasstring;

    if (!$self->check) {
        Sympa::Log::Syslog::do_log('err',
            'error : syntax error in task %s, you should check %s',
            $self->get_description, $self->{'template'});
        Sympa::Log::Syslog::do_log('notice',
            "Ignoring creation task request");
        return undef;
    }
    Sympa::Log::Syslog::do_log('debug2', 'Resulting task_as_string: %s',
        $self->as_string());
    return 1;
}

# Chop whetever content the task as string could contain (except titles)
# before the label of the task.
sub crop_after_label {
    my $self  = shift;
    my $label = shift;

    Sympa::Log::Syslog::do_log(
        'debug',
        'Cropping task content to keep only the content located starting label %s',
        $label
    );

    # If this variable still contains 0 at the end of the sub, that means that
    # the label after which we want to crop does not exist in the task. We
    # will therefore not crop anything and return the task with the same
    # content.
    my $label_found_in_task = 0;
    my @new_parsed_instructions;
    $self->parse
        unless (defined $self->{'parsed_instructions'}
        && $#{$self->{'parsed_instructions'}} > -1);
    foreach my $line (@{$self->{'parsed_instructions'}}) {
        if ($line->{'nature'} eq 'label' && $line->{'label'} eq $label) {
            $label_found_in_task = 1;
            push @new_parsed_instructions,
                {'nature' => 'empty line', 'line_as_string' => ''};
        }
        if ($label_found_in_task || $line->{'nature'} eq 'title') {
            push @new_parsed_instructions, $line;
        }
    }
    unless ($label_found_in_task) {
        Sympa::Log::Syslog::do_log('err',
            'The label %s does not exist in task %s. We can not crop after it.'
        );
        return undef;
    } else {
        $self->{'parsed_instructions'} = \@new_parsed_instructions;
        $self->stringify_parsed_instructions;
    }

    return 1;
}

## Stores the task to database
sub store {
    my $self = shift;

    Sympa::Log::Syslog::do_log('debug', 'Spooling task %s',
        $self->get_description);
    my $taskspool = Sympa::Spool::File::Task->new;
    my %meta;
    $meta{'task_date'}    = $self->{'date'};
    $meta{'date'}         = $self->{'date'};
    $meta{'task_label'}   = $self->{'label'};
    $meta{'task_model'}   = $self->{'model'};
    $meta{'task_flavour'} = $self->{'flavour'};
    if ($self->{'list'}) {
        $meta{'list'}        = $self->{'list'}{'name'};
        $meta{'domain'}      = $self->{'list'}{'domain'};
        $meta{'task_object'} = $self->{'id'};
    } else {
        $meta{'task_object'} = '_global';
    }

    Sympa::Log::Syslog::do_log(
        'debug3',
        'Task creation done. date: %s, label: %s, model: %s, flavour: %s',
        $self->{'date'},
        $self->{'label'},
        $self->{'model'},
        $self->{'flavour'}
    );
    unless ($taskspool->store($self->{'messageasstring'}, \%meta)) {
        Sympa::Log::Syslog::do_log('err', 'Unable to store task %s.',
            $self->get_description);
        return undef;
    }
    Sympa::Log::Syslog::do_log('debug3', 'task %s successfully stored.',
        $self->get_description);
    return 1;
}

## Removes a task using message key
sub remove {
    Sympa::Log::Syslog::do_log('debug2', '(%s)', @_);
    my $self = shift;

    my $taskspool = Sympa::Spool::File::Task->new;
    unless ($taskspool->remove_message($self->{'messagekey'})) {
        Sympa::Log::Syslog::do_log('err',
            'Unable to remove task (messagekey = %s)',
            $self->{'messagekey'});
        return undef;
    }
    return 1;
}

## Builds a string giving the name of the model of the task, along with its
## flavour and, if the task is in list context, the name of the list.
sub get_description {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug3',
        'Computing textual description for task %s.%s',
        $self->{'model'}, $self->{'flavour'});
    unless (defined $self->{'description'} && $self->{'description'} ne '') {
        $self->{'description'} = sprintf '%s.%s', $self->{'model'},
            $self->{'flavour'};
        if (defined $self->{'list'}) {    # list task
            $self->{'description'} .= sprintf ' (list %s)', $self->{'id'};
        }
    }
    return $self->{'description'};
}

## Uses the parsed instructions to build a new task as string. If no parsed
## instructions are found, returns the original task as string.
sub stringify_parsed_instructions {
    my $self = shift;
    Sympa::Log::Syslog::do_log(
        'debug2',
        'Resetting messageasstring key of task object from the parsed content of %s',
        $self->get_description
    );

    my $new_string = $self->as_string();
    unless (defined $new_string) {
        Sympa::Log::Syslog::do_log(
            'err',
            'task %s has no parsed content. Leaving messageasstring key unchanged',
            $self->get_description
        );
        return undef;
    } else {
        $self->{'messageasstring'} = $new_string;
        if (Sympa::Log::Syslog::get_log_level() > 1) {
            Sympa::Log::Syslog::do_log('debug2',
                'task %s content recreated. Content:',
                $self->get_description);
            foreach (split "\n", $self->{'messageasstring'}) {
                Sympa::Log::Syslog::do_log('debug2', '%s', $_);
            }
        }
    }
    return 1;
}

## Returns a string built from parsed isntructions or undef if no parsed
## instructions exist.
## This sub reprensents what we obtain when concatenating the lines found in
## the parsed
## instructions only. we don't try to save anything. If there are no parsed
## instructions,
## You end up with an undef value and that's it. If you want to obtain the
## task as a string
## and don't know whether the instructions were parsed before or not, use
## stringify_parsed_instructions().
sub as_string {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug2',
        'Generating task string from the parsed content of task %s',
        $self->get_description);

    my $task_as_string = '';
    if (defined $self->{'parsed_instructions'}
        && $#{$self->{'parsed_instructions'}} > -1) {
        foreach my $line (@{$self->{'parsed_instructions'}}) {
            $task_as_string .= "$line->{'line_as_string'}\n";
        }
        $task_as_string =~ s/\n\n$/\n/;
    } else {
        Sympa::Log::Syslog::do_log('err',
            'Task %s appears to have no parsed instructions.');
        $task_as_string = undef;
    }
    return $task_as_string;
}

## Returns the local part of the list name of the task if the task is in list
## context, undef otherwise.
sub get_short_listname {
    my $self = shift;
    if (defined $self->{'list'}) {
        return $self->{'list'}{'name'};
    }
    return undef;
}

## Returns the full list name of the task if the task is in list context,
## undef otherwise.
sub get_full_listname {
    my $self = shift;
    if (defined $self->{'list'}) {
        return $self->{'list'}->get_list_id;
    }
    return undef;
}

## Check the syntax of a task
sub check {
    my $self = shift;    # the task to check
    Sympa::Log::Syslog::do_log('debug2', 'check %s', $self->get_description);

    $self->parse;

    # are all labels used ?
    foreach my $label (keys %{$self->{'labels'}}) {
        Sympa::Log::Syslog::do_log('debug2',
            'Warning : label %s exists but is not used in %s',
            $label, $self->get_description)
            unless (defined $self->{'used_labels'}{$label});
    }

    # do all used labels exist ?
    foreach my $label (keys %{$self->{'used_labels'}}) {
        unless (defined $self->{'labels'}{$label}) {
            Sympa::Log::Syslog::do_log('err',
                'Error : label %s is used but does not exist in %s',
                $label, $self->get_description);
            return undef;
        }
    }

    # are all variables used ?
    foreach my $var (keys %{$self->{'vars'}}) {
        Sympa::Log::Syslog::do_log('debug2',
            'Warning : var %s exists but is not used in %s',
            $var, $self->get_description)
            unless (defined $self->{'used_vars'}{$var});
    }

    # do all used variables exist ?
    foreach my $var (keys %{$self->{'used_vars'}}) {
        unless (defined $self->{'vars'}{$var}) {
            Sympa::Log::Syslog::do_log('err',
                'Error : var %s is used but does not exist in %s',
                $var, $self->get_description);
            return undef;
        }
    }
    return 1;
}

## Executes the task
sub execute {

    my $self = shift;
    Sympa::Log::Syslog::do_log('notice', 'Running task id = %s, %s)',
        $self->{'messagekey'}, $self->get_description);
    if (!$self->parse) {
        $self->{'error'} = 'parse';
        $self->error_report;
        return undef;
    } elsif (!$self->process_all) {
        $self->{'error'} = 'execution';
        $self->error_report;
        return undef;
    } else {
        Sympa::Log::Syslog::do_log(
            'notice',
            'The task %s has been correctly executed. Removing it (messagekey=%s)',
            $self->get_description,
            $self->{'messagekey'}
        );
    }
    return 1;
}

## Parses the task as string into parsed instructions.
sub parse {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug2', "Parsing task id = %s : %s",
        $self->{'messagekey'}, $self->get_description);

    my $messageasstring = $self->{'messageasstring'};    # task to execute
    unless ($messageasstring) {
        Sympa::Log::Syslog::do_log('err',
            'No string describing the task available in %s',
            $self->get_description);
        return undef;
    }
    my $lnb = 0;                                         # line number
    foreach my $line (split('\n', $messageasstring)) {
        $lnb++;
        my $instruction;
        eval {
            $instruction = Sympa::Instruction->new(
                line_as_string => $line,
                line_number    => $lnb,
            );
        };
        if ($EVAL_ERROR) {
            my $error = {
                message => $EVAL_ERROR,
                type    => 'parsing',
                line    => $lnb
            };
            push @{$self->{errors}}, $error;
            $self->error_report;
            return undef;
        }
        push @{$self->{'parsed_instructions'}}, $instruction;
    }
    $self->make_summary;
    return 1;
}

## Processes all parsed instructions sequentially.
sub process_all {
    my $self = shift;
    my $variables;
    Sympa::Log::Syslog::do_log('debug',
        'Processing all instructions found in task %s',
        $self->get_description);

    foreach my $instruction (@{$self->{'parsed_instructions'}}) {
        if (defined $self->{'must_stop'}) {
            Sympa::Log::Syslog::do_log('debug', 'Stopping here for task %s',
                $self->get_description);
            last;
        }
        $instruction->{'variables'} = $variables;

        my $result;
        eval {
            $result = $instruction->execute();
        };
        if ($EVAL_ERROR) {
            my $error = {
                message => $EVAL_ERROR,
                type    => 'execution',
                line    => $instruction->{'line_number'},
            };
            push @{$self->{errors}}, $error;
            Sympa::Log::Syslog::do_log(
                'err',
                'Error while executing %s at line %s, task %s',
                $instruction->{'line_as_string'},
                $instruction->{'line_number'},
                $self->get_description
            );
            return undef;
        }

        if (ref $result && $result->{'type'} eq 'variables') {
            $variables = $result->{'variables'};
        }
    }
    return 1;
}

## Changes the label of a task file
sub change_label {
    my $task_file = $_[0];
    my $new_label = $_[1];

    my $new_task_file = $task_file;
    $new_task_file =~ s/(.+\.)(\w*)(\.\w+\.\w+$)/$1$new_label$3/;

    if (rename($task_file, $new_task_file)) {
        Sympa::Log::Syslog::do_log('notice',
            "$task_file renamed in $new_task_file");
        return 1;
    } else {
        Sympa::Log::Syslog::do_log('err',
            "error ; can't rename $task_file in $new_task_file");
        return undef;
    }
}

## Check that a task in list context is still legitimate.
sub check_list_task_is_valid {
    Sympa::Log::Syslog::do_log('debug3', '(%s)', @_);
    my $self  = shift;
    my $list  = $self->{'list'};
    my $model = $self->{'model'};

    ## Skip closed lists
    unless (defined $list and ref $list eq 'Sympa::List' and $list->status eq 'open')
    {
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

sub make_summary {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug2',
        'Computing general informations about the task %s',
        $self->get_description);

    $self->{'labels'}      = {};
    $self->{'used_labels'} = {};
    $self->{'vars'}        = {};
    $self->{'used_vars'}   = {};

    foreach my $instruction (@{$self->{'parsed_instructions'}}) {
        if ($instruction->{'nature'} eq 'label') {
            $self->{'labels'}{$instruction->{'label'}} = 1;
        } elsif ($instruction->{'nature'} eq 'assignment'
            && $instruction->{'var'}) {
            $self->{'vars'}{$instruction->{'var'}} = 1;
        } elsif ($instruction->{'nature'} eq 'command') {
            foreach my $used_var (keys %{$instruction->{'used_vars'}}) {
                $self->{'used_vars'}{$used_var} = 1;
            }
            foreach my $used_label (keys %{$instruction->{'used_labels'}}) {
                $self->{'used_labels'}{$used_label} = 1;
            }
        }
    }

}

sub error_report {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug2', 'Producing error report for task %s',
        $self->get_description);

    my $data;
    if (defined $self->{'list'}) {
        $data->{'list'} = $self->{'list'};
    }
    $self->{'human_date'} = Sympa::Tools::Time::adate($self->{'date'});
    $data->{'task'}       = $self;
    Sympa::Log::Syslog::do_log(
        'err',
        'Execution of task %s failed. sending detailed report to listmaster',
        $self->get_description
    );
    Sympa::Site->send_notify_to_listmaster('task_error', $data);
}

## Get unique ID.
sub get_id {
    return shift->get_description() || '';
}

1;
