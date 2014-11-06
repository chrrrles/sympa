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

Sympa::Scenario - A scenario

=head1 DESCRIPTION

FIXME

=cut

package Sympa::Scenario;

use strict;
use warnings;

use Carp qw(croak);
use English qw(-no_match_vars);
use File::Spec;
use List::Util qw(first);
use Mail::Address;
use Net::Netmask;
use Scalar::Util qw(blessed);

use Sympa::ConfDef;
use Sympa::Language;
use Sympa::List; # FIXME: circular dependency
use Sympa::Logger;
use Sympa::Site;
use Sympa::Tools::Data;
use Sympa::Tools::Time;

my %all_scenarios;
my %persistent_cache;

=head1 CLASS METHODS

=over 4

=item Sympa::Scenario->new(%parameters)

Creates a new L<Sympa::Scenario> object.

Parameters:

=over 4

=item * I<that>: FIXME

=item * I<name>: FIXME

=item * I<function>: FIXME

=item * I<file_path>: FIXME

=back

Returns a new L<Sympa::Scenario> object, or I<undef> for failure.

=cut

sub new {
    my ($class, %params) = @_;
    $main::logger->do_log(
        Sympa::Logger::DEBUG2,
        '(%s, %s, function=%s, name=%s, file_path=%s)',
        $class,
        $params{that},
        $params{function},
        $params{name},
        $params{file_path},
    );

    my $that      = $params{that};
    my $file_path = $params{file_path};
    my $function  = $params{function};
    my $name      = $params{name};

    if (!$that) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Missing that parameter');
        return undef;
    }

    unless ($that eq 'Site'                           or
            (ref $that && $that->isa('Sympa::List'))  or
            (ref $that && $that->isa('Sympa::VirtualHost'))
    ) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Invalid that parameter');
        return undef;
    }

    ## Check parameters
    ## Need either file_path or function+name
    ## Note: parameter 'directory' was deprecated
    unless ($file_path or ($function and $name)) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Missing either file_path parameter or function and name parameters'
        );
        return undef;
    }

    my $scenario_struct;

    ## Determine the file path of the scenario

    if ($file_path and $file_path eq 'ERROR') {
        return $all_scenarios{$file_path};
    }

    unless ($file_path) {
        $file_path =
            $that->get_etc_filename('scenari/' . $function . '.' . $name);
    }

    my $self;

    if ($file_path) {
        $self->{'file_path'} = $file_path;

        ## Try to follow symlink.  If it succeed, try to get function and name
        ## from real path name.
        my $filename;
        if (-l $file_path) {
            my $realpath = Cwd::abs_path($file_path);
            if (    $realpath
                and -r $realpath
                and ($filename = [File::Spec->splitpath($realpath)]->[2])
                and $filename =~ /^([^\.]+)\.(.+)$/
                and (!$function or $function eq $1)   # only for same function
                ) {
                ($function, $name) = ($1, $2);
            }
        }
        ## Otherwise, get function and name from original path name
        if (!($function and $name) and -r $file_path) {
            $filename = [File::Spec->splitpath($file_path)]->[2];
            unless ($filename and $filename =~ /^([^\.]+)\.(.+)$/) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Failed to determine scenario type and name from "%s"',
                    $file_path);
                return undef;
            }
            ($function, $name) = ($1, $2);
        }

        ## Load the scenario if previously loaded in memory
        if (defined $all_scenarios{$file_path}) {
            ## Use cache unless file has changed on disk
            if ($all_scenarios{$file_path}{'date'} >= (stat($file_path))[9]) {
                return $all_scenarios{$file_path};
            }
        }

        ## Load the scenario

        ## Get the data from file
        unless (open SCENARIO, '<', $file_path) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Failed to open scenario "%s"',
                $file_path);
            return undef;
        }
        my $data = join '', <SCENARIO>;
        close SCENARIO;

        ## Keep rough scenario
        $self->{'data'} = $data;

        $scenario_struct = _parse_scenario($function, $name, $data);
    } elsif ($function eq 'include') {
        ## include.xx not found will not raise an error message
        return undef;
    } else {
        ## Default rule is 'true() smtp -> reject'
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Unable to find scenario file "%s.%s", please report to listmaster',
            $function,
            $name
        );
        $scenario_struct =
            _parse_scenario($function, $name, 'true() smtp -> reject');
        $self->{'file_path'} = 'ERROR';                   ## special value
        $self->{'data'}      = 'true() smtp -> reject';
    }

    ## Keep track of the current time ; used later to reload scenario files
    ## when they changed on disk
    $self->{'date'} = time;

    unless (ref($scenario_struct) eq 'HASH') {
        $main::logger->do_log(Sympa::Logger::ERR, 'Failed to load scenario "%s.%s"',
            $function, $name);
        return undef;
    }

    $self->{'name'}   = $scenario_struct->{'name'};
    $self->{'rules'}  = $scenario_struct->{'rules'};
    $self->{'title'}  = $scenario_struct->{'title'};
    $self->{'struct'} = $scenario_struct;

    bless $self, $class;

    ## Keep the scenario in memory
    $all_scenarios{$self->{'file_path'}} = $self;

    return $self;
}

## Parse scenario rules
sub _parse_scenario {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s)', @_);
    my ($function, $scenario_name, $paragraph) = @_;

    my $structure = {};
    $structure->{'name'} = $scenario_name;
    my @scenario;
    my @rules = split /\n/, $paragraph;

    foreach my $current_rule (@rules) {
        my @auth_methods_list;
        next if ($current_rule =~ /^\s*\w+\s*$/o);    # skip paragraph name
        my $rule = {};
        $current_rule =~ s/\#.*$//;                   # remove comments
        next if ($current_rule =~ /^\s*$/);           # skip empty lines
        if ($current_rule =~ /^\s*title\.gettext\s+(.*)\s*$/i) {
            $structure->{'title'}{'gettext'} = $1;
            next;
        } elsif ($current_rule =~ /^\s*title\.(\S+)\s+(.*)\s*$/i) {
            my ($lang, $title) = ($1, $2);
            # canonicalize lang if possible.
            $lang = Sympa::Language::canonic_lang($lang) || $lang;
            $structure->{'title'}{$lang} = $title;
            next;
        } elsif ($current_rule =~ /^\s*title\s+(.*)\s*$/i) {
            $structure->{'title'}{'default'} = $1;
            next;
        }

        if ($current_rule =~ /\s*(include\s*\(?\'?(.*)\'?\)?)\s*$/i) {
            $rule->{'condition'} = $1;
            push(@scenario, $rule);
        } elsif ($current_rule =~
            /^\s*(.*?)\s+((\s*(md5|pgp|smtp|smime|dkim)\s*,?)*)\s*->\s*(.*)\s*$/gi
            ) {
            $rule->{'condition'} = $1;
            $rule->{'action'}    = $5;
            my $auth_methods = $2 || 'smtp';
            $auth_methods =~ s/\s//g;
            @auth_methods_list = split ',', $auth_methods;
        } else {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'syntax error in scenario %s rule line %d expected : <condition> <auth_mod> -> <action>',
                $function,
                $.
            );
            $main::logger->do_log(Sympa::Logger::ERR, 'error parsing "%s"',
                $current_rule);
            return undef;
        }

        ## Duplicate the rule for each mentionned authentication method
        foreach my $auth_method (@auth_methods_list) {
            push(
                @scenario,
                {   'condition'   => $rule->{condition},
                    'auth_method' => $auth_method,
                    'action'      => $rule->{action}
                }
            );
        }
    }

    $structure->{'rules'} = \@scenario;

    return $structure;
}

=back

=head2 FUNCTIONS

=over 4

=item request_action(%parameters)

Return the action to perform for 1 sender
using 1 auth method to perform 1 operation

IN : -$that (+) : ref(List) | ref(Robot) | "Site"
     -$operation (+) : scalar
     -$auth_method (+) : 'smtp'|'md5'|'pgp'|'smime'|'dkim'
     -$context (+) : ref(HASH) containing information
       to evaluate scenario (scenario var)
     -$debug : adds keys in the returned HASH

OUT : undef | ref(HASH) containing keys :
       -action : 'do_it'|'reject'|'request_auth'
          |'owner'|'editor'|'editorkey'|'listmaster'
       -reason : defined if action == 'reject'
          and in scenario : reject(reason='...')
          key for template authorization_reject.tt2
       -tt2 : defined if action == 'reject'
          and in scenario : reject(tt2='...') or reject('...tt2')
          match a key in authorization_reject.tt2
       -condition : the checked condition
          (defined if $debug)
       -auth_method : the checked auth_method
          (defined if $debug)

=cut

sub request_action {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, %s, %s)', @_);
    my (%params) = @_;
    my $list        = $params{that};
    my $operation   = $params{operation};
    my $auth_method = $params{auth_method};
    my $context     = $params{context};

    croak "missing 'list' parameter" unless $list;
    croak "invalid 'list' parameter" unless $list->isa('Sympa::List');

    my $robot = $list->robot();

    my $trace_scenario;
    ## Defining default values for parameters.
    $context->{'sender'}      ||= 'nobody';
    $context->{'email'}       ||= $context->{'sender'};
    $context->{'remote_host'} ||= 'unknown_host';
    $context->{'robot_domain'} = $robot->domain;
    $context->{'robot_object'} = $robot;
    $context->{'msg'}          = $context->{'message'}->as_entity()
        if defined $context->{'message'};
    $context->{'msg_encrypted'} = 'smime'
        if defined $context->{'message'}
        && $context->{'message'}->is_encrypted();
    ## Check that authorization method is one of those known by Sympa
    unless ($auth_method =~ /^(smtp|md5|pgp|smime|dkim)/) {
        $main::logger->do_log(Sympa::Logger::INFO,
            "fatal error : unknown auth method $auth_method in Sympa::List::get_action"
        );
        return undef;
    }

    my $scenario;

    # this var is defined to control if log scenario is activated or not
    my $log_it;
    if (${$robot->loging_for_module || {}}{'scenario'}) {

        #activate log if no condition is defined
        unless (scalar keys %{$robot->loging_condition || {}}) {
            $log_it = 1;
        } else {

            #activate log if ip or email match
            my $loging_conditions = $robot->loging_condition || {};
            if ((   defined $loging_conditions->{'ip'}
                    && $loging_conditions->{'ip'} =~
                    /$context->{'remote_addr'}/
                )
                || (defined $loging_conditions->{'email'}
                    && $loging_conditions->{'email'} =~
                    /$context->{'email'}/i)
                ) {
                $main::logger->do_log(
                    Sympa::Logger::INFO,
                    'Will log scenario process for user with email: "%s", IP: "%s"',
                    $context->{'email'},
                    $context->{'remote_addr'}
                );
                $log_it = 1;
            }
        }
    }
    if ($log_it) {
        $trace_scenario =
              'scenario request '
            . $operation
            . ' for list '
            . ($list->get_id) . ' :';
        $main::logger->do_log(Sympa::Logger::INFO,
            'Will evaluate scenario %s for list %s',
            $operation, $list);
    }

    $context->{'list_object'} = $list;
    ## The $operation refers to a list parameter of the same name
    ## The list parameter might be structured ('.' is a separator)
    $scenario = $list->get_scenario($operation);

    ## List parameter might not be defined (example : web_archive.access)
    unless ($scenario) {
        my $return = {
            'action'      => 'reject',
            'reason'      => 'parameter-not-defined',
            'auth_method' => '',
            'condition'   => ''
        };
        if ($log_it) {
            $main::logger->do_log(Sympa::Logger::INFO,
                '%s rejected reason parameter not defined',
                $trace_scenario);
        }
        return $return;
    }

    ## Prepares custom_vars in $context
    if (scalar @{$list->custom_vars}) {
        foreach my $var (@{$list->custom_vars}) {
            $context->{'custom_vars'}{$var->{'name'}} = $var->{'value'};
        }
    }

    ## pending/closed lists => send/visibility are closed
    unless ($list->status eq 'open') {
        if ($operation =~ /^(send|visibility)$/) {
            my $return = {
                'action'      => 'reject',
                'reason'      => 'list-no-open',
                'auth_method' => '',
                'condition'   => ''
            };
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "$trace_scenario rejected reason list not open");
            }
            return $return;
        }
    }

    ### the following lines are used by the document sharing action
    if (defined $context->{'scenario'}) {
        my @operations = split /\./, $operation;

        # loading of the structure
        $scenario = Sympa::Scenario->new(
            that     => $list,
            function => $operations[$#operations],
            name     => $context->{'scenario'},
        );
    }


    unless (defined $scenario and defined $scenario->{'rules'}) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Failed to load scenario for "%s"',
            $operation);
        return undef;
    }

    return $scenario->evaluate(
        context     => $context,
        auth_method => $auth_method,
        operation   => $operation,
        log_it      => $log_it,
        trace_scenario => $trace_scenario,
        robot          => $robot,
        that           => $list
    );
}

sub evaluate {
    my ($self, %params) = @_;

    my $context        = $params{context};
    my $auth_method    = $params{auth_method};
    my $operation      = $params{operation};
    my $log_it         = $params{log_it};
    my $robot          = $params{robot};
    my $trace_scenario = $params{trace_scenario};
    my $that           = $params{that};
    my @rules = @{$self->{'rules'}};
    my $name = $self->{'name'};

    unless ($name) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "internal error : configuration for operation $operation is not yet performed by scenario"
        );
        return undef;
    }

    ## Include include.<action>.header if found
    my $include_scenario = Sympa::Scenario->new(
        that       => $that,
        function => 'include',
        name     => $operation . '.header',
    );
    if (defined $include_scenario) {
        ## Add rules at the beginning of the array
        unshift @rules, @{$include_scenario->{'rules'}};
    }
    ## Look for 'include' directives amongst rules first
    for (my $idx = 0; $idx < scalar @rules; $idx++) {
        if ($rules[$idx]->{'condition'} =~
            /^\s*include\s*\(?\'?([\w\.]+)\'?\)?\s*$/i) {
            my $include_file     = $1;
            my $include_scenario = Sympa::Scenario->new(
                that     => $that,
                function => 'include',
                name     => $include_file,
            );
            if (defined $include_scenario) {
                ## Removes the include directive and replace it with
                ## included rules
                ##FIXME: possibie recursive include
                splice @rules, $idx, 1, @{$include_scenario->{'rules'}};
            }
        }
    }

    ## Include a Blacklist rules if configured for this action
    if (Sympa::Site->blacklist->{$operation}) {
        foreach my $auth ('smtp', 'dkim', 'md5', 'pgp', 'smime') {
            my $blackrule = {
                'condition'   => "search('blacklist.txt',[sender])",
                'action'      => 'reject,quiet',
                'auth_method' => $auth
            };
            ## Add rules at the beginning of the array
            unshift @rules, ($blackrule);
        }
    }

    my $return = {};
    foreach my $rule (@rules) {
        if ($log_it) {
            $main::logger->do_log(
                Sympa::Logger::INFO, 'Verify rule %s, auth %s, action %s',
                $rule->{'condition'}, $rule->{'auth_method'},
                $rule->{'action'}
            );
        }
        if ($auth_method eq $rule->{'auth_method'}) {
            if ($log_it) {
                $main::logger->do_log(
                    Sympa::Logger::INFO,
                    'Context uses auth method %s',
                    $rule->{'auth_method'}
                );
            }
            my $result = verify($context, $rule->{'condition'}, $log_it);

            ## Cope with errors
            if (!defined($result)) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "error in $rule->{'condition'},$rule->{'auth_method'},$rule->{'action'}"
                );
                $main::logger->do_log(
                    Sympa::Logger::INFO,
                    'Error in %s scenario, in list %s',
                    $context->{'scenario'},
                    $context->{'listname'}
                );

                $robot->send_notify_to_listmaster(
                    'error-performing-condition',
                    [$context->{'listname'} . "  " . $rule->{'condition'}]);
                return undef;
            }

            ## Rule returned false
            if ($result == -1) {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "$trace_scenario condition $rule->{'condition'} with authentication method $rule->{'auth_method'} not verified."
                    );
                }
                next;
            }

            my $action = $rule->{'action'};

            ## reject : get parameters
            if ($action =~ /^(ham|spam|unsure)/) {
                $action = $1;
            }
            if ($action =~ /^reject(\((.+)\))?(\s?,\s?(quiet))?/) {
                my ($p, $q) = ($2, $4);
                if ($q and $q eq 'quiet') {
                    $action = 'reject,quiet';
                } else {
                    $action = 'reject';
                }
                my @param = ();
                @param = split /,/, $p if $p;

                foreach my $p (@param) {
                    if ($p =~ /^reason=\'?(\w+)\'?/) {
                        $return->{'reason'} = $1;
                        next;

                    } elsif ($p =~ /^tt2=\'?(\w+)\'?/) {
                        $return->{'tt2'} = $1;
                        next;

                    }
                    if ($p =~ /^\'?[^=]+\'?/) {
                        $return->{'tt2'} = $p;

                        # keeping existing only, not merging with reject
                        # parameters in scenarios
                        last;
                    }
                }
            }

            $return->{'action'} = $action;

            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "$trace_scenario condition $rule->{'condition'} with authentication method $rule->{'auth_method'} issued result : $action"
                );
            }

            if ($result == 1) {
                if ($log_it) {
                    $main::logger->do_log(
                        Sympa::Logger::INFO, "rule '%s %s -> %s' accepted",
                        $rule->{'condition'}, $rule->{'auth_method'},
                        $rule->{'action'}
                    );
                }

                ## Check syntax of returned action
                unless ($action =~
                    /^(do_it|reject|request_auth|owner|editor|editorkey|listmaster|ham|spam|unsure)/
                    ) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        "Matched unknown action '%s' in scenario",
                        $rule->{'action'});
                    return undef;
                }
                return $return;
            }
        } else {
            if ($log_it) {
                $main::logger->do_log(
                    Sympa::Logger::INFO,
                    'Context does not use auth method %s',
                    $rule->{'auth_method'}
                );
            }
        }
    }
    $main::logger->do_log(Sympa::Logger::INFO, "no rule match, reject");

    if ($log_it) {
        $main::logger->do_log(Sympa::Logger::INFO,
            "$trace_scenario : no rule match request rejected");
    }

    $return = {
        'action'      => 'reject',
        'reason'      => 'no-rule-match',
        'auth_method' => 'default',
        'condition'   => 'default'
    };
    return $return;
}

=item verify( CONTEXT, CONDITION, LOG_IT )

check if email respect some condition

=cut

sub verify {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my ($context, $condition, $log_it) = @_;

    my $robot;
    if ($context->{'list_object'}) {
        $robot = $context->{'list_object'}->robot;
    } elsif ($context->{'robot_object'}) {
        $robot = $context->{'robot_object'};
    } elsif ($context->{'robot_domain'}) {
        $robot = $context->{'robot_domain'};
        croak "missing 'robot' parameter" unless $robot;
        croak "invalid 'robot' parameter" unless
            (blessed $robot and $robot->isa('Sympa::VirtualHost'));
    }

    my $pinfo;
    if ($robot) {
        $pinfo = $robot->list_params;
    } else {
        $pinfo = {};
    }

    unless (defined($context->{'sender'})) {
        $main::logger->do_log(Sympa::Logger::INFO,
            "internal error, no sender find in Sympa::List::verify, report authors");
        return undef;
    }

    $context->{'execution_date'} = time
        unless (defined($context->{'execution_date'}));

    my $list;
    if ($context->{'listname'} && !defined $context->{'list_object'}) {
        unless ($context->{'list_object'} =
            Sympa::List->new($context->{'listname'}, $robot)) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Unable to create List object for list %s',
                $context->{'listname'}
            );
            return undef;
        }
    }

    if (defined($context->{'list_object'})) {
        $list = $context->{'list_object'};
        $context->{'listname'} = $list->name;

        $context->{'host'} = $list->host;
    }

    if (defined($context->{'msg'})) {
        my $header = $context->{'msg'}->head;
        unless (
            defined $context->{'listname'}
            && ((   $header->get('to')
                    && (join(', ', $header->get('to')) =~
                        /$context->{'listname'}/i)
                )
                || ($header->get('cc')
                    && (join(', ', $header->get('cc')) =~
                        /$context->{'listname'}/i)
                )
            )
            ) {
            $context->{'is_bcc'} = 1;
        } else {
            $context->{'is_bcc'} = 0;
        }

    }
    unless ($condition =~
        /(\!)?\s*(true|is_listmaster|verify_netmask|is_editor|is_owner|is_subscriber|less_than|match|equal|message|older|newer|all|search|customcondition\:\:\w+)\s*\(\s*(.*)\s*\)\s*/i
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "syntax error: unknown condition $condition");
        return undef;
    }
    my $negation = 1;
    if ($1 and $1 eq '!') {
        $negation = -1;
    }

    my $condition_key = lc($2);
    my $arguments     = $3;
    my @args;

    ## The expression for regexp is tricky because we don't allow the '/'
    ## character (that indicates the end of the regexp
    ## but we allow any number of \/ escape sequence)
    while (
        $arguments =~ s/^\s*(
				(\[\w+(\-\>[\w\-]+)?\](\[[-+]?\d+\])?)
				|
				([\w\-\.]+)
				|
				'[^,)]*'
				|
				"[^,)]*"
				|
				\/([^\/]*((\\\/)*[^\/]+))*\/
				|(\w+)\.ldap
				|(\w+)\.sql
				)\s*,?//x
        ) {
        my $value = $1;

        ## Custom vars
        if ($value =~ /\[custom_vars\-\>([\w\-]+)\]/i) {
            $value =~
                s/\[custom_vars\-\>([\w\-]+)\]/$context->{'custom_vars'}{$1}/;
        }

        ## Sympa::Family vars
        if ($value =~ /\[family\-\>([\w\-]+)\]/i) {
            $value =~ s/\[family\-\>([\w\-]+)\]/$context->{'family'}{$1}/;
        }

        ## Config param
        elsif ($value =~ /\[conf\-\>([\w\-]+)\]/i) {
            my $conf_key = $1;
            my $conf_value;
            if (scalar(
                    grep { $_->{'name'} and $_->{'name'} eq $conf_key }
                        @Sympa::ConfDef::params
                )
                and ($conf_value = $robot->$conf_key)
                ) {
                $value =~ s/\[conf\-\>([\w\-]+)\]/$conf_value/;
            } else {
                $main::logger->do_log(Sympa::Logger::DEBUG,
                    'undefined variable context %s in rule %s',
                    $value, $condition);
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        'undefined variable context %s in rule %s',
                        $value, $condition);
                }

                # a condition related to a undefined context variable is
                # always false
                return -1 * $negation;
            }

            ## List param
        } elsif ($value =~ /\[list\-\>([\w\-]+)\]/i) {
            my $param = $1;

            if ($param =~ /^(name|total)$/) {
                my $val = $list->$param;
                $value =~ s/\[list\-\>([\w\-]+)\]/$val/;
            } elsif ($param eq 'address') {
                my $list_address = $list->get_list_address();
                $value =~ s/\[list\-\>([\w\-]+)\]/$list_address/;
            } elsif (exists $pinfo->{$param} and !ref($list->$param)) {
                my $val = $list->$param;
                $value =~ s/\[list\-\>([\w\-]+)\]/$val/;
            } else {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Unknown list parameter %s in rule %s',
                    $value, $condition);
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        'Unknown list parameter %s in rule %s',
                        $value, $condition);
                }
                return undef;
            }

        } elsif ($value =~ /\[env\-\>([\w\-]+)\]/i) {

            $value =~ s/\[env\-\>([\w\-]+)\]/$ENV{$1}/;

            ## Sender's user/subscriber attributes (if subscriber)
        } elsif ($value =~ /\[user\-\>([\w\-]+)\]/i) {

            $context->{'user'} ||=
                Sympa::User::get_global_user(
                    $context->{'sender'},
                    Sympa::Site->db_additional_user_fields
                );
            $value =~ s/\[user\-\>([\w\-]+)\]/$context->{'user'}{$1}/;

        } elsif ($value =~ /\[user_attributes\-\>([\w\-]+)\]/i) {

            $context->{'user'} ||=
                Sympa::User::get_global_user(
                    $context->{'sender'},
                    Sympa::Site->db_additional_user_fields
                );
            $value =~
                s/\[user_attributes\-\>([\w\-]+)\]/$context->{'user'}{'attributes'}{$1}/;

        } elsif (($value =~ /\[subscriber\-\>([\w\-]+)\]/i)
            && defined($context->{'sender'} ne 'nobody')) {

            $context->{'subscriber'} ||=
                $list->get_list_member($context->{'sender'});
            $value =~
                s/\[subscriber\-\>([\w\-]+)\]/$context->{'subscriber'}{$1}/;

        } elsif ($value =~
            /\[(msg_header|header)\-\>([\w\-]+)\](?:\[([-+]?\d+)\])?/i) {
            ## SMTP header field.
            ## "[msg_header->field] returns arrayref of field values,
            ## preserving order. "[msg_header->field][index]" returns one
            ## field value.
            my $field_name = $2;
            my $index = (defined $3) ? $3 + 0 : undef;
            if (defined($context->{'msg'})) {
                my $headers = $context->{'msg'}->head->header();
                my @fields = grep {$_} map {
                    my ($h, $v) = split /\s*:\s*/, $_, 2;
                    (lc $h eq lc $field_name) ? $v : undef;
                } @{$headers || []};
                ## Defaulting empty or missing fields to '', so that we can
                ## test their value in Scenario, considering that, for an
                ## incoming message, a missing field is equivalent to an empty
                ## field : the information it is supposed to contain isn't
                ## available.
                if (defined $index) {
                    $value = $fields[$index];
                    unless (defined $value) {
                        $value = '';
                    }
                } else {
                    unless (@fields) {
                        @fields = ('');
                    }
                    $value = \@fields;
                }
            } else {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        'no message object found to evaluate rule %s',
                        $condition);
                }
                return -1 * $negation;
            }

        } elsif ($value =~ /\[msg_body\]/i) {
            unless (defined($context->{'msg'})
                && defined($context->{'msg'}->effective_type() =~ /^text/)
                && defined($context->{'msg'}->bodyhandle)) {
                if ($log_it) {
                    $main::logger->do_log(
                        Sympa::Logger::INFO,
                        'no proper textual message body to evaluate rule %s',
                        $condition
                    );
                }
                return -1 * $negation;
            }

            $value = $context->{'msg'}->bodyhandle->as_string();

        } elsif ($value =~ /\[msg_part\-\>body\]/i) {
            unless (defined($context->{'msg'})) {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        'no message to evaluate rule %s', $condition);
                }
                return -1 * $negation;
            }

            my @bodies;
            ## FIXME:Should be recurcive...
            foreach my $part ($context->{'msg'}->parts) {
                next unless ($part->effective_type() =~ /^text/);
                next unless (defined $part->bodyhandle);

                push @bodies, $part->bodyhandle->as_string();
            }
            $value = \@bodies;

        } elsif ($value =~ /\[msg_part\-\>type\]/i) {
            unless (defined($context->{'msg'})) {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        'no message to evaluate rule %s', $condition);
                }
                return -1 * $negation;
            }

            my @types;
            foreach my $part ($context->{'msg'}->parts) {
                push @types, $part->effective_type();
            }
            $value = \@types;

        } elsif ($value =~ /\[current_date\]/i) {
            my $time = time;
            $value =~ s/\[current_date\]/$time/;

            ## Quoted string
        } elsif ($value =~ /\[(\w+)\]/i) {

            if (defined($context->{$1})) {
                $value =~ s/\[(\w+)\]/$context->{$1}/i;
            } else {
                $main::logger->do_log(Sympa::Logger::DEBUG,
                    "undefined variable context $value in rule $condition");
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "undefined variable context $value in rule $condition"
                    );
                }

                # a condition related to a undefined context variable is
                # always false
                return -1 * $negation;
            }

        } elsif ($value =~ /^'(.*)'$/ || $value =~ /^"(.*)"$/) {
            $value = $1;
        }
        push(@args, $value);

    }

    # Getting rid of spaces.
    $condition_key =~ s/^\s*//g;
    $condition_key =~ s/\s*$//g;

    # condition that require 0 argument
    if ($condition_key =~ /^(true|all)$/i) {
        unless ($#args == -1) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "syntax error: incorrect number of argument or incorrect argument syntaxe $condition"
            );
            return undef;
        }

        # condition that require 1 argument
    } elsif ($condition_key =~ /^(is_listmaster|verify_netmask)$/) {
        unless ($#args == 0) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "syntax error: incorrect argument number for condition $condition_key"
            );
            return undef;
        }

        # condition that require 1 or 2 args (search : historical reasons)
    } elsif ($condition_key =~ /^search$/o) {
        unless ($#args == 1 || $#args == 0) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "syntax error: Incorrect argument number for condition $condition_key"
            );
            return undef;
        }

        # condition that require 2 args
    } elsif ($condition_key =~
        /^(is_owner|is_editor|is_subscriber|less_than|match|equal|message|newer|older)$/o
        ) {
        unless ($#args == 1) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                "syntax_error: incorrect argument number (%d instead of %d) for condition $condition_key",
                $#args + 1,
                2
            );
            return undef;
        }
    } elsif ($condition_key !~ /^customcondition::/o) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "syntax error: unknown condition $condition_key");
        return undef;
    }

    ## Now eval the condition
    ##### condition : true
    if ($condition_key =~ /^(true|any|all)$/i) {
        if ($log_it) {
            $main::logger->do_log(Sympa::Logger::INFO,
                'Condition %s is always true (rule %s)',
                $condition_key, $condition);
        }
        return $negation;
    }
    ##### condition is_listmaster
    if ($condition_key eq 'is_listmaster') {
        if (!ref $args[0] and $args[0] eq 'nobody') {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    '%s is not listmaster of robot %s (rule %s)',
                    $args[0], $robot, $condition);
            }
            return -1 * $negation;
        }

        my @arg;
        my $ok = undef;
        if (ref $args[0] eq 'ARRAY') {
            @arg = map { $_->address }
                grep {$_} map { (Mail::Address->parse($_)) } @{$args[0]};
        } else {
            @arg = map { $_->address }
                grep {$_} Mail::Address->parse($args[0]);
        }
        foreach my $arg (@arg) {
            if ($robot->is_listmaster($arg)) {
                $ok = $arg;
                last;
            }
        }
        if ($ok) {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    '%s is listmaster of robot %s (rule %s)',
                    $ok, $robot, $condition);
            }
            return $negation;
        } else {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    '%s is not listmaster of robot %s (rule %s)',
                    $args[0], $robot, $condition);
            }
            return -1 * $negation;
        }
    }

    ##### condition verify_netmask
    if ($condition_key eq 'verify_netmask') {

        ## Check that the IP address of the client is available
        ## Means we are in a web context
        unless (defined $ENV{'REMOTE_ADDR'}) {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    'REMOTE_ADDR env variable not set (rule %s)', $condition);
            }
            return -1;   ## always skip this rule because we can't evaluate it
        }
        my $block;
        unless ($block = Net::Netmask->new2($args[0])) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "syntax error: failed to parse netmask '$args[0]'");
            return undef;
        }
        if ($block->match($ENV{'REMOTE_ADDR'})) {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    'REMOTE_ADDR %s matches %s (rule %s)',
                    $ENV{'REMOTE_ADDR'}, $args[0], $condition);
            }
            return $negation;
        } else {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    'REMOTE_ADDR %s does not match %s (rule %s)',
                    $ENV{'REMOTE_ADDR'}, $args[0], $condition);
            }
            return -1 * $negation;
        }
    }

    ##### condition older
    if ($condition_key =~ /^(older|newer)$/) {

        $negation *= -1 if ($condition_key eq 'newer');
        my $arg0 = Sympa::Tools::Time::epoch_conv($args[0]);
        my $arg1 = Sympa::Tools::Time::epoch_conv($args[1]);

        $main::logger->do_log(Sympa::Logger::DEBUG3, '%s(%d, %d)', $condition_key,
            $arg0, $arg1);
        if ($arg0 <= $arg1) {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    '%s is smaller than %s (rule %s)',
                    $arg0, $arg1, $condition);
            }
            return $negation;
        } else {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    '%s is NOT smaller than %s (rule %s)',
                    $arg0, $arg1, $condition);
            }
            return -1 * $negation;
        }
    }

    ##### condition is_owner, is_subscriber and is_editor
    if ($condition_key =~ /^(is_owner|is_subscriber|is_editor)$/i) {
        my ($list2);

        if ($args[1] eq 'nobody') {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "%s can't be used to evaluate (rule %s)",
                    $args[1], $condition);
            }
            return -1 * $negation;
        }

        ## The list is local or in another local robot
        if ($args[0] =~ /\@/) {
            $list2 = Sympa::List->new($args[0]);
        } else {
            $list2 = Sympa::List->new($args[0], $robot);
        }

        if (!$list2) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "unable to create list object \"$args[0]\"");
            return -1 * $negation;
        }

        my @arg;
        my $ok = undef;
        if (ref $args[1] eq 'ARRAY') {
            @arg = map { $_->address }
                grep {$_} map { (Mail::Address->parse($_)) } @{$args[1]};
        } else {
            @arg = map { $_->address }
                grep {$_} Mail::Address->parse($args[1]);
        }

        if ($condition_key eq 'is_subscriber') {
            foreach my $arg (@arg) {
                if ($list2->is_list_member($arg)) {
                    $ok = $arg;
                    last;
                }
            }
            if ($ok) {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "%s is member of list %s (rule %s)",
                        $ok, $args[0], $condition);
                }
                return $negation;
            } else {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "%s is NOT member of list %s (rule %s)",
                        $args[1], $args[0], $condition);
                }
                return -1 * $negation;
            }

        } elsif ($condition_key eq 'is_owner') {
            foreach my $arg (@arg) {
                if ($list2->am_i('owner', $arg)) {
                    $ok = $arg;
                    last;
                }
            }
            if ($ok) {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "%s is owner of list %s (rule %s)",
                        $ok, $args[0], $condition);
                }
                return $negation;
            } else {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "%s is NOT owner of list %s (rule %s)",
                        $args[1], $args[0], $condition);
                }
                return -1 * $negation;
            }

        } elsif ($condition_key eq 'is_editor') {
            foreach my $arg (@arg) {
                if ($list2->am_i('editor', $arg)) {
                    $ok = $arg;
                    last;
                }
            }
            if ($ok) {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "%s is editor of list %s (rule %s)",
                        $ok, $args[0], $condition);
                }
                return $negation;
            } else {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "%s is NOT editor of list %s (rule %s)",
                        $args[1], $args[0], $condition);
                }
                return -1 * $negation;
            }
        }
    }
    ##### match
    if ($condition_key eq 'match') {
        unless ($args[1] =~ /^\/(.*)\/$/) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Match parameter %s is not a regexp',
                $args[1]);
            return undef;
        }
        my $regexp = $1;

        # Nothing can match an empty regexp.
        if ($regexp =~ /^$/) {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "regexp '%s' is empty (rule %s)",
                    $regexp, $condition);
            }
            return -1 * $negation;
        }

        if ($regexp =~ /\[host\]/) {
            my $reghost = $robot->host;
            $reghost =~ s/\./\\./g;
            $regexp  =~ s/\[host\]/$reghost/g;
        }

        # wrap matches with eval{} to avoid crash by malformed regexp.
        my $r = 0;
        if (ref($args[0])) {
            eval {
                foreach my $arg (@{$args[0]}) {
                    if ($arg =~ /$regexp/i) {
                        $r = 1;
                        last;
                    }
                }
            };
        } else {
            eval {
                if ($args[0] =~ /$regexp/i) {
                    $r = 1;
                }
            };
        }
        if ($EVAL_ERROR) {
            $main::logger->do_log(Sympa::Logger::ERR, 'cannot evaluate match: %s',
                $EVAL_ERROR);
            return undef;
        }
        if ($r) {
            if ($log_it) {
                my $args_as_string = '';
                if (ref($args[0])) {
                    foreach my $arg (@{$args[0]}) {
                        $args_as_string .= "$arg, ";
                    }
                } else {
                    $args_as_string = $args[0];
                }
                $main::logger->do_log(Sympa::Logger::INFO,
                    "'%s' matches regexp '%s' (rule %s)",
                    $args_as_string, $regexp, $condition);
            }
            return $negation;
        } else {
            if ($log_it) {
                my $args_as_string = '';
                if (ref($args[0])) {
                    foreach my $arg (@{$args[0]}) {
                        $args_as_string .= "$arg, ";
                    }
                } else {
                    $args_as_string = $args[0];
                }
                $main::logger->do_log(Sympa::Logger::INFO,
                    "'%s' does not match regexp '%s' (rule %s)",
                    $args_as_string, $regexp, $condition);
            }
            return -1 * $negation;
        }
    }

    ## search rule
    if ($condition_key eq 'search') {
        my $val_search;

        # we could search in the family if we got ref on Sympa::Family object
        $val_search = _search(($list || $robot), $args[0], $context);
        return undef unless defined $val_search;
        if ($val_search == 1) {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "'%s' found in '%s', robot %s (rule %s)",
                    $context->{'sender'}, $args[0], $robot, $condition);
            }
            return $negation;
        } else {
            if ($log_it) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "'%s' NOT found in '%s', robot %s (rule %s)",
                    $context->{'sender'}, $args[0], $robot, $condition);
            }
            return -1 * $negation;
        }
    }

    ## equal
    if ($condition_key eq 'equal') {
        if (ref($args[0])) {
            foreach my $arg (@{$args[0]}) {
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'ARG: %s', $arg);
                if (lc($arg) eq lc($args[1])) {
                    if ($log_it) {
                        $main::logger->do_log(Sympa::Logger::INFO,
                            "'%s' equals '%s' (rule %s)",
                            lc($arg), lc($args[1]), $condition);
                    }
                    return $negation;
                }
            }
        } else {
            if (lc($args[0]) eq lc($args[1])) {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "'%s' equals '%s' (rule %s)",
                        lc($args[0]), lc($args[1]), $condition);
                }
                return $negation;
            }
        }
        if ($log_it) {
            $main::logger->do_log(Sympa::Logger::INFO,
                "'%s' does NOT equal '%s' (rule %s)",
                lc($args[0]), lc($args[1]), $condition);
        }
        return -1 * $negation;
    }

    ## custom perl module
    if ($condition_key =~ /^customcondition::(\w+)/o) {
        my $condition = $1;

        my $res = _verify_custom(($list || $robot), $condition, \@args);
        unless (defined $res) {
            if ($log_it) {
                my $args_as_string = '';
                foreach my $arg (@args) {
                    $args_as_string .= ", $arg";
                }
                $main::logger->do_log(
                    Sympa::Logger::INFO,
                    "custom condition '%s' returned an undef value with arguments '%s' (rule %s)",
                    $condition,
                    $args_as_string,
                    $condition
                );
            }
            return undef;
        }
        if ($log_it) {
            my $args_as_string = '';
            foreach my $arg (@args) {
                $args_as_string .= ", $arg";
            }
            if ($res == 1) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "'%s' verifies custom condition '%s' (rule %s)",
                    $args_as_string, $condition, $condition);
            } else {
                $main::logger->do_log(Sympa::Logger::INFO,
                    "'%s' does not verify custom condition '%s' (rule %s)",
                    $args_as_string, $condition, $condition);
            }
        }
        return $res * $negation;
    }

    ## less_than
    if ($condition_key eq 'less_than') {
        if (ref($args[0])) {
            foreach my $arg (@{$args[0]}) {
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'ARG: %s', $arg);
                if (Sympa::Tools::Data::smart_lessthan($arg, $args[1])) {
                    if ($log_it) {
                        $main::logger->do_log(Sympa::Logger::INFO,
                            "'%s' is less than '%s' (rule %s)",
                            $arg, $args[1], $condition);
                    }
                    return $negation;
                }
            }
        } else {
            if (Sympa::Tools::Data::smart_lessthan($args[0], $args[1])) {
                if ($log_it) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        "'%s' is less than '%s' (rule %s)",
                        $args[0], $args[1], $condition);
                }
                return $negation;
            }
        }

        if ($log_it) {
            $main::logger->do_log(Sympa::Logger::INFO,
                "'%s' is NOT less than '%s' (rule %s)",
                $args[0], $args[1], $condition);
        }
        return -1 * $negation;
    }
    return undef;
}

# Verify if a given user is part of an LDAP, SQL or TXT search filter
sub _search {
    my $that        = shift || 'Site';
    my $filter_file = shift;
    my $context     = shift;

    unless (ref $that and ref $that eq 'Sympa::List') {
        croak "missing 'that' parameter" unless $that;
        croak "invalid 'that' parameter" unless
            $that eq '*' or
            (blessed $that and $that->isa('Sympa::VirtualHost'));
    }

    my $sender = $context->{'sender'};

    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, sender=%s)',
        $that, $filter_file, $sender);

    if ($filter_file =~ /\.sql$/) {

        my $file = $that->get_etc_filename("search_filters/$filter_file");

        my $timeout = 3600;
        my $sql_conf;

        unless ($sql_conf = Sympa::Conf::load_sql_filter($file)) {
            $that->send_notify_to_owner('named_filter',
                {'filter' => $filter_file})
                if ref $that eq 'Sympa::List';
            return undef;
        }

        my $statement = $sql_conf->{'sql_named_filter_query'}->{'statement'};
        my $filter    = $statement;
        my @statement_args;    ## Useful to later quote parameters

        ## Minimalist variable parser ; only parse [x] or [x->y]
        ## should be extended with the code from verify()
        while ($filter =~ /\[(\w+(\-\>[\w\-]+)?)\]/x) {
            my ($full_var) = ($1);
            my ($var, $key) = split /\-\>/, $full_var;

            unless (defined $context->{$var}) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Failed to parse variable '%s' in filter '%s'",
                    $var, $file);
                return undef;
            }

            if (defined $key) {    ## Should be a hash
                unless (defined $context->{$var}{$key}) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        "Failed to parse variable '%s.%s' in filter '%s'",
                        $var, $key, $file);
                    return undef;
                }

                $filter    =~ s/\[$full_var\]/$context->{$var}{$key}/;
                $statement =~ s/\[$full_var\]/\%s/;
                push @statement_args, $context->{$var}{$key};
            } else {               ## Scalar
                $filter    =~ s/\[$full_var\]/$context->{$var}/;
                $statement =~ s/\[$full_var\]/\%s/;
                push @statement_args, $context->{$var};

            }
        }

        #        $statement =~ s/\[sender\]/%s/g;
        #        $filter =~ s/\[sender\]/$sender/g;

        if (defined($persistent_cache{'named_filter'}{$filter_file}{$filter})
            && (time <=
                $persistent_cache{'named_filter'}{$filter_file}{$filter}
                {'update'} + $timeout)
            ) {    ## Cache has 1hour lifetime
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Using previous SQL named filter cache');
            return $persistent_cache{'named_filter'}{$filter_file}{$filter}
                {'value'};
        }

        require Sympa::Datasource::SQL;
        my $ds = Sympa::Datasource::SQL->new($sql_conf->{'sql_named_filter_query'});
        unless (defined $ds && $ds->connect() && $ds->ping) {
            $main::logger->do_log(
                Sympa::Logger::NOTICE,
                'Unable to connect to the SQL server %s:%d',
                $sql_conf->{'db_host'},
                $sql_conf->{'db_port'}
            );
            return undef;
        }

        ## Quote parameters
        foreach (@statement_args) {
            $_ = $ds->quote($_);
        }

        $statement = sprintf $statement, @statement_args;
        unless ($ds->query($statement)) {
            $main::logger->do_log(Sympa::Logger::DEBUG, '%s named filter cancelled',
                $file);
            return undef;
        }

        my $res = $ds->fetch;
        $ds->disconnect();
        my $first_row = ref($res->[0]) ? $res->[0]->[0] : $res->[0];
        $main::logger->do_log(Sympa::Logger::DEBUG2, 'Result of SQL query : %d = %s',
            $first_row, $statement);

        if ($first_row == 0) {
            $persistent_cache{'named_filter'}{$filter_file}{$filter}
                {'value'} = 0;
        } else {
            $persistent_cache{'named_filter'}{$filter_file}{$filter}
                {'value'} = 1;
        }
        $persistent_cache{'named_filter'}{$filter_file}{$filter}{'update'} =
            time;
        return $persistent_cache{'named_filter'}{$filter_file}{$filter}
            {'value'};
    } elsif ($filter_file =~ /\.ldap$/) {
        ## Determine full path of the filter file
        my $file = $that->get_etc_filename("search_filters/$filter_file");

        unless ($file) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Could not find search filter %s', $filter_file);
            return undef;
        }
        my $timeout = 3600;
        my %ldap_conf = _load_sympa_configuration($file);

        return undef unless %ldap_conf;

        my $filter = $ldap_conf{'filter'};

        ## Minimalist variable parser ; only parse [x] or [x->y]
        ## should be extended with the code from verify()
        while ($filter =~ /\[(\w+(\-\>[\w\-]+)?)\]/x) {
            my ($full_var) = ($1);
            my ($var, $key) = split /\-\>/, $full_var;

            unless (defined $context->{$var}) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Failed to parse variable '%s' in filter '%s'",
                    $var, $file);
                return undef;
            }

            if (defined $key) {    ## Should be a hash
                unless (defined $context->{$var}{$key}) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        "Failed to parse variable '%s.%s' in filter '%s'",
                        $var, $key, $file);
                    return undef;
                }

                $filter =~ s/\[$full_var\]/$context->{$var}{$key}/;
            } else {               ## Scalar
                $filter =~ s/\[$full_var\]/$context->{$var}/;

            }
        }

        #	$filter =~ s/\[sender\]/$sender/g;

        if (defined($persistent_cache{'named_filter'}{$filter_file}{$filter})
            && (time <=
                $persistent_cache{'named_filter'}{$filter_file}{$filter}
                {'update'} + $timeout)
            ) {                    ## Cache has 1hour lifetime
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Using previous LDAP named filter cache');
            return $persistent_cache{'named_filter'}{$filter_file}{$filter}
                {'value'};
        }

        require Sympa::Datasource::LDAP;
        my $ldap;
        my $param = Sympa::Tools::Data::dup_var(\%ldap_conf);
        my $ds    = Sympa::Datasource::LDAP->new($param);

        unless (defined $ds && ($ldap = $ds->connect())) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "Unable to connect to the LDAP server '%s'",
                $param->{'ldap_host'});
            return undef;
        }

        ## The 1.1 OID correponds to DNs ; it prevents the LDAP server from
        ## preparing/providing too much data
        my $mesg = $ldap->search(
            base   => "$ldap_conf{'suffix'}",
            filter => "$filter",
            scope  => "$ldap_conf{'scope'}",
            attrs  => ['1.1']
        );
        unless ($mesg) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "Unable to perform LDAP search");
            return undef;
        }
        unless ($mesg->code == 0) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Ldap search failed');
            return undef;
        }

        if ($mesg->count() == 0) {
            $persistent_cache{'named_filter'}{$filter_file}{$filter}
                {'value'} = 0;

        } else {
            $persistent_cache{'named_filter'}{$filter_file}{$filter}
                {'value'} = 1;
        }

        $ds->disconnect()
            or $main::logger->do_log(Sympa::Logger::NOTICE,
            'Sympa::List::search_ldap.Unbind impossible');
        $persistent_cache{'named_filter'}{$filter_file}{$filter}{'update'} =
            time;

        return $persistent_cache{'named_filter'}{$filter_file}{$filter}
            {'value'};

    } elsif ($filter_file =~ /\.txt$/) {

        # $main::logger->do_log(Sympa::Logger::INFO, 'Sympa::List::search: eval %s',
        # $filter_file);
        my @files =
            $that->get_etc_filename("search_filters/$filter_file",
            {'order' => 'all'});

        ## Raise an error except for blacklist.txt
        unless (@files) {
            if ($filter_file eq 'blacklist.txt') {
                return -1;
            } else {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Could not find search filter %s', $filter_file);
                return undef;
            }
        }

        my $sender = lc($sender);
        foreach my $file (@files) {
            $main::logger->do_log(Sympa::Logger::DEBUG3,
                'Sympa::List::search: found file  %s', $file);
            unless (open FILE, $file) {
                $main::logger->do_log(Sympa::Logger::ERR, 'Could not open file %s',
                    $file);
                return undef;
            }
            while (<FILE>) {

                # $main::logger->do_log(Sympa::Logger::DEBUG3, 'Sympa::List::search: eval
                # rule %s', $_);
                next if (/^\s*$/o || /^[\#\;]/o);
                my $regexp = $_;
                chomp $regexp;
                $regexp =~ s/\*/.*/;
                $regexp = '^' . $regexp . '$';

                # $main::logger->do_log(Sympa::Logger::DEBUG3, 'Sympa::List::search: eval  %s
                # =~ /%s/i', $sender,$regexp);
                return 1 if ($sender =~ /$regexp/i);
            }
        }
        return -1;
    } else {
        $main::logger->do_log(Sympa::Logger::ERR, "Unknown filter file type %s",
            $filter_file);
        return undef;
    }
}

# eval a custom perl module to verify a scenario condition
sub _verify_custom {
    my $that      = shift || 'Site';
    my $condition = shift;
    my $args_ref  = shift;

    my $robot;
    if (ref $that and ref $that eq 'Sympa::List') {
        $robot = $that->robot;
    } else {
        $robot = $that;
        croak "missing 'robot' parameter" unless $robot;
        croak "invalid 'robot' parameter" unless
            $robot eq '*' or
            (blessed $robot and $robot->isa('Sympa::VirtualHost'));
    }

    my $timeout = 3600;

    my $filter = join('*', @{$args_ref});
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, filter=%s)',
        $that, $condition, $filter);

    if (defined($persistent_cache{'named_filter'}{$condition}{$filter})
        && (time <=
            $persistent_cache{'named_filter'}{$condition}{$filter}{'update'} +
            $timeout)
        ) {    ## Cache has 1hour lifetime
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Using previous custom condition cache %s', $filter);
        return $persistent_cache{'named_filter'}{$condition}{$filter}
            {'value'};
    }

    # use this if you want per list customization (be sure you know what
    # you are doing)
    #my $file = $that->get_etc_filename("custom_conditions/${condition}.pm");
    my $file = $robot->get_etc_filename("custom_conditions/${condition}.pm");
    unless ($file) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'No module found for %s custom condition', $condition);
        return undef;
    }
    $main::logger->do_log(Sympa::Logger::NOTICE, 'Use module %s for custom condition',
        $file);
    eval { require "$file"; };
    if ($EVAL_ERROR) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Error requiring %s : %s (%s)',
            $condition, "$EVAL_ERROR", ref($EVAL_ERROR));
        return undef;
    }
    my $res;
    eval "\$res = CustomCondition::${condition}::verify(\@{\$args_ref});";
    if ($EVAL_ERROR) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Error evaluating %s : %s (%s)',
            $condition, "$EVAL_ERROR", ref($EVAL_ERROR));
        return undef;
    }

    return undef unless defined $res;

    $persistent_cache{'named_filter'}{$condition}{$filter}{'value'} =
        ($res == 1 ? 1 : 0);
    $persistent_cache{'named_filter'}{$condition}{$filter}{'update'} = time;
    return $persistent_cache{'named_filter'}{$condition}{$filter}{'value'};
}

=back

=head2 INSTANCE METHODS

=over 4

=item $scenario->get_current_title ()

Get internationalized title of the scenario, under current language context.

=cut

## Get the title in the current language
sub get_current_title {
    my $self = shift;

    foreach my $lang (Sympa::Language::implicated_langs($main::language->get_lang))
    {
        if (exists $self->{'title'}{$lang}) {
            return $self->{'title'}{$lang};
        }
    }
    if (exists $self->{'title'}{'gettext'}) {
        return $main::language->gettext($self->{'title'}{'gettext'});
    } elsif (exists $self->{'title'}{'default'}) {
        return $self->{'title'}{'default'};
    } else {
        return $self->{'name'};
    }
}

=item scenario->get_id ()

Get unique ID of object.

=cut

sub get_id {
    return shift->{'file_path'} || '';
}

=item $scenario->is_purely_closed ()

Returns 1 if all conditions in scenario are "true()   [an_auth_method]    ->  reject"

=cut

sub is_purely_closed {
    my $self = shift;
    foreach my $rule (@{$self->{'rules'}}) {
        if (   $rule->{'condition'} ne 'true'
            && $rule->{'action'} !~ /reject/) {
            $main::logger->do_log(Sympa::Logger::DEBUG2,
                'Scenario %s is not purely closed.',
                $self->{'title'});
            return 0;
        }
    }
    $main::logger->do_log(Sympa::Logger::NOTICE, 'Scenario %s is purely closed.',
        $self->{'file_path'});
    return 1;
}

sub _load_ldap_configuration {
    my ($config) = @_;

    $main::logger->do_log(Sympa::Logger::DEBUG3, 'Ldap::load(%s)', $config);

    my $line_num   = 0;
    my $config_err = 0;
    my ($i, %o);

    ## Open the configuration file or return and read the lines.
    unless (open(IN, $config)) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unable to open %s: %s',
            $config, $ERRNO);
        return undef;
    }

    my @valid_options    = qw(host suffix filter scope bind_dn bind_password);
    my @required_options = qw(host suffix filter);

    my %valid_options    = map { $_ => 1 } @valid_options;
    my %required_options = map { $_ => 1 } @required_options;

    my %Default_Conf = (
        'host'          => undef,
        'suffix'        => undef,
        'filter'        => undef,
        'scope'         => 'sub',
        'bind_dn'       => undef,
        'bind_password' => undef
    );

    my %Ldap = ();

    my $folded_line;
    while (my $current_line = <IN>) {
        $line_num++;
        next if ($current_line =~ /^\s*$/o || $current_line =~ /^[\#\;]/o);

        ## Cope with folded line (ending with '\')
        if ($current_line =~ /\\\s*$/) {
            $current_line =~ s/\\\s*$//;    ## remove trailing \
            chomp $current_line;
            $folded_line .= $current_line;
            next;
        } elsif (defined $folded_line) {
            $current_line = $folded_line . $current_line;
            $folded_line  = undef;
        }

        if ($current_line =~ /^(\S+)\s+(.+)$/io) {
            my ($keyword, $value) = ($1, $2);
            $value =~ s/\s*$//;

            $o{$keyword} = [$value, $line_num];
        } else {

            #	    printf STDERR Msg(1, 3, "Malformed line %d: %s"), $config,
            #	    $_;
            $config_err++;
        }
    }
    close(IN);

    ## Check if we have unknown values.
    foreach $i (sort keys %o) {
        $Ldap{$i} = $o{$i}[0] || $Default_Conf{$i};

        unless ($valid_options{$i}) {
            $main::logger->do_log(Sympa::Logger::ERR, "Line %d, unknown field: %s \n",
                $o{$i}[1], $i);
            $config_err++;
        }
    }
    ## Do we have all required values ?
    foreach $i (keys %required_options) {
        unless (defined $o{$i} or defined $Default_Conf{$i}) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "Required field not found : %s\n", $i);
            $config_err++;
            next;
        }
    }
    return %Ldap;
}

=back

=cut

1;
