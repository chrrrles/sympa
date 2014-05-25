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

package Sympa::Instruction;

use strict;

use Carp qw(croak);
use English qw(-no_match_vars);
use Time::Local qw();

use Sympa::Log::Syslog;
use Sympa::Tools;
use Sympa::Tools::Time;

###### DEFINITION OF AVAILABLE COMMANDS FOR TASKS ######

my $delay_pattern = qr/
    (?:\d+ y)?
    (?:\d+ m)?
    (?:\d+ w)?
    (?:\d+ d)?
    (?:\d+ h)?
    (?:\d+ min)?
    (?:\d+ sec)?
/xi;
my $time_pattern = qr/(?: \d+ | execution_date )/xi;

my $delay_regexp = qr/^$delay_pattern$/;
my $date_regexp = qr/^(?:
    $time_pattern  |
    $delay_pattern |
    $time_pattern [+-] $delay_pattern
)$/x;
my $var_regexp  = qr/^@\w+$/;
my $subarg_regexp = qr/^
        (\w+)
        (?: \( ([^)]+) \) )?
$/x;

# regular commands
my %commands = (
    'next' => {
        'args' => ['date', '\w*'],

        # date   label
        'sub' => \&_next_cmd,
    },
    'stop' => {
        'args' => [],
        'sub'  => \&_stop,
    },
    'create' => {
        'args' => ['subarg', '\w+', '\w+'],

        #object    model  model choice
        'sub' => \&_create_cmd,
    },
    'exec' => {
        'args' => ['.+'],

        #script
        'sub' => \&_exec_cmd,
    },
    'update_crl' => {
        'args' => ['\w+', 'date'],

        #file    #delay
        'sub' => \&_update_crl,
    },
    'expire_bounce' => {
        'args' => ['\d+'],

        #Number of days (delay)
        'sub' => \&_expire_bounce,
    },
    'chk_cert_expiration' => {
        'args' => ['\w+', 'date'],

        #template  date
        'sub' => \&_chk_cert_expiration,
    },
    'sync_include' => {
        'args' => [],
        'sub'  => \&_sync_include,
    },
    'purge_user_table' => {
        'args' => [],
        'sub'  => \&_purge_user_table,
    },
    'purge_logs_table' => {
        'args' => [],
        'sub'  => \&_purge_logs_table,
    },
    'purge_session_table' => {
        'args' => [],
        'sub'  => \&_purge_session_table,
    },
    'purge_tables' => {
        'args' => [],
        'sub'  => \&_purge_tables,
    },
    'purge_one_time_ticket_table' => {
        'args' => [],
        'sub'  => \&_purge_one_time_ticket_table,
    },
    'purge_orphan_bounces' => {
        'args' => [],
        'sub'  => \&_purge_orphan_bounces,
    },
    'eval_bouncers' => {
        'args' => [],
        'sub'  => \&_eval_bouncers,
    },
    'process_bouncers' => {
        'args' => [],
        'sub'  => \&_process_bouncers,
    },
);

# commands which use a variable. If you add such a command, the first
# parameter must be the variable
my %var_commands = (
    'delete_subs' => {
        'args' => ['var'],

        # variable
        'sub' => \&_delete_subs_cmd,
    },
    'send_msg' => {
        'args' => ['var', '\w+'],

        #variable template
        'sub' => \&_send_msg,
    },
    'rm_file' => {
        'args' => ['var'],

        # variable
        'sub' => \&_rm_file,
    },
);

foreach (keys %var_commands) {
    $commands{$_} = $var_commands{$_};
}

# commands which are used for assignments
my %asgn_commands = (
    'select_subs' => {
        'args' => ['subarg'],

        # condition
        'sub' => \&_select_subs,
    },
    'delete_subs' => {
        'args' => ['var'],

        # variable
        'sub' => \&_delete_subs_cmd,
    },
);

foreach (keys %asgn_commands) {
    $commands{$_} = $asgn_commands{$_};
}

sub new {
    my ($class, %params) = @_;

    my $self = bless {
        line_as_string => $params{line_as_string},
        line_number    => $params{line_number},
    }, $class;

    # raise an exception if parsing fails
    $self->_parse();

    return $self;
}

## Parses the line of a task and returns a hash that can be executed.
sub _parse {
    my $self = shift;

    Sympa::Log::Syslog::do_log('debug2', 'Parsing "%s"',
        $self->{'line_as_string'});

    $self->{'nature'} = undef;

    # empty line
    if (!$self->{'line_as_string'}) {
        $self->{'nature'} = 'empty line';

        # comment
    } elsif ($self->{'line_as_string'} =~ /^\s*\#.*/) {
        $self->{'nature'} = 'comment';

        # title
    } elsif ($self->{'line_as_string'} =~ /^\s*title\...\s*(.*)\s*/i) {
        $self->{'nature'} = 'title';
        $self->{'title'}  = $1;

        # label
    } elsif ($self->{'line_as_string'} =~ /^\s*\/\s*(.*)/) {
        $self->{'nature'} = 'label';
        $self->{'label'}  = $1;

        # command
    } elsif ($self->{'line_as_string'} =~ /^\s*(\w+)\s*\((.*)\)\s*/i) {
        my $command = lc($1);
        my @args = split(/,/, $2);
        foreach (@args) { s/\s//g; }

        unless ($commands{$command}) {
            croak "unknown command $command\n";
        } else {
            $self->{'nature'}  = 'command';
            $self->{'command'} = $command;

            # arguments recovery. no checking of their syntax !!!
            $self->{'Rarguments'} = \@args;
            $self->_chk_cmd();
        }

        # assignment
    } elsif ($self->{'line_as_string'} =~ /^\s*(@\w+)\s*=\s*(.+)/) {

        my $subinstruction = Sympa::Instruction->new(
            line_as_string => $2,
            line_number    => $self->{'line_number'}
        );

        unless ($asgn_commands{$subinstruction->{'command'}}) {
            croak "non valid assignment $2\n";
        } else {
            $self->{'nature'}     = 'assignment';
            $self->{'var'}        = $1;
            $self->{'command'}    = $subinstruction->{'command'};
            $self->{'Rarguments'} = $subinstruction->{'Rarguments'};
        }
    } else {
        croak "syntax error\n";
    }
    return 1;
}

## Checks the arguments of a command
sub _chk_cmd {

    my $self = shift;

    Sympa::Log::Syslog::do_log(
        'debug2', 'chk_cmd(%s, %d, %s)',
        $self->{'command'},
        $self->{'line_number'},
        join(',', @{$self->{'Rarguments'}})
    );

    if (defined $commands{$self->{'command'}}) {

        my @expected_args = @{$commands{$self->{'command'}}{'args'}};
        my @args          = @{$self->{'Rarguments'}};

        unless ($#expected_args == $#args) {
            croak "wrong number of arguments for $self->{'command'}\n";
        }

        foreach my $arg (@args) {
            my $regexp = $expected_args[0];
            shift(@expected_args);

            if ($regexp eq 'date') {
                croak "argument '$arg' is not a valid date\n"
                    unless $arg =~ $date_regexp;
            } elsif ($regexp eq 'delay') {
                croak "argument '$arg' is not a valid delay\n"
                    unless $arg =~ $delay_regexp;
            } elsif ($regexp eq 'var') {
                croak "argument '$arg' is not a valid variable\n"
                    unless $arg =~ $var_regexp;
            } elsif ($regexp eq 'subarg') {
                croak "argument '$arg' is not a valid sub-argument\n"
                    unless $arg =~ $subarg_regexp;
            } else {
                croak "argument '$arg' is not valid\n"
                    unless $arg =~ /^$regexp$/i;
            }

            $self->{'used_labels'}{$args[1]} = 1
                if ($self->{'command'} eq 'next' && ($args[1]));
            $self->{'used_vars'}{$args[0]} = 1
                if ($var_commands{$self->{'command'}});
        }
    }
    return 1;
}

sub as_string {
    my $self = shift;
    Sympa::Log::Syslog::do_log('debug3',
        'Computing string representation of the instruction.');
    return $self->{'line_as_string'};
}

## Calls the appropriate functions for a parsed line of a task.
sub execute {
    my ($self, $task) = @_;

    Sympa::Log::Syslog::do_log(
        'debug',
        'Processing "%s" (line %d of task %s)',
        $self->{'line_as_string'},
        $self->{'line_number'},
        $task->get_description
    );

    if (
        $self->{nature} eq 'assignement' ||
        $self->{nature} eq 'command'
    ) {
        # regular commands
        return &{$commands{$self->{'command'}}{'sub'}}($self, $task);
    } else {
        return { output => 'Nothing to compute' };
    }
}

### command subroutines ###

# remove files whose name is given in the key 'file' of the hash
sub _rm_file {

    my ($self, $task) = @_;

    my @tab = @{$self->{'Rarguments'}};
    my $var = $tab[0];

    foreach my $key (keys %{$self->{'variables'}{$var}}) {
        my $file = $self->{'variables'}{$var}{$key}{'file'};
        next unless ($file);
        unless (unlink($file)) {
            $self->_error(
                {   'task' => $task,
                    'type' => 'execution',
                    'message' =>
                        "error in rm_file command : unable to remove $file"
                }
            );
            return undef;
        }
    }
    return 1;
}

sub _stop {

    my ($self, $task) = @_;

    Sympa::Log::Syslog::do_log('notice',
        "$self->{'line_number'} : stop $task->{'messagekey'}");

    unless ($task->remove) {
        $self->_error(
            {   'task' => $task,
                'type' => 'execution',
                'message' =>
                    "error in stop command : unable to delete task $task->{'messagekey'}"
            }
        );
        return undef;
    }
}

sub _send_msg {
    my ($self, $task) = @_;

    require Sympa::Site;

    my @tab      = @{$self->{'Rarguments'}};
    my $template = $tab[1];
    my $var      = $tab[0];

    Sympa::Log::Syslog::do_log('notice',
        "line $self->{'line_number'} : send_msg (@{$self->{'Rarguments'}})");

    if ($task->{'object'} eq '_global') {
        foreach my $email (keys %{$self->{'variables'}{$var}}) {
            unless (
                Sympa::Site->send_file(
                    $template, $email, $self->{'variables'}{$var}{$email}
                )
                ) {
                Sympa::Log::Syslog::do_log('notice',
                    "Unable to send template $template to $email");
                $self->_error(
                    {   'task' => $task,
                        'type' => 'execution',
                        'message' =>
                            "Unable to send template $template to $email"
                    }
                );
                return undef;
            } else {
                Sympa::Log::Syslog::do_log('notice',
                    "--> message sent to $email");
            }
        }
    } else {
        my $list = $task->{'list_object'};
        foreach my $email (keys %{$self->{'variables'}{$var}}) {
            unless (
                $list->send_file(
                    $template, $email, $self->{'variables'}{$var}{$email}
                )
                ) {
                Sympa::Log::Syslog::do_log('notice',
                    "Unable to send template $template to $email");
                $self->_error(
                    {   'task' => $task,
                        'type' => 'execution',
                        'message' =>
                            "Unable to send template $template to $email"
                    }
                );
                return undef;
            } else {
                Sympa::Log::Syslog::do_log('notice',
                    "--> message sent to $email");
            }
        }
    }
    return 1;
}

sub _next_cmd {
    my ($self, $task) = @_;

    require Sympa::Site;
    require Sympa::Spool::File::Task;
    require Sympa::Task;

    my @tab = @{$self->{'Rarguments'}};

    # conversion of the date argument into epoch format
    my $date = Sympa::Tools::Time::epoch_conv($tab[0], $task->{'date'});
    my $label = $tab[1];

    Sympa::Log::Syslog::do_log('debug2',
        "line $self->{'line_number'} of $task->{'model'} : next ($date, $label)"
    );

    $task->{'must_stop'} = 1;
    my $listname = $task->{'object'};
    my $model    = $task->{'model'};

    ## Determine type
    my ($type, $flavour);
    my %data = (
        'creation_date'  => $task->{'date'},
        'execution_date' => 'execution_date'
    );
    if ($listname eq '_global') {
        $type = '_global';
        foreach my $key (keys %Sympa::Spool::File::Task::global_models) {
            if ($Sympa::Spool::File::Task::global_models{$key} eq $model) {
                $flavour = Sympa::Site->$key;
                last;
            }
        }
    } else {
        $type = 'list';
        my $list = $task->{'list_object'};
        $data{'list'}{'name'}  = $list->name;
        $data{'list'}{'robot'} = $list->domain;

        if ($model eq 'sync_include') {
            unless ($list->user_data_source eq 'include2') {
                $self->_error(
                    {   'task' => $task,
                        'type' => 'execution',
                        'message' =>
                            sprintf(
                            'List %s no more require sync_include task',
                            $list->name)
                    }
                );
                return undef;
            }
            $data{'list'}{'ttl'} = $list->ttl;
            $flavour = 'ttl';
        } else {
            my $model_task_parameter = $model . '_task';
            unless (%{$list->$model_task_parameter}) {
                $self->_error(
                    {   'task'    => $task,
                        'type'    => 'execution',
                        'message' => sprintf(
                            'List %s no more require %s task',
                            $list->name, $model
                        )
                    }
                );
                return undef;
            }
            $flavour = $list->$model_task_parameter->{'name'};
        }
    }
    Sympa::Log::Syslog::do_log('debug2', 'Will create next task');
    unless (
        Sympa::Task::create(
            {   'creation_date' => $date,
                'label'         => $tab[1],
                'model'         => $model,
                'flavour'       => $flavour,
                'data'          => \%data
            }
        )
        ) {
        $self->_error(
            {   'task' => $task,
                'type' => 'execution',
                'message' =>
                    "error in create command : Failed to create task $model.$flavour"
            }
        );
        return undef;
    }

    my $human_date = Sympa::Tools::Time::adate($date);
    Sympa::Log::Syslog::do_log('debug2', "--> new task $model ($human_date)");
    return 1;
}

sub _select_subs {
    my ($self, $task) = @_;

    require Sympa::Scenario;

    my @tab       = @{$self->{'Rarguments'}};
    my $condition = $tab[0];

    Sympa::Log::Syslog::do_log('debug2',
        "line $self->{'line_number'} : select_subs ($condition)");
    $condition =~ /(\w+)\(([^\)]*)\)/;
    if ($2) {    # conversion of the date argument into epoch format
        my $date = Sympa::Tools::Time::epoch_conv($2, $task->{'date'});
        $condition = "$1($date)";
    }

    my @users;        # the subscribers of the list
    my %selection;    # hash of subscribers who match the condition
    my $list = $task->{'list_object'};

    for (
        my $user = $list->get_first_list_member();
        $user;
        $user = $list->get_next_list_member()
        ) {
        push(@users, $user);
    }

    # parameter of subroutine Sympa::Scenario::verify
    my $verify_context = {
        'sender'      => 'nobody',
        'email'       => 'nobody',
        'remote_host' => 'unknown_host',
        'listname'    => $task->{'object'}
    };

    my $new_condition =
        $condition;    # necessary to the older & newer condition rewriting
                       # loop on the subscribers of $list_name
    foreach my $user (@users) {

        # condition rewriting for older and newer
        $new_condition = "$1($user->{'update_date'}, $2)"
            if ($condition =~ /(older|newer)\((\d+)\)/);
        if (Sympa::Scenario::verify($verify_context, $new_condition) == 1) {
            $selection{$user->{'email'}} = undef;
            Sympa::Log::Syslog::do_log('notice',
                "--> user $user->{'email'} has been selected");
        }
    }
    return \%selection;
}

sub _delete_subs_cmd {
    my ($self, $task) = @_;

    require Sympa::Scenario;
    require Sympa::Site;

    my @tab = @{$self->{'Rarguments'}};
    my $var = $tab[0];

    Sympa::Log::Syslog::do_log('notice',
        "line $self->{'line_number'} : delete_subs ($var)");

    my $list = $task->{'list_object'};
    my %selection;    # hash of subscriber emails who are successfully deleted

    foreach my $email (keys %{$self->{'variables'}{$var}}) {
        Sympa::Log::Syslog::do_log('notice', "email : $email");
        my $result = Sympa::Scenario::request_action(
            $list, 'del', 'smime',
            {   'sender' => Sympa::Site->listmaster,
                'email'  => $email,
            }
        );
        my $action;
        $action = $result->{'action'} if (ref($result) eq 'HASH');
        if ($action =~ /reject/i) {
            $self->_error(
                {   'task'    => $task,
                    'type'    => 'execution',
                    'message' => "Deletion of $email not allowed"
                }
            );
            return undef;
        } else {
            unless (my $u = $list->delete_list_member($email)) {
                $self->_error(
                    {   'task' => $task,
                        'type' => 'execution',
                        'message' =>
                            "Deletion of $email from list $list->get_list_id failed"
                    }
                );
            } else {
                Sympa::Log::Syslog::do_log('notice', "--> $email deleted");
                $selection{$email} = {};
            }
        }
    }

    return \%selection;
}

sub _create_cmd {

    my ($self, $task) = @_;

    my @tab     = @{$self->{'Rarguments'}};
    my $arg     = $tab[0];
    my $model   = $tab[1];
    my $flavour = $tab[2];

    Sympa::Log::Syslog::do_log('notice',
        "line $self->{'line_number'} : create ($arg, $model, $flavour)");

    # recovery of the object type and object
    my $type;
    my $object;
    if ($arg =~ /$subarg_regexp/) {
        $type   = $1;
        $object = $2;
    } else {
        $self->_error(
            {   'task'    => $task,
                'type'    => 'execution',
                'message' => "Don't know how to create $arg"
            }
        );
        return undef;
    }

    # building of the data hash necessary to the create subroutine
    my %data = (
        'creation_date'  => $task->{'date'},
        'execution_date' => 'execution_date'
    );

    if ($type eq 'list') {
        my $list = Sympa::List->new($object);
        $data{'list'}{'name'} = $list->name;
    }
    $type = '_global';
    unless (Sympa::Task::create($task->{'date'}, '', $model, $flavour, \%data)) {
        $self->_error(
            {   'task'    => $task,
                'type'    => 'execution',
                'message' => "Creation of task $model.$flavour failed"
            }
        );
        return undef;
    }
    return 1;
}

sub _exec_cmd {

    my ($self, $task) = @_;

    my @tab  = @{$self->{'Rarguments'}};
    my $file = $tab[0];

    Sympa::Log::Syslog::do_log('notice',
        "line $self->{'line_number'} : exec ($file)");

    system($file);

    if ($CHILD_ERROR != 0) {
        my $message;
        if ($CHILD_ERROR == -1) {
            $message = "Failed to execute: $ERRNO";
        } elsif ($CHILD_ERROR & 127) {
            $message = sprintf 'Child died with signal %d, %s coredump',
                ($CHILD_ERROR & 127), ($CHILD_ERROR & 128) ? 'with' : 'without';
        } else {
            $message = sprintf 'Child exited with value %d', $CHILD_ERROR >> 8;
        }
        $self->_error(
            {'task' => $task, 'type' => 'execution', 'message' => $message});
        return undef;
    }
    return 1;
}

sub _purge_logs_table {

    # If a log is older then $list->get_latest_distribution_date()-$delai expire the log
    my ($self, $task) = @_;
    my $execution_date = $task->{'date'};
    my @slots          = ();

    Sympa::Log::Syslog::do_log('debug2', 'purge_logs_table()');
    unless (Sympa::Log::Database::db_log_del()) {
        $self->_error(
            {   'task'    => $task,
                'type'    => 'execution',
                'message' => "Failed to delete logs"
            }
        );
        return undef;
    }

    #-----------Data aggregation, to make statistics-----------------
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) =
        localtime($execution_date);
    $min = 0;
    $sec = 0;
    my $date_end =
        Time::Local::timelocal($sec, $min, $hour, $mday, $mon, $year, $wday, $yday,
        $isdst);

    my $sth;
    unless (
        $sth = Sympa::DatabaseManager::do_query(
            q{SELECT date_stat
	      FROM stat_table
	      WHERE read_stat = 0
	      ORDER BY date_stat ASC
	      %s},
            Sympa::DatabaseManager::get_limit_clause({'rows_count' => 1})
        )
        ) {
        $self->_error(
            {   'task'    => $task,
                'type'    => 'execution',
                'message' => 'Unable to retrieve oldest non processed stat'
            }
        );
        return undef;
    }
    my @res = $sth->fetchrow_array;
    $sth->finish;

    return 1 unless @res;
    my $date_deb = $res[0] - ($res[0] % 3600);

    #hour to hour
    for (my $i = $date_deb; $i <= $date_end; $i = $i + 3600) {
        push(@slots, $i);
    }

    for (my $j = 1; $j <= scalar(@slots); $j++) {
        Sympa::Log::Database::aggregate_data($slots[$j - 1],
            ($slots[$j] || $date_end));
    }

    #-------------------------------------------------------------------

    Sympa::Log::Syslog::do_log('notice', 'purge_logs_table(): logs purged');
    return 1;
}

## remove sessions from session_table if older than Sympa::Site->session_table_ttl
sub _purge_session_table {

    my ($self, $task) = @_;
    Sympa::Log::Syslog::do_log('info', 'task_manager::purge_session_table()');
    require Sympa::Session;

    my $removed = Sympa::Session::purge_old_sessions('Site');
    unless (defined $removed) {
        $self->_error(
            {   'task'    => $task,
                'type'    => 'execution',
                'message' => 'Failed to remove old sessions'
            }
        );
        return undef;
    }
    Sympa::Log::Syslog::do_log('notice',
        'purge_session_table(): %s rows removed in session_table', $removed);
    return 1;
}

## remove messages from bulkspool table when no more packet have any pointer
## to this message
sub _purge_tables {
    my ($self, $task) = @_;

    require Sympa::Bulk;
    require Sympa::List;
    require Sympa::Robot;
    require Sympa::Tracking;

    Sympa::Log::Syslog::do_log('info', 'task_manager::purge_tables()');

    my $removed;

    $removed = Sympa::Bulk::purge_bulkspool();
    unless (defined $removed) {
        $self->_error(
            {   'task'    => $task,
                'type'    => 'execution',
                'message' => 'Failed to purge tables'
            }
        );
    }
    Sympa::Log::Syslog::do_log('notice', '%s rows removed in bulkspool_table',
        $removed);

    $removed = 0;
    foreach my $robot (@{Sympa::Robot::get_robots()}) {
        my $all_lists = Sympa::List::get_lists($robot);
        foreach my $list (@$all_lists) {
            $removed +=
                Sympa::Tracking::remove_message_by_period($list,
                $list->tracking->{'retention_period'});
        }
    }
    Sympa::Log::Syslog::do_log('notice', "%s rows removed in tracking table",
        $removed);

    return 1;
}

## remove one time ticket table if older than Sympa::Site->one_time_ticket_table_ttl
sub _purge_one_time_ticket_table {
    my ($self, $task) = @_;
    Sympa::Log::Syslog::do_log('info',
        'task_manager::purge_one_time_ticket_table()');

    require Sympa::Session;

    my $removed = Sympa::Session::purge_old_tickets('Site');
    unless (defined $removed) {
        $self->_error(
            {   'task'    => $task,
                'type'    => 'execution',
                'message' => 'Failed to remove old tickets'
            }
        );
        return undef;
    }
    Sympa::Log::Syslog::do_log(
        'notice',
        'purge_one_time_ticket_table(): %s row removed in one_time_ticket_table',
        $removed
    );
    return 1;
}

sub _purge_user_table {
    my ($self, $task) = @_;

    Sympa::Log::Syslog::do_log('debug2', 'purge_user_table()');

    require Sympa::Robot;
    require Sympa::List;
    require Sympa::Site;
    require Sympa::User;

    ## Load user_table entries
    my @users = Sympa::User::get_all_global_user();

    ## Load known subscribers/owners/editors
    my %known_people;

    ## Listmasters
    foreach my $l (@{Sympa::Site->listmasters}) {
        $known_people{$l} = 1;
    }

    foreach my $robot (@{Sympa::Robot::get_robots()}) {

        my $all_lists = Sympa::List::get_lists($robot);
        foreach my $list (@$all_lists) {

            ## Owners
            my $owners = $list->get_owners();
            if (defined $owners) {
                foreach my $o (@{$owners}) {
                    $known_people{$o->{'email'}} = 1;
                }
            }

            ## Editors
            my $editors = $list->get_editors();
            if (defined $editors) {
                foreach my $e (@{$editors}) {
                    $known_people{$e->{'email'}} = 1;
                }
            }

            ## Subscribers
            for (
                my $user = $list->get_first_list_member();
                $user;
                $user = $list->get_next_list_member()
                ) {
                $known_people{$user->{'email'}} = 1;
            }
        }
    }

    ## Look for unused entries
    my @purged_users;
    foreach (@users) {
        unless ($known_people{$_}) {
            Sympa::Log::Syslog::do_log('debug2', 'User to purge: %s', $_);
            push @purged_users, $_;
        }
    }

    unless ($#purged_users < 0) {
        unless (Sympa::User::delete_global_user(@purged_users)) {
            $self->_error(
                {   'task'    => $task,
                    'type'    => 'execution',
                    'message' => 'Failed to delete users'
                }
            );
            return undef;
        }
    }

    my $result;
    $result->{'purged_users'} = $#purged_users + 1;
    return $result;
}

## Subroutine which remove bounced message of no-more known users
sub _purge_orphan_bounces {
    my ($self, $task) = @_;

    require Sympa::List;

    Sympa::Log::Syslog::do_log('info', 'purge_orphan_bounces()');

    ## Hash {'listname' => 'bounced address' => 1}
    my %bounced_users;
    my $all_lists;

    unless ($all_lists = Sympa::List::get_lists()) {
        Sympa::Log::Syslog::do_log('notice', 'No list available');
        return 1;
    }

    foreach my $list (@$all_lists) {
        my $listname = $list->name;
        ## first time: loading DB entries into %bounced_users
        for (
            my $user_ref = $list->get_first_bouncing_list_member();
            $user_ref;
            $user_ref = $list->get_next_bouncing_list_member()
            ) {
            my $user_id = $user_ref->{'email'};
            $bounced_users{$listname}{$user_id} = 1;
        }
        my $bounce_dir = $list->get_bounce_dir();
        unless (-d $bounce_dir) {
            Sympa::Log::Syslog::do_log('notice',
                'No bouncing subscribers in list %s', $listname);
            next;
        }

        ## then reading Bounce directory & compare with %bounced_users
        unless (opendir(BOUNCE, $bounce_dir)) {
            $self->_error(
                {   'task' => $task,
                    'type' => 'execution',
                    'message' =>
                        "Error while opening bounce directory $bounce_dir"
                }
            );
            return undef;
        }

        ## Finally removing orphan files
        foreach my $bounce (readdir(BOUNCE)) {
            if ($bounce =~ /\@/) {
                unless (defined($bounced_users{$listname}{$bounce})) {
                    Sympa::Log::Syslog::do_log('info',
                        'removing orphan Bounce for user %s in list %s',
                        $bounce, $listname);
                    unless (unlink($bounce_dir . '/' . $bounce)) {
                        $self->_error(
                            {   'task' => $task,
                                'type' => 'execution',
                                'message' =>
                                    "Error while removing file $bounce_dir/$bounce"
                            }
                        );
                    }
                }
            }
        }

        closedir BOUNCE;
    }
    return 1;
}

sub _expire_bounce {
    # If a bounce is older then $list->get_latest_distribution_date()-$delai expire the bounce
    # Is this variable my be set in to task modele ?
    my ($self, $task) = @_;

    require Sympa::List;

    my @tab            = @{$self->{'Rarguments'}};
    my $delay          = $tab[0];

    Sympa::Log::Syslog::do_log('debug2', 'expire_bounce(%d)', $delay);
    my $all_lists = Sympa::List::get_lists();
    foreach my $list (@$all_lists) {
        my $listname = $list->name;

        # the reference date is the date until which we expire bounces in
        # second
        # the latest_distribution_date is the date of last distribution #days
        # from 01 01 1970
        unless ($list->get_latest_distribution_date()) {
            Sympa::Log::Syslog::do_log(
                'debug2',
                'bounce expiration : skipping list %s because could not get latest distribution date',
                $listname
            );
            next;
        }
        my $refdate =
            (($list->get_latest_distribution_date() - $delay) * 3600 * 24);

        for (
            my $u = $list->get_first_bouncing_list_member();
            $u;
            $u = $list->get_next_bouncing_list_member()
            ) {
            $u->{'bounce'} =~ /^(\d+)\s+(\d+)\s+(\d+)(\s+(.*))?$/;
            $u->{'last_bounce'} = $2;
            if ($u->{'last_bounce'} < $refdate) {
                my $email = $u->{'email'};

                unless ($list->is_list_member($email)) {
                    $self->_error(
                        {   'task'    => $task,
                            'type'    => 'execution',
                            'message' => "$email not subscribed"
                        }
                    );
                    next;
                }

                unless (
                    $list->update_list_member(
                        $email,
                        {'bounce'         => 'NULL'},
                        {'bounce_address' => 'NULL'}
                    )
                    ) {
                    $self->_error(
                        {   'task'    => $task,
                            'type'    => 'execution',
                            'message' => "failed update database for $email"
                        }
                    );
                    next;
                }
                my $escaped_email = Sympa::Tools::escape_chars($email);

                my $bounce_dir = $list->get_bounce_dir();

                unless (unlink $bounce_dir . '/' . $escaped_email) {
                    $self->_error(
                        {   'task' => $task,
                            'type' => 'execution',
                            'message' =>
                                "failed deleting $bounce_dir/$escaped_email"
                        }
                    );
                    next;
                }
                Sympa::Log::Syslog::do_log(
                    'info',
                    'expire bounces for subscriber %s of list %s (last distribution %s, last bounce %s )',
                    $email,
                    $listname,
                    POSIX::strftime(
                        "%d %b %Y",
                        localtime(
                            $list->get_latest_distribution_date() * 3600 * 24
                        )
                    ),
                    POSIX::strftime(
                        "%d %b %Y", localtime($u->{'last_bounce'})
                    )
                );

            }
        }
    }

    return 1;
}

sub _chk_cert_expiration {
    my ($self, $task) = @_;

    require Sympa::Site;
    require Sympa::Spool::File::Task;

    my $cert_dir       = Sympa::Site->ssl_cert_dir;
    my $execution_date = $task->{'date'};
    my @tab            = @{$self->{'Rarguments'}};
    my $template       = $tab[0];
    my $limit          = Sympa::Tools::Time::duration_conv($tab[1], $execution_date);


    Sympa::Log::Syslog::do_log('notice',
        "line $self->{'line_number'} : chk_cert_expiration (@{$self->{'Rarguments'}})"
    );

    ## building of certificate list
    unless (opendir(DIR, $cert_dir)) {
        $self->_error(
            {   'task' => $task,
                'type' => 'execution',
                'message' =>
                    "error in chk_cert_expiration command : can't open dir $cert_dir"
            }
        );
        return undef;
    }
    my @certificates = grep !/^(\.\.?)|(.+expired)$/, readdir DIR;
    closedir(DIR);

    foreach (@certificates) {

        # an empty .soon_expired file is created when a user is warned that
        # his certificate is soon expired
        my $soon_expired_file = $_ . '.soon_expired';

        # recovery of the certificate expiration date
        open(ENDDATE, "openssl x509 -enddate -in $cert_dir/$_ -noout |");
        my $date = <ENDDATE>;    # expiration date
        close(ENDDATE);
        chomp($date);

        unless ($date) {
            Sympa::Log::Syslog::do_log('err',
                "error in chk_cert_expiration command : can't get expiration date for $_ by using the x509 openssl command"
            );
            next;
        }

        $date =~ /notAfter=(\w+)\s*(\d+)\s[\d\:]+\s(\d+).+/;
        my @date = (0, 0, 0, $2, $Sympa::Spool::File::Task::months{$1}, $3 - 1900);
        $date =~ s/notAfter=//;
        my $expiration_date = Time::Local::timegm(@date);

        # no near expiration nor expiration processing
        if ($expiration_date > $limit) {

            # deletion of unuseful soon_expired file if it is existing
            if (-e $soon_expired_file) {
                unless (unlink($soon_expired_file)) {
                    $self->_error(
                        {   'task'    => $task,
                            'type'    => 'execution',
                            'message' => "Can't delete $soon_expired_file"
                        }
                    );
                }
            }
            next;
        }

        # expired certificate processing
        if ($expiration_date < $execution_date) {

            Sympa::Log::Syslog::do_log('notice',
                "--> $_ certificate expired ($date), certificate file deleted"
            );
            unless (unlink("$cert_dir/$_")) {
                $self->_error(
                    {   'task'    => $task,
                        'type'    => 'execution',
                        'message' => "Can't delete certificate file $_"
                    }
                );
            }
            if (-e $soon_expired_file) {
                unless (unlink("$cert_dir/$soon_expired_file")) {
                    $self->_error(
                        {   'task'    => $task,
                            'type'    => 'execution',
                            'message' => "Can't delete $soon_expired_file"
                        }
                    );
                }
            }
            next;
        }

        # soon expired certificate processing
        if (   ($expiration_date > $execution_date)
            && ($expiration_date < $limit)
            && !(-e $soon_expired_file)) {

            unless (open(FILE, ">$cert_dir/$soon_expired_file")) {
                $self->_error(
                    {   'task'    => $task,
                        'type'    => 'execution',
                        'message' => "Can't create $soon_expired_file"
                    }
                );
                next;
            } else {
                close(FILE);
            }

            my %tpl_context;    # datas necessary to the template

            open(ID, "openssl x509 -subject -in $cert_dir/$_ -noout |");
            my $id = <ID>;      # expiration date
            close(ID);
            chomp($id);

            unless ($id) {
                $self->_error(
                    {   'task' => $task,
                        'type' => 'execution',
                        'message' =>
                            "Can't get expiration date for $_ by using the x509 openssl command"
                    }
                );
                next;
            }

            $id =~ s/subject= //;
            Sympa::Log::Syslog::do_log('notice', "id : $id");
            $tpl_context{'expiration_date'} = Sympa::Tools::Time::adate($expiration_date);
            $tpl_context{'certificate_id'}  = $id;
            $tpl_context{'auto_submitted'}  = 'auto-generated';
            unless (Sympa::Site->send_file($template, $_, \%tpl_context)) {
                $self->_error(
                    {   'task'    => $task,
                        'type'    => 'execution',
                        'message' => "Unable to send template $template to $_"
                    }
                );
            }
            Sympa::Log::Syslog::do_log('notice',
                "--> $_ certificate soon expired ($date), user warned");
        }
    }
    return 1;
}

## attention, j'ai n'ai pas pu comprendre les retours d'erreurs des commandes
## wget donc pas de verif sur le bon fonctionnement de cette commande
sub _update_crl {
    my ($self, $task) = @_;

    require Sympa::Scenario;
    require Sympa::Site;

    my @tab = @{$self->{'Rarguments'}};
    my $limit = Sympa::Tools::Time::epoch_conv($tab[1], $task->{'date'});
    my $CA_file = Sympa::Site->home . "/$tab[0]";   # file where CA urls are stored ;
    Sympa::Log::Syslog::do_log('notice',
        "line $self->{'line_number'} : update_crl (@tab)");

    # building of CA list
    my @CA;
    unless (open(FILE, $CA_file)) {
        $self->_error(
            {   'task' => $task,
                'type' => 'execution',
                'message' =>
                    "error in update_crl command : can't open $CA_file file"
            }
        );
        return undef;
    }
    while (<FILE>) {
        chomp;
        push(@CA, $_);
    }
    close(FILE);

    # updating of crl files
    my $crl_dir = Sympa::Site->crl_dir;
    unless (-d Sympa::Site->crl_dir) {
        if (mkdir(Sympa::Site->crl_dir, 0775)) {
            Sympa::Log::Syslog::do_log('notice', 'creating spool %s',
                Sympa::Site->crl_dir);
        } else {
            $self->_error(
                {   'task'    => $task,
                    'type'    => 'execution',
                    'message' => 'Unable to create CRLs directory '
                        . Sympa::Site->crl_dir
                }
            );
            return undef;
        }
    }

    foreach my $url (@CA) {

        my $crl_file =
            Sympa::Tools::escape_chars($url);    # convert an URL into a file name
        my $file = "$crl_dir/$crl_file";

        ## create $file if it doesn't exist
        unless (-e $file) {
            my $cmd = "wget -O \'$file\' \'$url\'";
            open CMD, "| $cmd";
            close CMD;
        }

        # recovery of the crl expiration date
        open(ID, "openssl crl -nextupdate -in \'$file\' -noout -inform der|");
        my $date = <ID>;                   # expiration date
        close(ID);
        chomp($date);

        unless ($date) {
            $self->_error(
                {   'task' => $task,
                    'type' => 'execution',
                    'message' =>
                        "Can't get expiration date for $file CRL file by using the crl openssl command"
                }
            );
            next;
        }

        $date =~ /nextUpdate=(\w+)\s*(\d+)\s(\d\d)\:(\d\d)\:\d\d\s(\d+).+/;
        my @date = (0, $4, $3 - 1, $2, $Sympa::Spool::File::Task::months{$1}, $5 - 1900);
        my $expiration_date = Time::Local::timegm(@date);

        ## check if the crl is soon expired or expired
        #my $file_date = $task->{'date'} - (-M $file) * 24 * 60 * 60; # last modification date
        my $condition = "newer($limit, $expiration_date)";
        my $verify_context;
        $verify_context->{'sender'} = 'nobody';

        if (Sympa::Scenario::verify($verify_context, $condition) == 1) {
            unlink($file);
            Sympa::Log::Syslog::do_log('notice',
                "--> updating of the $file CRL file");
            my $cmd = "wget -O \'$file\' \'$url\'";
            open CMD, "| $cmd";
            close CMD;
            next;
        }
    }
    return 1;
}

## Subroutine for bouncers evaluation:
# give a score for each bouncing user
sub _eval_bouncers {
    my ($self, $task) = @_;

    require Sympa::List;

    my $all_lists = Sympa::List::get_lists();
    foreach my $list (@$all_lists) {
        my $listname     = $list->name;
        my $list_traffic = {};

        Sympa::Log::Syslog::do_log('info', 'eval_bouncers(%s)', $listname);

        ## Analizing file Msg-count and fill %$list_traffic
        unless (open(COUNT, $list->dir . '/msg_count')) {
            if (-f $list->dir . '/msg_count') {
                $self->_error(
                    {   'task' => $task,
                        'type' => 'execution',
                        'message' =>
                            "Could not open 'msg_count' file for list $listname"
                    }
                );
                next;
            } else {
                $self->_error(
                    {   'task' => $task,
                        'type' => 'execution',
                        'message' =>
                            "File 'msg_count' does not exist for list $listname"
                    }
                );
                next;
            }
        }
        while (<COUNT>) {
            if (/^(\w+)\s+(\d+)/) {
                my ($a, $b) = ($1, $2);
                $list_traffic->{$a} = $b;
            }
        }
        close(COUNT);

        #for each bouncing user
        for (
            my $user_ref = $list->get_first_bouncing_list_member();
            $user_ref;
            $user_ref = $list->get_next_bouncing_list_member()
            ) {

            my $score = get_score($user_ref, $list_traffic) || 0;
            ## copying score into DataBase
            unless (
                $list->update_list_member(
                    $user_ref->{'email'}, {'score' => $score}
                )
                ) {
                $self->_error(
                    {   'task' => $task,
                        'type' => 'execution',
                        'message' =>
                            "Error while updating DB for user $user_ref->{'email'}"
                    }
                );
                next;
            }
        }
    }
    return 1;
}

sub _none {

    1;
}

## Routine for automatic bouncing users management
##
sub _process_bouncers {
    my ($self, $task) = @_;
    Sympa::Log::Syslog::do_log('info',
        'Processing automatic actions on bouncing users');

    require Sympa::List;

###########################################################################
    # This sub apply a treatment foreach category of bouncing-users
    #
    # The relation between possible actions and correponding subroutines
    # is indicated by the following hash (%actions).
    # It's possible to add actions by completing this hash and the one in list
    # config (file List.pm, in sections "bouncers_levelX"). Then you must
    # write
    # the code for your action:
    # The action subroutines have two parameter :
    # - the name of the current list
    # - a reference on users email list:
    # Look at the "remove_bouncers" sub in List.pm for an example
###########################################################################

    ## possible actions
    my %actions = (
        'remove_bouncers' => \&Sympa::List::remove_bouncers,
        'notify_bouncers' => \&Sympa::List::notify_bouncers,
        'none'            => \&none
    );

    my $all_lists = Sympa::List::get_lists();
    foreach my $list (@$all_lists) {
        my $listname = $list->name;

        my @bouncers;

        # @bouncers = ( ['email1', 'email2', 'email3',....,],    There is one
        # line
        #               ['email1', 'email2', 'email3',....,],    foreach
        #               bounce
        #               ['email1', 'email2', 'email3',....,],)   level.

        next unless ($list);

        my $max_level = $list->get_max_bouncers_level();

        ##  first, bouncing email are sorted in @bouncer
        for (
            my $user_ref = $list->get_first_bouncing_list_member();
            $user_ref;
            $user_ref = $list->get_next_bouncing_list_member()
            ) {

            ## Skip included users (cannot be removed)
            next if ($user_ref->{'is_included'});

            for (my $level = $max_level; ($level >= 1); $level--) {
                my $bouncers_level_parameter = 'bouncers_level' . $level;
                if ($user_ref->{'bounce_score'} >=
                    $list->$bouncers_level_parameter->{'rate'}) {
                    push(@{$bouncers[$level]}, $user_ref->{'email'});
                    $level = ($level - $max_level);
                }
            }
        }

        ## then, calling action foreach level
        for (my $level = $max_level; ($level >= 1); $level--) {
            my $bouncers_level_parameter = 'bouncers_level' . $level;
            my $action = $list->$bouncers_level_parameter->{'action'};
            my $notification =
                $list->$bouncers_level_parameter->{'notification'};

            if (defined $bouncers[$level] && @{$bouncers[$level]}) {
                ## calling action subroutine with (list,email list) in
                ## parameter
                unless ($actions{$action}->($list, $bouncers[$level])) {
                    $self->_error(
                        {   'task' => $task,
                            'type' => 'execution',
                            'message' =>
                                "Error while trying to execute action for bouncing users in list $listname"
                        }
                    );
                    return undef;
                }

                ## calling notification subroutine with (list,action, email
                ## list) in parameter
                my $param = {
                    'listname'  => $listname,
                    'action'    => $action,
                    'user_list' => \@{$bouncers[$level]},
                    'total'     => $#{$bouncers[$level]} + 1
                };

                if ($notification eq 'listmaster') {
                    unless (
                        $list->robot->send_notify_to_listmaster(
                            'automatic_bounce_management', $param
                        )
                        ) {
                        $self->_error(
                            {   'task' => $task,
                                'type' => 'execution',
                                'message' =>
                                    'error while notifying listmaster'
                            }
                        );
                    }
                } elsif ($notification eq 'owner') {
                    unless (
                        $list->send_notify_to_owner(
                            'automatic_bounce_management', $param
                        )
                        ) {
                        $self->_error(
                            {   'task' => $task,
                                'type' => 'execution',
                                'message' =>
                                    'error while notifying listmaster'
                            }
                        );
                    }
                }
            }
        }
    }
    return 1;
}

sub _get_score {
    my $user_ref     = shift;
    my $list_traffic = shift;

    Sympa::Log::Syslog::do_log('debug', 'Get_score(%s) ',
        $user_ref->{'email'});

    require Sympa::Site;

    my $min_period    = Sympa::Site->minimum_bouncing_period;
    my $min_msg_count = Sympa::Site->minimum_bouncing_count;

    # Analizing bounce_subscriber_field and keep usefull infos for notation
    $user_ref->{'bounce'} =~ /^(\d+)\s+(\d+)\s+(\d+)(\s+(.*))?$/;

    my $BO_period    = int($1 / 86400) - Sympa::Site->bounce_delay;
    my $EO_period    = int($2 / 86400) - Sympa::Site->bounce_delay;
    my $bounce_count = $3;
    my $bounce_type  = $4;

    my $msg_count = 0;
    my $min_day   = $EO_period;

    unless ($bounce_count >= $min_msg_count) {

        #not enough messages distributed to keep score
        Sympa::Log::Syslog::do_log('debug',
            'Not enough messages for evaluation of user %s',
            $user_ref->{'email'});
        return undef;
    }

    unless (($EO_period - $BO_period) >= $min_period) {

        #too short bounce period to keep score
        Sympa::Log::Syslog::do_log('debug',
            'Too short period for evaluate %s',
            $user_ref->{'email'});
        return undef;
    }

    # calculate number of messages distributed in list while user was bouncing
    foreach my $date (sort { $b <=> $a } keys(%$list_traffic)) {
        if (($date >= $BO_period) && ($date <= $EO_period)) {
            $min_day = $date;
            $msg_count += $list_traffic->{$date};
        }
    }

    # Adjust bounce_count when msg_count file is too recent, compared to the
    # bouncing period
    my $tmp_bounce_count = $bounce_count;
    unless ($EO_period == $BO_period) {
        my $ratio = (($EO_period - $min_day) / ($EO_period - $BO_period));
        $tmp_bounce_count *= $ratio;
    }

    ## Regularity rate tells how much user has bounced compared to list
    ## traffic
    $msg_count ||= 1;    ## Prevents "Illegal division by zero" error
    my $regularity_rate = $tmp_bounce_count / $msg_count;

    ## type rate depends on bounce type (5 = permanent ; 4 =tewmporary)
    my $type_rate = 1;
    $bounce_type =~ /(\d)\.(\d)\.(\d)/;
    if ($1 == 4) {       # if its a temporary Error: score = score/2
        $type_rate = .5;
    }

    my $note = $bounce_count * $regularity_rate * $type_rate;

    ## Note should be an integer
    $note = int($note + 0.5);

    #    $note = 100 if ($note > 100); # shift between message ditrib &
    #    bounces => note > 100

    return $note;
}

sub _sync_include {
    my ($self, $task) = @_;

    Sympa::Log::Syslog::do_log('debug2', 'sync_include(%s)', $task->{'id'});

    my $list = $task->{'list_object'};
    unless (defined $list and ref $list eq 'Sympa::List') {
        return undef;
    }
    unless ($list->sync_include()) {
        $self->_error(
            {   'task' => $task,
                'type' => 'execution',
                'message' =>
                    sprintf(
                    'Error while synchronizing list members for list %s',
                    $list)
            }
        );
    }
    if (scalar @{$list->editor_include} or scalar @{$list->owner_include}) {
        unless ($list->sync_include_admin()) {
            $self->_error(
                {   'task' => $task,
                    'type' => 'execution',
                    'message' =>
                        sprintf(
                        'Error while synchronizing list admins for list %s',
                        $list->get_id)
                }
            );
        }
    }
    return undef if ($self->{'errors'});
    return 1;
}

## Marks the task as being in error with details of the exact error.
sub _error {
    my $self  = shift;
    my $param = shift;

    my $task = $param->{'task'};
    Sympa::Log::Syslog::do_log(
        'err',
        'Error at line %s in task %s: %s',
        $self->{'line_number'},
        $task->get_description, $param->{'message'}
    );
    my $error_description;
    $error_description->{'message'} = $param->{'message'};
    $error_description->{'type'}    = $param->{'type'};
    $error_description->{'line'}    = $self->{'line_number'};

    if (defined $task) {
        if (defined $task->{'errors'}) {
            push @{$task->{'errors'}}, $error_description;
        } else {
            $task->{'errors'} = [$error_description];
        }
    } else {
        Sympa::Log::Syslog::do_log('err',
            'No task object to register error. It will not be used in the reports.'
        );
        return undef;
    }
    return 1;
}

1;