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

Sympa::Monitor - An activity recorder

=head1 DESCRIPTION

This class implements an activity recorder, for monitoring purpose.

=cut

package Sympa::Monitor;

use strict;
use English qw(-no_match_vars);

#use Carp; # currently not used
use POSIX qw();
use Time::HiRes;

use Sympa::Tools::Time;

#XXXuse Sympa::List; # no longer used
#use Sympa::DatabaseManager; #FIXME: dependency loop between Log & SDM

my ($sth, @sth_stack, $rows_nb);

our $last_date_aggregation;

##sub import {
##my @call = caller(1);
##printf "Import from $call[3]\n";
##Log->export_to_level(1, @_);
##}
##


sub get_log_date {
    my $sth;
    my @dates;
    foreach my $query ('MIN', 'MAX') {
        unless ($sth =
            Sympa::DatabaseManager::do_query("SELECT $query(date_logs) FROM logs_table")) {
            do_log(Sympa::Logger::ERR, 'Unable to get %s date from logs_table', $query);
            return undef;
        }
        while (my $d = ($sth->fetchrow_array)[0]) {
            push @dates, $d;
        }
    }

    return @dates;
}

# add log in RDBMS
sub db_log {
    my (%params) = @_;

    my $list         = $params{'list'} || '';
    my $robot        = $params{'robot'};
    my $action       = $params{'action'};
    my $parameters   = $params{'parameters'} || '';
    my $target_email = $params{'target_email'} || '';
    my $msg_id       = Sympa::Tools::clean_msg_id($params{'msg_id'}) || '';
    my $status       = $params{'status'};
    my $error_type   = $params{'error_type'} || '';
    my $user_email   = Sympa::Tools::clean_msg_id($params{'user_email'}) || '';
    my $client       = $params{'client'};
    my $daemon       = $params{'daemon'};
    my $date         = Time::HiRes::time;
    my $random       = int(rand(1000000));
    my $id           = int($date * 1000) . $random;

    unless ($user_email) {
        $user_email = 'anonymous';
    }

    my $listname;
    unless ($list) {
        $listname = '';
    } elsif (ref $list and ref $list eq 'Sympa::List') {
        $listname = $list->name;
        $robot ||= $list->robot;
    } elsif ($list =~ /(.+)\@(.+)/) {

        #remove the robot name of the list name
        $listname = $1;
        $robot ||= $2;
    }

    my $robot_id;
    if (ref $robot and ref $robot eq 'Sympa::VirtualHost') {
        $robot_id = $robot->name;
    } else {
        $robot_id = $robot || '';
    }

    unless ($daemon =~ /^(task|archived|sympa|wwsympa|bounced|sympa_soap)$/) {
        do_log(Sympa::Logger::ERR, "Internal_error : incorrect process value $daemon");
        return undef;
    }

    ## Insert in log_table

    unless (
        Sympa::DatabaseManager::do_prepared_query(
            q{INSERT INTO logs_table
	  (id_logs, date_logs, robot_logs, list_logs, action_logs,
	   parameters_logs, target_email_logs, msg_id_logs, status_logs,
	   error_type_logs, user_email_logs, client_logs, daemon_logs)
	  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)},
            $id, Sympa::DatabaseManager::AS_DOUBLE($date), $robot_id, $listname, $action,
            substr($parameters, 0, 100), $target_email, $msg_id, $status,
            $error_type, $user_email, $client, $daemon
        )
        ) {
        do_log(Sympa::Logger::ERR, 'Unable to insert new db_log entry in the database');
        return undef;
    }

    #if (($action eq 'send_mail') && $list && $robot){
    #	update_subscriber_msg_send($user_email,$list,$robot,1);
    #}

    return 1;
}

#insert data in stats table
sub db_stat_log {
    my (%params) = @_;

    my $list      = $params{'list'};
    my $operation = $params{'operation'};
    my $date   = time;               #epoch time : time since 1st january 1970
    my $mail   = $params{'mail'};
    my $daemon = $params{'daemon'};
    my $ip     = $params{'client'} || '';
    my $robot  = $params{'robot'};
    my $parameter = $params{'parameter'} || '';
    my $random    = int(rand(1000000));
    my $id        = $date . $random;
    my $read      = 0;

    if (ref($list) =~ /List/i) {
        $list = $list->get_id;
    }
    if ($list =~ /(.+)\@(.+)/) {    #remove the robot name of the list name
        $list = $1;
        unless ($robot) {
            $robot = $2;
        }
    }

    ##insert in stat table
    unless (
        Sympa::DatabaseManager::do_query(
            'INSERT INTO stat_table (id_stat, date_stat, email_stat, operation_stat, list_stat, daemon_stat, user_ip_stat, robot_stat, parameter_stat, read_stat) VALUES (%s, %d, %s, %s, %s, %s, %s, %s, %s, %d)',
            $id,
            $date,
            Sympa::DatabaseManager::quote($mail),
            Sympa::DatabaseManager::quote($operation),
            Sympa::DatabaseManager::quote($list),
            Sympa::DatabaseManager::quote($daemon),
            Sympa::DatabaseManager::quote($ip),
            Sympa::DatabaseManager::quote($robot),
            Sympa::DatabaseManager::quote($parameter),
            Sympa::DatabaseManager::quote($read)
        )
        ) {
        do_log(Sympa::Logger::ERR, 'Unable to insert new stat entry in the database');
        return undef;
    }
    return 1;
}    #end sub

sub db_stat_counter_log {
    my (%params) = @_;

    my $date_deb  = $params{'begin_date'};
    my $date_fin  = $params{'end_date'};
    my $data      = $params{'data'};
    my $list      = $params{'list'};
    my $variation = $params{'variation'};
    my $total     = $params{'total'};
    my $robot     = $params{'robot'};
    my $random    = int(rand(1000000));
    my $id        = $date_deb . $random;

    if ($list =~ /(.+)\@(.+)/) {    #remove the robot name of the list name
        $list = $1;
        unless ($robot) {
            $robot = $2;
        }
    }

    unless (
        Sympa::DatabaseManager::do_query(
            'INSERT INTO stat_counter_table (id_counter, beginning_date_counter, end_date_counter, data_counter, robot_counter, list_counter, variation_counter, total_counter) VALUES (%s, %d, %d, %s, %s, %s, %d, %d)',
            $id,
            $date_deb,
            $date_fin,
            Sympa::DatabaseManager::quote($data),
            Sympa::DatabaseManager::quote($robot),
            Sympa::DatabaseManager::quote($list),
            $variation,
            $total
        )
        ) {
        do_log(Sympa::Logger::ERR,
            'Unable to insert new stat counter entry in the database');
        return undef;
    }
    return 1;

}    #end sub

# delete logs in RDBMS
sub db_log_del {
    my $exp = Sympa::Site->logs_expiration_period;
    my $date = time - ($exp * 30 * 24 * 60 * 60);

    unless (
        Sympa::DatabaseManager::do_query(
            q{DELETE FROM logs_table
	  WHERE logs_table.date_logs <= %d},
            $date
        )
        ) {
        do_log(Sympa::Logger::ERR, 'Unable to delete db_log entry from the database');
        return undef;
    }
    return 1;

}

# Scan log_table with appropriate select
sub get_first_db_log {
    my $select = shift;
    my $sortby = shift || 'date';
    my $way    = shift || 'asc';
    $sortby = 'date'
        unless $sortby =~
            /^(list|parameters|msg_id|action|client|user_email|daemon|target_email|status|error_type|robot)$/;
    $way = 'asc'
        unless $way =~ /^(asc|desc)$/;
    $select->{'target_type'} = 'none'
        unless $select->{'target_type'} =~
            /^(list|parameters|msg_id|action|client|user_email|daemon|target_email|status|error_type|robot)$/;

    my %action_type = (
        'message' => [
            'reject',       'distribute',  'arc_delete',   'arc_download',
            'sendMessage',  'remove',      'record_email', 'send_me',
            'd_remove_arc', 'rebuildarc',  'remind',       'send_mail',
            'DoFile',       'sendMessage', 'DoForward',    'DoMessage',
            'DoCommand',    'SendDigest'
        ],
        'authentication' => [
            'login',        'logout',
            'loginrequest', 'sendpasswd',
            'ssologin',     'ssologin_succeses',
            'remindpasswd', 'choosepasswd'
        ],
        'subscription' =>
            ['subscribe', 'signoff', 'add', 'del', 'ignoresub', 'subindex'],
        'list_management' => [
            'create_list',          'rename_list',
            'close_list',           'edit_list',
            'admin',                'blacklist',
            'install_pending_list', 'purge_list',
            'edit_template',        'copy_template',
            'remove_template'
        ],
        'bounced'     => ['resetbounce', 'get_bounce'],
        'preferences' => [
            'set',       'setpref', 'pref', 'change_email',
            'setpasswd', 'editsubscriber'
        ],
        'shared' => [
            'd_unzip',                'd_upload',
            'd_read',                 'd_delete',
            'd_savefile',             'd_overwrite',
            'd_create_dir',           'd_set_owner',
            'd_change_access',        'd_describe',
            'd_rename',               'd_editfile',
            'd_admin',                'd_install_shared',
            'd_reject_shared',        'd_properties',
            'creation_shared_file',   'd_unzip_shared_file',
            'install_file_hierarchy', 'd_copy_rec_dir',
            'd_copy_file',            'change_email',
            'set_lang',               'new_d_read',
            'd_control'
        ],
    );

    my $statement =
        sprintf
        "SELECT date_logs, robot_logs AS robot, list_logs AS list, action_logs AS action, parameters_logs AS parameters, target_email_logs AS target_email,msg_id_logs AS msg_id, status_logs AS status, error_type_logs AS error_type, user_email_logs AS user_email, client_logs AS client, daemon_logs AS daemon FROM logs_table WHERE robot_logs=%s ",
        Sympa::DatabaseManager::quote($select->{'robot'});

    #if a type of target and a target are specified
    if (($select->{'target_type'}) && ($select->{'target_type'} ne 'none')) {
        if ($select->{'target'}) {
            $select->{'target_type'} = lc($select->{'target_type'});
            $select->{'target'}      = lc($select->{'target'});
            $statement .= 'AND '
                . $select->{'target_type'}
                . '_logs = '
                . Sympa::DatabaseManager::quote($select->{'target'}) . ' ';
        }
    }

    #if the search is between two date
    if ($select->{'date_from'}) {
        my @tab_date_from = split /[-\/.]/, $select->{'date_from'};
        my $date_from = POSIX::mktime(
            0, 0, -1, $tab_date_from[0],
            $tab_date_from[1] - 1,
            $tab_date_from[2] - 1900
        );
        unless ($select->{'date_to'}) {
            my $date_from2 = POSIX::mktime(
                0, 0, 25, $tab_date_from[0],
                $tab_date_from[1] - 1,
                $tab_date_from[2] - 1900
            );
            $statement .= sprintf "AND date_logs BETWEEN '%s' AND '%s' ",
                $date_from, $date_from2;
        }
        if ($select->{'date_to'}) {
            my @tab_date_to = split /[-\/.]/, $select->{'date_to'};
            my $date_to = POSIX::mktime(
                0, 0, 25, $tab_date_to[0],
                $tab_date_to[1] - 1,
                $tab_date_to[2] - 1900
            );

            $statement .= sprintf "AND date_logs BETWEEN '%s' AND '%s' ",
                $date_from, $date_to;
        }
    }

    #if the search is on a precise type
    if ($select->{'type'}) {
        if (   ($select->{'type'} ne 'none')
            && ($select->{'type'} ne 'all_actions')) {
            my $first = 'false';
            foreach my $type (@{$action_type{$select->{'type'}}}) {
                if ($first eq 'false') {

                    #if it is the first action, put AND on the statement
                    $statement .=
                        sprintf "AND (logs_table.action_logs = '%s' ", $type;
                    $first = 'true';
                }

                #else, put OR
                else {
                    $statement .= sprintf "OR logs_table.action_logs = '%s' ",
                        $type;
                }
            }
            $statement .= ')';
        }

    }

    #if the listmaster want to make a search by an IP adress.
    if ($select->{'ip'}) {
        $statement .= sprintf 'AND client_logs = %s ',
            Sympa::DatabaseManager::quote($select->{'ip'});
    }

    ## Currently not used
    #if the search is on the actor of the action
    if ($select->{'user_email'}) {
        $select->{'user_email'} = lc($select->{'user_email'});
        $statement .= sprintf 'AND user_email_logs = %s ',
            Sympa::DatabaseManager::quote($select->{'user_email'});
    }

    #if a list is specified -just for owner or above-
    if ($select->{'list'}) {
        $select->{'list'} = lc($select->{'list'});
        $statement .= sprintf 'AND list_logs = %s ',
            Sympa::DatabaseManager::quote($select->{'list'});
    }

    if ($sortby eq 'date') {
        $statement .= sprintf 'ORDER BY date_logs %s ', $way;
    } elsif (Sympa::Site->db_type =~ /^(mysql|Sybase)$/) {

        # On MySQL, collation is case-insensitive by default.
        # On Sybase, collation is defined at the time of database creation.
        $statement .= sprintf 'ORDER BY %s_logs %s, date_logs ', $sortby,
            $way;
    } else {
        $statement .= sprintf 'ORDER BY lower(%s_logs) %s, date_logs ',
            $sortby, $way;
    }

    push @sth_stack, $sth;
    unless ($sth = Sympa::DatabaseManager::do_query($statement)) {
        do_log(Sympa::Logger::ERR, 'Unable to retrieve logs entry from the database');
        return undef;
    }

    my $log = $sth->fetchrow_hashref('NAME_lc');
    $rows_nb = $sth->rows;

    ## If no rows returned, return an empty hash
    ## Required to differenciate errors and empty results
    if ($rows_nb == 0) {
        $sth->finish;
        $sth = pop @sth_stack;
        return {};
    }

    ## We can't use the "AS date" directive in the SELECT statement because
    ## "date" is a reserved keywork with Oracle
    $log->{'date'} = $log->{'date_logs'} if defined $log->{'date_logs'};
    return $log;
}

sub return_rows_nb {
    return $rows_nb;
}

sub get_next_db_log {

    my $log = $sth->fetchrow_hashref('NAME_lc');

    unless (defined $log) {
        $sth->finish;
        $sth = pop @sth_stack;
    }

    ## We can't use the "AS date" directive in the SELECT statement because
    ## "date" is a reserved keywork with Oracle
    $log->{date} = $log->{date_logs} if defined($log->{date_logs});

    return $log;
}

#aggregate date from stat_table to stat_counter_table
#dates must be in epoch format
sub aggregate_data {
    my ($begin_date, $end_date) = @_;

    # the hash containing aggregated data that the sub deal_data will return.
    my $aggregated_data;

    unless (
        $sth = Sympa::DatabaseManager::do_query(
            q{SELECT *
	  FROM stat_table
	  WHERE (date_stat BETWEEN %s AND %s) AND (read_stat = 0)},
            $begin_date, $end_date
        )
        ) {
        do_log(Sympa::Logger::ERR,
            'Unable to retrieve stat entries between date %s and date %s',
            $begin_date, $end_date);
        return undef;
    }

    my $res = $sth->fetchall_hashref('id_stat');

    $aggregated_data = deal_data($res);

    #the line is read, so update the read_stat from 0 to 1
    unless (
        $sth = Sympa::DatabaseManager::do_query(
            q{UPDATE stat_table
	  SET read_stat = 1
	  WHERE date_stat BETWEEN %s AND %s},
            $begin_date, $end_date
        )
        ) {
        do_log(
            Sympa::Logger::ERR,
            'Unable to set stat entries between date %s and date %s as read',
            $begin_date,
            $end_date
        );
        return undef;
    }

    #store reslults in stat_counter_table
    foreach my $key_op (keys(%$aggregated_data)) {

        #store send mail data-------------------------------
        if ($key_op eq 'send_mail') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                foreach my $key_list (
                    keys(%{$aggregated_data->{$key_op}->{$key_robot}})) {

                    db_stat_counter_log(
                        'begin_date' => $begin_date,
                        'end_date'   => $end_date,
                        'data'       => $key_op,
                        'list'       => $key_list,
                        'variation' =>
                            $aggregated_data->{$key_op}->{$key_robot}
                            ->{$key_list}->{'count'},
                        'total' => '',
                        'robot' => $key_robot
                    );

                    #updating susbcriber_table
                    foreach my $key_mail (
                        keys(
                            %{  $aggregated_data->{$key_op}->{$key_robot}
                                    ->{$key_list}
                                }
                        )
                        ) {

                        if (($key_mail ne 'count') && ($key_mail ne 'size')) {
                            update_subscriber_msg_send(
                                $key_mail,
                                $key_list,
                                $key_robot,
                                $aggregated_data->{$key_op}->{$key_robot}
                                    ->{$key_list}->{$key_mail}
                            );
                        }
                    }
                }
            }
        }

        #store added subscribers--------------------------------
        if ($key_op eq 'add_subscriber') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                foreach my $key_list (
                    keys(%{$aggregated_data->{$key_op}->{$key_robot}})) {

                    db_stat_counter_log(
                        'begin_date' => $begin_date,
                        'end_date'   => $end_date,
                        'data'       => $key_op,
                        'list'       => $key_list,
                        'variation' =>
                            $aggregated_data->{$key_op}->{$key_robot}
                            ->{$key_list}->{'count'},
                        'total' => '',
                        'robot' => $key_robot
                    );
                }
            }
        }

        #store deleted subscribers--------------------------------------
        if ($key_op eq 'del_subscriber') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                foreach my $key_list (
                    keys(%{$aggregated_data->{$key_op}->{$key_robot}})) {

                    foreach my $key_param (
                        keys(
                            %{  $aggregated_data->{$key_op}->{$key_robot}
                                    ->{$key_list}
                                }
                        )
                        ) {

                        db_stat_counter_log(
                            'begin_date' => $begin_date,
                            'end_date'   => $end_date,
                            'data'       => $key_param,
                            'list'       => $key_list,
                            'variation' =>
                                $aggregated_data->{$key_op}->{$key_robot}
                                ->{$key_list}->{$key_param},
                            'total' => '',
                            'robot' => $key_robot
                        );

                    }
                }
            }
        }

        #store lists created--------------------------------------------
        if ($key_op eq 'create_list') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                db_stat_counter_log(
                    'begin_date' => $begin_date,
                    'end_date'   => $end_date,
                    'data'       => $key_op,
                    'list'       => '',
                    'variation' =>
                        $aggregated_data->{$key_op}->{$key_robot},
                    'total' => '',
                    'robot' => $key_robot
                );
            }
        }

        #store lists copy-----------------------------------------------
        if ($key_op eq 'copy_list') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                db_stat_counter_log(
                    'begin_date' => $begin_date,
                    'end_date'   => $end_date,
                    'data'       => $key_op,
                    'list'       => '',
                    'variation' =>
                        $aggregated_data->{$key_op}->{$key_robot},
                    'total' => '',
                    'robot' => $key_robot
                );
            }
        }

        #store lists closed----------------------------------------------
        if ($key_op eq 'close_list') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                db_stat_counter_log(
                    'begin_date' => $begin_date,
                    'end_date'   => $end_date,
                    'data'       => $key_op,
                    'list'       => '',
                    'variation' =>
                        $aggregated_data->{$key_op}->{$key_robot},
                    'total' => '',
                    'robot' => $key_robot
                );
            }
        }

        #store lists purged-------------------------------------------------
        if ($key_op eq 'purge_list') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                db_stat_counter_log(
                    'begin_date' => $begin_date,
                    'end_date'   => $end_date,
                    'data'       => $key_op,
                    'list'       => '',
                    'variation' =>
                        $aggregated_data->{$key_op}->{$key_robot},
                    'total' => '',
                    'robot' => $key_robot
                );
            }
        }

        #store messages rejected-------------------------------------------
        if ($key_op eq 'reject') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                foreach my $key_list (
                    keys(%{$aggregated_data->{$key_op}->{$key_robot}})) {

                    db_stat_counter_log(
                        'begin_date' => $begin_date,
                        'end_date'   => $end_date,
                        'data'       => $key_op,
                        'list'       => $key_list,
                        'variation' =>
                            $aggregated_data->{$key_op}->{$key_robot}
                            ->{$key_list},
                        'total' => '',
                        'robot' => $key_robot
                    );
                }
            }
        }

        #store lists rejected----------------------------------------------
        if ($key_op eq 'list_rejected') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                db_stat_counter_log(
                    'begin_date' => $begin_date,
                    'end_date'   => $end_date,
                    'data'       => $key_op,
                    'list'       => '',
                    'variation' =>
                        $aggregated_data->{$key_op}->{$key_robot},
                    'total' => '',
                    'robot' => $key_robot
                );
            }
        }

        #store documents uploaded------------------------------------------
        if ($key_op eq 'd_upload') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                foreach my $key_list (
                    keys(%{$aggregated_data->{$key_op}->{$key_robot}})) {

                    db_stat_counter_log(
                        'begin_date' => $begin_date,
                        'end_date'   => $end_date,
                        'data'       => $key_op,
                        'list'       => $key_list,
                        'variation' =>
                            $aggregated_data->{$key_op}->{$key_robot}
                            ->{$key_list},
                        'total' => '',
                        'robot' => $key_robot
                    );
                }
            }

        }

        #store folder creation in shared-----------------------------------
        if ($key_op eq 'd_create_directory') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                foreach my $key_list (
                    keys(%{$aggregated_data->{$key_op}->{$key_robot}})) {

                    db_stat_counter_log(
                        'begin_date' => $begin_date,
                        'end_date'   => $end_date,
                        'data'       => $key_op,
                        'list'       => $key_list,
                        'variation' =>
                            $aggregated_data->{$key_op}->{$key_robot}
                            ->{$key_list},
                        'total' => '',
                        'robot' => $key_robot
                    );
                }
            }

        }

        #store file creation in shared-------------------------------------
        if ($key_op eq 'd_create_file') {

            foreach my $key_robot (keys(%{$aggregated_data->{$key_op}})) {

                foreach my $key_list (
                    keys(%{$aggregated_data->{$key_op}->{$key_robot}})) {

                    db_stat_counter_log(
                        'begin_date' => $begin_date,
                        'end_date'   => $end_date,
                        'data'       => $key_op,
                        'list'       => $key_list,
                        'variation' =>
                            $aggregated_data->{$key_op}->{$key_robot}
                            ->{$key_list},
                        'total' => '',
                        'robot' => $key_robot
                    );
                }
            }

        }

    }    #end of foreach

    my $d_deb = localtime($begin_date);
    my $d_fin = localtime($end_date);
    do_log(Sympa::Logger::DEBUG2, 'data aggregated from %s to %s', $d_deb, $d_fin);
}

#called by subroutine aggregate_data
#get in parameter the result of db request and put in an hash data we need.
sub deal_data {

    my $result_request = shift;
    my %data;

    #on parcours caque ligne correspondant a un nuplet
    #each $id correspond to an hash
    foreach my $id (keys(%$result_request)) {

        # ---test about send_mail---
        if ($result_request->{$id}->{'operation_stat'} eq 'send_mail') {

            #test if send_mail value exists already or not, if not, create it
            unless (exists($data{'send_mail'})) {
                $data{'send_mail'} = undef;

            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot
            my $l_name =
                $result_request->{$id}->{'list_stat'};     #get name of list
            my $email =
                $result_request->{$id}->{'email_stat'};    #get the sender

            # if the listname and robot  dont exist in $data, create it, with
            # size & count to zero
            unless (exists($data{'send_mail'}{$r_name}{$l_name})) {
                $data{'send_mail'}{$r_name}{$l_name}{'size'}  = 0;
                $data{'send_mail'}{$r_name}{$l_name}{'count'} = 0;
                $data{'send_mail'}{$r_name}{$l_name}{$email}  = 0;

            }

            #on ajoute la taille du message
            $data{'send_mail'}{$r_name}{$l_name}{'size'} +=
                $result_request->{$id}->{'parameter_stat'};

            #on ajoute +1 message envoyé
            $data{'send_mail'}{$r_name}{$l_name}{'count'}++;

            #et on incrémente le mail
            $data{'send_mail'}{$r_name}{$l_name}{$email}++;
        }

        # ---test about add_susbcriber---
        if ($result_request->{$id}->{'operation_stat'} eq 'add subscriber') {

            unless (exists($data{'add_subscriber'})) {
                $data{'add_subscriber'} = undef;
            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot
            my $l_name =
                $result_request->{$id}->{'list_stat'};     #get name of list

            # if the listname and robot  dont exist in $data, create it, with
            # count to zero
            unless (exists($data{'add_subscriber'}{$r_name}{$l_name})) {
                $data{'add_subscriber'}{$r_name}{$l_name}{'count'} = 0;
            }

            #on incrémente le nombre d'inscriptions
            $data{'add_subscriber'}{$r_name}{$l_name}{'count'}++;

        }

        # ---test about del_subscriber---
        if ($result_request->{$id}->{'operation_stat'} eq 'del subscriber') {

            unless (exists($data{'del_subscriber'})) {
                $data{'del_subscriber'} = undef;
            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot
            my $l_name =
                $result_request->{$id}->{'list_stat'};     #get name of list
            my $param =
                $result_request->{$id}->{'parameter_stat'
                };    #if del is usubcription, deleted by admin or bounce...

            unless (exists($data{'del_subscriber'}{$r_name}{$l_name})) {
                $data{'del_subscriber'}{$r_name}{$l_name}{$param} = 0;
            }

            #on incrémente les parametres
            $data{'del_subscriber'}{$r_name}{$l_name}{$param}++;
        }

        # ---test about list creation---
        if ($result_request->{$id}->{'operation_stat'} eq 'create_list') {

            unless (exists($data{'create_list'})) {
                $data{'create_list'} = undef;
            }

            my $r_name =
                $result_request->{$id}
                ->{'robot_stat'};    #get the name of the robot

            unless (exists($data{'create_list'}{$r_name})) {
                $data{'create_list'}{$r_name} = 0;
            }

            #on incrémente le nombre de création de listes
            $data{'create_list'}{$r_name}++;
        }

        # ---test about copy list---
        if ($result_request->{$id}->{'operation_stat'} eq 'copy list') {

            unless (exists($data{'copy_list'})) {
                $data{'copy_list'} = undef;
            }

            my $r_name =
                $result_request->{$id}
                ->{'robot_stat'};    #get the name of the robot

            unless (exists($data{'copy_list'}{$r_name})) {
                $data{'copy_list'}{$r_name} = 0;
            }

            #on incrémente le nombre de copies de listes
            $data{'copy_list'}{$r_name}++;
        }

        # ---test about closing list---
        if ($result_request->{$id}->{'operation_stat'} eq 'close_list') {

            unless (exists($data{'close_list'})) {
                $data{'close_list'} = undef;
            }

            my $r_name =
                $result_request->{$id}
                ->{'robot_stat'};    #get the name of the robot

            unless (exists($data{'close_list'}{$r_name})) {
                $data{'close_list'}{$r_name} = 0;
            }

            #on incrémente le nombre de création de listes
            $data{'close_list'}{$r_name}++;
        }

        # ---test abount purge list---
        if ($result_request->{$id}->{'operation_stat'} eq 'purge list') {

            unless (exists($data{'purge_list'})) {
                $data{'purge_list'} = undef;
            }

            my $r_name =
                $result_request->{$id}
                ->{'robot_stat'};    #get the name of the robot

            unless (exists($data{'purge_list'}{$r_name})) {
                $data{'purge_list'}{$r_name} = 0;
            }

            #on incrémente le nombre de création de listes
            $data{'purge_list'}{$r_name}++;
        }

        # ---test about rejected messages---
        if ($result_request->{$id}->{'operation_stat'} eq 'reject') {

            unless (exists($data{'reject'})) {
                $data{'reject'} = undef;
            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot
            my $l_name =
                $result_request->{$id}->{'list_stat'};     #get name of list

            unless (exists($data{'reject'}{$r_name}{$l_name})) {
                $data{'reject'}{$r_name}{$l_name} = 0;
            }

            #on icrémente le nombre de messages rejetés pour une liste
            $data{'reject'}{$r_name}{$l_name}++;
        }

        # ---test about rejected creation lists---
        if ($result_request->{$id}->{'operation_stat'} eq 'list_rejected') {

            unless (exists($data{'list_rejected'})) {
                $data{'list_rejected'} = undef;
            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot

            unless (exists($data{'list_rejected'}{$r_name})) {
                $data{'list_rejected'}{$r_name} = 0;
            }

            #on incrémente le nombre de listes rejetées par robot
            $data{'list_rejected'}{$r_name}++;
        }

        # ---test about upload sharing---
        if ($result_request->{$id}->{'operation_stat'} eq 'd_upload') {

            unless (exists($data{'d_upload'})) {
                $data{'d_upload'} = undef;
            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot
            my $l_name =
                $result_request->{$id}->{'list_stat'};     #get name of list

            unless (exists($data{'d_upload'}{$r_name}{$l_name})) {
                $data{'d_upload'}{$r_name}{$l_name} = 0;
            }

            #on incrémente le nombre de docupents uploadés par liste
            $data{'d_upload'}{$r_name}{$l_name}++;
        }

        # ---test about folder creation in shared---
        if ($result_request->{$id}->{'operation_stat'} eq
            'd_create_dir(directory)') {

            unless (exists($data{'d_create_directory'})) {
                $data{'d_create_directory'} = undef;
            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot
            my $l_name =
                $result_request->{$id}->{'list_stat'};     #get name of list

            unless (exists($data{'d_create_directory'}{$r_name}{$l_name})) {
                $data{'d_create_directory'}{$r_name}{$l_name} = 0;
            }

            #on incrémente le nombre de docupents uploadés par liste
            $data{'d_create_directory'}{$r_name}{$l_name}++;
        }

        # ---test about file creation in shared---
        if ($result_request->{$id}->{'operation_stat'} eq
            'd_create_dir(file)') {

            unless (exists($data{'d_create_file'})) {
                $data{'d_create_file'} = undef;
            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot
            my $l_name =
                $result_request->{$id}->{'list_stat'};     #get name of list

            unless (exists($data{'d_create_file'}{$r_name}{$l_name})) {
                $data{'d_create_file'}{$r_name}{$l_name} = 0;
            }

            #on incrémente le nombre de docupents uploadés par liste
            $data{'d_create_file'}{$r_name}{$l_name}++;
        }

        # ---test about archive---
        if ($result_request->{$id}->{'operation_stat'} eq 'arc') {

            unless (exists($data{'archive visited'})) {
                $data{'archive_visited'} = undef;
            }

            my $r_name =
                $result_request->{$id}->{'robot_stat'};    #get name of robot
            my $l_name =
                $result_request->{$id}->{'list_stat'};     #get name of list

            unless (exists($data{'archive_visited'}{$r_name}{$l_name})) {
                $data{'archive_visited'}{$r_name}{$l_name} = 0;
            }

            #on incrémente le nombre de fois ou les archive sont visitées
            $data{'archive_visited'}{$r_name}{$l_name}++;
        }

    }    #end of foreach
    return \%data;
}

# subroutine to Update subscriber_table about message send, upgrade field
# number_messages_subscriber
sub update_subscriber_msg_send {

    my ($mail, $list, $robot, $counter) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '%s,%s,%s,%s', $mail, $list, $robot,
        $counter);

    unless (
        $sth = Sympa::DatabaseManager::do_query(
            "SELECT number_messages_subscriber from subscriber_table WHERE (robot_subscriber = '%s' AND list_subscriber = '%s' AND user_subscriber = '%s')",
            $robot, $list, $mail
        )
        ) {
        do_log(Sympa::Logger::ERR,
            'Unable to retrieve message count for user %s, list %s@%s',
            $mail, $list, $robot);
        return undef;
    }

    my $nb_msg =
        $sth->fetchrow_hashref('number_messages_subscriber') + $counter;

    unless (
        Sympa::DatabaseManager::do_query(
            "UPDATE subscriber_table SET number_messages_subscriber = '%d' WHERE (robot_subscriber = '%s' AND list_subscriber = '%s' AND user_subscriber = '%s')",
            $nb_msg, $robot, $list, $mail
        )
        ) {
        do_log(Sympa::Logger::ERR,
            'Unable to update message count for user %s, list %s@%s',
            $mail, $list, $robot);
        return undef;
    }
    return 1;

}

#get date of the last time we have aggregated data
sub get_last_date_aggregation {

    unless (
        $sth = Sympa::DatabaseManager::do_query(
            " SELECT MAX( end_date_counter ) FROM `stat_counter_table` ")
        ) {
        do_log(Sympa::Logger::ERR, 'Unable to retrieve last date of aggregation');
        return undef;
    }

    my $last_date = $sth->fetchrow_array;
    return $last_date;
}

sub agregate_daily_data {
    my (%params) = shift;

    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Agregating data');
    my $result;
    my $first_date = $params{'first_date'} || time;
    my $last_date  = $params{'last_date'}  || time;
    foreach my $begin_date (sort keys %{$params{'hourly_data'}}) {
        my $reftime = Sympa::Tools::Time::get_midnight_time($begin_date);
        unless (defined $params{'first_date'}) {
            $first_date = $reftime if ($reftime < $first_date);
        }
        next
            if ($begin_date < $first_date
            || $params{'hourly_data'}{$begin_date}{'end_date_counter'} >
            $last_date);
        if (defined $result->{$reftime}) {
            $result->{$reftime} +=
                $params{'hourly_data'}{$begin_date}{'variation_counter'};
        } else {
            $result->{$reftime} =
                $params{'hourly_data'}{$begin_date}{'variation_counter'};
        }
    }
    for (my $date = $first_date; $date < $last_date; $date += 86400) {
        $result->{$date} = 0 unless (defined $result->{$date});
    }
    return $result;
}

1;
