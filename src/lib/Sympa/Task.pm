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

Sympa::Task - An abstract background task

=head1 DESCRIPTION

This is an abstract base for all background tasks.

=cut

package Sympa::Task;

use strict;

use Carp qw(croak);
use English qw(-no_match_vars);
use Template;

use Sympa::Log::Syslog;
use Sympa::Instruction;

=head1 CLASS METHODS

=over

=item Sympa::Task->new(%parameters)

Creates a new L<Sympa::Task> subclass object.

The exact subclass depends on the presence of a I<list> parameter:

=over 4

=item * if present, L<Sympa::Task::List> is used

=item * if absent, L<Sympa::Task::Global> is used

=back

Parameters:

=over 4

=item * I<messageasstring>: FIXME

=item * I<date>: FIXME

=item * I<label>: FIXME

=item * I<model>: FIXME

=item * I<flavour>: FIXME

=item * I<data>: FIXME

=item * I<list>: FIXME

=back

Returns a new L<Sympa::Task> subclass object, or I<undef> for failure.

=cut

sub new {
    my ($class, %params) = @_;

    if ($params{list}) {
        require Sympa::Task::List;
        return Sympa::Task::List->new(%params);
    } else {
        require Sympa::Task::Global;
        return Sympa::Task::Global->new(%params);
    }
}

# private constructor used by subclasses
sub _new {
    my ($class, %params) = @_;

    Sympa::Log::Syslog::do_log(
        Sympa::Log::Syslog::DEBUG2,
        'Sympa::Task::new  messagekey = %s',
        $params{'messagekey'}
    );

    my $self = bless {
        'messageasstring' => $params{'messageasstring'},
        'date'            => $params{'date'} || time(),
        'label'           => $params{'label'},
        'model'           => $params{'model'},
        'flavour'         => $params{'flavour'},
        'description'     => $params{'model'} . '.' . $params{'flavour'},
        'Rdata'           => $params{'data'},
    }, $class;

    return $self;
}

=back

=head1 INSTANCE METHODS

=over

=item $task->init()

Initialize a task.

Returns a true value for success, I<undef> for failure.

=cut

sub init {
    my ($self) = @_;

    unless ($self->{'model'}) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            'Missing a model name. Impossible to get a template. Aborting.');
        return undef;
    }
    unless ($self->{'flavour'}) {
        Sympa::Log::Syslog::do_log(
            Sympa::Log::Syslog::ERR,
            'Missing a flavour name for model %s name. Impossible to get a template. Aborting.',
            $self->{'model'}
        );
        return undef;
    }

    # model recovery
    my $model_name = 
        $self->{'model'} . '.' . $self->{'flavour'} . '.' . 'task';

    my $template = $self->_get_template($model_name);
    unless ($template) {
        Sympa::Log::Syslog::do_log(
            Sympa::Log::Syslog::ERR,
            'Unable to find task model %s. Creation aborted',
            $model_name);
        return undef;
    }

    # string content generation
    my $content_ok = $self->_generate_from_template($template);
    return unless $content_ok;

    # string content parsing
    eval {
        $self->_parse();
    };
    return undef if $EVAL_ERROR;

    # content checking
    my $summary = $self->_make_summary();
    my $syntax_ok = $self->_check_syntax($summary);
    unless ($syntax_ok) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            'error : syntax error in task %s, you should check %s',
            $self->get_description, $template);
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::NOTICE,
            "Ignoring creation task request");
        return undef;
    }

    ## In case a label is specified, ensure we won't use anything in the task
    ## prior to this label.
    if ($self->{'label'}) {
        return undef unless ($self->_crop_after_label($self->{'label'}));
    }

    return 1;
}

## Uses the template of this task to generate the task as string.
sub _generate_from_template {
    my ($self, $template) = @_;

    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG,
        "Generate task content with tt2 template %s",
        $template);

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
            $template, $self->{'Rdata'}, \$messageasstring
        )
        ) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "Failed to parse task template '%s' : %s",
            $template, $tt2->error());
        return undef;
    }
    $self->{'messageasstring'} = $messageasstring;

    return 1;
}

# Chop whetever content the task as string could contain (except titles)
# before the label of the task.
sub _crop_after_label {
    my $self  = shift;
    my $label = shift;

    Sympa::Log::Syslog::do_log(
        Sympa::Log::Syslog::DEBUG,
        'Cropping task content to keep only the content located starting label %s',
        $label
    );

    # If this variable still contains 0 at the end of the sub, that means that
    # the label after which we want to crop does not exist in the task. We
    # will therefore not crop anything and return the task with the same
    # content.
    my $label_found_in_task = 0;
    my @new_parsed_instructions;
    $self->_parse
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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            'The label %s does not exist in task %s. We can not crop after it.'
        );
        return undef;
    } else {
        $self->{'parsed_instructions'} = \@new_parsed_instructions;
        $self->_stringify_parsed_instructions;
    }

    return 1;
}

=item $task->get_id()

Returns the task unique ID.

=cut

sub get_id {
    return shift->get_description() || '';
}

=item $task->get_description()

Returns the task description.

=cut

sub get_description {
    my $self = shift;
    return $self->{'description'};
}

## Uses the parsed instructions to build a new task as string. If no parsed
## instructions are found, returns the original task as string.
sub _stringify_parsed_instructions {
    my $self = shift;
    Sympa::Log::Syslog::do_log(
        Sympa::Log::Syslog::DEBUG2,
        'Resetting messageasstring key of task object from the parsed content of %s',
        $self->get_description
    );

    my $new_string = $self->as_string();
    unless (defined $new_string) {
        Sympa::Log::Syslog::do_log(
            Sympa::Log::Syslog::ERR,
            'task %s has no parsed content. Leaving messageasstring key unchanged',
            $self->get_description
        );
        return undef;
    } else {
        $self->{'messageasstring'} = $new_string;
        if (Sympa::Log::Syslog::get_log_level() > 1) {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2,
                'task %s content recreated. Content:',
                $self->get_description);
            foreach (split "\n", $self->{'messageasstring'}) {
                Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2, '%s', $_);
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
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2,
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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            'Task %s appears to have no parsed instructions.');
        $task_as_string = undef;
    }
    return $task_as_string;
}

sub _check_syntax {
    my ($self, $summary) = @_;
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2, 'check %s', $self->get_description);

    # are all labels used ?
    foreach my $label (keys %{$summary->{'labels'}}) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2,
            'Warning : label %s exists but is not used in %s',
            $label, $self->get_description)
            unless (defined $summary->{'used_labels'}{$label});
    }

    # do all used labels exist ?
    foreach my $label (keys %{$summary->{'used_labels'}}) {
        unless (defined $summary->{'labels'}{$label}) {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
                'Error : label %s is used but does not exist in %s',
                $label, $self->get_description);
            return undef;
        }
    }

    # are all variables used ?
    foreach my $var (keys %{$summary->{'vars'}}) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2,
            'Warning : var %s exists but is not used in %s',
            $var, $self->get_description)
            unless (defined $summary->{'used_vars'}{$var});
    }

    # do all used variables exist ?
    foreach my $var (keys %{$summary->{'used_vars'}}) {
        unless (defined $summary->{'vars'}{$var}) {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
                'Error : var %s is used but does not exist in %s',
                $var, $self->get_description);
            return undef;
        }
    }
    return 1;
}

=item $task->executes()

Executes the task.

=cut

sub execute {
    my ($self) = @_;

    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::NOTICE, 'Running task id = %s, %s)',
        $self->{'messagekey'}, $self->get_description);

    # will raise an exception in case of error
    $self->_parse();

    # will raise an exception in case of error
    $self->_process_all();
}

# Parses the raw content of this task into instructions.
sub _parse {
    my $self = shift;
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2, "Parsing task id = %s : %s",
        $self->{'messagekey'}, $self->get_description);

    my $messageasstring = $self->{'messageasstring'};    # task to execute
    unless ($messageasstring) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
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
        croak "parsing error at line $lnb: $EVAL_ERROR\n"
            if $EVAL_ERROR;

        push @{$self->{'parsed_instructions'}}, $instruction;
    }
    return 1;
}

# Processes all instructions sequentially.
sub _process_all {
    my $self = shift;
    my $variables;
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG,
        'Processing all instructions found in task %s',
        $self->get_description);

    foreach my $instruction (@{$self->{'parsed_instructions'}}) {
        if (defined $self->{'must_stop'}) {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG, 'Stopping here for task %s',
                $self->get_description);
            last;
        }

        my $result;
        eval {
            $result = $instruction->execute($self, $variables);
        };
        croak "execution error at line $instruction->{'line_number'}: $EVAL_ERROR\n"
            if $EVAL_ERROR;

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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::NOTICE,
            "$task_file renamed in $new_task_file");
        return 1;
    } else {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            "error ; can't rename $task_file in $new_task_file");
        return undef;
    }
}

=item $task->check_validity()

Check this task is still valid.

=cut

sub _make_summary {
    my $self = shift;
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2,
        'Computing general informations about the task %s',
        $self->get_description);

    my $summary = {
        'labels'      => {},
        'used_labels' => {},
        'vars'        => {},
        'used_vars'   => {},
    };

    foreach my $instruction (@{$self->{'parsed_instructions'}}) {
        if ($instruction->{'nature'} eq 'label') {
            $summary->{'labels'}{$instruction->{'label'}} = 1;
        } elsif ($instruction->{'nature'} eq 'assignment'
            && $instruction->{'var'}) {
            $summary->{'vars'}{$instruction->{'var'}} = 1;
        } elsif ($instruction->{'nature'} eq 'command') {
            foreach my $used_var (keys %{$instruction->{'used_vars'}}) {
                $summary->{'used_vars'}{$used_var} = 1;
            }
            foreach my $used_label (keys %{$instruction->{'used_labels'}}) {
                $summary->{'used_labels'}{$used_label} = 1;
            }
        }
    }

    return $summary;
}

=back

=cut

1;
