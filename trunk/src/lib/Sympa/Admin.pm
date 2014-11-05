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

Sympa::Admin - Administrative function for the lists

=head1 DESCRIPTION 

Central module for creating and editing lists.

=cut 

package Sympa::Admin;

use strict;

use English qw(-no_match_vars);
use File::Copy;

use Sympa::Conf;
use Sympa::Constants;
use Sympa::Language;
use Sympa::List;
use Sympa::Log::Database;
use Sympa::Logger;
use Sympa::Site;
use Sympa::Tools;
use Sympa::Tools::File;
use Sympa::User;

my $language = Sympa::Language->instance;

=pod 

=head1 SUBFUNCTIONS 

This is the description of the subfunctions contained by admin.pm 

=cut 

=pod 

=head2 sub create_list_old(HASHRef,STRING,STRING)

Creates a list. Used by the create_list() sub in sympa.pl and the do_create_list() sub in wwsympa.fcgi.

=head3 Arguments 

=over 

=item * I<$param>, a ref on a hash containing parameters of the config list. The following keys are mandatory:

=over 4

=item - I<$param-E<gt>{'listname'}>,

=item - I<$param-E<gt>{'subject'}>,

=item - I<$param-E<gt>{'owner'}>, (or owner_include): array of hashes, with key email mandatory

=item - I<$param-E<gt>{'owner_include'}>, array of hashes, with key source mandatory

=back

=item * I<$template>, a string containing the list creation template

=item * I<$robot>, a string containing the name of the robot the list will be hosted by.

=back 

=head3 Return 

=over 

=item * I<undef>, if something prevents the list creation

=item * I<a reference to a hash>, if the list is normally created. This hash contains two keys:

=over 4

=item - I<list>, the list object corresponding to the list just created

=item - I<aliases>, undef if not applicable; 1 (if ok) or $aliases : concatenated string of aliases if they are not installed or 1 (in status open)

=back

=back 

=cut 

########################################################
# create_list_old
########################################################
# Create a list : used by sympa.pl--create_list and
#                 wwsympa.fcgi--do_create_list
# without family concept
#
# IN  : - $param : ref on parameters of the config list
#         with obligatory :
#         $param->{'listname'}
#         $param->{'subject'}
#         $param->{'owner'} (or owner_include):
#          array of hash,with key email obligatory
#         $param->{'owner_include'} array of hash :
#              with key source obligatory
#       - $template : the create list template
#       - $robot_id : the list's robot
#       - $origin : the source of the command : web, soap or command_line
#              no longer used
# OUT : - hash with keys :
#          -list :$list
#          -aliases : undef if not applicable; 1 (if ok) or
#           $aliases : concated string of alias if they
#           are not installed or 1(in status open)
#######################################################
sub create_list_old {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, %s, %s)', @_);
    my ($param, $template, $robot, $origin, $user_mail) = @_;

    $robot = Sympa::Robot::clean_robot($robot);
    my $robot_id = $robot->name;

    ## obligatory list parameters
    foreach my $arg ('listname', 'subject') {
        unless ($param->{$arg}) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'create_list_old : missing list param %s', $arg);
            return undef;
        }
    }

    # owner.email || owner_include.source
    unless (check_owner_defined($param->{'owner'}, $param->{'owner_include'}))
    {
        $main::logger->do_log(Sympa::Logger::ERR,
            'create_list_old : problem in owner definition in this list creation'
        );
        return undef;
    }

    # template
    unless ($template) {
        $main::logger->do_log(Sympa::Logger::ERR, 'missing param "template"');
        return undef;
    }

    # robot
    unless ($robot) {
        $main::logger->do_log(Sympa::Logger::ERR, 'missing param "robot"');
        return undef;
    }

    ## check listname
    $param->{'listname'} = lc($param->{'listname'});
    my $listname_regexp = Sympa::Tools::get_regexp('listname');

    unless ($param->{'listname'} =~ /^$listname_regexp$/i) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'create_list_old : incorrect listname %s',
            $param->{'listname'});
        return undef;
    }

    my (undef, $type) = $robot->split_listname($param->{'listname'});
    if ($type) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'incorrect listname %s matches one of service aliases',
            $param->{'listname'});
        return undef;
    }

    if ($param->{'listname'} eq $robot->email) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'incorrect listname %s matches one of service aliases',
            $param->{'listname'});
        return undef;
    }

    ## Check listname on SMTP server
    my $res = list_check_smtp($param->{'listname'}, $robot);
    unless (defined $res) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "create_list_old : can't check list %.128s on %s",
            $param->{'listname'}, $robot);
        return undef;
    }

    ## Check this listname doesn't exist already.
    if ($res
        || Sympa::List->new($param->{'listname'}, $robot, {'just_try' => 1}))
    {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'could not create already existing list %s on %s for %s',
            $param->{'listname'},
            $robot,
            join(', ', map { $_->{'email'} } @{$param->{'owner'} || []})
        );
        return undef;
    }

    ## Check the template supposed to be used exist.
    my $template_file = $robot->get_etc_filename(
        'create_list_templates/' . $template . '/config.tt2');
    unless (defined $template_file) {
        $main::logger->do_log(Sympa::Logger::ERR, 'no template %s found', $template);
        return undef;
    }

    ## Create the list directory
    my $list_dir = $robot->home . '/' . $param->{'listname'};

    ## Check the privileges on the list directory
    unless (mkdir($list_dir, 0777)) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'create_list_old : unable to create %s : %s',
            $list_dir, $CHILD_ERROR);
        return undef;
    }

    ## Check topics
    if ($param->{'topics'}) {
        unless ($robot->is_available_topic($param->{'topics'})) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'topics param %s not defined in topics.conf',
                $param->{'topics'});
        }
    }

    ## Creation of the config file
    ##FIXME:should be unneccessary
    $param->{'creation'}{'date'} = $language->gettext_strftime(
        "%d %b %Y at %H:%M:%S", localtime time
    );
    $param->{'creation'}{'date_epoch'} = time;
    $param->{'creation_email'} ||= $robot->get_address('listmaster');
    $param->{'status'} ||= 'open';

    my $tt2_include_path =
        $robot->get_etc_include_path('create_list_templates/' . $template);

    ## Lock config before openning the config file
    my $lock_fh = Sympa::LockedFile->new($list_dir . '/config', 5, '>');
    unless ($lock_fh) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Impossible to create %s/config : %s',
            $list_dir, $ERRNO);
        return undef;
    }
    ## Use an intermediate handler to encode to filesystem_encoding
    my $config = '';
    my $fd     = IO::Scalar->new(\$config);
    #FIXME: Check parse error
    Sympa::Template::parse_tt2($param, 'config.tt2', $fd, $tt2_include_path);

    #    Encode::from_to($config, 'utf8', Sympa::Site->filesystem_encoding);
    print $lock_fh $config;

    ## Unlock config file
    $lock_fh->close;

    ## Creation of the info file
    # remove DOS linefeeds (^M) that cause problems with Outlook 98, AOL, and
    # EIMS:
    $param->{'description'} =~ s/\r\n|\r/\n/g;

    ## info file creation.
    unless (open INFO, '>', "$list_dir/info") {
        $main::logger->do_log(Sympa::Logger::ERR, 'Impossible to create %s/info : %s',
            $list_dir, $ERRNO);
    }
    if (defined $param->{'description'}) {
        Encode::from_to($param->{'description'},
            'utf8', Sympa::Site->filesystem_encoding);
        print INFO $param->{'description'};
    }
    close INFO;

    ## Create list object
    my $list;
    unless ($list = Sympa::List->new($param->{'listname'}, $robot)) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'unable to create list %s for robot %s',
            $param->{'listname'}, $robot);
        return undef;
    }

    ## Create shared if required
    ##FIXME: add "shared_doc.enabled" parameter then use it.
    if (scalar keys %{$list->shared_doc}) {
        $list->create_shared();
    }

    #log in stat_table to make statistics

    if ($origin eq "web") {
        Sympa::Log::Database::db_stat_log(
            'robot'     => $robot_id,
            'list'      => $param->{'listname'},
            'operation' => 'create list',
            'mail'      => $user_mail,
            'daemon'    => 'wwsympa.fcgi'
        );
    }

    my $return = {};
    $return->{'list'} = $list;

    if ($list->status eq 'open') {
        $return->{'aliases'} = install_aliases($list);
    } else {
        $return->{'aliases'} = 1;
    }

    ## Synchronize list members if required
    if ($list->has_include_data_sources()) {
        $main::logger->do_log(Sympa::Logger::NOTICE, "Synchronizing list members...");
        $list->sync_include();
    }

    $list->save_config;
    return $return;
}

########################################################
# create_list
########################################################
# Create a list : used by sympa.pl--instantiate_family
# with family concept
#
# IN  : - $param : ref on parameters of the config list
#         with obligatory :
#         $param->{'listname'}
#         $param->{'subject'}
#         $param->{'owner'} (or owner_include):
#          array of hash,with key email obligatory
#         $param->{'owner_include'} array of hash :
#              with key source obligatory
#       - $family : the family object
#       - $robot : the list's robot.  ** No longer used.
#       - $abort_on_error : won't create the list directory on
#          tt2 process error (usefull for dynamic lists that
#          throw exceptions)
# OUT : - hash with keys :
#          -list :$list
#          -aliases : undef if not applicable; 1 (if ok) or
#           $aliases : concated string of alias if they
#           are not installed or 1(in status open)
#######################################################
sub create_list {
    my ($param, $family, $robot, $abort_on_error) = @_;
    $main::logger->do_log(Sympa::Logger::INFO,
        'Creating a list; listname=%s, family=%s, subject=%s',
        $param->{'listname'}, $family, $param->{'subject'});

    ## mandatory list parameters
    foreach my $arg ('listname') {
        unless ($param->{$arg}) {
            $main::logger->do_log(Sympa::Logger::ERR, 'missing list param "%s"',
                $arg);
            return undef;
        }
    }

    unless ($family) {
        $main::logger->do_log(Sympa::Logger::ERR, 'missing param "family"');
        return undef;
    }

    #robot
    $robot = $family->robot;
    unless ($robot) {
        $main::logger->do_log(Sympa::Logger::ERR, 'missing param "robot"');
        return undef;
    }

    ## check listname
    $param->{'listname'} = lc($param->{'listname'});
    my $listname_regexp = Sympa::Tools::get_regexp('listname');

    unless ($param->{'listname'} =~ /^$listname_regexp$/i) {
        $main::logger->do_log(Sympa::Logger::ERR, 'incorrect listname %s',
            $param->{'listname'});
        return undef;
    }

    my ($name, $type) = $robot->split_listname($param->{'listname'});
    if ($type) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'incorrect listname %s matches one of service aliases',
            $param->{'listname'});
        return undef;
    }
    if ($param->{'listname'} eq $robot->email) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'incorrect listname %s matches one of service aliases',
            $param->{'listname'});
        return undef;
    }

    ## Check listname on SMTP server
    my $res = list_check_smtp($param->{'listname'}, $robot);
    unless (defined $res) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'can\'t check list %.128s on robot %s',
            $param->{'listname'}, $robot);
        return undef;
    }

    if ($res) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'could not create already existing list %s on %s for %s',
            $param->{'listname'},
            $robot,
            join(', ', @{$param->{'owner'} || []})
        );
        return undef;
    }

    ## template file
    my $template_file = $family->get_etc_filename('config.tt2');
    unless (defined $template_file) {
        $main::logger->do_log(Sympa::Logger::ERR, 'no config template from family %s',
            $family);
        return undef;
    }

    my $family_config = $robot->automatic_list_families || {};
    $param->{'family_config'} = $family_config->{$family->name};
    my $conf;
    my $tt_result =
        Sympa::Template::parse_tt2($param, 'config.tt2', \$conf,
        [$family->dir]);
    unless (defined $tt_result || !$abort_on_error) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'abort on tt2 error. List %s from family %s',
            $param->{'listname'}, $family);
        return undef;
    }

    ## Create the list directory
    my $list_dir = $robot->home . '/' . $param->{'listname'};

    unless (-r $list_dir || mkdir($list_dir, 0777)) {
        $main::logger->do_log(Sympa::Logger::ERR, 'unable to create %s : %s',
            $list_dir, $CHILD_ERROR);
        return undef;
    }

    ## Check topics
    if (defined $param->{'topics'}) {
        unless ($robot->is_available_topic($param->{'topics'})) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'topics param %s not defined in topics.conf',
                $param->{'topics'});
        }
    }

    ## Lock config before openning the config file
    my $lock_fh = Sympa::LockedFile->new($list_dir . '/config', 5, '>');
    unless ($lock_fh) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Impossible to create %s/config : %s',
            $list_dir, $!);
        return undef;
    }
    print $lock_fh $conf;

    ## Unlock config file
    $lock_fh->close;

    ## Creation of the info file
    # remove DOS linefeeds (^M) that cause problems with Outlook 98, AOL, and
    # EIMS:
    $param->{'description'} =~ s/\r\n|\r/\n/g;

    unless (open INFO, '>', "$list_dir/info") {
        $main::logger->do_log(Sympa::Logger::ERR, 'Impossible to create %s/info : %s',
            $list_dir, $ERRNO);
    }
    if (defined $param->{'description'}) {
        print INFO $param->{'description'};
    }
    close INFO;

    ## Create associated files if a template was given.
    for my $file (
        'message.footer',      'message.header',
        'message.footer.mime', 'message.header.mime',
        'info'
        ) {
        my $template_file = $family->get_etc_filename($file . ".tt2");
        if (defined $template_file) {
            my $file_content;
            my $tt_result = Sympa::Template::parse_tt2($param, $file . ".tt2",
                \$file_content, [$family->dir]);
            unless (defined $tt_result) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'tt2 error. List %s from family %s, file %s',
                    $param->{'listname'}, $family, $file);
            }
            unless (open FILE, '>', "$list_dir/$file") {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Impossible to create %s/%s : %s',
                    $list_dir, $file, $ERRNO);
            }
            print FILE $file_content;
            close FILE;
        }
    }

    ## Create list object
    my $list;
    unless ($list = Sympa::List->new($param->{'listname'}, $robot)) {
        $main::logger->do_log(Sympa::Logger::ERR, 'unable to create list %s',
            $param->{'listname'});
        return undef;
    }

    ## Create shared if required
    ## #FIXME: add "shared_doc.enabled" option then refer it.
    if (scalar keys %{$list->shared_doc}) {
        $list->create_shared();
    }

    ##FIXME:should be unneccessary
    $list->creation(
        {   'date' => $language->gettext_strftime(
                "%d %b %Y at %H:%M:%S", localtime time
            ),
            'date_epoch' => time,
            'email'      => (
                       $param->{'creation_email'}
                    || $robot->get_address('listmaster')
            )
        }
    );
    $list->status($param->{'status'} || 'open');
    $list->family($family);

    my $return = {};
    $return->{'list'} = $list;

    if ($list->status eq 'open') {
        $return->{'aliases'} = install_aliases($list);
    } else {
        $return->{'aliases'} = 1;
    }

    ## Synchronize list members if required
    if ($list->has_include_data_sources()) {
        $main::logger->do_log(Sympa::Logger::NOTICE, "Synchronizing list members...");
        $list->sync_include();
    }

    return $return;
}

########################################################
# update_list
########################################################
# update a list : used by sympa.pl--instantiate_family
# with family concept when the list already exists
#
# IN  : - $list : the list to update
#       - $param : ref on parameters of the new
#          config list with obligatory :
#         $param->{'listname'}
#         $param->{'subject'}
#         $param->{'owner'} (or owner_include):
#          array of hash,with key email obligatory
#         $param->{'owner_include'} array of hash :
#              with key source obligatory
#       - $family : the family object
#       - $robot : the list's robot
#
# OUT : - $list : the updated list or undef
#######################################################
sub update_list {
    my ($list, $param, $family, $robot) = @_;
    $main::logger->do_log(Sympa::Logger::INFO,
        '(listname=%s, family=<%s>, subject=%s)',
        $param->{'listname'}, $family->get_id(), $param->{'subject'});

    ## mandatory list parameters
    foreach my $arg ('listname') {
        unless ($param->{$arg}) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'update_list : missing list param %s', $arg);
            return undef;
        }
    }

    ## template file
    my $template_file = $family->get_etc_filename('config.tt2');
    unless (defined $template_file) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'update_list : no config template from family %s', $family);
        return undef;
    }

    ## Check topics
    if (defined $param->{'topics'}) {
        unless ($robot->is_available_topic($param->{'topics'})) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'topics param %s not defined in topics.conf',
                $param->{'topics'});
        }
    }

    ## Lock config before openning the config file
    my $lock_fh = Sympa::LockedFile->new($list->{'dir'} . '/config', 5, '>');
    unless ($lock_fh) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Impossible to create %s/config : %s',
            $list->{'dir'}, $!);
        return undef;
    }
    #FIXME: Check parse error
    Sympa::Template::parse_tt2($param, 'config.tt2', $lock_fh,
        [$family->{'dir'}]);
    ## Unlock config file
    $lock_fh->close;

    ## Create list object
    unless ($list = Sympa::List->new($param->{'listname'}, $robot)) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'create_list : unable to create list %s',
            $param->{'listname'});
        return undef;
    }

    ##FIXME:should be unneccessary
    $list->creation(
        {   'date' => $language->gettext_strftime(
                "%d %b %Y at %H:%M:%S", localtime time
            ),
            'date_epoch' => time,
            'email'      => (
                       $param->{'creation_email'}
                    || $list->robot->get_address('listmaster')
            )
        }
    );
    $list->status($param->{'status'} || 'open');
    $list->family($family);

    ## Synchronize list members if required
    if ($list->has_include_data_sources()) {
        $main::logger->do_log(Sympa::Logger::NOTICE, "Synchronizing list members...");
        $list->sync_include();
    }

    return $list;
}

########################################################
# rename_list
########################################################
# Rename a list or move a list to another virtual host
#
# IN  : - list
#       - new_listname
#       - new_robot
#       - mode  : 'copy'
#       - auth_method
#       - user_email
#       - remote_host
#       - remote_addr
#       - options : 'skip_authz' to skip authorization scenarios eval
#
# OUT via reference :
#       - aliases
#       - status : 'pending'
#
# OUT : - scalar
#           undef  : error
#           1      : success
#           string : error code
#######################################################
sub rename_list {
    my (%param) = @_;
    $main::logger->do_log(Sympa::Logger::INFO, '',);

    my $list         = $param{'list'};
    my $robot        = $list->domain;
    my $old_listname = $list->name;

    # check new listname syntax
    my $new_listname    = lc($param{'new_listname'});
    my $listname_regexp = Sympa::Tools::get_regexp('listname');

    unless ($new_listname =~ /^$listname_regexp$/i) {
        $main::logger->do_log(Sympa::Logger::ERR, 'incorrect listname %s',
            $new_listname);
        return 'incorrect_listname';
    }

    my $new_robot_id = $param{'new_robot'};
    my $new_robot    = Sympa::Robot->new($new_robot_id);

    unless ($new_robot) {
        $main::logger->do_log(Sympa::Logger::ERR, 'incorrect robot %s',
            $new_robot_id);
        return 'unknown_robot';
    }

    ## Evaluate authorization scenario unless run as listmaster (sympa.pl)
    my ($result, $r_action, $reason);
    unless ($param{'options'}{'skip_authz'}) {
        my $scenario = Sympa::Scenario->new(
            that     => $robot,
            function => 'create_list',
            name     => $robot->create_list(),
        );
        unless ($scenario) {
            $main::logger->do_log(
                Sympa::Logger::ERR, 'Failed to load scenario for "create_list"'
            );
            return 'authorization';
        }

        $result = $scenario->evaluate(
            that        => $new_robot,
            operation   => 'create_list',
            auth_method => $param{'auth_method'},
            context     => {
                'sender'      => $param{'user_email'},
                'remote_host' => $param{'remote_host'},
                'remote_addr' => $param{'remote_addr'}
            }
        );

        if (ref($result) eq 'HASH') {
            $r_action = $result->{'action'};
            $reason   = $result->{'reason'};
        }

        unless ($r_action =~ /do_it|listmaster/) {
            $main::logger->do_log(Sympa::Logger::ERR, 'authorization error');
            return 'authorization';
        }
    }

    ## Check listname on SMTP server
    my $res = list_check_smtp($param{'new_listname'}, $new_robot);
    unless (defined($res)) {
        $main::logger->do_log(Sympa::Logger::ERR, "can't check list %.128s on %s",
            $param{'new_listname'}, $new_robot);
        return 'internal';
    }

    if ($res
        || ($list->name ne $param{'new_listname'})
        &&    ## Do not test if listname did not change
        (Sympa::List->new($param{'new_listname'}, $new_robot, {'just_try' => 1}))
        ) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Could not rename list %s: new list %s on %s already existing list',
            $list,
            $param{'new_listname'},
            $new_robot
        );
        return 'list_already_exists';
    }

    my (undef, $type) = $new_robot->split_listname($param{'new_listname'});
    if ($type) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Incorrect listname %s matches one of service aliases',
            $param{'new_listname'});
        return 'incorrect_listname';
    }

    unless ($param{'mode'} eq 'copy') {
        $list->savestats();

        ## Dump subscribers
        $list->_save_list_members_file(
            $list->dir . "/subscribers.closed.dump");

        $param{'aliases'} = remove_aliases($list);
    }

    ## Rename or create this list directory itself
    my $new_dir = $new_robot->home . '/' . $param{'new_listname'};

    ## If we are in 'copy' mode, create en new list
    if ($param{'mode'} eq 'copy') {
        unless (
            $list = clone_list_as_empty(
                $list->name,            $list->domain,
                $param{'new_listname'}, $param{'new_robot'},
                $param{'user_email'}
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "Unable to load $param{'new_listname'} while renaming");
            return 'internal';
        }
    }

    # set list status to pending if creation list is moderated
    if ($r_action =~ /listmaster/) {
        $list->status('pending');
        $list->robot->send_notify_to_listmaster(
            'request_list_renaming',
            {   'list'         => $list,
                'new_listname' => $param{'new_listname'},
                'old_listname' => $old_listname,
                'email'        => $param{'user_email'},
                'mode'         => $param{'mode'}
            }
        );
        $param{'status'} = 'pending';
    }

    ## Save config file for the new() later to reload it
    $list->save_config($param{'user_email'});

    ## This code should be in Sympa::List::rename()
    unless ($param{'mode'} eq 'copy') {
        unless (move($list->dir, $new_dir)) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to rename %s to %s : %s',
                $list->dir, $new_dir, $ERRNO);
            return 'internal';
        }

        ## Rename archive
        my $arc_dir = $list->robot->arc_path . '/' . $list->get_id();
        my $new_arc_dir =
              $new_robot->arc_path . '/'
            . $param{'new_listname'} . '@'
            . $param{'new_robot'};
        if (-d $arc_dir && $arc_dir ne $new_arc_dir) {
            unless (move($arc_dir, $new_arc_dir)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Unable to rename archive $arc_dir");

                # continue even if there is some troubles with archives
                # return undef;
            }
        }

        ## Rename bounces
        my $bounce_dir = $list->get_bounce_dir();
        my $new_bounce_dir =
              $new_robot->bounce_path . '/'
            . $param{'new_listname'} . '@'
            . $param{'new_robot'};
        if (-d $bounce_dir && $bounce_dir ne $new_bounce_dir) {
            unless (move($bounce_dir, $new_bounce_dir)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Unable to rename bounces from $bounce_dir to $new_bounce_dir"
                );
            }
        }

        # if subscribtion are stored in database rewrite the database
        unless (
            Sympa::DatabaseManager::do_prepared_query(
                'UPDATE subscriber_table SET list_subscriber = ?, robot_subscriber = ? WHERE list_subscriber = ? AND robot_subscriber = ?',
                $param{'new_listname'}, $param{'new_robot'},
                $list->name,            $list->domain
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to rename list %s to %s@%s in the database',
                $list, $param{'new_listname'}, $param{'new_robot'});
            return 'internal';
        }
        unless (
            Sympa::DatabaseManager::do_prepared_query(
                'UPDATE admin_table SET list_admin = ?, robot_admin = ? WHERE list_admin = ? AND robot_admin = ?',
                $param{'new_listname'}, $param{'new_robot'},
                $list->name,            $list->domain
            )
            ) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Unable to change admins in database while renaming list %s to %s@%s',
                $list,
                $param{'new_listname'},
                $param{'new_robot'}
            );
            return 'internal';
        }

        # clear old list cache on database if any
        $list->list_cache_purge;
    }
    ## Move stats
    unless (
        Sympa::DatabaseManager::do_query(
            "UPDATE stat_table SET list_stat=%s, robot_stat=%s WHERE (list_stat = %s AND robot_stat = %s )",
            Sympa::DatabaseManager::quote($param{'new_listname'}),
            Sympa::DatabaseManager::quote($param{'new_robot'}),
            Sympa::DatabaseManager::quote($list->name),
            Sympa::DatabaseManager::quote($robot)
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to transfer stats from list %s@%s to list %s',
            $param{'new_listname'}, $param{'new_robot'}, $list);
    }

    ## Move stat counters
    unless (
        Sympa::DatabaseManager::do_query(
            "UPDATE stat_counter_table SET list_counter=%s, robot_counter=%s WHERE (list_counter = %s AND robot_counter = %s )",
            Sympa::DatabaseManager::quote($param{'new_listname'}),
            Sympa::DatabaseManager::quote($param{'new_robot'}),
            Sympa::DatabaseManager::quote($list->name),
            Sympa::DatabaseManager::quote($robot)
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to transfer stat counter from list %s@%s to list %s',
            $param{'new_listname'}, $param{'new_robot'}, $list);
    }

    ## Install new aliases
    $param{'listname'} = $param{'new_listname'};

    unless (
        $list = Sympa::List->new(
            $param{'new_listname'}, $param{'new_robot'},
            {'reload_config' => 1}
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unable to load $param{'new_listname'} while renaming");
        return 'internal';
    }

    ## Check custom_subject
    if (my $c = $list->custom_subject) {

        # FIXME MO: this is unsave: check/replace full listname
        if ($c =~ /$old_listname/) {
            $c =~ s/$old_listname/$param{new_listname}/g;
            $list->custom_subject($c);
            $list->save_config($param{'user_email'});
        }
    }

    if ($list->status eq 'open') {
        $param{'aliases'} = install_aliases($list);
    }

    unless ($param{'mode'} eq 'copy') {

        ## Rename files in spools
        ## Auth & Mod  spools
        foreach my $spool (
            'queueauth',      'queuemod',
            'queuetask',      'queuebounce',
            'queue',          'queueoutgoing',
            'queuesubscribe', 'queueautomatic'
            ) {
            unless (opendir(DIR, Sympa::Site->$spool)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Unable to open '%s' spool : %s",
                    Sympa::Site->$spool, $ERRNO);
            }

            foreach my $file (sort readdir(DIR)) {
                next
                    unless ($file =~ /^$old_listname\_/
                    || $file =~ /^$old_listname\./
                    || $file =~ /^$old_listname\@$robot\./
                    || $file =~ /^\.$old_listname\@$robot\_/
                    || $file =~ /^$old_listname\@$robot\_/
                    || $file =~ /\.$old_listname$/);

                my $newfile = $file;
                if ($file =~ /^$old_listname\_/) {
                    $newfile =~ s/^$old_listname\_/$param{'new_listname'}\_/;
                } elsif ($file =~ /^$old_listname\./) {
                    $newfile =~ s/^$old_listname\./$param{'new_listname'}\./;
                } elsif ($file =~ /^$old_listname\@$robot\./) {
                    $newfile =~
                        s/^$old_listname\@$robot\./$param{'new_listname'}\@$param{'new_robot'}\./;
                } elsif ($file =~ /^$old_listname\@$robot\_/) {
                    $newfile =~
                        s/^$old_listname\@$robot\_/$param{'new_listname'}\@$param{'new_robot'}\_/;
                } elsif ($file =~ /^\.$old_listname\@$robot\_/) {
                    $newfile =~
                        s/^\.$old_listname\@$robot\_/\.$param{'new_listname'}\@$param{'new_robot'}\_/;
                } elsif ($file =~ /\.$old_listname$/) {
                    $newfile =~ s/\.$old_listname$/\.$param{'new_listname'}/;
                }

                ## Rename file
                unless (
                    move(
                        Sympa::Site->$spool . "/$file",
                        Sympa::Site->$spool . "/$newfile"
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        "Unable to rename %s to %s : %s",
                        Sympa::Site->$spool . "/$file",
                        Sympa::Site->$spool . "/$newfile",
                        $ERRNO
                    );
                    next;
                }

                ## Change X-Sympa-To
                Sympa::Tools::change_x_sympa_to(
                    Sympa::Site->$spool . "/$newfile",
                    "$param{'new_listname'}\@$param{'new_robot'}");
            }

            close DIR;
        }
        ## Digest spool
        if (-f Sympa::Site->queuedigest . "/$old_listname") {
            unless (
                move(
                    Sympa::Site->queuedigest . "/$old_listname",
                    Sympa::Site->queuedigest . "/$param{'new_listname'}"
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    "Unable to rename %s to %s : %s",
                    Sympa::Site->queuedigest . "/$old_listname",
                    Sympa::Site->queuedigest . "/$param{'new_listname'}",
                    $ERRNO
                );
                next;
            }
        } elsif (-f Sympa::Site->queuedigest . "/$old_listname\@$robot") {
            unless (
                move(
                    Sympa::Site->queuedigest . "/$old_listname\@$robot",
                    Sympa::Site->queuedigest
                        . "/$param{'new_listname'}\@$param{'new_robot'}"
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    "Unable to rename %s to %s : %s",
                    Sympa::Site->queuedigest . "/$old_listname\@$robot",
                    Sympa::Site->queuedigest
                        . "/$param{'new_listname'}\@$param{'new_robot'}",
                    $ERRNO
                );
                next;
            }
        }
    }

    return 1;
}

########################################################
# clone_list_as_empty {
########################################################
# Clone a list config including customization, templates, scenario config
# but without archives, subscribers and shared
#
# IN  : - $source_list_name : the list to clone
#       - $source_robot : robot of the list to clone
#       - $new_listname : the target listname
#       - $new_robot_id : the target list's robot
#       - $email : the email of the requestor : used in config as
#       admin->last_update->email
#
# OUT : - $list : the updated list or undef
##
sub clone_list_as_empty {

    my $source_list_name = shift;
    my $source_robot     = shift;
    my $new_listname     = shift;
    my $new_robot_id     = shift;
    my $email            = shift;

    my $list;
    unless ($list = Sympa::List->new($source_list_name, $source_robot)) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Admin::clone_list_as_empty : new list failed %s %s',
            $source_list_name, $source_robot);
        return undef;
    }

    $main::logger->do_log(Sympa::Logger::INFO,
        "Admin::clone_list_as_empty ($source_list_name, $source_robot,$new_listname,$new_robot_id,$email)"
    );

    my $new_dir;
    if (-d Sympa::Site->home . '/' . $new_robot_id) {
        $new_dir =
            Sympa::Site->home . '/' . $new_robot_id . '/' . $new_listname;
    } elsif ($new_robot_id eq Sympa::Site->domain) {
        $new_dir = Sympa::Site->home . '/' . $new_listname;
    } else {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Admin::clone_list_as_empty : unknown robot $new_robot_id");
        return undef;
    }

    unless (mkdir $new_dir, 0775) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Admin::clone_list_as_empty : failed to create directory %s : %s',
            $new_dir,
            $ERRNO
        );
        return undef;
    }
    chmod 0775, $new_dir;
    foreach my $subdir ('etc', 'web_tt2', 'mail_tt2', 'data_sources') {
        if (-d $new_dir . '/' . $subdir) {
            unless (
                Sympa::Tools::File::copy_dir(
                    $list->dir . '/' . $subdir,
                    $new_dir . '/' . $subdir
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'Admin::clone_list_as_empty :  failed to copy_directory %s : %s',
                    $new_dir . '/' . $subdir,
                    $ERRNO
                );
                return undef;
            }
        }
    }

    # copy mandatory files
    foreach my $file ('config') {
        unless (
            File::Copy::copy(
                $list->dir . '/' . $file, $new_dir . '/' . $file
            )
            ) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Admin::clone_list_as_empty : failed to copy %s : %s',
                $new_dir . '/' . $file, $ERRNO
            );
            return undef;
        }
    }

    # copy optional files
    foreach my $file ('message.footer', 'message.header', 'info', 'homepage')
    {
        if (-f $list->dir . '/' . $file) {
            unless (
                File::Copy::copy(
                    $list->dir . '/' . $file,
                    $new_dir . '/' . $file
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'Admin::clone_list_as_empty : failed to copy %s : %s',
                    $new_dir . '/' . $file, $ERRNO
                );
                return undef;
            }
        }
    }

    my $new_list;

    # now switch List object to new list, update some values
    unless (
        $new_list = Sympa::List->new(
            $new_listname, $new_robot_id, {'reload_config' => 1}
        )
        ) {
        $main::logger->do_log(Sympa::Logger::INFO,
            "Admin::clone_list_as_empty : unable to load $new_listname while renamming"
        );
        return undef;
    }
    $new_list->serial(0);
    my $creation = {
        'date_epoch' => time,
        ##FIXME:should be unneccessary
        'date' => $language->gettext_strftime(
            "%d %b %y at %H:%M:%S", localtime time
        )
    };
    ##FIXME: creation.email may be empty
    $creation->{'email'} = $email if $email;
    $new_list->creation($creation);
    $new_list->save_config($email);
    return $new_list;
}

########################################################
# check_owner_defined
########################################################
# verify if they are any owner defined : it must exist
# at least one param owner(in $owner) or one param
# owner_include (in $owner_include)
# the owner param must have sub param email
# the owner_include param must have sub param source
#
# IN  : - $owner : ref on array of hash
#                  or
#                  ref on hash
#       - $owner_include : ref on array of hash
#                          or
#                          ref on hash
# OUT : - 1 if exists owner(s)
#         or
#         undef if no owner defined
#########################################################
sub check_owner_defined {
    my ($owner, $owner_include) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2, "check_owner_defined()");

    if (ref($owner) eq "ARRAY") {
        if (ref($owner_include) eq "ARRAY") {
            if (($#{$owner} < 0) && ($#{$owner_include} < 0)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'missing list param owner or owner_include');
                return undef;
            }
        } else {
            if (($#{$owner} < 0) && !($owner_include)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'missing list param owner or owner_include');
                return undef;
            }
        }
    } else {
        if (ref($owner_include) eq "ARRAY") {
            if (!($owner) && ($#{$owner_include} < 0)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'missing list param owner or owner_include');
                return undef;
            }
        } else {
            if (!($owner) && !($owner_include)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'missing list param owner or owner_include');
                return undef;
            }
        }
    }

    if (ref($owner) eq "ARRAY") {
        foreach my $o (@{$owner}) {
            unless ($o) {
                $main::logger->do_log(Sympa::Logger::ERR, 'empty param "owner"');
                return undef;
            }
            unless ($o->{'email'}) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'missing sub param "email" for param "owner"');
                return undef;
            }
        }
    } elsif (ref($owner) eq "HASH") {
        unless ($owner->{'email'}) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'missing sub param "email" for param "owner"');
            return undef;
        }
    } elsif (defined $owner) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'missing sub param "email" for param "owner"');
        return undef;
    }

    if (ref($owner_include) eq "ARRAY") {
        foreach my $o (@{$owner_include}) {
            unless ($o) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'empty param "owner_include"');
                return undef;
            }
            unless ($o->{'source'}) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'missing sub param "source" for param "owner_include"');
                return undef;
            }
        }
    } elsif (ref($owner_include) eq "HASH") {
        unless ($owner_include->{'source'}) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'missing sub param "source" for param "owner_include"');
            return undef;
        }
    } elsif (defined $owner_include) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'missing sub param "source" for param "owner_include"');
        return undef;
    }
    return 1;
}

#####################################################
# list_check_smtp
#####################################################
# check if the requested list exists already using
#   smtp 'rcpt to'
#
# IN  : - $list : name of the list
#       - $robot : list's robot
# OUT : - Net::SMTP object or 0
#####################################################
sub list_check_smtp {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $list  = shift;
    my $robot = Sympa::Robot::clean_robot(shift);

    my $conf = '';
    my $smtp;
    my (@suf, @addresses);

    my $smtp_relay = $robot->list_check_smtp;
    my $smtp_helo = $robot->list_check_helo || $smtp_relay;
    $smtp_helo =~ s/:[-\w]+$//;
    my $suffixes = $robot->list_check_suffixes;
    return 0
        unless $smtp_relay and $suffixes;
    my $domain = $robot->host;
    @suf = split(/\s*,\s*/, $suffixes);
    return 0 if !@suf;

    for (@suf) {
        push @addresses, $list . "-$_\@" . $domain;
    }
    push @addresses, "$list\@" . $domain;

    eval { require Net::SMTP; };
    if ($EVAL_ERROR) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to use Net library, Net::SMTP required, install it (CPAN) first'
        );
        return undef;
    }
    if ($smtp = Net::SMTP->new(
            $smtp_relay,
            Hello   => $smtp_helo,
            Timeout => 30
        )
        ) {
        $smtp->mail('');
        for (@addresses) {
            $conf = $smtp->to($_);
            last if $conf;
        }
        $smtp->quit();
        return $conf;
    }
    return undef;
}

##########################################################
# install_aliases
##########################################################
# Install sendmail aliases for $list
#
# IN  : - $list : object list
#       - $robot : the list's robot.  ** No longer used.
# OUT : - undef if not applicable or aliases not installed
#         1 (if ok) or
##########################################################
sub install_aliases {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $list = shift;

    return 1
        if Sympa::Site->sendmail_aliases =~ /^none$/i;

    my $alias_manager = Sympa::Site->alias_manager;
    my $output_file   = Sympa::Site->tmpdir . '/aliasmanager.stdout.' . $PID;
    my $error_output_file =
        Sympa::Site->tmpdir . '/aliasmanager.stderr.' . $PID;
    $main::logger->do_log(Sympa::Logger::DEBUG3, '%s add alias %s@%s for list %s',
        $alias_manager, $list->name, $list->host, $list);

    unless (-x $alias_manager) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Failed to install aliases: %s',
            $ERRNO);
        return undef;
    }
    ##FIXME: 'host' parameter is passed to alias_manager: no 'domain'
    ## parameter to determine robot.
    my $cmd = sprintf '%s add %s %s >%s 2> %s',
        $alias_manager, $list->name, $list->host,
        $output_file, $error_output_file;
    system($cmd);
    my $status = $CHILD_ERROR >> 8;
    if ($status == 0) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'Aliases installed successfully: list %s', $list);
        return 1;
    }

    ## get error code
    my $error_output;
    open ERR, $error_output_file;
    while (<ERR>) {
        $error_output .= $_;
    }
    close ERR;
    unlink $error_output_file;

    if ($status == 1) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Configuration file %s has errors : %s',
            Sympa::Conf::get_sympa_conf(),
            $error_output
        );
    } elsif ($status == 2) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Internal error : Incorrect call to alias_manager : %s',
            $error_output);
    } elsif ($status == 3) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Could not read sympa config file, report to httpd error_log: %s',
            $error_output
        );
    } elsif ($status == 4) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Could not get default domain, report to httpd error_log: %s',
            $error_output);
    } elsif ($status == 5) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to append to alias file: %s',
            $error_output);
    } elsif ($status == 6) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unable to run newaliases: %s',
            $error_output);
    } elsif ($status == 7) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to read alias file, report to httpd error_log: %s',
            $error_output);
    } elsif ($status == 8) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Could not create temporay file, report to httpd error_log: %s',
            $error_output);
    } elsif ($status == 13) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'Some of list aliases already exist: %s',
            $error_output);
    } elsif ($status == 14) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Can not open lock file, report to httpd error_log: %s',
            $error_output);
    } elsif ($status == 15) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'The parser returned empty aliases: %s',
            $error_output);
    } elsif ($status == 16) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unknown robot: %s', $error_output);
    } else {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unknown error %s while running alias manager %s : %s",
            $status, $alias_manager, $error_output);
    }

    return undef;
}

#########################################################
# remove_aliases
#########################################################
# Remove sendmail aliases for $list
#
# IN  : - $list : object list
#       - $robot : the list's robot.  ** No longer used
# OUT : - undef if not applicable
#         1 (if ok) or
#         $aliases : concated string of alias not removed
#########################################################

sub remove_aliases {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $list = shift;

    return 1
        if Sympa::Site->sendmail_aliases =~ /^none$/i;

    my $status = $list->remove_aliases();
    my $suffix = $list->robot->return_path_suffix;
    my $aliases;

    unless ($status == 1) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Failed to remove aliases for list %s', $list);

        ## build a list of required aliases the listmaster should install
        my $libexecdir = Sympa::Constants::LIBEXECDIR;
        my $name       = $list->name;
        $aliases = <<EOF;
#----------------- $name
$name: "$libexecdir/queue $name"
$name-request: "|$libexecdir/queue $name-request"
$name$suffix: "|$libexecdir/bouncequeue $name"
$name-unsubscribe: "|$libexecdir/queue $name-unsubscribe"
# $name-subscribe: "|$libexecdir/queue $name-subscribe"
EOF

        return $aliases;
    }

    $main::logger->do_log(Sympa::Logger::INFO, 'Aliases removed successfully');

    return 1;
}

#####################################################
# check_topics
#####################################################
# Check $topic in the $robot conf
#
# IN  : - $topic : id of the topic
#       - $robot : the list's robot
# OUT : - 1 if the topic is in the robot conf or undef
#####################################################
##OBSOLETED: Use $robot->is_available_topic().
sub check_topics {
    my $topic = shift;
    my $robot = Sympa::Robot::clean_robot(shift);
    return $robot->is_available_topic($topic);
}

# change a user email address for both his memberships and ownerships
#
# IN  : - current_email : current user email address
#       - new_email     : new user email address
#       - robot         : virtual robot
#
# OUT : - status(scalar)          : status of the subroutine
#       - failed_for(arrayref)    : list of lists for which the change could
#       not be done (because user was
#                                   included or for authorization reasons)
sub change_user_email {
    my %in = @_;

    my @failed_for;

    unless ($in{'current_email'} && $in{'new_email'} && $in{'robot'}) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Missing incoming parameter');
        return undef;
    }

    my $robot = Sympa::Robot::clean_robot($in{'robot'});

    ## Change email as list MEMBER
    foreach my $list (
        Sympa::List::get_which($in{'current_email'}, $robot, 'member')) {

        my $l = $list->name;

        my $user_entry = $list->get_list_member($in{'current_email'});

        if ($user_entry->{'included'} == 1) {
            ## Check the type of data sources
            ## If only include_list of local mailing lists, then no problem
            ## Otherwise, notify list owner
            ## We could also force a sync_include for local lists
            my $use_external_data_sources;
            foreach my $datasource_id (split(/,/, $user_entry->{'id'})) {
                my $datasource = $list->search_datasource($datasource_id);
                if (   !defined $datasource
                    || $datasource->{'type'} ne 'include_list'
                    || (   $datasource->{'def'} =~ /\@(.+)$/
                        && $1 ne $robot->domain)
                    ) {
                    $use_external_data_sources = 1;
                    last;
                }
            }
            if ($use_external_data_sources) {
                ## Notify list owner
                $list->send_notify_to_owner(
                    'failed_to_change_included_member',
                    {   'current_email' => $in{'current_email'},
                        'new_email'     => $in{'new_email'},
                        'datasource' =>
                            $list->get_datasource_name($user_entry->{'id'})
                    }
                );
                push @failed_for, $list;
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'could not change member email for list %s because member is included',
                    $list
                );
                next;
            }
        }

        ## Check if user is already member of the list with his new address
        ## then we just need to remove the old address
        if ($list->is_list_member($in{'new_email'})) {
            unless (
                $list->delete_list_member('users' => [$in{'current_email'}]))
            {
                push @failed_for, $list;
                $main::logger->do_log(Sympa::Logger::INFO,
                    'could not remove email from list %s', $l);
            }

        } else {

            unless (
                $list->update_list_member(
                    $in{'current_email'},
                    {'email' => $in{'new_email'}, 'update_date' => time}
                )
                ) {
                push @failed_for, $list;
                $main::logger->do_log(Sympa::Logger::ERR,
                    'could not change email for list %s', $l);
            }
        }
    }

    ## Change email as list OWNER/MODERATOR
    my %updated_lists;
    foreach my $role ('owner', 'editor') {
        foreach my $list (
            Sympa::List::get_which($in{'current_email'}, $robot, $role)) {

            ## Check if admin is include via an external datasource
            my $admin_user =
                $list->get_list_admin($role, $in{'current_email'});
            if ($admin_user->{'included'}) {
                ## Notify listmaster
                $robot->send_notify_to_listmaster(
                    'failed_to_change_included_admin',
                    {   'list'          => $list,
                        'current_email' => $in{'current_email'},
                        'new_email'     => $in{'new_email'},
                        'datasource' =>
                            $list->get_datasource_name($admin_user->{'id'})
                    }
                );
                push @failed_for, $list;
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'could not change %s email for list %s because admin is included',
                    $role,
                    $list
                );
                next;
            }

            ## Go through owners/editors of the list
            foreach my $admin (@{$list->$role}) {
                next
                    unless (
                    lc($admin->{'email'}) eq lc($in{'current_email'}));

                ## Update entry with new email address
                $admin->{'email'} = $in{'new_email'};
                $updated_lists{$list->name}++;
            }

            ## Update Db cache for the list
            $list->sync_include_admin();
            $list->save_config();
        }
    }
    ## Notify listmasters that list owners/moderators email have changed
    if (keys %updated_lists) {
        $robot->send_notify_to_listmaster(
            'listowner_email_changed',
            {   'previous_email' => $in{'current_email'},
                'new_email'      => $in{'new_email'},
                'updated_lists'  => keys %updated_lists
            }
        );
    }

    ## Update User_table and remove existing entry first (to avoid duplicate
    ## entries)
    my $old_user = Sympa::User->new(
        $in{'new_email'}, Sympa::Site->db_additional_user_fields
    );
    $old_user->expire if $old_user;
    my $user = Sympa::User->new(
        $in{'current_email'}, Sympa::Site->db_additional_user_fields
    );
    unless ($user and $user->moveto($in{'new_mail'})) {
        $main::logger->do_log(Sympa::Logger::ERR, 'change_email: update failed');
        return undef;
    }

    ## Update netidmap_table
    unless (
        $robot->update_email_netidmap_db(
            $in{'current_email'}, $in{'new_email'}
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR, 'change_email: update failed');
        return undef;
    }

    return (1, \@failed_for);
}

1;
