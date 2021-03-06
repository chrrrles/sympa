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

Sympa::List - A mailing-list

=head1 DESCRIPTION

This class implements a mailing-list.

=cut

package Sympa::List;

use strict;
use warnings;
use base qw(Sympa::ConfigurableObject);

use Carp qw(croak);
use Data::Dumper;
use Digest::MD5;
use Encode qw();
use English;    # FIXME: drop $PREMATCH usage
use LWP::UserAgent;
use MIME::EncWords;
use POSIX qw();
use Storable qw(dclone);
use Time::Local qw();

use Sympa::Archive;
use Sympa::Constants;
use Sympa::DatabaseManager;
use Sympa::Datasource;
use Sympa::Family; # FIXME: circular dependency
use Sympa::Fetch;
use Sympa::Language;
use Sympa::ListDef;
use Sympa::Logger;
use Sympa::LockedFile;
use Sympa::Message;
use Sympa::Monitor;
use Sympa::VirtualHost; # FIXME: circular dependency
use Sympa::Scenario; # FIXME: circular dependency
use Sympa::Spool::File::Key;
use Sympa::Spool::File::Message;
use Sympa::Spool::File::Subscribe;
use Sympa::Spool::File::Task;
use Sympa::Template; # FIXME: circular dependency
use Sympa::Tools::Data;
use Sympa::Tools::File;
use Sympa::Tools::Message;
use Sympa::Tools::SMIME;
use Sympa::Tools::Text;
use Sympa::Tracking;
use Sympa::User;

my @sources_providing_listmembers = qw/
    include_file
    include_ldap_2level_query
    include_ldap_query
    include_list
    include_remote_file
    include_remote_sympa_list
    include_sql_query
    /;

#XXX include_admin
my @more_data_sources = qw/
    editor_include
    owner_include
    /;

# All non-pluggable sources are in the admin user file
my %config_in_admin_user_file = map +($_ => 1),
    @sources_providing_listmembers;

=encoding utf-8

=head1 CONSTRUCTOR AND INITIALIZER

=over 4

=item new( NAME, [ ROBOT, [ OPTIONS ] ] )

 Sympa::List->new();

Creates a new object which will be used for a list and
eventually loads the list if a name is given. Returns
a List object.

=over 4

=item NAME

Name of list.

=item ROBOT

Name of robot.

=item OPTIONS

Optional hashref.  See load().

=back

=back

=over 4

=item load ( NAME, [ ROBOT, [ OPTIONS ] ] )

Loads the indicated list into the object.

=over 4

=item NAME

Name of list.

=item ROBOT

Name of robot.

=item OPTIONS

Optional hashref.  

=over 4

=item C<'just_try' =E<gt> TRUE>

Won't log errors.

=item C<'reload_config' =E<gt> TRUE>

Force reload config.  Cache won't be used anyway.

=item C<'skip_name_check' =E<gt> TRUE>

Won't check correctness of list name.

=item C<'skip_sync_admin' =E<gt> TRUE>

Won't synchronize owner/editor.

=item C<'force_sync_admin' =E<gt> TRUE>

Force synchronizing owner/editor.

=back

=back

=back

=head1 METHODS AND FUNCTIONS

=over 4

=item save_config ( EMAIL )

Saves the indicated list object to the disk files.
EMAIL is the user performing save.

=item savestats ()

Saves updates the statistics file on disk.

=item update_stats( BYTES )

Updates the stats, argument is number of bytes, returns the next
sequence number. Does nothing if no stats.

=item send_sub_to_owner ( WHO, COMMENT )

Send a message to the list owners telling that someone
wanted to subscribe to the list.

=item send_to_editor ( MSG )
    
Send a Mail::Internet type object to the editor (for approval).

=item send_msg ( MSG )

Sends the Mail::Internet message to the list.

=item send_file ( FILE, USERS, PARAM )

Sends the file to the USER.
See L<Site/send_file>.

=item delete_list_member ( ARRAY )

Delete the indicated users from the list.
 
=item delete_list_admin ( ROLE, ARRAY )

Delete the indicated admin user with the predefined role from the list.

=item get_max_size ()

Returns the maximum allowed size for a message.

=item get_reply_to ()

Returns an array with the Reply-To values.

=item get_real_total ()

Returns the number of subscribers to the list.
Older name is get_total().  Current version won't use cache anymore.
Use total() to get cached number.

=item get_list_member ( USER )

Returns a subscriber of the list.

=item get_list_admin ( ROLE, USER)

Return an admin user of the list with predefined role

=item get_first_list_member ()

Returns a hash to the first user on the list.

=item get_first_list_admin ( ROLE )

Returns a hash to the first admin user with predefined role on the list.

=item get_next_list_member ()

Returns a hash to the next users, until we reach the end of
the list.

=item get_next_list_admin ()

Returns a hash to the next admin users, until we reach the end of
the list.

=item update_list_member ( USER, HASHPTR )

Sets the new values given in the hash for the user.

=item update_list_admin ( USER, ROLE, HASHPTR )

Sets the new values given in the hash for the admin user.

=item add_list_member ( USER, HASHPTR )

Adds a new user to the list. May overwrite existing
entries.

=item add_admin_user ( USER, ROLE, HASHPTR )

Adds a new admin user to the list. May overwrite existing
entries.

=item is_list_member ( USER )

Returns true if the indicated user is member of the list.
 
=item am_i ( FUNCTION, USER )

Returns true is USER has FUNCTION (owner, editor) on the
list.

=item get_state ( FLAG )

Returns the value for a flag : sig or sub.

=item may_do ( ACTION, USER )

Chcks is USER may do the ACTION for the list. ACTION can be
one of following : send, review, index, getm add, del,
reconfirm, purge.

=item is_moderated ()

Returns true if the list is moderated.

=item archive_exist ( FILE )

Returns true if the indicated file exists.

=item archive_send ( WHO, FILE )

Send the indicated archive file to the user, if it exists.

=item archive_ls ()

Returns the list of available files, if any.

=item archive_msg ( MSG )

Archives the Mail::Internet message given as argument.

=item is_archived ()

Returns true is the list is configured to keep archives of
its messages.

=item get_stats ( OPTION )

Returns either a formatted printable strings or an array whith
the statistics. OPTION can be 'text' or 'array'.

=item print_info ( FDNAME )

Print the list information to the given file descriptor, or the
currently selected descriptor.

=back

=cut

## Database and SQL statement handlers
my ($sth, @sth_stack);

#my %list_cache; # No longer used: Now each Robot object have list cache.

## DB fields with numeric type
## We should not do quote() for these while inserting data
my %numeric_field = (
    'cookie_delay_user'       => 1,
    'bounce_score_subscriber' => 1,
    'subscribed_subscriber'   => 1,
    'included_subscriber'     => 1,
    'subscribed_admin'        => 1,
    'included_admin'          => 1,
    'wrong_login_count'       => 1,
);

## List parameter values except for parameters below.
my %list_option = (

    # reply_to_header.apply
    'forced'  => {'gettext_id' => 'overwrite Reply-To: header field'},
    'respect' => {'gettext_id' => 'preserve existing header field'},

    # reply_to_header.value
    'sender' => {'gettext_id' => 'sender'},

    # reply_to_header.value, include_remote_sympa_list.cert
    'list' => {'gettext_id' => 'list'},

    # include_ldap_2level_query.select2, include_ldap_2level_query.select1,
    # include_ldap_query.select, reply_to_header.value
    'all' => {'gettext_id' => 'all'},

    # reply_to_header.value
    'other_email' => {'gettext_id' => 'other email address'},

    # msg_topic_keywords_apply_on
    'subject'          => {'gettext_id' => 'subject field'},
    'body'             => {'gettext_id' => 'message body'},
    'subject_and_body' => {'gettext_id' => 'subject and body'},

    # bouncers_level2.notification, bouncers_level2.action,
    # bouncers_level1.notification, bouncers_level1.action,
    # spam_protection, dkim_signature_apply_on, web_archive_spam_protection
    'none' => {'gettext_id' => 'do nothing'},

    # bouncers_level2.notification, bouncers_level1.notification,
    # welcome_return_path, remind_return_path, rfc2369_header_fields,
    # archive.access
    'owner' => {'gettext_id' => 'owner'},

    # bouncers_level2.notification, bouncers_level1.notification
    'listmaster' => {'gettext_id' => 'listmaster'},

    # bouncers_level2.action, bouncers_level1.action
    'remove_bouncers' => {'gettext_id' => 'remove bouncing users'},
    'notify_bouncers' => {'gettext_id' => 'notify bouncing users'},

    # pictures_feature, dkim_feature, merge_feature,
    # inclusion_notification_feature, tracking.delivery_status_notification,
    # tracking.message_delivery_notification
    'on'  => {'gettext_id' => 'enabled'},
    'off' => {'gettext_id' => 'disabled'},

    # include_remote_sympa_list.cert
    'robot' => {'gettext_id' => 'robot'},

    # include_ldap_2level_query.select2, include_ldap_2level_query.select1,
    # include_ldap_query.select
    'first' => {'gettext_id' => 'first entry'},

    # include_ldap_2level_query.select2, include_ldap_2level_query.select1
    'regex' => {'gettext_id' => 'entries matching regular expression'},

    # include_ldap_2level_query.scope2, include_ldap_2level_query.scope1,
    # include_ldap_query.scope
    'base' => {'gettext_id' => 'base'},
    'one'  => {'gettext_id' => 'one level'},
    'sub'  => {'gettext_id' => 'subtree'},

    # include_ldap_2level_query.use_ssl, include_ldap_query.use_ssl
    'yes' => {'gettext_id' => 'yes'},
    'no'  => {'gettext_id' => 'no'},

    # include_ldap_2level_query.ssl_version, include_ldap_query.ssl_version
    'sslv2' => {'gettext_id' => 'SSL version 2'},
    'sslv3' => {'gettext_id' => 'SSL version 3'},
    'tls'   => {'gettext_id' => 'TLS'},

    # editor.reception, owner_include.reception, owner.reception,
    # editor_include.reception
    'mail'   => {'gettext_id' => 'receive notification email'},
    'nomail' => {'gettext_id' => 'no notifications'},

    # editor.visibility, owner_include.visibility, owner.visibility,
    # editor_include.visibility
    'conceal'   => {'gettext_id' => 'concealed from list menu'},
    'noconceal' => {'gettext_id' => 'listed on the list menu'},

    # welcome_return_path, remind_return_path
    'unique' => {'gettext_id' => 'bounce management'},

    # owner_include.profile, owner.profile
    'privileged' => {'gettext_id' => 'privileged owner'},
    'normal'     => {'gettext_id' => 'normal owner'},

    # priority
    '0' => {'gettext_id' => '0 - highest priority'},
    '9' => {'gettext_id' => '9 - lowest priority'},
    'z' => {'gettext_id' => 'queue messages only'},

    # spam_protection, web_archive_spam_protection
    'at'         => {'gettext_id' => 'replace @ characters'},
    'javascript' => {'gettext_id' => 'use JavaScript'},

    # msg_topic_tagging
    'required_sender' => {'gettext_id' => 'required to post message'},
    'required_moderator' =>
        {'gettext_id' => 'required to distribute message'},

    # msg_topic_tagging, custom_attribute.optional
    'optional' => {'gettext_id' => 'optional'},

    # custom_attribute.optional
    'required' => {'gettext_id' => 'required'},

    # custom_attribute.type
    'string'  => {'gettext_id' => 'string'},
    'text'    => {'gettext_id' => 'multi-line text'},
    'integer' => {'gettext_id' => 'number'},
    'enum'    => {'gettext_id' => 'set of keywords'},

    # footer_type
    'mime'   => {'gettext_id' => 'add a new MIME part'},
    'append' => {'gettext_id' => 'append to message body'},

    # archive.access
    'open'    => {'gettext_id' => 'open'},
    'closed'  => {'gettext_id' => 'closed'},
    'private' => {'gettext_id' => 'subscribers only'},
    'public'  => {'gettext_id' => 'public'},

##    ## user_data_source
##    'database' => {'gettext_id' => 'RDBMS'},
##    'file'     => {'gettext_id' => 'include from local file'},
##    'include'  => {'gettext_id' => 'include from external source'},
##    'include2' => {'gettext_id' => 'general datasource'},

    # rfc2369_header_fields
    'help'        => {'gettext_id' => 'help'},
    'subscribe'   => {'gettext_id' => 'subscription'},
    'unsubscribe' => {'gettext_id' => 'unsubscription'},
    'post'        => {'gettext_id' => 'posting address'},
    'archive'     => {'gettext_id' => 'list archive'},

    # dkim_signature_apply_on
    'md5_authenticated_messages' =>
        {'gettext_id' => 'authenticated by password'},
    'smime_authenticated_messages' =>
        {'gettext_id' => 'authenticated by S/MIME signature'},
    'dkim_authenticated_messages' =>
        {'gettext_id' => 'authenticated by DKIM signature'},
    'editor_validated_messages' => {'gettext_id' => 'approved by editor'},
    'any'                       => {'gettext_id' => 'any messages'},

    # archive.period
    'day'     => {'gettext_id' => 'daily'},
    'week'    => {'gettext_id' => 'weekly'},
    'month'   => {'gettext_id' => 'monthly'},
    'quarter' => {'gettext_id' => 'quarterly'},
    'year'    => {'gettext_id' => 'yearly'},

    # web_archive_spam_protection
    'cookie' => {'gettext_id' => 'use HTTP cookie'},

    # verp_rate
    '100%' => {'gettext_id' => '100% - always'},
    '0%'   => {'gettext_id' => '0% - never'},

    # archive_crypted_msg
    'original'  => {'gettext_id' => 'original messages'},
    'decrypted' => {'gettext_id' => 'decrypted messages'},

    # tracking.message_delivery_notification
    'on_demand' => {'gettext_id' => 'on demand'},
);

## Values for subscriber reception mode.
my %reception_mode = (
    'mail'        => {'gettext_id' => 'standard (direct reception)'},
    'digest'      => {'gettext_id' => 'digest MIME format'},
    'digestplain' => {'gettext_id' => 'digest plain text format'},
    'summary'     => {'gettext_id' => 'summary mode'},
    'notice'      => {'gettext_id' => 'notice mode'},
    'txt'         => {'gettext_id' => 'text-only mode'},
    'html'        => {'gettext_id' => 'html-only mode'},
    'urlize'      => {'gettext_id' => 'urlize mode'},
    'nomail'      => {'gettext_id' => 'no mail'},
    'not_me'      => {'gettext_id' => 'you do not receive your own posts'}
);

## Values for subscriber visibility mode.
my %visibility_mode = (
    'noconceal' => {'gettext_id' => 'listed in the list review page'},
    'conceal'   => {'gettext_id' => 'concealed'}
);

## Values for list status.
my %list_status = (
    'open'          => {'gettext_id' => 'in operation'},
    'pending'       => {'gettext_id' => 'list not yet activated'},
    'error_config'  => {'gettext_id' => 'erroneous configuration'},
    'family_closed' => {'gettext_id' => 'closed family instance'},
    'closed'        => {'gettext_id' => 'closed list'},
);

## This is the generic hash which keeps all lists in memory.
my %edit_list_conf = ();

## Last modification times
my %mtime;

#use Fcntl; # duplicated
## Creates an object.
sub new {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, %s)', @_);

    ## NOTICE: Don't use accessors like "$self->dir" but "$self->{'dir'}",
    ## since the object has not been fully initialized yet.

    my $pkg     = shift;
    my $name    = shift;
    my $robot   = shift;
    my $options = shift || {};
    my $list;

    unless ($options->{'skip_name_check'}) {
        if ($name && $name =~ /\@/) {
            ## Allow robot in the name
            my @parts = split /\@/, $name;
            $robot ||= $parts[1];
            $name = $parts[0];
        }
        unless ($robot) {
            ## Look for the list if no robot was provided
            $robot = search_list_among_robots($name);
        }
        if ($robot) {
            croak "missing 'robot' parameter" unless $robot;
            croak "invalid 'robot' parameter" unless
                $robot eq '*' or
                (blessed $robot and $robot->isa('Sympa::VirtualHost'));
        }

        unless ($robot) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Missing robot parameter, cannot create list object for %s',
                $name)
                unless ($options->{'just_try'});
            return undef;
        }

        ## Only process the list if the name is valid.
        my $listname_regexp = Sympa::Tools::get_regexp('listname');
        unless ($name and ($name =~ /^($listname_regexp)$/io)) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Incorrect listname "%s"',
                $name)
                unless $options->{'just_try'};
            return undef;
        }
        ## Lowercase the list name.
        $name = lc $1;

        ## Reject listnames with reserved list suffixes
        my (undef, $type) = $robot->split_listname($name);
        if ($type) {
            unless ($options->{'just_try'}) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'Incorrect name: listname "%s" matches one of service aliases',
                    $name
                );
                return undef;
            }
        }
    } else {
        croak "missing 'robot' parameter" unless $robot;
        croak "invalid 'robot' parameter" unless
            (blessed $robot and $robot->isa('Sympa::VirtualHost'));
    }

    my $status;
    ## If list already in memory and not previously purged by another process
    if ($robot->lists($name) and -d $robot->lists($name)->dir) {

        # use the current list in memory and update it
        $list = $robot->lists($name);
    } else {

        # create a new object list
        $list = bless {} => $pkg;
    }
    $status = $list->load($name, $robot, $options);
    unless (defined $status) {
        return undef;
    }

    ## Config file was loaded or reloaded
    if (($status == 1 && !$options->{'skip_sync_admin'})
        || $options->{'force_sync_admin'}) {

        ## Update admin_table
        unless (defined $list->sync_include_admin()) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'sync_include_admin for list %s failed', $list)
                unless $options->{'just_try'};
        }
        if ($list->get_nb_owners() < 1) {
            $list->set_status_error_config('no_owner_defined');
        }
    }

    return $list;
}

## When no robot is specified, look for a list among robots
sub search_list_among_robots {
    my $listname = shift;

    unless ($listname) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Missing list parameter');
        return undef;
    }

    foreach my $robot (@{Sympa::VirtualHost::get_robots() || []}) {
        if (-d $robot->home . '/' . $listname) {
            return $robot;
        }
    }

    return 0;
}

## set the list in status error_config and send a notify to listmaster
sub set_status_error_config {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, ...)', @_);

    my ($self, $message, @param) = @_;

    unless ($self->config and $self->status eq 'error_config') {
        $self->status('error_config');

        ## No more save config in error...
        #$self->save_config($self->robot->get_address('listmaster'));
        #$self->savestats();
        $main::logger->do_log(Sympa::Logger::ERR,
            'The list %s is set in status error_config: %s(%s)',
            $self, $message, join(', ', @param));
        $self->robot->send_notify_to_listmaster($message,
            [$self->name, @param]);
    }
}

## set the list in status family_closed and send a notify to owners
sub set_status_family_closed {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, ...)', @_);

    my ($self, $message, @param) = @_;

    unless ($self->status eq 'family_closed') {
        unless (
            $self->close_list(
                $self->robot->get_address('listmaster'),
                'family_closed'
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Impossible to set the list %s in status family_closed',
                $self);
            return undef;
        }
        $main::logger->do_log(Sympa::Logger::INFO,
            'The list %s is set in status family_closed', $self);
        unless ($self->send_notify_to_owner($message, \@param)) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Impossible to send notify to owner informing status family_closed for the list %s',
                $self
            );
        }

        # messages : close_list
    }
    return 1;
}

## Saves the statistics data to disk.
sub savestats {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    ## Be sure the list has been loaded.
    my $name = $self->name;
    my $dir  = $self->dir;
    return undef unless $self->robot->lists($name);

    ## Lock file
    my $lock_fh = Sympa::LockedFile->new($dir . '/stats', 2, '>');
    unless ($lock_fh) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Could not create new lock');
        return undef;
    }

    printf $lock_fh "%d %.0f %.0f %.0f %d %d %d\n",
        @{$self->{'stats'}}, $self->{'total'}, $self->{'last_sync'},
        $self->{'last_sync_admin_user'};

    ## Release the lock
    unless ($lock_fh->close) {
        return undef;
    }

    ## Changed on disk
    $self->{'mtime'}[2] = time;

    return 1;
}

## msg count.
sub increment_msg_count {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    ## Be sure the list has been loaded.
    my $file = $self->dir . '/msg_count';
    my $time = time;

    my %count;
    if (open(MSG_COUNT, $file)) {
        while (<MSG_COUNT>) {
            if ($_ =~ /^(\d+)\s(\d+)$/) {
                $count{$1} = $2;
            }
        }
        close MSG_COUNT;
    }
    my $today = int($time / 86400);
    if ($count{$today}) {
        $count{$today}++;
    } else {
        $count{$today} = 1;
    }

    unless (open(MSG_COUNT, ">$file.$PID")) {
        $main::logger->do_log(Sympa::Logger::ERR, "Unable to create '%s.%s' : %s",
            $file, $PID, $ERRNO);
        return undef;
    }
    foreach my $key (sort { $a <=> $b } keys %count) {
        printf MSG_COUNT "%d\t%d\n", $key, $count{$key};
    }
    close MSG_COUNT;

    unless (rename("$file.$PID", $file)) {
        $main::logger->do_log(Sympa::Logger::ERR, "Unable to write '%s' : %s",
            $file, $ERRNO);
        return undef;
    }

    return 1;
}

# Returns the number of messages sent to the list
sub get_msg_count {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    ## Be sure the list has been loaded.
    my $file = $self->dir . '/stats';

    my $count = 0;
    if (open(MSG_COUNT, $file)) {
        while (<MSG_COUNT>) {
            if ($_ =~ /^(\d+)\s+(.*)$/) {
                $count = $1;
            }
        }
        close MSG_COUNT;
    }

    return $count;

}
## last date of distribution message .
sub get_latest_distribution_date {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    ## Be sure the list has been loaded.
    my $file = $self->dir . '/msg_count';

    my $latest_date = 0;
    unless (open(MSG_COUNT, $file)) {
        $main::logger->do_log(Sympa::Logger::DEBUG3, 'unable to open file %s', $file);
        return undef;
    }

    while (<MSG_COUNT>) {
        if ($_ =~ /^(\d+)\s(\d+)$/) {
            $latest_date = $1 if ($1 > $latest_date);
        }
    }
    close MSG_COUNT;

    return undef if ($latest_date == 0);
    return $latest_date;
}

## Update the stats struct
## Input  : num of bytes of msg
## Output : num of msgs sent
sub update_stats {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my ($self, $bytes) = @_;

    my @stats = (@{$self->stats});
    $stats[0]++;    # messsages sent
    $stats[1] += $self->total;             # total messages sent
    $stats[2] += $bytes;                   # octets sent
    $stats[3] += $bytes * $self->total;    # total octets sent
    $self->{'stats'} = \@stats;

    ## Update 'msg_count' file, used for bounces management
    $self->increment_msg_count();

    return $stats[0];
}

## Extract a set of rcpt for which verp must be use from a rcpt_tab.
## Input  :  percent : the rate of subscribers that must be threaded using
## verp
##           xseq    : the message sequence number
##           @rcpt   : a tab of emails
## return :  a tab of rcpt for which rcpt must be use depending on the message
## sequence number, this way every subscriber is "VERPed" from time to time
##           input table @rcpt is spliced : rcpt for which verp must be used
##           are extracted from this table
sub extract_verp_rcpt {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s, %s)', @_);
    my $percent     = shift;
    my $xseq        = shift;
    my $refrcpt     = shift;
    my $refrcptverp = shift;

    my @result;

    if ($percent ne '0%') {
        my $nbpart;
        if ($percent =~ /^(\d+)\%/) {
            $nbpart = 100 / $1;
        } else {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Wrong format for parameter extract_verp: %s. Can\'t process VERP.',
                $percent
            );
            return undef;
        }

        my $modulo = $xseq % $nbpart;
        my $lenght = int(($#{$refrcpt} + 1) / $nbpart) + 1;

        @result = splice @$refrcpt, $lenght * $modulo, $lenght;
    }
    foreach my $verprcpt (@$refrcptverp) {
        push @result, $verprcpt;
    }
    return (@result);
}

## Dumps a copy of lists to disk, in text format
sub dump {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    unless (defined $self) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unknown list');
        return undef;
    }

    my $user_file_name = $self->dir . '/subscribers.db.dump';

    unless ($self->_save_list_members_file($user_file_name)) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Failed to save file %s',
            $user_file_name);
        return undef;
    }

    $self->{'mtime'} = [
        (stat($self->dir . '/config'))[9],
        (stat($self->dir . '/subscribers'))[9],
        (stat($self->dir . '/stats'))[9]
    ];

    return 1;
}

## Saves the configuration file to disk
sub save_config {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my ($self, $email) = @_;

    return undef unless $self;

    ## Lock file
    my $config_file_name = $self->dir . '/config';
    my $lock_fh = Sympa::LockedFile->new($config_file_name, 5, '+<');
    unless ($lock_fh) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Could not create new lock');
        return undef;
    }

    unless ($self->_save_list_config_file($email)) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'unable to save config file %s/config', $self->dir);
        $lock_fh->close();
        return undef;
    }

    ## Release the lock
    unless ($lock_fh->close()) {
        return undef;
    }

    ## Also update the binary version of the data structure
    $self->list_cache_update_config;

    return 1;
}

## Loads the administrative data for a list
sub load {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s, %s)', @_);

    ## NOTICE: Don't use accessors like "$self->dir" but "$self->{'dir'}",
    ## since the object has not been fully initialized yet.

    my ($self, $name, $robot, $options) = @_;

    unless ($robot) {
        ## Look for the list if no robot was provided
        $robot = search_list_among_robots($name);
    }

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));
    unless (ref $robot) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unknown robot');
        return undef;
    }

    ## Set of initializations ; only performed when the config is first loaded
    unless ($self->{'name'} and $self->{'robot'} and $self->{'dir'}) {
        if ($robot and -d $robot->home) {
            $self->{'dir'} = $robot->home . '/' . $name;
        } elsif ($robot and $robot->domain eq Sympa::Site->domain) {
            $self->{'dir'} = Sympa::Site->home . '/' . $name;
        } else {
            $main::logger->do_log(Sympa::Logger::ERR,
                'No such robot (virtual domain) %s', $robot)
                unless $options->{'just_try'};
            return undef;
        }

        $self->{'robot'}  = $robot;
        $self->{'domain'} = $robot->domain;
        $self->{'name'}   = $name;
    }

    unless ($self->{'name'} eq $name
        and $self->{'domain'} eq $robot->domain) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Bug in logic.  Ask developer');
        return undef;
    }

    unless (-d $self->{'dir'} and -f $self->{'dir'} . '/config') {
        $main::logger->do_log(Sympa::Logger::DEBUG3,
            'Missing directory (%s) or config file for %s',
            $self->{'dir'}, $self)
            unless $options->{'just_try'};
        return undef;
    }

    ## Last modification of list config ($m1), subscribers ($m2) and stats
    ## ($m3) on memory cache.  $m2 is no longer used.
    my ($m1, $m2, $m3) = (0, 0, 0);
    ($m1, $m2, $m3) = @{$self->{'mtime'}} if defined $self->{'mtime'};

    my $time_config = (stat("$self->{'dir'}/config"))[9];
    my $time_stats  = (stat("$self->{'dir'}/stats"))[9];
    my $config      = undef;
    my $cached;

    ## Load list config
    if (   !$options->{'reload_config'}
        and $m1
        and $time_config
        and $time_config <= $m1) {
        $main::logger->do_log(Sympa::Logger::DEBUG3,
            'config for %s on memory is up-to-date', $self);
    } elsif (!$options->{'reload_config'}
        and defined($cached = $self->list_cache_fetch($m1, $time_config))) {
        $m1               = $cached->{'epoch'};
        $config           = $cached->{'config'};
        $self->{'config'} = $config;
        $self->{'admin'} = {};    # clear cached parameter values
        $self->{'total'} = $cached->{'total'} if defined $cached->{'total'};
        $main::logger->do_log(Sympa::Logger::DEBUG3,
            'got config for %s from serialized data', $self);
    } elsif ($options->{'reload_config'} or $time_config > $m1) {
        $config = _load_list_config_file($robot, $self->{'dir'}, 'config');
        unless (defined $config) {
            $self->set_status_error_config('load_admin_file_error');
            $self->list_cache_purge;
            return undef;
        }
        $m1               = $time_config;
        $self->{'config'} = $config;
        $self->{'admin'}  = {};             # clear cached parameter values
        $main::logger->do_log(Sympa::Logger::DEBUG3, 'got config for %s from file',
            $self);

        ## check param_constraint.conf if belongs to a family and
        ## the config has been loaded
        if (defined $self->family_name and $self->status ne 'error_config') {
            my $family;
            unless ($family = $self->family) {
                $self->set_status_error_config('no_list_family',
                    $self->family_name);
                $self->list_cache_purge;
                return undef;
            }

            my $error = $family->check_param_constraint($self);
            unless ($error) {
                $self->set_status_error_config('no_check_rules_family',
                    $family->{'name'});
            } elsif (ref $error eq 'ARRAY') {
                $self->set_status_error_config('no_respect_rules_family',
                    $family->{'name'});
            }
        }

        # config was reloaded.  Update cache too.
        $self->list_cache_update_config;
    }

    ## Check if the current list has a public key X.509 certificate.
    $self->{'as_x509_cert'} =
        (      -r $self->{'dir'} . '/cert.pem'
            || -r $self->{'dir'} . '/cert.pem.enc') ? 1 : 0;

    ## Load stats file if first new() or stats file changed
    if ($time_stats > $m3) {
        $self->_load_stats_file();
        $m3 = $time_stats;
    }

    $self->{'mtime'} = [$m1, $m2, $m3];
    $robot->lists($name, $self);
    return $config ? 1 : 0;
}

## Return a list of hash's owners and their param
sub get_owners {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    my $owners = ();

    # owners are in the admin_table ; they might come from an include data
    # source
    for (
        my $owner = $self->get_first_list_admin('owner');
        $owner;
        $owner = $self->get_next_list_admin()
        ) {
        push(@{$owners}, $owner);
    }

    return $owners;
}

sub get_nb_owners {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    my $resul  = 0;
    my $owners = $self->get_owners;

    if (defined $owners) {
        $resul = $#{$owners} + 1;
    }
    return $resul;
}

## Return a hash of list's editors and their param(empty if there isn't any
## editor)
sub get_editors {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    my $editors = ();

    # editors are in the admin_table ; they might come from an include data
    # source
    for (
        my $editor = $self->get_first_list_admin('editor');
        $editor;
        $editor = $self->get_next_list_admin()
        ) {
        push(@{$editors}, $editor);
    }

    return $editors;
}

## Returns an array of owners' email addresses
sub get_owners_email {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my ($self, $param) = @_;

    my @rcpt;
    my $owners = ();

    $owners = $self->get_owners();

    if ($param->{'ignore_nomail'}) {
        foreach my $o (@{$owners}) {
            push(@rcpt, lc($o->{'email'}));
        }
    } else {
        foreach my $o (@{$owners}) {
            next if ($o->{'reception'} eq 'nomail');
            push(@rcpt, lc($o->{'email'}));
        }
    }
    unless (@rcpt) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Warning : no owner found for list %s', $self);
    }
    return @rcpt;
}

## Returns an array of editors' email addresses
#  or owners if there isn't any editors'email adress
sub get_editors_email {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my ($self, $param) = @_;

    my @rcpt;
    my $editors = ();

    $editors = $self->get_editors();

    if ($param->{'ignore_nomail'}) {
        foreach my $e (@{$editors}) {
            push(@rcpt, lc($e->{'email'}));
        }
    } else {
        foreach my $e (@{$editors}) {
            next if ($e->{'reception'} eq 'nomail');
            push(@rcpt, lc($e->{'email'}));
        }
    }
    unless (@rcpt) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Warning : no editor found for list %s, getting owners', $self);
        @rcpt = $self->get_owners_email($param);
    }
    return @rcpt;
}

## return the config_changes hash
## Used ONLY with lists belonging to a family.
sub get_config_changes {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    unless ($self->family_name) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'there is no family_name for this list %s.', $self);
        return undef;
    }

    ## load config_changes
    my $time_file = (stat($self->dir . '/config_changes'))[9];
    unless (defined $self->{'config_changes'}
        && ($self->{'config_changes'}{'mtime'} >= $time_file)) {
        unless ($self->{'config_changes'} =
            $self->_load_config_changes_file()) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Impossible to load file config_changes from list %s', $self);
            return undef;
        }
    }
    return $self->{'config_changes'};
}

## update file config_changes if the list belongs to a family by
#  writing the $what(file or param) name
sub update_config_changes {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my $self = shift;
    my $what = shift;

    # one param or a ref on array of param
    my $name = shift;

    unless ($self->family_name) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'there is no family_name for this list %s.', $self);
        return undef;
    }
    unless (($what eq 'file') || ($what eq 'param')) {
        $main::logger->do_log(Sympa::Logger::ERR,
            '%s is wrong : must be "file" or "param".', $what);
        return undef;
    }

    # status parameter isn't updating set in config_changes
    if (($what eq 'param') && ($name eq 'status')) {
        return 1;
    }

    ## load config_changes
    my $time_file = (stat($self->dir . '/config_changes'))[9];
    unless (defined $self->{'config_changes'}
        && ($self->{'config_changes'}{'mtime'} >= $time_file)) {
        unless ($self->{'config_changes'} =
            $self->_load_config_changes_file()) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Impossible to load file config_changes from list %s', $self);
            return undef;
        }
    }

    if (ref($name) eq 'ARRAY') {
        foreach my $n (@{$name}) {
            $self->{'config_changes'}{$what}{$n} = 1;
        }
    } else {
        $self->{'config_changes'}{$what}{$name} = 1;
    }

    $self->_save_config_changes_file();

    return 1;
}

## return a hash of config_changes file
sub _load_config_changes_file {
    ##$main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    my $config_changes = {};

    unless (-e $self->dir . '/config_changes') {
        $main::logger->do_log(Sympa::Logger::ERR,
            'No file %s/config_changes. Assuming no changes', $self->dir);
        return $config_changes;
    }

    unless (open(FILE, $self->dir . '/config_changes')) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'File %s/config_changes exists, but unable to open it: %s',
            $self->dir, $ERRNO);
        return undef;
    }

    while (<FILE>) {

        next if /^\s*(\#.*|\s*)$/;

        if (/^param\s+(.+)\s*$/) {
            $config_changes->{'param'}{$1} = 1;

        } elsif (/^file\s+(.+)\s*$/) {
            $config_changes->{'file'}{$1} = 1;

        } else {
            $main::logger->do_log(Sympa::Logger::ERR, 'bad line : %s', $_);
            next;
        }
    }
    close FILE;

    $config_changes->{'mtime'} = (stat($self->dir . '/config_changes'))[9];

    return $config_changes;
}

## save config_changes file in the list directory
sub _save_config_changes_file {
    ##$main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    unless ($self->family_name) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'there is no family_name for this list %s.', $self);
        return undef;
    }
    unless (open(FILE, '>', $self->dir . '/config_changes')) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'unable to create file %s/config_changes : %s',
            $self->dir, $ERRNO);
        return undef;
    }

    foreach my $what ('param', 'file') {
        foreach my $name (keys %{$self->{'config_changes'}{$what}}) {
            print FILE "$what $name\n";
        }
    }
    close FILE;

    return 1;
}

## Returns the list parameter value from $list
#  the parameter is simple ($param) or composed ($param & $minor_param)
#  the value is a scalar or a ref on an array of scalar
# (for parameter digest : only for days)
sub get_param_value {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my $self        = shift;
    my $param       = shift;
    my $as_arrayref = shift || 0;
    my $pinfo       = $self->robot->list_params;
    my $minor_param;
    my $value;

    if ($param =~ /^([\w-]+)\.([\w-]+)$/) {
        $param       = $1;
        $minor_param = $2;
    }

    ## Multiple parameter (owner, custom_header, ...)
    if (ref($self->$param) eq 'ARRAY' and !$pinfo->{$param}{'split_char'}) {
        my @values;
        foreach my $elt (@{$self->$param}) {
            my $val =
                _get_single_param_value($pinfo, $elt, $param, $minor_param);
            push @values, $val if defined $val;
        }
        $value = \@values;
    } else {
        $value = _get_single_param_value($pinfo, $self->$param, $param,
            $minor_param);
        if ($as_arrayref) {
            return [$value] if defined $value;
            return [];
        }
    }
    return $value;
}

## Returns the single list parameter value from struct $p, with $key entrie,
#  $k is optionnal
#  the single value can be a ref on a list when the parameter value is a list
sub _get_single_param_value {
    my $pinfo = shift;
    my $p     = shift;
    my $key   = shift;
    my $k     = shift;

    if (   defined($pinfo->{$key}{'scenario'})
        or defined($pinfo->{$key}{'task'})) {
        return $p->{'name'};
    } elsif (ref($pinfo->{$key}{'file_format'})) {
        if (defined $pinfo->{$key}{'file_format'}{$k}{'scenario'}) {
            return $p->{$k}{'name'};
        } elsif ($pinfo->{$key}{'file_format'}{$k}{'occurrence'} =~ /n$/
            and $pinfo->{$key}{'file_format'}{$k}{'split_char'}) {
            return $p->{$k};    # ref on an array
        } else {
            return $p->{$k};
        }
    } else {
        if (    $pinfo->{$key}{'occurrence'} =~ /n$/
            and $pinfo->{$key}{'split_char'}) {
            return $p;          # ref on an array
        } elsif ($key eq 'digest') {
            return $p->{'days'};    # ref on an array
        } else {
            return $p;
        }
    }
}

###########################################################################
#                       FUNCTIONS FOR MESSAGE SENDING                     #
###########################################################################
#                                                                         #
#  -list distribution
#  -template sending                                                      #
#  -service messages
#  -notification sending(listmaster, owner, editor, user)                 #
#                                                                         #

###################   LIST DISTRIBUTION  ##################################

####################################################
# distribute_msg
####################################################
#  prepares and distributes a message to a list, do
#  some of these :
#  stats, hidding sender, adding custom subject,
#  archive, changing the replyto, removing headers,
#  adding headers, storing message in digest
#
#
# IN : -$self (+): ref(List)
#      -$message (+): ref(Message)
#      -$apply_dkim_signature : on | off
# OUT : -$numsmtp : number of sendmail process
####################################################
sub distribute_msg {
    my $self  = shift;
    my %param = @_;

    my $message              = $param{'message'};
    my $apply_dkim_signature = $param{'apply_dkim_signature'};

    $main::logger->do_log(
        Sympa::Logger::DEBUG2,
        '(%s, msg=%s, size=%s, filename=%s, smime_crypted=%s, apply_dkim_signature=%s)',
        $self,
        $message,
        $message->get_size(),
        $message->as_file(),
        $message->is_encrypted(),
        $apply_dkim_signature
    );

    my $hdr = $message->as_entity()->head;

    ## Update the stats, and returns the new X-Sequence, if any.
    my $sequence = $self->update_stats($message->get_size());

    ## Loading info msg_topic file if exists, add X-Sympa-Topic
    my $info_msg_topic;
    if ($self->is_there_msg_topic()) {
        my $msg_id = $message->get_msg_id;
        $info_msg_topic = $self->load_msg_topic($msg_id);

        # add X-Sympa-Topic header
        if (ref($info_msg_topic) eq "HASH") {
            $message->add_topic($info_msg_topic->{'topic'});
        }
    }

    ## Hide the sender if the list is anonymoused
    if ($self->anonymous_sender) {
        foreach my $field (@{Sympa::Site->anonymous_header_fields || []}) {
            $hdr->delete($field);
        }
        $hdr->add('From', $self->anonymous_sender);
        my $new_id = '<' . $self->name . '.' . $sequence . '@anonymous' . '>';
        $hdr->add('Message-id', $new_id);

        # rename update topic content id of the message
        if ($info_msg_topic) {
            my $topicspool = Sympa::Spool::File::Message->new(
                name      => 'topic',
                directory => Sympa::Site->queuetopic()
            );
            rename(
                "$topicspool->{'dir'}/$info_msg_topic->{'filename'}",
                "$topicspool->{'dir'}/$self->->get_id.$new_id"
            );
            $info_msg_topic->{'filename'} = "$self->->get_id.$new_id";
        }
        ## TODO remove S/MIME and PGP signature if any
    }

    ## Add Custom Subject
    if ($self->custom_subject) {
        my $subject_field = $message->get_decoded_subject();
        $subject_field =~
            s/^\s*(.*)\s*$/$1/;    ## Remove leading and trailing blanks

        ## Search previous subject tagging in Subject
        my $custom_subject = $self->custom_subject;

        ## tag_regexp will be used to remove the custom subject if it is
        ## already present in the message subject.
        ## Remember that the value of custom_subject can be
        ## "dude number [%list.sequence"%]" whereas the actual subject will
        ## contain "dude number 42".
        my $list_name_escaped = $self->name;
        $list_name_escaped =~ s/(\W)/\\$1/g;
        my $tag_regexp = $custom_subject;
        ## cleanup, just in case dangerous chars were left
        $tag_regexp =~ s/([^\w\s\x80-\xFF])/\\$1/g;
        ## Replaces "[%list.sequence%]" by "\d+"
        $tag_regexp =~ s/\\\[\\\%\s*list\\\.sequence\s*\\\%\\\]/\\d+/g;
        ## Replace "[%list.name%]" by escaped list name
        $tag_regexp =~
            s/\\\[\\\%\s*list\\\.name\s*\\\%\\\]/$list_name_escaped/g;
        ## Replaces variables declarations by "[^\]]+"
        $tag_regexp =~ s/\\\[\\\%\s*[^]]+\s*\\\%\\\]/[^]]+/g;
        ## Takes spaces into account
        $tag_regexp =~ s/\s+/\\s+/g;

        ## Add subject tag
        #FIXME: Check parse error
        $message->as_entity()->head->delete('Subject');
        my $parsed_tag;
        Sympa::Template::parse_tt2(
            {   'list' => {
                    'name'     => $self->name,
                    'sequence' => $self->stats->[0]
                }
            },
            [$custom_subject],
            \$parsed_tag
        );

        ## If subject is tagged, replace it with new tag
        ## Splitting the subject in two parts :
        ##   - what will be before the custom subject (probably some "Re:")
        ##   - what will be after it : the original subject sent to the list.
        ## The custom subject is not kept.
        my $before_tag;
        my $after_tag;
        if ($custom_subject =~ /\S/) {
            $subject_field =~ s/\s*\[$tag_regexp\]\s*/ /;
        }
        $subject_field =~ s/\s+$//;

        # truncate multiple "Re:" and equivalents.
        my $re_regexp = Sympa::Tools::get_regexp('re');
        if ($subject_field =~ /^\s*($re_regexp\s*)($re_regexp\s*)*/) {
            ($before_tag, $after_tag) = ($1, $POSTMATCH);    #'
        } else {
            ($before_tag, $after_tag) = ('', $subject_field);
        }

        ## Encode subject using initial charset

        ## Don't try to encode the subject if it was not originally encoded.
        my $charset = $message->get_subject_charset();
        if ($charset) {
            $subject_field = MIME::EncWords::encode_mimewords(
                Encode::decode_utf8(
                    $before_tag . '[' . $parsed_tag . '] ' . $after_tag
                ),
                Charset     => $charset,
                Encoding    => 'A',
                Field       => 'Subject',
                Replacement => 'FALLBACK'
            );
        } else {
            $subject_field =
                $before_tag . ' '
                . MIME::EncWords::encode_mimewords(
                Encode::decode_utf8('[' . $parsed_tag . ']'),
                Charset  => Site->get_charset,
                Encoding => 'A',
                Field    => 'Subject'
                )
                . ' '
                . $after_tag;
        }
        $message->as_entity()->head->add('Subject', $subject_field);
    }

    ## Prepare tracking if list config allow it
    my $apply_tracking = 'off';

    $apply_tracking = 'dsn'
        if $self->tracking->{'delivery_status_notification'} eq 'on';
    $apply_tracking = 'mdn'
        if $self->tracking->{'message_delivery_notification'} eq 'on';
    $apply_tracking = 'mdn'
        if $self->tracking->{'message_delivery_notification'} eq 'on_demand'
            and $message->get_header('Disposition-Notification-To');

    if ($apply_tracking ne 'off') {

        # remove notification request because a new one will be inserted if
        # needed
        $hdr->delete('Disposition-Notification-To');
    }

    ## Remove unwanted headers if present.
    if ($self->remove_headers) {
        foreach my $field (@{$self->remove_headers}) {
            $hdr->delete($field);
        }
    }

    ## Archives

    $self->archive_msg($message);

    ## Change the reply-to header if necessary.
    if ($self->reply_to_header) {
        unless ($message->get_header('Reply-To')
            and $self->reply_to_header->{'apply'} ne 'forced') {
            my $reply;

            $hdr->delete('Reply-To');

            #FIXME: use get_sender_email() ?
            my $sender_address = $message->get_header('From');

            if ($self->reply_to_header->{'value'} eq 'list') {
                $reply = $self->get_address();
            } elsif ($self->reply_to_header->{'value'} eq 'sender') {
                $reply = $sender_address;
            } elsif ($self->reply_to_header->{'value'} eq 'all') {
                $reply = $self->get_address() . ', ' . $sender_address;
            } elsif ($self->reply_to_header->{'value'} eq 'other_email') {
                $reply = $self->reply_to_header->{'other_email'};
            }

            $hdr->add('Reply-To', $reply) if $reply;
        }
    }

    ## Add useful headers
    $hdr->add('X-Loop',     $self->get_address());
    $hdr->add('X-Sequence', $sequence);
    $hdr->add('Errors-to',  $self->get_address('return_path'));
    $hdr->add('Precedence', 'list');
    $hdr->add('Precedence', 'bulk');

    # The Sender: header should be added at least for DKIM compatibility
    $hdr->add('Sender',       $self->get_address('owner'));
    $hdr->add('X-no-archive', 'yes');

    foreach my $i (@{$self->custom_header}) {
        $hdr->add($1, $2) if $i =~ /^([\S\-\:]*)\s(.*)$/;
    }

    ## Add RFC 2919 header field
    if ($message->get_header('List-Id')) {
        $main::logger->do_log(
            Sympa::Logger::NOTICE,
            'Found List-Id: %s',
            $message->get_header('List-Id')
        );
        $hdr->delete('List-Id');
    }
    $self->add_list_header($hdr, 'id');

    ## Add RFC 2369 header fields
    foreach my $field (
        @{$self->robot->list_params->{'rfc2369_header_fields'}->{'format'}}) {
        if (scalar grep { $_ eq $field } @{$self->rfc2369_header_fields}) {
            $self->add_list_header($hdr, $field);
        }
    }

    ## Add RFC5064 Archived-At SMTP header field
    $self->add_list_header($hdr, 'archived_at');

    ## Remove outgoing header fields
    ## Useful to remove some header fields that Sympa has set
    if ($self->remove_outgoing_headers) {
        foreach my $field (@{$self->remove_outgoing_headers}) {
            $hdr->delete($field);
        }
    }

    ## store msg in digest if list accept digest mode (encrypted message can't
    ## be included in digest)
    if ($self->is_digest() and not $message->is_encrypted()) {
        $self->store_digest($message);
    }

    ## Synchronize list members, required if list uses include sources
    ## unless sync_include has been performed recently.
    if ($self->has_include_data_sources()) {
        $self->on_the_fly_sync_include('use_ttl' => 1);
    }

    ## Blindly send the message to all users.
    my $numsmtp = $self->send_msg(
        'message'              => $message,
        'apply_dkim_signature' => $apply_dkim_signature,
        'apply_tracking'       => $apply_tracking
    );
    $self->savestats() if (defined($numsmtp));
    return $numsmtp;
}

####################################################
# send_msg_digest
####################################################
# Send a digest message to the subscribers with
# reception digest, digestplain or summary
#
# IN : -$self(+) : ref(List)
#      $message_in_spool : an digest spool entry in database
# OUT : 1 : ok
#       | 0 if no subscriber for sending digest
#       | undef
####################################################
sub send_msg_digest {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self       = shift;
    my $messagekey = shift;

    ## Create the list of subscribers in various digest modes
    return 0 unless ($self->get_lists_of_digest_recipients());

    my $digestspool = Sympa::Spool::File::Message->new(
        name      => 'digest',
        directory => Sympa::Site->queuedigest(),
        selector  => {'messagekey' => $messagekey}
    );
    $self->split_spooled_digest_to_messages(
        {'message_in_spool' => $digestspool->next});
    $self->prepare_messages_for_digest();
    $self->prepare_digest_parameters();
    $self->do_digest_sending();

    delete $self->{'digest'};
    $digestspool->remove({'messagekey' => $messagekey});
    return 1;
}

sub get_lists_of_digest_recipients {
    my $self  = shift;
    my $param = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG,
        'Getting list of digest recipients for list %s',
        $self->get_id);
    $self->{'digest'}{'tabrcpt'}        = [];
    $self->{'digest'}{'tabrcptsummary'} = [];
    $self->{'digest'}{'tabrcptplain'}   = [];
    for (
        my $user = $self->get_first_list_member();
        $user;
        $user = $self->get_next_list_member()
        ) {
        my $user_data = $self->user('member', $user->{'email'}) || undef;
        ## test to know if the rcpt suspended her subscription for this list
        ## if yes, don't send the message
        if ($user_data->{'suspend'} eq '1') {
            if (($user_data->{'startdate'} <= time)
                && (   (time <= $user_data->{'enddate'})
                    || (!$user_data->{'enddate'}))
                ) {
                next;
            } elsif (($user_data->{'enddate'} < time)
                && ($user_data->{'enddate'})) {
                ## If end date is < time, update the BDD by deleting the
                ## suspending user's data
                $self->restore_suspended_subscription($user->{'email'});
            }
        }
        if ($user->{'reception'} eq "digest") {
            push @{$self->{'digest'}{'tabrcpt'}}, $user->{'email'};

        } elsif ($user->{'reception'} eq "summary") {
            ## Create the list of subscribers in summary mode
            push @{$self->{'digest'}{'tabrcptsummary'}}, $user->{'email'};

        } elsif ($user->{'reception'} eq "digestplain") {
            push @{$self->{'digest'}{'tabrcptplain'}}, $user->{'email'};
        }
    }
    if (    ($#{$self->{'digest'}{'tabrcpt'}} == -1)
        and ($#{$self->{'digest'}{'tabrcptsummary'}} == -1)
        and ($#{$self->{'digest'}{'tabrcptplain'}} == -1)) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'No subscriber for sending digest in list %s', $self);
        return 0;
    }
    return 1;
}

#FIXME: This method should be moved to the Class of its own.
sub split_spooled_digest_to_messages {
    my $self  = shift;
    my $param = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Splitting spooled digest into message objects for list %s',
        $self->get_id);
    my $message_in_spool = $param->{'message_in_spool'};
    $self->{'digest'}{'list_of_mail'} = [];
    my $separator = "\n\n" . Sympa::Tools::get_separator() . "\n\n";
    my @messages_as_string =
        split(/$separator/, $message_in_spool->{'messageasstring'});
    splice @messages_as_string, 0, 1;

    foreach my $message_as_string (@messages_as_string) {
        my $message = Sympa::Message->new(
            'messageasstring' => $message_as_string,
            'noxsymnpato'     => 1
        );
        next unless $message;
        push @{$self->{'digest'}{'list_of_mail'}}, $message;
    }

    ## Deletes the introduction part
    return 1;
}

sub prepare_messages_for_digest {
    my $self  = shift;
    my $param = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Preparing messages for digest for list %s',
        $self->get_id);
    $self->{'digest'}{'all_msg'} = [];
    return undef unless ($self->{'digest'}{'list_of_mail'});
    foreach my $i (0 .. $#{$self->{'digest'}{'list_of_mail'}}) {
        my $mail    = ${$self->{'digest'}{'list_of_mail'}}[$i];
        my $subject = $mail->decode_header('Subject');
        my $from    = $mail->decode_header('From');
        my $date    = $mail->decode_header('Date');

        my $msg = {};
        $msg->{'id'}      = $i + 1;
        $msg->{'subject'} = $subject;
        $msg->{'from'}    = $from;
        $msg->{'date'}    = $date;

        $msg->{'full_msg'} = $mail->as_string();
        $msg->{'body'}     = $mail->as_entity()->body_as_string();
        $msg->{'plain_body'} = Sympa::Tools::Message::plain_body_as_string($mail->as_entity());

        ## Should be extracted from Date:
        $msg->{'month'} = POSIX::strftime("%Y-%m", localtime(time));
        $msg->{'message_id'} =
            Sympa::Tools::clean_msg_id($mail->get_header('Message-Id'));

        ## Clean up Message-ID
        $msg->{'message_id'} =
            Sympa::Tools::escape_chars($msg->{'message_id'});

        #push @{$param->{'msg_list'}}, $msg ;
        push @{$self->{'digest'}{'all_msg'}}, $msg;
    }
    $self->{'digest'}{'group_of_msg'} = [];
    ## Split messages into groups of digest_max_size size
    while (@{$self->{'digest'}{'all_msg'}}) {
        my @group = splice @{$self->{'digest'}{'all_msg'}}, 0,
            $self->digest_max_size;
        push @{$self->{'digest'}{'group_of_msg'}}, \@group;
    }
    return 1;
}

sub prepare_digest_parameters {
    my $self  = shift;
    my $param = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Preparing digest parameters for list %s',
        $self->get_id);
    $self->{'digest'}{'template_params'} = {
        'replyto'          => $self->get_address('owner'),
        'to'               => $self->get_address(),
        'table_of_content' => $main::language->gettext("Table of contents:"),
        'boundary1'        => '----------=_'
            . Sympa::Tools::get_message_id($self->domain),
        'boundary2' => '----------=_'
            . Sympa::Tools::get_message_id($self->domain),
    };
    if ($self->get_reply_to() =~ /^list$/io) {
        $self->{'digest'}{'template_params'}{'replyto'} = "$param->{'to'}";
    }
    my @now = localtime(time);
    $self->{'digest'}{'template_params'}{'datetime'} =
        $main::language->gettext_strftime( "%a, %d %b %Y %H:%M:%S", @now);
    $self->{'digest'}{'template_params'}{'date'} =
        $main::language->gettext_strftime("%a, %d %b %Y", @now);
    $self->{'digest'}{'template_params'}{'current_group'} = 0;
    $self->{'digest'}{'template_params'}{'total_group'} =
        $#{$self->{'digest'}{'group_of_msg'}} + 1;
    return 1;
}

sub do_digest_sending {
    my $self = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Actually sending digest for list %s',
        $self->get_id);
    foreach my $group (@{$self->{'digest'}{'group_of_msg'}}) {

        $self->{'digest'}{'template_params'}{'current_group'}++;
        $self->{'digest'}{'template_params'}{'msg_list'} = $group;
        $self->{'digest'}{'template_params'}{'auto_submitted'} =
            'auto-forwarded';
        ## Prepare Digest
        if ($#{$self->{'digest'}{'tabrcpt'}} > -1) {
            ## Send digest
            $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sending MIME digest');
            unless (
                $self->send_file(
                    'digest',
                    $self->{'digest'}{'tabrcpt'},
                    $self->{'digest'}{'template_params'}
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::NOTICE,
                    'Unable to send template "digest" to %s list subscribers',
                    $self
                );
            }
        }

        ## Prepare Plain Text Digest
        if ($#{$self->{'digest'}{'tabrcptplain'}} > -1) {
            ## Send digest-plain
            $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sending plain digest');
            unless (
                $self->send_file(
                    'digest_plain',
                    $self->{'digest'}{'tabrcptplain'},
                    $self->{'digest'}{'template_params'}
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::NOTICE,
                    'Unable to send template "digest_plain" to %s list subscribers',
                    $self
                );
            }
        }

        ## send summary
        if ($#{$self->{'digest'}{'tabrcptsummary'}} > -1) {
            $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sending summary digest');
            unless (
                $self->send_file(
                    'summary',
                    $self->{'digest'}{'tabrcptsummary'},
                    $self->{'digest'}{'template_params'}
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::NOTICE,
                    'Unable to send template "summary" to %s list subscribers',
                    $self
                );
            }
        }
    }
}

=over 4

=item send_dsn

Sends an delivery status notification (DSN).
See L<Site/send_dsn>.

=back

=cut

####################################################
# send_file
####################################################
#  Send a message to user(s), relative to a list.
#  Find the tt2 file according to $tpl, set up
#  $data for the next parsing (with $context and
#  configuration)
#  Message is signed if the list has a key and a
#  certificate
#
# IN : -$self (+): ref(List)
#      -$tpl (+): template file name (file.tt2),
#         without tt2 extension
#      -$who (+): SCALAR |ref(ARRAY) - recipient(s)
#      -$context : ref(HASH) - for the $data set up
#         to parse file tt2, keys can be :
#         -user : ref(HASH), keys can be :
#           -email
#           -lang
#           -password
#         -auto_submitted auto-generated|auto-replied|auto-forwarded
#         -...
# OUT : 1 | undef
####################################################

####################################################
# send_msg
####################################################
# selects subscribers according to their reception
# mode in order to distribute a message to a list
# and sends the message to them. For subscribers in reception mode 'mail',
# and in a msg topic context, selects only one who are subscribed to the topic
# of the message.
#
#
# IN : -$self (+): ref(List)
#      -$message (+): ref(Message)
# OUT : -$numsmtp : number of sendmail process
#       | 0 : no subscriber for sending message in list
#       | undef
####################################################
sub send_msg {

    my $self  = shift;
    my %param = @_;

    my $apply_dkim_signature = $param{'apply_dkim_signature'};
    my $apply_tracking       = $param{'apply_tracking'};
    my $message              = $param{'message'};
    unless (defined $message && ref($message) eq 'Sympa::Message') {
        $main::logger->do_log(Sympa::Logger::ERR, 'Invalid message paramater');
        return undef;
    }
    $message->check_message_structure;

    $main::logger->do_log(
        Sympa::Logger::DEBUG2,
        'Sympa::List::send_msg(filename = %s, smime_crypted = %s,apply_dkim_signature = %s )',
        $message->as_file(),
        $message->is_encrypted(),
        $apply_dkim_signature
    );
    my $original_message_id = $message->get_msg_id;
    my $name                = $self->name;
    my $robot               = $self->domain;

    my $total = $self->get_real_total;
    unless ($total > 0) {
        $main::logger->do_log(Sympa::Logger::INFO, 'No subscriber in list %s', $name);
        return 0;
    }

    #FIXME: get_sender_email() ?
    my $sender_line = $message->get_header('From');
    my @sender_hdr  = Mail::Address->parse($sender_line);
    foreach my $email (@sender_hdr) {
        $message->{'sender_hash'}{lc($email->address)} = 1;
    }

    ## Bounce rate
    my $rate = $self->get_total_bouncing() * 100 / $total;
    if ($rate > $self->bounce->{'warn_rate'}) {
        unless ($self->send_notify_to_owner('bounce_rate', {'rate' => $rate}))
        {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Unable to send notify "bounce_rate" to %s listowner', $self);
        }
    }

    ## Who is the envelope sender?
    my $from     = $self->get_address('return_path');
    my $nbr_smtp = 0;
    my $nbr_verp = 0;

    # prepare VERP parameter
    my $verp_rate = $self->verp_rate;

    # force VERP if tracking is requested.
    $verp_rate = '100%'
        if (($apply_tracking eq 'dsn') || ($apply_tracking eq 'mdn'));

    my $xsequence = $self->stats->[0];

    my $dkim_parameters;

    # prepare dkim parameters
    if ($apply_dkim_signature eq 'on') {
        $dkim_parameters = $self->get_dkim_parameters();
    }

    # separate subscribers depending on user reception option and also if VERP
    # a dicovered some bounce for them.
    return 0 unless ($self->get_list_members_per_mode($message));
    my $topics_updated_total = 0;
    foreach my $mode (sort keys %{$message->{'rcpts_by_mode'}}) {
        $topics_updated_total +=
            $self->filter_recipients_by_topics($message, $mode, $verp_rate,
            $xsequence);
    }
    return 0 unless ($topics_updated_total);
    my ($tag_verp, $tag_mode) = find_packet_to_tag_as_last($message);

    foreach my $mode (sort keys %{$message->{'rcpts_by_mode'}}) {
        my $new_message = dclone $message;
        delete $new_message->{'messagekey'};    #FIXME: required?
        $new_message->prepare_message_according_to_mode($mode);
        my $verp = 'off';
        if ($message->{'rcpts_by_mode'}{$mode}{'noverp'}) {
            my $result = $main::mailer->distribute_message(
                'message' => $new_message,
                'rcpt'    => $message->{'rcpts_by_mode'}{$mode}{'noverp'},
                'list'    => $self,
                'verp'    => $verp,
                'dkim'    => $dkim_parameters,
                'tag_as_last' =>
                    (($mode eq $tag_mode) && ($tag_verp eq 'noverp'))
            );
            unless (defined $result) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Sympa::List::send_msg, could not send message to distribute from $from (verp disabled)"
                );
                return undef;
            }
            $nbr_smtp += $result;
        }

        $verp = 'on';

        if (($apply_tracking eq 'dsn') || ($apply_tracking eq 'mdn')) {
            $verp = $apply_tracking;
            Sympa::Tracking::db_init_notification_table(
                $self,
                'msgid' => $original_message_id,

                # what ever the message is transformed because of the
                # reception option, tracking use the original message id
                'rcpt' => $message->{'rcpts_by_mode'}{$mode}{'verp'},
                'reception_option' => $mode
            );
        }

        #  ignore those reception option where mail must not ne sent
        next if ($mode =~ /nomail|summary|digest|digestplain/);

        if ($message->{'rcpts_by_mode'}{$mode}{'verp'}) {
            ## prepare VERP sending.
            my $result = $main::mailer->distribute_message(
                'message' => $new_message,
                'rcpt'    => $message->{'rcpts_by_mode'}{$mode}{'verp'},
                'list'    => $self,
                'verp'    => $verp,
                'dkim'    => $dkim_parameters,
                'tag_as_last' =>
                    (($mode eq $tag_mode) && ($tag_verp eq 'verp'))
            );
            unless (defined $result) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Sympa::List::send_msg, could not send message to distribute from $from (verp enabled)"
                );
                return undef;
            }
            $nbr_smtp += $result;
            $nbr_verp += $result;
        }
    }
    return $nbr_smtp;
}

sub get_list_members_per_mode {
    my $self    = shift;
    my $message = shift;
    my (@tabrcpt,                  @tabrcpt_verp,
        @tabrcpt_notice,           @tabrcpt_notice_verp,
        @tabrcpt_txt,              @tabrcpt_txt_verp,
        @tabrcpt_html,             @tabrcpt_html_verp,
        @tabrcpt_url,              @tabrcpt_url_verp,
        @tabrcpt_digestplain_verp, @tabrcpt_digest_verp,
        @tabrcpt_summary_verp,     @tabrcpt_nomail_verp
    );

    for (
        my $user = $self->get_first_list_member();
        $user;
        $user = $self->get_next_list_member()
        ) {
        unless ($user->{'email'}) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Skipping user with no email address in list %s',
                $self->get_id);
            next;
        }
        my $user_data = $self->user('member', $user->{'email'}) || undef;
        ## test to know if the rcpt suspended her subscription for this list
        ## if yes, don't send the message
        if (defined $user_data && $user_data->{'suspend'} eq '1') {
            if (($user_data->{'startdate'} <= time)
                && (   (time <= $user_data->{'enddate'})
                    || (!$user_data->{'enddate'}))
                ) {
                push @tabrcpt_nomail_verp, $user->{'email'};
                next;
            } elsif (($user_data->{'enddate'} < time)
                && ($user_data->{'enddate'})) {
                ## If end date is < time, update the BDD by deleting the
                ## suspending user's data
                $self->restore_suspended_subscription($user->{'email'});
            }
        }
        if ($user->{'reception'} eq 'digestplain') {

            # digest digestplain, nomail and summary reception option are
            # initialized for tracking feature only
            push @tabrcpt_digestplain_verp, $user->{'email'};
        } elsif ($user->{'reception'} eq 'digest') {
            push @tabrcpt_digest_verp, $user->{'email'};
            $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s digest',
                $user->{'email'});
        } elsif ($user->{'reception'} eq 'summary') {
            push @tabrcpt_summary_verp, $user->{'email'};
            $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s summary',
                $user->{'email'});
        } elsif ($user->{'reception'} eq 'nomail') {
            push @tabrcpt_nomail_verp, $user->{'email'};
            $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s nomail',
                $user->{'email'});
        } elsif ($user->{'reception'} eq 'notice') {
            if ($user->{'bounce_address'}) {
                push @tabrcpt_notice_verp, $user->{'email'};
                $main::logger->do_log(Sympa::Logger::DEBUG3,
                    'user %s notice and verp',
                    $user->{'email'});
            } else {
                push @tabrcpt_notice, $user->{'email'};
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s notice',
                    $user->{'email'});
            }
        } elsif (
            $message->is_encrypted()
            && (!-r Sympa::Site->ssl_cert_dir . '/'
                . Sympa::Tools::escape_chars($user->{'email'})
                && !-r Sympa::Site->ssl_cert_dir . '/'
                . Sympa::Tools::escape_chars($user->{'email'} . '@enc'))
            ) {
            $main::logger->do_log(Sympa::Logger::DEBUG3, 'No certificate for user %s',
                $user->{'email'});
            ## Missing User certificate
            my $subject = $message->get_header('Subject');
            my $sender  = $message->get_header('From');      #FIXME
            unless (
                $self->send_file(
                    'x509-user-cert-missing',
                    $user->{'email'},
                    {   'mail' =>
                            {'subject' => $subject, 'sender' => $sender},
                        'auto_submitted' => 'auto-generated'
                    }
                )
                ) {
                $main::logger->do_log(Sympa::Logger::NOTICE,
                    "Unable to send template 'x509-user-cert-missing' to $user->{'email'}"
                );
            }
        } elsif (!$message->is_signed
            && $message->has_text_part
            && $user->{'reception'} eq 'txt') {
            if ($user->{'bounce_address'}) {
                push @tabrcpt_txt_verp, $user->{'email'};
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s txt and verp',
                    $user->{'email'});
            } else {
                push @tabrcpt_txt, $user->{'email'};
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s txt',
                    $user->{'email'});
            }
        } elsif (!$message->is_signed
            && $message->has_html_part
            && $user->{'reception'} eq 'html') {
            if ($user->{'bounce_address'}) {
                push @tabrcpt_html_verp, $user->{'email'};
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s html and verp',
                    $user->{'email'});
            } else {
                push @tabrcpt_html, $user->{'email'};
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s html',
                    $user->{'email'});
            }
        } elsif (!$message->is_signed
            && $message->has_attachments
            && $user->{'reception'} eq 'urlize') {
            if ($user->{'bounce_address'}) {
                push @tabrcpt_url_verp, $user->{'email'};
                $main::logger->do_log(Sympa::Logger::DEBUG3,
                    'user %s urlize and verp',
                    $user->{'email'});
            } else {
                push @tabrcpt_url, $user->{'email'};
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s urlize',
                    $user->{'email'});
            }
        } else {
            if ($user->{'bounce_score'}) {
                push @tabrcpt_verp, $user->{'email'}
                    unless ($message->{'sender_hash'}{$user->{'email'}})
                    && ($user->{'reception'} eq 'not_me');
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s mail and verp',
                    $user->{'email'});
            } else {
                push @tabrcpt, $user->{'email'}
                    unless ($message->{'sender_hash'}{$user->{'email'}})
                    && ($user->{'reception'} eq 'not_me');
                $main::logger->do_log(Sympa::Logger::DEBUG3, 'user %s mail',
                    $user->{'email'});
            }
        }
    }
    unless (@tabrcpt
        || @tabrcpt_notice
        || @tabrcpt_txt
        || @tabrcpt_html
        || @tabrcpt_url
        || @tabrcpt_verp
        || @tabrcpt_notice_verp
        || @tabrcpt_txt_verp
        || @tabrcpt_html_verp
        || @tabrcpt_url_verp) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'No subscriber for sending msg in list %s',
            $self->get_id);
        return 0;
    }
    $message->{'rcpts_by_mode'}{'mail'}{'noverp'} = \@tabrcpt
        if ($#tabrcpt > -1);
    $message->{'rcpts_by_mode'}{'mail'}{'verp'} = \@tabrcpt_verp
        if ($#tabrcpt_verp > -1);
    $message->{'rcpts_by_mode'}{'notice'}{'noverp'} = \@tabrcpt_notice
        if ($#tabrcpt_notice > -1);
    $message->{'rcpts_by_mode'}{'notice'}{'verp'} = \@tabrcpt_notice_verp
        if ($#tabrcpt_notice_verp > -1);
    $message->{'rcpts_by_mode'}{'txt'}{'noverp'} = \@tabrcpt_txt
        if ($#tabrcpt_txt > -1);
    $message->{'rcpts_by_mode'}{'txt'}{'verp'} = \@tabrcpt_txt_verp
        if ($#tabrcpt_txt_verp > -1);
    $message->{'rcpts_by_mode'}{'html'}{'noverp'} = \@tabrcpt_html
        if ($#tabrcpt_html > -1);
    $message->{'rcpts_by_mode'}{'html'}{'verp'} = \@tabrcpt_html_verp
        if ($#tabrcpt_html_verp > -1);
    $message->{'rcpts_by_mode'}{'url'}{'noverp'} = \@tabrcpt_url
        if ($#tabrcpt_url > -1);
    $message->{'rcpts_by_mode'}{'url'}{'verp'} = \@tabrcpt_url_verp
        if ($#tabrcpt_url_verp > -1);
    $message->{'rcpts_by_mode'}{'nomail'}{'verp'} = \@tabrcpt_nomail_verp
        if ($#tabrcpt_nomail_verp > -1);
    $message->{'rcpts_by_mode'}{'summary'}{'verp'} = \@tabrcpt_summary_verp
        if ($#tabrcpt_summary_verp > -1);
    $message->{'rcpts_by_mode'}{'digest'}{'verp'} = \@tabrcpt_digest_verp
        if ($#tabrcpt_digest_verp > -1);
    $message->{'rcpts_by_mode'}{'digestplain'}{'verp'} =
        \@tabrcpt_digestplain_verp
        if ($#tabrcpt_digestplain_verp > -1);
    return 1;
}

sub filter_recipients_by_topics {
    my $self      = shift;
    my $message   = shift;
    my $mode      = shift;
    my $verp_rate = shift;
    my $xsequence = shift;
    ## TOPICS
    my @selected_tabrcpt;
    my @possible_verptabrcpt;
    if ($self->is_there_msg_topic()) {
        @selected_tabrcpt =
            $self->select_list_members_for_topic(
                $message->get_topic() || '',
                $message->{'rcpts_by_mode'}{$mode}{'noverp'}
            );
        @possible_verptabrcpt =
            $self->select_list_members_for_topic(
                $message->get_topic() || '',
            $message->{'rcpts_by_mode'}{$mode}{'verp'}
        );
    } else {
        @selected_tabrcpt = @{$message->{'rcpts_by_mode'}{$mode}{'noverp'}};
        @possible_verptabrcpt = @{$message->{'rcpts_by_mode'}{$mode}{'verp'}};
    }

    ## Preparing VERP recipients.
    my @verp_selected_tabrcpt =
        extract_verp_rcpt($verp_rate, $xsequence, \@selected_tabrcpt,
        \@possible_verptabrcpt);

    if ($#selected_tabrcpt > -1) {
        $message->{'rcpts_by_mode'}{$mode}{'noverp'} = \@selected_tabrcpt;
    } else {
        delete $message->{'rcpts_by_mode'}{$mode}{'noverp'};
    }
    if ($#verp_selected_tabrcpt > -1) {
        $message->{'rcpts_by_mode'}{$mode}{'verp'} = \@verp_selected_tabrcpt;
    } else {
        delete $message->{'rcpts_by_mode'}{$mode}{'verp'};
    }
    return $#verp_selected_tabrcpt + $#selected_tabrcpt + 2;
}

sub find_packet_to_tag_as_last {
    my $message = shift;
    my $tag_verp   = 0;
    my $tag_noverp = 0;
    foreach my $mode (sort keys %{$message->{'rcpts_by_mode'}}) {
        if ($message->{'rcpts_by_mode'}{$mode}{'verp'}) {
            $tag_verp = $mode;
        }
        if ($message->{'rcpts_by_mode'}{$mode}{'noverp'}) {
            $tag_noverp = $mode;
        }
    }
    if ($tag_verp) {
        return ('verp', $tag_verp);
    } else {
        return ('noverp', $tag_noverp);
    }
}

###################   SERVICE MESSAGES   ##################################

###############################################################
# send_to_editor
###############################################################
# Sends a message to the list editor to ask him for moderation
# ( in moderation context : editor or editorkey). The message
# to moderate is set in spool queuemod with name containing
# a key (reference send to editor for moderation)
# In context of msg_topic defined the editor must tag it
# for the moderation (on Web interface)
#
# IN : -$self(+) : ref(List)
#      -$method : 'md5' - for "editorkey" | 'smtp' - for "editor"
#      -$message(+) : ref(Message) - the message to moderate
# OUT : $modkey : the moderation key for naming message waiting
#         for moderation in spool queuemod
#       | undef
#################################################################
sub send_to_editor {
    my ($self, $method, $message) = @_;
    my $encrypt = 'smime_crypted' if $message->is_encrypted();
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, encrypt=%s)',
        $self, $method, $message, $encrypt);

    my ($i, @rcpt);
    my $name  = $self->name;
    my $host  = $self->host;
    my $robot = $self->robot;

    return unless $name and $self->config;

    my @now = localtime(time);
    my $messageid =
          $now[6]
        . $now[5]
        . $now[4]
        . $now[3]
        . $now[2]
        . $now[1] . "."
        . int(rand(6))
        . int(rand(6))
        . int(rand(6))
        . int(rand(6))
        . int(rand(6))
        . int(rand(6)) . "\@"
        . $host;
    my $modkey = Digest::MD5::md5_hex(join('/', $self->cookie, $messageid));
    my $boundary = "__ \<$messageid\>";

    if ($method eq 'md5') {

        # move message to spool  mod
        my $modspool = Sympa::Spool::File::Key->new(
            name      => 'mod',
            directory => Sympa::Site->queuemod()
        );
        $modspool->store(
            $message->to_string,    #FIXME: maybe encrypted
            {   'list'    => $message->get_list()->name,
                'robot'   => $message->get_robot()->name,
                'authkey' => $modkey,
            }
        );

        # prepare html view of this message
        my $destination_dir =
              Sympa::Site->viewmail_dir . '/mod/'
            . $self->get_id() . '/'
            . $modkey;
        Sympa::Archive::convert_single_message(
            $self, $message,
            'destination_dir' => $destination_dir,
            'attachement_url' => join('/', '..', 'viewmod', $name, $modkey),
        );
    }
    @rcpt = $self->get_editors_email();

    my $hdr = $message->as_entity()->head;

    ## Did we find a recipient?
    if ($#rcpt < 0) {
        $main::logger->do_log(
            Sympa::Logger::NOTICE,
            "No editor found for list %s. Trying to proceed ignoring nomail option",
            $self
        );
        my $messageid = $message->get_msg_id;

        @rcpt = $self->get_editors_email({'ignore_nomail', 1});
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Warning : no owner and editor defined at all in list %s', $name)
            unless (@rcpt);

        ## Could we find a recipient by ignoring the "nomail" option?
        if ($#rcpt >= 0) {
            $main::logger->do_log(
                Sympa::Logger::NOTICE,
                'All the intended recipients of message %s in list %s have set the "nomail" option. Ignoring it and sending it to all of them.',
                $messageid,
                $self
            );
        } else {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Impossible to send the moderation request for message %s to editors of list %s. Neither editor nor owner defined!',
                $messageid,
                $self
            );
            return undef;
        }
    }

    my $subject = $message->decode_header('Subject');
    my $headers = Sympa::Site->sender_headers();
    my $param = {
        'modkey'         => $modkey,
        'boundary'       => $boundary,
        'msg_from'       => $message->get_sender_email(headers => $headers),
        'subject'        => $subject,
        'spam_status'    => $message->is_spam() ? 'spam' : undef,
        'mod_spool_size' => $self->get_mod_spool_size,
        'method'         => $method
    };

    if ($self->is_there_msg_topic() && $self->is_msg_topic_tagging_required())
    {
        $param->{'request_topic'} = 1;
    }

    foreach my $recipient (@rcpt) {
        if ($encrypt and $encrypt eq 'smime_crypted') {
            $message->encrypt($recipient);
            unless ($message->is_encrypted()) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Could not encrypt message for moderator %s', $recipient);
            }
            $param->{'msg'} = $message->as_entity();
        } else {
            $param->{'msg'} = $message->as_entity();    #FIXME
        }

        # create a one time ticket that will be used as an MD5 URL credential

        unless (
            $param->{'one_time_ticket'} = Sympa::Auth::create_one_time_ticket(
                $recipient, $robot, 'modindex/' . $name, 'mail'
            )
            ) {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                "Unable to create one_time_ticket for $recipient, service modindex/$name"
            );
        } else {
            $main::logger->do_log(Sympa::Logger::DEBUG,
                "ticket $param->{'one_time_ticket'} created");
        }
        Sympa::Template::allow_absolute_path();
        $param->{'auto_submitted'} = 'auto-forwarded';

        unless ($self->send_file('moderate', $recipient, $param)) {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Unable to send template "moderate" to %s', $recipient);
            return undef;
        }
    }
    return $modkey;
}

####################################################
# send_auth
####################################################
# Sends an authentication request for a sent message to distribute.
# The message for distribution is copied in the authqueue
# spool in order to wait for confirmation by its sender.
# This message is named with a key.
# In context of msg_topic defined, the sender must tag it
# for the confirmation
#
# IN : -$self (+): ref(List)
#      -$message (+): ref(Message)
#
# OUT : $authkey : the key for naming message waiting
#         for confirmation (or tagging) in spool queueauth
#       | undef
####################################################
sub send_auth {
    my ($self, $message) = @_;
    my $sender = $message->get_sender_email(
        headers => Sympa::Site->sender_headers()
    );
    my $file   = $message->as_file();
    $main::logger->do_log(Sympa::Logger::DEBUG3, 'Sympa::List::send_auth(%s, %s)',
        $sender, $file);

    ## Ensure 1 second elapsed since last message
    ## DV: What kind of lame hack is this???
    sleep(1);

    my $name      = $self->name;
    my $host      = $self->host;
    return undef unless $name and $self->config;

    my @now = localtime(time);
    my $messageid =
          $now[6]
        . $now[5]
        . $now[4]
        . $now[3]
        . $now[2]
        . $now[1] . "."
        . int(rand(6))
        . int(rand(6))
        . int(rand(6))
        . int(rand(6))
        . int(rand(6))
        . int(rand(6)) . "\@"
        . $host;
    my $authkey = Digest::MD5::md5_hex(join('/', $self->cookie, $messageid));
    chomp $authkey;

    my $spool = Sympa::Spool::File::Key->new(
        name      => 'auth',
        directory => Sympa::Site->queueauth()
    );
    $spool->update(
        {'messagekey' => $message->{'messagekey'}},
        {   "spoolname"   => 'auth',
            'authkey'     => $authkey,
            'messagelock' => 'NULL'
        }
    );
    my $param = {
        'authkey'  => $authkey,
        'boundary' => "----------------- Message-Id: \<$messageid\>",
        'file'     => $file
    };

    if ($self->is_there_msg_topic() && $self->is_msg_topic_tagging_required())
    {
        $param->{'request_topic'} = 1;
    }

    if ($message->is_encrypted()) {
        $message->encrypt($sender);
        unless ($message->is_encrypted()) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Could not encrypt message for moderator %s', $sender);
        }
        $param->{'msg'} = $message->as_entity();
    } else {
        $param->{'msg'} = $message->as_entity();
    }

    Sympa::Template::allow_absolute_path();
    $param->{'auto_submitted'} = 'auto-forwarded';

    unless ($self->send_file('send_auth', $sender, $param)) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            "Unable to send template 'send_auth' to $sender");
        return undef;
    }
    return $authkey;
}

=over 4

=item request_auth

Sends an authentication request for a requested command .
See L<Site/request_auth>.

=back

=cut

####################################################
# archive_send
####################################################
# sends an archive file to someone (text archive
# file : independent from web archives)
#
# IN : -$self(+) : ref(List)
#      -$who(+) : recipient
#      -file(+) : name of the archive file to send
# OUT : - | undef
#
######################################################
sub archive_send {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, &s)', @_);
    my ($self, $who, $file) = @_;

    return unless $self->is_archived();    #FIXME

    my $dir = $self->robot->arc_path . '/' . $self->get_id;
    my $msg_list = Sympa::Archive::scan_dir_archive($dir, $file);

    my $subject = sprintf 'Archive of %s, file %s', $self->name, $file;
    my $param = {
        'to'       => $who,
        'subject'  => $subject,
        'msg_list' => $msg_list,
        'filename' => $file
    };

    $param->{'boundary1'} = Sympa::Tools::get_message_id($self->robot);
    $param->{'boundary2'} = Sympa::Tools::get_message_id($self->robot);
    $param->{'from'}      = $self->robot->get_address();                #FIXME

    $param->{'auto_submitted'} = 'auto-replied';
    unless ($self->send_file('get_archive', $who, $param)) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Unable to send template "get_archive" to %s', $who);
        return undef;
    }
}

####################################################
# archive_send_last
####################################################
# sends last archive file
#
# IN : -$self(+) : ref(List)
#      -$who(+) : recipient
# OUT : - | undef
#
######################################################
sub archive_send_last {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my ($self, $who) = @_;

    return unless $self->is_archived();    #FIXME
    my $dir = $self->dir . '/archives';

    my $message = Sympa::Message->new(
        'file' => "$dir/last_message",
        'noxsympato' => 'noxsympato'
    );
    unless ($message) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to create Message object from file %s',
            "$dir/last_message");
        return undef;
    }

    my $msg = {};
    $msg->{'id'} = 1;

    $msg->{'subject'} = $message->decode_header('Subject');
    $msg->{'from'}    = $message->decode_header('From');
    $msg->{'date'}    = $message->decode_header('Date');

    $msg->{'full_msg'} = $message->as_string();    # raw message

    my $subject = sprintf 'Archive of %s, last message', $self->name;
    my $param = {
        'to'       => $who,
        'subject'  => $subject,
        'msg_list' => [$msg],
        'filename' => 'last_message'
    };

    $param->{'boundary1'} = Sympa::Tools::get_message_id($self->robot);
    $param->{'boundary2'} = Sympa::Tools::get_message_id($self->robot);
    $param->{'from'}      = $self->robot->get_address();                #FIXME
    $param->{'auto_submitted'} = 'auto-replied';

    unless ($self->send_file('get_archive', $who, $param)) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Unable to send template "get_archive" to %s', $who);
        return undef;
    }
}

###################   NOTIFICATION SENDING  ###############################

####################################################
# send_notify_to_owner
####################################################
# Sends a notice to list owner(s) by parsing
# listowner_notification.tt2 template
#
# IN : -$self (+): ref(List)
#      -$operation (+): notification type
#      -$param(+) : ref(HASH) | ref(ARRAY)
#       values for template parsing
#
# OUT : 1 | undef
#
######################################################
sub send_notify_to_owner {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my ($self, $operation, $param) = @_;

    my @to    = $self->get_owners_email();
    my $robot = $self->domain;

    unless (@to) {
        $main::logger->do_log(
            Sympa::Logger::NOTICE,
            'No owner defined or all of them use nomail option in list %s ; using listmasters as default',
            $self
        );
        @to = split /,/, $self->robot->listmaster;
    }
    foreach my $r (@to) {
        $main::logger->do_log(Sympa::Logger::DEBUG3, 'to %s', $r);
    }

    unless (defined $operation) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'missing incoming parameter "$operation"');
        return undef;
    }

    if (ref($param) eq 'HASH') {

        $param->{'auto_submitted'} = 'auto-generated';
        $param->{'to'}             = join(',', @to);
        $param->{'type'}           = $operation;

        if ($operation eq 'warn-signoff') {
            $param->{'escaped_gecos'} = $param->{'gecos'};
            $param->{'escaped_gecos'} =~ s/\s/\%20/g;
            $param->{'escaped_who'} = $param->{'who'};
            $param->{'escaped_who'} =~ s/\s/\%20/g;
            foreach my $owner (@to) {
                $param->{'one_time_ticket'} =
                    Sympa::Auth::create_one_time_ticket($owner, $robot,
                    'search/' . $self->name . '/' . $param->{'escaped_who'},
                    $param->{'ip'});
                unless (
                    $self->send_file(
                        'listowner_notification', [$owner], $param
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::NOTICE,
                        'Unable to send template "listowner_notification" to %s list owner %s',
                        $self,
                        $owner
                    );
                }
            }
        } elsif ($operation eq 'subrequest') {
            $param->{'escaped_gecos'} = $param->{'gecos'};
            $param->{'escaped_gecos'} =~ s/\s/\%20/g;
            $param->{'escaped_who'} = $param->{'who'};
            $param->{'escaped_who'} =~ s/\s/\%20/g;
            foreach my $owner (@to) {
                $param->{'one_time_ticket'} =
                    Sympa::Auth::create_one_time_ticket($owner, $robot,
                    'subindex/' . $self->name,
                    $param->{'ip'});
                unless (
                    $self->send_file(
                        'listowner_notification', [$owner], $param
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::NOTICE,
                        'Unable to send template "listowner_notification" to %s list owner %s',
                        $self,
                        $owner
                    );
                }
            }
        } elsif ($operation eq 'sigrequest') {
            $param->{'escaped_who'} = $param->{'who'};
            $param->{'escaped_who'} =~ s/\s/\%20/g;
            $param->{'sympa'} = $self->robot->get_address();
            foreach my $owner (@to) {
                $param->{'one_time_ticket'} =
                    Sympa::Auth::create_one_time_ticket($owner, $robot,
                    'sigindex/' . $self->name,
                    $param->{'ip'});
                unless (
                    $self->send_file(
                        'listowner_notification', [$owner], $param
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::NOTICE,
                        'Unable to send template "listowner_notification" to %s list owner %s',
                        $self,
                        $owner
                    );
                }
            }
        } else {
            if ($operation eq 'bounce_rate') {
                $param->{'rate'} = int($param->{'rate'} * 10) / 10;
            }
            unless ($self->send_file('listowner_notification', \@to, $param))
            {
                $main::logger->do_log(
                    Sympa::Logger::NOTICE,
                    'Unable to send template "listowner_notification" to %s list owner',
                    $self
                );
                return undef;
            }
        }

    } elsif (ref($param) eq 'ARRAY') {

        my $data = {
            'to'   => join(',', @to),
            'type' => $operation
        };

        for my $i (0 .. $#{$param}) {
            $data->{"param$i"} = $param->[$i];
        }
        unless ($self->send_file('listowner_notification', \@to, $data)) {
            $main::logger->do_log(
                Sympa::Logger::NOTICE,
                'Unable to send template "listowner_notification" to %s list owner',
                $self
            );
            return undef;
        }

    } else {

        $main::logger->do_log(
            Sympa::Logger::ERR,
            'error on incoming parameter "$param", it must be a ref on HASH or a ref on ARRAY',
        );
        return undef;
    }
    return 1;
}

sub get_picture_path {
    my $self = shift;
    return join '/',
        $self->robot->static_content_path, 'pictures', $self->get_id, @_;
}

sub get_picture_url {
    my $self = shift;
    return join '/',
        $self->robot->static_content_url, 'pictures', $self->get_id, @_;
}

#*******************************************
## Function : find_picture_filenames
## Description : return the type of a pictures
##               according to the user
## IN : list, email
##*******************************************
sub find_picture_filenames {
    my $self  = shift;
    my $email = shift;

    my $login = Digest::MD5::md5_hex($email);
    my @ret   = ();

    foreach my $ext (qw{gif jpg jpeg png}) {
        if (-f $self->get_picture_path($login . '.' . $ext)) {
            push @ret, $login . '.' . $ext;
        }
    }
    return @ret;
}

sub find_picture_paths {
    my $self  = shift;
    my $email = shift;

    return
        map { $self->get_picture_path($_) }
        $self->find_picture_filenames($email);
}

## Find pictures URL
### IN : list, email
sub find_picture_url {
    my $self  = shift;
    my $email = shift;

    my ($filename) = $self->find_picture_filenames($email);
    return undef unless $filename;
    return $self->get_picture_url($filename);
}

#########################
## Delete a member's picture file
#########################
# remove picture from user $2 in list $1
#########################
sub delete_list_member_picture {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self  = shift;
    my $email = shift;

    my $ret = 1;
    foreach my $path ($self->find_picture_paths($email)) {
        unless (unlink $path) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Failed to delete %s', $path);
            $ret = undef;
        } else {
            $main::logger->do_log(Sympa::Logger::DEBUG3,
                'File deleted successfully: %s', $path);
        }
    }

    return $ret;
}

####################################################
# send_notify_to_editor
####################################################
# Sends a notice to list editor(s) or owner (if no editor)
# by parsing listeditor_notification.tt2 template
#
# IN : -$self (+): ref(List)
#      -$operation (+): notification type
#      -$param(+) : ref(HASH) | ref(ARRAY)
#       values for template parsing
#
# OUT : 1 | undef
#
######################################################
sub send_notify_to_editor {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my ($self, $operation, $param) = @_;

    my @to = $self->get_editors_email();

    #my $robot = $self->domain;
    $param->{'auto_submitted'} = 'auto-generated';

    unless (@to) {
        $main::logger->do_log(
            Sympa::Logger::NOTICE,
            'Warning : no editor or owner defined or all of them use nomail option in list %s',
            $self
        );
        return undef;
    }
    unless (defined $operation) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'missing incoming parameter "$operation"');
        return undef;
    }
    if (ref($param) eq 'HASH') {

        $param->{'to'} = join(',', @to);
        $param->{'type'} = $operation;

        unless ($self->send_file('listeditor_notification', \@to, $param)) {
            $main::logger->do_log(
                Sympa::Logger::NOTICE,
                'Unable to send template "listeditor_notification" to %s list editor',
                $self
            );
            return undef;
        }

    } elsif (ref($param) eq 'ARRAY') {

        my $data = {
            'to'   => join(',', @to),
            'type' => $operation
        };

        foreach my $i (0 .. $#{$param}) {
            $data->{"param$i"} = $param->[$i];
        }
        unless ($self->send_file('listeditor_notification', \@to, $data)) {
            $main::logger->do_log(
                Sympa::Logger::NOTICE,
                'Unable to send template "listeditor_notification" to %s list editor',
                $self
            );
            return undef;
        }

    } else {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'error on incoming parameter "$param", it must be a ref on HASH or a ref on ARRAY',
        );
        return undef;
    }
    return 1;
}

####################################################
# send_notify_to_user
####################################################
# Send a notice to a user (sender, subscriber ...)
# by parsing user_notification.tt2 template
#
# IN : -$self (+): ref(List)
#      -$operation (+): notification type
#      -$user(+): email of notified user
#      -$param(+) : ref(HASH) | ref(ARRAY)
#       values for template parsing
#
# OUT : 1 | undef
#
######################################################
sub send_notify_to_user {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, %s)', @_);
    my ($self, $operation, $user, $param) = @_;

    my $robot = $self->domain;
    $param->{'auto_submitted'} = 'auto-generated';

    unless (defined $operation) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'missing incoming parameter "$operation"');
        return undef;
    }
    unless ($user) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'missing incoming parameter "$user"');
        return undef;
    }

    if (ref($param) eq "HASH") {
        $param->{'to'}   = $user;
        $param->{'type'} = $operation;

        if ($operation eq 'auto_notify_bouncers') {
        }

        unless ($self->send_file('user_notification', $user, $param)) {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Unable to send template "user_notification" to %s', $user);
            return undef;
        }

    } elsif (ref($param) eq "ARRAY") {

        my $data = {
            'to'   => $user,
            'type' => $operation
        };

        for my $i (0 .. $#{$param}) {
            $data->{"param$i"} = $param->[$i];
        }
        unless ($self->send_file('user_notification', $user, $data)) {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Unable to send template "user_notification" to %s', $user);
            return undef;
        }

    } else {

        $main::logger->do_log(Sympa::Logger::ERR,
            'error on incoming parameter "$param", it must be a ref on HASH or a ref on ARRAY'
        );
        return undef;
    }
    return 1;
}

#
#                                                                         #
#                                                                         #
################### END functions for sending messages ####################

=over 4

=item compute_auth

Generate a MD5 checksum using private cookie and parameters
See L<Site/compute_auth>.

=back

=cut

=over 4

=item get_etc_filename

Look for a file in the list > robot > server > default locations.
See L<Site/get_etc_filename>.

=item get_etc_include_path

make an array of include path for tt2 parsing.
See L<Site/get_etc_include_path>.

=back

=cut

## Delete the indicate list member
## IN : - ref to array
##      - option exclude
##
## $list->delete_list_member('users' => \@u, 'exclude' => 1)
## $list->delete_list_member('users' => [$email], 'exclude' => 1)
sub delete_list_member {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s => %s, ...)', @_);
    my $self      = shift;
    my %param     = @_;
    my @u         = @{$param{'users'}};
    my $exclude   = $param{'exclude'};
    my $parameter = $param{'parameter'
        };    #case of deleting : bounce? manual signoff or deleted by admin?
    my $daemon_name = $param{'daemon'};

    my $name  = $self->name;
    my $total = 0;

    foreach my $who (@u) {
        $who = Sympa::Tools::clean_email($who);

        ## Include in exclusion_table only if option is set.
        if ($exclude == 1) {
            ## Insert in exclusion_table if $user->{'included'} eq '1'
            $self->insert_delete_exclusion($who, 'insert');

        }

        $self->user('member', $who, 0);

        ## Delete record in SUBSCRIBER
        unless (
            Sympa::DatabaseManager::do_prepared_query(
                q{DELETE FROM subscriber_table WHERE user_subscriber = ? AND list_subscriber = ? AND robot_subscriber = ?},
                $who, $name, $self->domain
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to remove member %s on list %s',
                $who, $self);
            next;
        }

        $self->delete_list_member_picture($who);

        #log in stat_table to make statistics
        Sympa::Monitor::db_stat_log(
            'robot'     => $self->domain,
            'list'      => $name,
            'operation' => 'del subscriber',
            'parameter' => $parameter,
            'mail'      => $who,
            'daemon'    => $daemon_name
        );

        $total--;
    }

    $self->total($self->total + $total);
    $self->savestats();

    return (-1 * $total);
}

## Delete the indicated admin users from the list.
sub delete_list_admin {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, ...)', @_);
    my ($self, $role, @u) = @_;

    my $name  = $self->name;
    my $total = 0;

    foreach my $who (@u) {
        $who = Sympa::Tools::clean_email($who);

        $self->user($role, $who, 0);

        ## Delete record in ADMIN
        unless (
            Sympa::DatabaseManager::do_prepared_query(
                q{DELETE FROM admin_table WHERE user_admin = ? AND list_admin = ? AND robot_admin = ? AND role_admin = ?},
                $who, $name, $self->domain, $role
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to remove admin %s on list %s',
                $who, $self);
            next;
        }

        $total--;
    }

    return (-1 * $total);
}

## Delete all admin_table entries
sub delete_all_list_admin {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '()');

    ## Delete record in ADMIN
    unless ($sth =
        Sympa::DatabaseManager::do_prepared_query(q{DELETE FROM admin_table}))
    {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to remove all admin from database');
        return undef;
    }

    return 1;
}

## Returns the maximum size allowed for a message to the list.
sub get_max_size {
    return shift->max_size;
}

## Returns an array with the Reply-To data
sub get_reply_to {
    my $self  = shift;
    my $value = $self->reply_to_header->{'value'};
    $value = $self->reply_to_header->{'other_email'}
        if $value eq 'other_email';

    return $value;
}

## Returns the number of subscribers to the list
## not using cache.
sub get_real_total {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    push @sth_stack, $sth;

    ## Query the Database
    unless (
        $sth = Sympa::DatabaseManager::do_prepared_query(
            q{SELECT count(*) FROM subscriber_table WHERE list_subscriber = ? AND robot_subscriber = ?},
            $self->name,
            $self->domain
        )
        ) {
        $main::logger->do_log(Sympa::Logger::DEBUG,
            'Unable to get subscriber count for list %s', $self);
        $sth = pop @sth_stack;
        return undef;
    }
    my $total = $sth->fetchrow;
    $sth->finish();

    $sth = pop @sth_stack;

    return $self->total($total);
}

######################################################################
###  suspend_subscription                                            #
## Suspend an user from list(s)                                      #
######################################################################
# IN:                                                                #
#   - email : the subscriber email                                   #
#   - data : start_date and end_date                                 #
# OUT:                                                               #
#   - undef if something went wrong.                                 #
#   - 1 if user is suspended from the list                           #
######################################################################
sub suspend_subscription {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my $self  = shift;
    my $email = shift;
    my $data  = shift;

    croak "Invalid parameter: $self"
        unless ref $self;    #prototype changed (6.2)

    unless (
        Sympa::DatabaseManager::do_prepared_query(
            q{UPDATE subscriber_table SET suspend_subscriber = 1, suspend_start_date_subscriber = ?, suspend_end_date_subscriber = ? WHERE user_subscriber = ? AND list_subscriber = ? AND robot_subscriber = ?},
            $data->{'startdate'}, $data->{'enddate'}, $email,
            $self->name,          $self->domain
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to suspend subscription of user %s to list %s',
            $email, $self);
        return undef;
    }

    return 1;
}

######################################################################
###  restore_suspended_subscription                                  #
## Restore the subscription of an user from list(s)                  #
######################################################################
# IN:                                                                #
#   - email : the subscriber email                                   #
# OUT:                                                               #
#   - undef if something went wrong.                                 #
#   - 1 if his/her subscription is restored                          #
######################################################################
sub restore_suspended_subscription {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self  = shift;
    my $email = shift;

    croak "Invalid parameter: $self"
        unless ref $self;    #prototype changed (6.2)

    unless (
        Sympa::DatabaseManager::do_prepared_query(
            q{UPDATE subscriber_table SET suspend_subscriber = 0, suspend_start_date_subscriber = NULL, suspend_end_date_subscriber = NULL WHERE user_subscriber = ? AND list_subscriber = ? AND robot_subscriber = ?},
            $email, $self->name, $self->domain
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to restore subscription of user %s to list %s',
            $email, $self);
        return undef;
    }

    return 1;
}

######################################################################
###  insert_delete_exclusion                                         #
## Update the exclusion_table                                        #
######################################################################
# IN:                                                                #
#   - email : the subscriber email                                   #
#   - action : insert or delete                                      #
# OUT:                                                               #
#   - undef if something went wrong.                                 #
#   - 1                                                              #
######################################################################
sub insert_delete_exclusion {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, %s)', @_);
    my $self   = shift;
    my $email  = shift;
    my $action = shift;

    croak "Invalid parameter: $self"
        unless ref $self;    #prototype changed (6.2)

    my $name     = $self->name;
    my $robot_id = $self->domain;

    my $r = 1;

    if ($action eq 'insert') {
        ## INSERT only if $user->{'included'} eq '1'
        my $user = $self->user('member', $email) || undef;
        my $date = time;

        if ($user->{'included'} eq '1') {
            ## Insert : list, user and date
            unless (
                Sympa::DatabaseManager::do_prepared_query(
                    q{INSERT INTO exclusion_table
		      (list_exclusion, robot_exclusion, user_exclusion,
		       date_exclusion)
		     VALUES (?, ?, ?, ?)},
                    $name, $robot_id, $email, $date
                )
                ) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Unable to exclude user %s from list %s',
                    $email, $self);
                return undef;
            }
        }
    } elsif ($action eq 'delete') {
        ## If $email is in exclusion_table, delete it.
        my $data_excluded = $self->get_exclusion();
        my @users_excluded;

        my $key = 0;
        while ($data_excluded->{'emails'}->[$key]) {
            push @users_excluded, $data_excluded->{'emails'}->[$key];
            $key = $key + 1;
        }

        $r = 0;
        my $sth;
        foreach my $users (@users_excluded) {
            if ($email eq $users) {
                ## Delete : list, user and date
                unless (
                    $sth = Sympa::DatabaseManager::do_prepared_query(
                        q{DELETE FROM exclusion_table
			  WHERE list_exclusion = ? AND robot_exclusion = ? AND
				user_exclusion = ?},
                        $name, $robot_id, $email
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        'Unable to remove entry %s for list %s from table exclusion_table',
                        $email,
                        $self
                    );
                }
                $r = $sth->rows;
            }
        }
    } else {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unknown action %s', $action);
        return undef;
    }

    return $r;
}

######################################################################
###  get_exclusion                                                   #
## Returns a hash with those excluded from the list and the date.    #
##                                                                   #
# IN:  - name : the name of the list                                 #
# OUT: - data_exclu : * %data_exclu->{'emails'}->[]                  #
#                     * %data_exclu->{'date'}->[]                    #
######################################################################
sub get_exclusion {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    croak "Invalid parameter: $self"
        unless ref $self;    #prototype changed (6.2)

    my $name     = $self->name;
    my $robot_id = $self->domain;

    push @sth_stack, $sth;

    if (defined $self->family_name and $self->family_name ne '') {
        unless (
            $sth = Sympa::DatabaseManager::do_prepared_query(
                q{SELECT user_exclusion AS email, date_exclusion AS "date"
		  FROM exclusion_table
		  WHERE (list_exclusion = ? OR family_exclusion = ?) AND
			robot_exclusion = ?},
                $name, $self->family_name, $robot_id
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to retrieve excluded users for list %s', $self);
            $sth = pop @sth_stack;
            return undef;
        }
    } else {
        unless (
            $sth = Sympa::DatabaseManager::do_prepared_query(
                q{SELECT user_exclusion AS email, date_exclusion AS "date"
		  FROM exclusion_table
		  WHERE list_exclusion = ? AND robot_exclusion=?},
                $name, $robot_id
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to retrieve excluded users for list %s', $self);
            $sth = pop @sth_stack;
            return undef;
        }
    }

    my @users;
    my @date;
    my $data;
    while ($data = $sth->fetchrow_hashref) {
        push @users, $data->{'email'};
        push @date,  $data->{'date'};
    }
    ## in order to use the data, we add the emails and dates in different
    ## array
    my $data_exclu = {
        "emails" => \@users,
        "date"   => \@date
    };
    $sth->finish();

    $sth = pop @sth_stack;

    unless ($data_exclu) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to retrieve information from database for list %s',
            $self);
        return undef;
    }
    return $data_exclu;
}

######################################################################
###  get_list_member                                                  #
## Returns a subscriber of the list.
## Options :
##    probe : don't log error if user does not exist
##    #
######################################################################
sub get_list_member {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self = shift;
    return $self->user('member', shift) || undef;
}

#######################################################################
# IN
#   - a single reference to a hash with the following keys:          #
#     * email : the subscriber email                                 #
#     * name: the name of the list                                   #
#     * domain: the virtual host under which the list is installed.  #
#
# OUT : undef if something wrong
#       a hash of tab of resembling emails
sub get_resembling_list_members_no_object {
    my $options = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', $options->{'name'},
        $options->{'email'}, $options->{'domain'});
    my @output;

    my $email    = Sympa::Tools::clean_email($options->{'email'});
    my $robot    = $options->{'domain'};
    my $listname = $options->{'name'};

    $email =~ /^(.*)\@(.*)$/;
    my $local_part        = $1;
    my $subscriber_domain = $2;
    my %subscribers_email;

    ##### plused
    # is subscriber a plused email ?
    if ($local_part =~ /^(.*)\+(.*)$/) {

        foreach my $subscriber (
            find_list_member_by_pattern_no_object(
                {   'email_pattern' => $1 . '@' . $subscriber_domain,
                    'name'          => $listname,
                    'domain'        => $robot
                }
            )
            ) {
            next if ($subscribers_email{$subscriber->{'email'}});
            $subscribers_email{$subscriber->{'email'}} = 1;
            push @output, $subscriber;
        }
    }

    # is some subscriber resembling with a plused email ?
    foreach my $subscriber (
        find_list_member_by_pattern_no_object(
            {   'email_pattern' => $local_part . '+%@' . $subscriber_domain,
                'name'          => $listname,
                'domain'        => $robot
            }
        )
        ) {
        next if ($subscribers_email{$subscriber->{'email'}});
        $subscribers_email{$subscriber->{'email'}} = 1;
        push @output, $subscriber;
    }

    # resembling local part
    # try to compare firstname.name@domain with name@domain
    foreach my $subscriber (
        find_list_member_by_pattern_no_object(
            {   'email_pattern' => '%'
                    . $local_part . '@'
                    . $subscriber_domain,
                'name'   => $listname,
                'domain' => $robot
            }
        )
        ) {
        next if ($subscribers_email{$subscriber->{'email'}});
        $subscribers_email{$subscriber->{'email'}} = 1;
        push @output, $subscriber;
    }

    if ($local_part =~ /^(.*)\.(.*)$/) {
        foreach my $subscriber (
            find_list_member_by_pattern_no_object(
                {   'email_pattern' => $2 . '@' . $subscriber_domain,
                    'name'          => $listname,
                    'domain'        => $robot
                }
            )
            ) {
            next if ($subscribers_email{$subscriber->{'email'}});
            $subscribers_email{$subscriber->{'email'}} = 1;
            push @output, $subscriber;
        }
    }

    #### Same local_part and resembling domain
    #
    # compare host.domain.tld with domain.tld
    if ($subscriber_domain =~ /^[^\.]\.(.*)$/) {
        my $upperdomain = $1;
        if ($upperdomain =~ /\./) {

            # remove first token if there is still at least 2 tokens try to
            # find a subscriber with that domain
            foreach my $subscriber (
                find_list_member_by_pattern_no_object(
                    {   'email_pattern' => $local_part . '@' . $upperdomain,
                        'name'          => $listname,
                        'domain'        => $robot
                    }
                )
                ) {
                next if ($subscribers_email{$subscriber->{'email'}});
                $subscribers_email{$subscriber->{'email'}} = 1;
                push @output, $subscriber;
            }
        }
    }
    foreach my $subscriber (
        find_list_member_by_pattern_no_object(
            {   'email_pattern' => $local_part . '@%' . $subscriber_domain,
                'name'          => $listname,
                'domain'        => $robot
            }
        )
        ) {
        next if ($subscribers_email{$subscriber->{'email'}});
        $subscribers_email{$subscriber->{'email'}} = 1;
        push @output, $subscriber;
    }

    # looking for initial
    if ($local_part =~ /^(.*)\.(.*)$/) {
        my $givenname = $1;
        my $name      = $2;
        my $initial   = '';
        if ($givenname =~ /^([a-z])/) {
            $initial = $1;
        }
        if ($name =~ /^([a-z])/) {
            $initial = $initial . $1;
        }
        foreach my $subscriber (
            find_list_member_by_pattern_no_object(
                {   'email_pattern' => $initial . '@' . $subscriber_domain,
                    'name'          => $listname,
                    'domain'        => $robot
                }
            )
            ) {
            next if ($subscribers_email{$subscriber->{'email'}});
            $subscribers_email{$subscriber->{'email'}} = 1;
            push @output, $subscriber;
        }
    }

    #### users in the same local part in any other domain
    #
    foreach my $subscriber (
        find_list_member_by_pattern_no_object(
            {   'email_pattern' => $local_part . '@%',
                'name'          => $listname,
                'domain'        => $robot
            }
        )
        ) {
        next if ($subscribers_email{$subscriber->{'email'}});
        $subscribers_email{$subscriber->{'email'}} = 1;
        push @output, $subscriber;
    }

    return \@output;

}

######################################################################
###  find_list_member_by_pattern_no_object                            #
## Get details regarding a subscriber.                               #
# IN:                                                                #
#   - a single reference to a hash with the following keys:          #
#     * email pattern : the subscriber email pattern looking for      #
#     * name: the name of the list                                   #
#     * domain: the virtual host under which the list is installed.  #
# OUT:                                                               #
#   - undef if something went wrong.                                 #
#   - a hash containing the user details otherwise                   #
######################################################################

sub find_list_member_by_pattern_no_object {
    my $options = shift;
    my $name    = $options->{'name'};
    my $email_pattern =
        Sympa::Tools::clean_email($options->{'email_pattern'});
    my @resembling_users;

    push @sth_stack, $sth;
    unless (
        $sth = Sympa::DatabaseManager::do_prepared_query(
            sprintf(
                q{SELECT %s
		FROM subscriber_table
		WHERE user_subscriber LIKE ? AND
		      list_subscriber = ? AND robot_subscriber = ?},
                _list_member_cols()
            ),
            $email_pattern,
            $name,
            $options->{'domain'}
        )
        ) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Unable to gather information corresponding to pattern %s for list %s@%s',
            $email_pattern,
            $name,
            $options->{'domain'}
        );
        $sth = pop @sth_stack;
        return undef;
    }

    while (my $user = $sth->fetchrow_hashref('NAME_lc')) {
        if (defined $user) {

            $user->{'reception'} ||= 'mail';
            $user->{'escaped_email'} =
                Sympa::Tools::escape_chars($user->{'email'});
            $user->{'update_date'} ||= $user->{'date'};
            if (defined $user->{custom_attribute}) {
                $user->{'custom_attribute'} =
                    parseCustomAttribute($user->{'custom_attribute'});
            }
            push @resembling_users, $user;
        }
    }
    $sth->finish();

    $sth = pop @sth_stack;
    ## Set session cache

    return @resembling_users;
}

sub _list_member_cols {
    my $additional = '';
    if (Sympa::Site->db_additional_subscriber_fields) {
        $additional = ', ' . Sympa::Site->db_additional_subscriber_fields;
    }
    return
        sprintf
        'user_subscriber AS email, comment_subscriber AS gecos, bounce_subscriber AS bounce, bounce_score_subscriber AS bounce_score, bounce_address_subscriber AS bounce_address, reception_subscriber AS reception, topics_subscriber AS topics, visibility_subscriber AS visibility, %s AS "date", %s AS update_date, subscribed_subscriber AS subscribed, included_subscriber AS included, include_sources_subscriber AS id, custom_attribute_subscriber AS custom_attribute, suspend_subscriber AS suspend, suspend_start_date_subscriber AS startdate, suspend_end_date_subscriber AS enddate%s',
        Sympa::DatabaseManager::get_canonical_read_date('date_subscriber'),
        Sympa::DatabaseManager::get_canonical_read_date('update_subscriber'),
        $additional;
}

## Returns an admin user of the list.
sub get_list_admin {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my $self = shift;
    my $role = shift;
    return $self->user($role, shift) || undef;
}

sub _list_admin_cols {
    return
        sprintf
        'user_admin AS email, comment_admin AS gecos, reception_admin AS reception, visibility_admin AS visibility, %s AS "date", %s AS update_date, info_admin AS info, profile_admin AS profile, subscribed_admin AS subscribed, included_admin AS included, include_sources_admin AS id',
        Sympa::DatabaseManager::get_canonical_read_date('date_admin'),
        Sympa::DatabaseManager::get_canonical_read_date('update_admin');
}

## Returns the first user for the list.

sub get_first_list_member {
    my ($self, $data) = @_;

    my ($sortby, $offset, $rows, $sql_regexp);
    $sortby = $data->{'sortby'};
    ## Sort may be domain, email, date
    $sortby ||= 'domain';
    $offset     = $data->{'offset'};
    $rows       = $data->{'rows'};
    $sql_regexp = $data->{'sql_regexp'};

    $main::logger->do_log(Sympa::Logger::DEBUG3,
        '(%s, sortby=%s, offset=%s, rows=%s)',
        $self, $sortby, $offset, $rows);

    my $name = $self->name;
    my $statement;

    ## SQL regexp
    my $selection = '';
    if ($sql_regexp) {
        $selection =
            sprintf
            " AND (user_subscriber LIKE %s OR comment_subscriber LIKE %s)",
            Sympa::DatabaseManager::quote($sql_regexp),
            Sympa::DatabaseManager::quote($sql_regexp);
    }

    ## Additional subscriber fields
    $statement = sprintf q{SELECT %s
	  FROM subscriber_table
	  WHERE list_subscriber = %s AND robot_subscriber = %s%s},
        _list_member_cols(),
        Sympa::DatabaseManager::quote($name),
        Sympa::DatabaseManager::quote($self->domain), $selection;

    ## SORT BY
    if ($sortby eq 'domain') {
        ## Redefine query to set "dom"
        $statement = sprintf q{SELECT %s, %s AS "dom"
	      FROM subscriber_table
	      WHERE list_subscriber = %s AND robot_subscriber = %s
	      ORDER BY dom}, _list_member_cols(),
            Sympa::DatabaseManager::get_substring_clause(
            {   'source_field'     => 'user_subscriber',
                'separator'        => '\@',
                'substring_length' => '50',
            }
            ),
            Sympa::DatabaseManager::quote($name),
            Sympa::DatabaseManager::quote($self->domain);

    } elsif ($sortby eq 'email') {
        ## Default SORT
        $statement .= ' ORDER BY email';

    } elsif ($sortby eq 'date') {
        $statement .= ' ORDER BY date DESC';

    } elsif ($sortby eq 'sources') {
        $statement .= " ORDER BY subscribed DESC,id";

    } elsif ($sortby eq 'name') {
        $statement .= ' ORDER BY gecos';
    }

    ## LIMIT clause
    if (defined($rows) and defined($offset)) {
        $statement .= Sympa::DatabaseManager::get_limit_clause(
            {'rows_count' => $rows, 'offset' => $offset});
    }

    push @sth_stack, $sth;

    unless ($sth = Sympa::DatabaseManager::do_query($statement)) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unable to get members of list %s',
            $self);
        $sth = pop @sth_stack;
        return undef;
    }

    my $user = $sth->fetchrow_hashref('NAME_lc');
    if (defined $user) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Warning: entry with empty email address in list %s', $self)
            unless $user->{'email'};
        $user->{'reception'} ||= 'mail';
        $user->{'reception'} = $self->default_user_options->{'reception'}
            unless ($self->is_available_reception_mode($user->{'reception'}));
        $user->{'update_date'} ||= $user->{'date'};

        ######################################################################
        if (defined $user->{custom_attribute}) {
            $user->{'custom_attribute'} =
                parseCustomAttribute($user->{'custom_attribute'});
        }
    } else {
        $sth->finish;
        $sth = pop @sth_stack;
    }

    ## If no offset (for LIMIT) was used, update total of subscribers
    unless ($offset) {
        $self->savestats()
            unless $self->total == $self->get_real_total;
    }

    return $user;
}

# Create a custom attribute from an XML description
# IN : File handle or a string, XML formed data as stored in database
# OUT : HASH data storing custom attributes.
sub parseCustomAttribute {
    my $xmldoc = shift;
    return undef if !defined $xmldoc or $xmldoc eq '';

    my $parser = XML::LibXML->new();
    my $tree;

    ## We should use eval to parse to prevent the program to crash if it fails
    if (ref($xmldoc) eq 'GLOB') {
        $tree = eval { $parser->parse_fh($xmldoc) };
    } else {
        $tree = eval { $parser->parse_string($xmldoc) };
    }

    unless (defined $tree) {
        $main::logger->do_log(Sympa::Logger::ERR, "Failed to parse XML data: %s",
            $EVAL_ERROR);
        return undef;
    }

    my $doc = $tree->getDocumentElement;

    my @custom_attr = $doc->getChildrenByTagName('custom_attribute');
    my %ca;
    foreach my $ca (@custom_attr) {
        my $id    = Encode::encode_utf8($ca->getAttribute('id'));
        my $value = Encode::encode_utf8($ca->getElementsByTagName('value'));
        $ca{$id} = {value => $value};
    }
    return \%ca;
}

# Create an XML Custom attribute to be stored into data base.
# IN : HASH data storing custom attributes
# OUT : string, XML formed data to be stored in database
sub createXMLCustomAttribute {
    my $custom_attr = shift;
    return
        '<?xml version="1.0" encoding="UTF-8" ?><custom_attributes></custom_attributes>'
        if (not defined $custom_attr);
    my $XMLstr = '<?xml version="1.0" encoding="UTF-8" ?><custom_attributes>';
    foreach my $k (sort keys %{$custom_attr}) {
        $XMLstr .=
              "<custom_attribute id=\"$k\"><value>"
            . Sympa::Tools::escape_html($custom_attr->{$k}{value})
            . "</value></custom_attribute>";
    }
    $XMLstr .= "</custom_attributes>";

    return $XMLstr;
}

## Returns the first admin_user with $role for the list.

sub get_first_list_admin {
    my ($self, $role, $data) = @_;

    my ($sortby, $offset, $rows, $sql_regexp);
    $sortby = $data->{'sortby'};
    ## Sort may be domain, email, date
    $sortby ||= 'domain';
    $offset     = $data->{'offset'};
    $rows       = $data->{'rows'};
    $sql_regexp = $data->{'sql_regexp'};

    $main::logger->do_log(Sympa::Logger::DEBUG3,
        '(%s, %s, sortby=%s, offset=%s, rows=%s)',
        $self, $role, $sortby, $offset, $rows);

    my $name = $self->name;
    my $statement;

    ## SQL regexp
    my $selection = '';
    if ($sql_regexp) {
        $selection =
            sprintf " AND (user_admin LIKE %s OR comment_admin LIKE %s)",
            Sympa::DatabaseManager::quote($sql_regexp),
            Sympa::DatabaseManager::quote($sql_regexp);
    }

    $statement = sprintf q{SELECT %s
	  FROM admin_table
	  WHERE list_admin = %s AND robot_admin = %s %s AND
		role_admin = %s},
        _list_admin_cols(),
        Sympa::DatabaseManager::quote($name),
        Sympa::DatabaseManager::quote($self->domain),
        $selection,
        Sympa::DatabaseManager::quote($role);

    ## SORT BY
    if ($sortby eq 'domain') {
        ## Redefine query to set "dom"
        $statement = sprintf q{SELECT %s, %s AS "dom"
	      FROM admin_table
	      WHERE list_admin = %s AND robot_admin = %s AND role_admin = %s
	      ORDER BY dom}, _list_admin_cols(),
            Sympa::DatabaseManager::get_substring_clause(
            {   'source_field'     => 'user_admin',
                'separator'        => '\@',
                'substring_length' => '50'
            }
            ),
            Sympa::DatabaseManager::quote($name),
            Sympa::DatabaseManager::quote($self->domain),
            Sympa::DatabaseManager::quote($role);
    } elsif ($sortby eq 'email') {
        $statement .= ' ORDER BY email';
    } elsif ($sortby eq 'date') {
        $statement .= ' ORDER BY date DESC';
    } elsif ($sortby eq 'sources') {
        $statement .= " ORDER BY subscribed DESC,id";
    } elsif ($sortby eq 'email') {
        $statement .= ' ORDER BY gecos';
    }

    ## LIMIT clause
    if (defined($rows) and defined($offset)) {
        $statement .= Sympa::DatabaseManager::get_substring_clause(
            {'rows_count' => $rows, 'offset' => $offset});
    }

    push @sth_stack, $sth;

    unless ($sth = Sympa::DatabaseManager::do_query($statement)) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to get admins having role %s for list %s',
            $role, $self);
        $sth = pop @sth_stack;
        return undef;
    }

    my $admin_user = $sth->fetchrow_hashref('NAME_lc');
    if (defined $admin_user) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Warning: entry with empty email address in list %s', $self)
            unless $admin_user->{'email'};
        $admin_user->{'reception'}   ||= 'mail';
        $admin_user->{'update_date'} ||= $admin_user->{'date'};
    } else {
        $sth->finish;
        $sth = pop @sth_stack;
    }

    return $admin_user;
}

## Loop for all subsequent users.
sub get_next_list_member {
    my $self = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG3, '');

    unless (defined $sth) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'No handle defined, get_first_list_member(%s) was not run',
            $self);
        return undef;
    }

    my $user = $sth->fetchrow_hashref('NAME_lc');

    if (defined $user) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Warning: entry with empty email address in list %s', $self)
            unless $user->{'email'};
        $user->{'reception'} ||= 'mail';
        unless ($self->is_available_reception_mode($user->{'reception'})) {
            $user->{'reception'} = $self->default_user_options->{'reception'};
        }
        $user->{'update_date'} ||= $user->{'date'};

        $main::logger->do_log(Sympa::Logger::DEBUG2, '(email = %s)',
            $user->{'email'});
        if (defined $user->{custom_attribute}) {
            my $custom_attr =
                parseCustomAttribute($user->{'custom_attribute'});
            unless (defined $custom_attr) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    "Failed to parse custom attributes for user %s, list %s",
                    $user->{'email'},
                    $self
                );
            }
            $user->{'custom_attribute'} = $custom_attr;
        }
    } else {
        $sth->finish;
        $sth = pop @sth_stack;
    }

    return $user;
}

## Loop for all subsequent admin users with the role defined in
## get_first_list_admin.
sub get_next_list_admin {
    my $self = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG3, '');

    unless (defined $sth) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Statement handle not defined, get_first_list_admin(%s) was not run',
            $self
        );
        return undef;
    }

    my $admin_user = $sth->fetchrow_hashref('NAME_lc');

    if (defined $admin_user) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Warning: entry with empty email address in list %s', $self)
            unless $admin_user->{'email'};
        $admin_user->{'reception'}   ||= 'mail';
        $admin_user->{'update_date'} ||= $admin_user->{'date'};
    } else {
        $sth->finish;
        $sth = pop @sth_stack;
    }
    return $admin_user;
}

## Returns the first bouncing user

sub get_first_bouncing_list_member {
    my $self = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '');

    my $name = $self->name;

    push @sth_stack, $sth;
    unless (
        $sth = Sympa::DatabaseManager::do_prepared_query(
            sprintf(
                q{SELECT %s
		FROM subscriber_table
		WHERE list_subscriber = ? AND robot_subscriber = ? AND
		      bounce_subscriber is not NULL},
                _list_member_cols()
            ),
            $name,
            $self->domain
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unable to get bouncing users %s',
            $self);
        $sth = pop @sth_stack;
        return undef;
    }

    my $user = $sth->fetchrow_hashref('NAME_lc');

    $sth->finish;
    $sth = pop @sth_stack;

    if (defined $user) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Warning: entry with empty email address in list %s', $self)
            unless $user->{'email'};
    }
    return $user;
}

## Loop for all subsequent bouncing users.
sub get_next_bouncing_list_member {
    my $self = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '');

    unless (defined $sth) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'No handle defined, get_first_bouncing_list_member(%s) was not run',
            $self
        );
        return undef;
    }

    my $user = $sth->fetchrow_hashref('NAME_lc');

    if (defined $user) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Warning: entry with empty email address in list %s', $self)
            unless $user->{'email'};

        if (defined $user->{custom_attribute}) {
            $user->{'custom_attribute'} =
                parseCustomAttribute($user->{'custom_attribute'});
        }

    } else {
        $sth->finish;
        $sth = pop @sth_stack;
    }

    return $user;
}

sub get_info {
    my $self = shift;

    my $info;

    unless (open INFO, $self->dir . '/info') {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Could not open %s : %s',
            $self->dir . '/info', $ERRNO
        );
        return undef;
    }

    while (<INFO>) {
        $info .= $_;
    }
    close INFO;

    return $info;
}

## Total bouncing subscribers
sub get_total_bouncing {
    my $self = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sympa::List::get_total_bouncing');

    my $name = $self->name;

    push @sth_stack, $sth;

    ## Query the Database
    unless (
        $sth = Sympa::DatabaseManager::do_prepared_query(
            q{SELECT count(*)
	      FROM subscriber_table
	      WHERE list_subscriber = ? AND robot_subscriber = ? AND
		    bounce_subscriber is not NULL},
            $name, $self->domain
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to gather bouncing subscribers count for list %s', $self);
        $sth = pop @sth_stack;
        return undef;
    }

    my $total = $sth->fetchrow;

    $sth->finish();

    $sth = pop @sth_stack;

    return $total;
}

## Is the indicated person a subscriber to the list?
sub is_list_member {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self = shift;
    return $self->user('member', shift) ? 1 : undef;
}

## Sets new values for the given user (except gecos)
sub update_list_member {
    my ($self, $who, $values) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', $who);
    $who = Sympa::Tools::clean_email($who);

    my ($field, $value, $table);
    my $name = $self->name;

    ## mapping between var and field names
    my %map_field = (
        reception            => 'reception_subscriber',
        topics               => 'topics_subscriber',
        visibility           => 'visibility_subscriber',
        date                 => 'date_subscriber',
        update_date          => 'update_subscriber',
        gecos                => 'comment_subscriber',
        password             => 'password_user',
        bounce               => 'bounce_subscriber',
        score                => 'bounce_score_subscriber',
        email                => 'user_subscriber',
        subscribed           => 'subscribed_subscriber',
        included             => 'included_subscriber',
        id                   => 'include_sources_subscriber',
        bounce_address       => 'bounce_address_subscriber',
        custom_attribute     => 'custom_attribute_subscriber',
        suspend              => 'suspend_subscriber',
        startdate_subscriber => 'suspend_start_date_subscriber',
        enddate              => 'suspend_end_date_subscriber'
    );

    ## mapping between var and tables
    my %map_table = (
        reception        => 'subscriber_table',
        topics           => 'subscriber_table',
        visibility       => 'subscriber_table',
        date             => 'subscriber_table',
        update_date      => 'subscriber_table',
        gecos            => 'subscriber_table',
        password         => 'user_table',
        bounce           => 'subscriber_table',
        score            => 'subscriber_table',
        email            => 'subscriber_table',
        subscribed       => 'subscriber_table',
        included         => 'subscriber_table',
        id               => 'subscriber_table',
        bounce_address   => 'subscriber_table',
        custom_attribute => 'subscriber_table',
        suspend          => 'subscriber_table',
        startdate        => 'subscriber_table',
        enddate          => 'subscriber_table'
    );

    ## additional DB fields
    if (defined Sympa::Site->db_additional_subscriber_fields) {
        foreach
            my $f (split ',', Sympa::Site->db_additional_subscriber_fields) {
            $map_table{$f} = 'subscriber_table';
            $map_field{$f} = $f;
        }
    }

    if (defined Sympa::Site->db_additional_user_fields) {
        foreach my $f (split ',', Sympa::Site->db_additional_user_fields) {
            $map_table{$f} = 'user_table';
            $map_field{$f} = $f;
        }
    }

##    $main::logger->do_log(Sympa::Logger::DEBUG2,
##	'custom_attribute id: %s', Sympa::Site->custom_attribute);
##    ## custom attributes
##    if (defined Sympa::Site->custom_attribute) {
##	foreach my $f (sort keys %{Sympa::Site->custom_attribute}) {
##	    $main::logger->do_log(Sympa::Logger::DEBUG2,
##
##		"custom_attribute id: Sympa::Site->custom_attribute->{id} name: Sympa::Site->custom_attribute->{name} type: Sympa::Site->custom_attribute->{type} "
##	    );
##
##	}
##    }

    ## Update each table
    foreach $table ('user_table', 'subscriber_table') {

        my @set_list;
        while (($field, $value) = each %{$values}) {

            unless ($map_field{$field} and $map_table{$field}) {
                $main::logger->do_log(Sympa::Logger::ERR, 'Unknown database field %s',
                    $field);
                next;
            }

            if ($map_table{$field} eq $table) {
                if ($field eq 'date' || $field eq 'update_date') {
                    $value = Sympa::DatabaseManager::get_canonical_write_date(
                        $value);
                } elsif ($value eq 'NULL') {    ## get_null_value?
                    if (Sympa::Site->db_type eq 'mysql') {
                        $value = '\N';
                    }
                } else {
                    if ($numeric_field{$map_field{$field}}) {
                        $value ||= 0;           ## Can't have a null value
                    } else {
                        $value = Sympa::DatabaseManager::quote($value);
                    }
                }
                my $set = sprintf "%s=%s", $map_field{$field}, $value;
                push @set_list, $set;
            }
        }
        next unless @set_list;

        ## Update field
        if ($table eq 'user_table') {
            unless (
                Sympa::DatabaseManager::do_query(
                    "UPDATE %s SET %s WHERE (email_user=%s)",
                    $table,
                    join(',', @set_list),
                    Sympa::DatabaseManager::quote($who)
                )
                ) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Could not update information for user %s in table %s',
                    $who, $table);
                return undef;
            }
        } elsif ($table eq 'subscriber_table') {
            if ($who eq '*') {
                unless (
                    Sympa::DatabaseManager::do_query(
                        "UPDATE %s SET %s WHERE (list_subscriber=%s AND robot_subscriber = %s)",
                        $table,
                        join(',', @set_list),
                        Sympa::DatabaseManager::quote($name),
                        Sympa::DatabaseManager::quote($self->domain)
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        'Could not update information for user %s in table %s for list %s',
                        $who,
                        $table,
                        $self
                    );
                    return undef;
                }
            } else {
                unless (
                    Sympa::DatabaseManager::do_query(
                        "UPDATE %s SET %s WHERE (user_subscriber=%s AND list_subscriber=%s AND robot_subscriber = %s)",
                        $table,
                        join(',', @set_list),
                        Sympa::DatabaseManager::quote($who),
                        Sympa::DatabaseManager::quote($name),
                        Sympa::DatabaseManager::quote($self->domain)
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        'Could not update information for user %s in table %s for list %s',
                        $who,
                        $table,
                        $self
                    );
                    return undef;
                }
            }
        }
    }

    ## Rename picture on disk if user email changed
    if ($values->{'email'}) {
        foreach my $path ($self->find_picture_paths($who)) {
            my $extension = [reverse split /\./, $path]->[0];
            my $new_path = $self->get_picture_path(
                Digest::MD5::md5_hex($values->{'email'}) . '.' . $extension
            );
            unless (rename $path, $new_path) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Failed to rename %s to %s : %s',
                    $path, $new_path, $ERRNO);
                last;
            }
        }
    }

    ## Reset session cache
    $self->user('member', $who, undef);
    $self->user('member', $who);

    return 1;
}

## Sets new values for the given admin user (except gecos)
sub update_list_admin {
    my ($self, $who, $role, $values) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s,%s)', $role, $who);
    $who = Sympa::Tools::clean_email($who);

    my ($field, $value, $table);

    my $name = $self->name;

    ## mapping between var and field names
    my %map_field = (
        reception   => 'reception_admin',
        visibility  => 'visibility_admin',
        date        => 'date_admin',
        update_date => 'update_admin',
        gecos       => 'comment_admin',
        password    => 'password_user',
        email       => 'user_admin',
        subscribed  => 'subscribed_admin',
        included    => 'included_admin',
        id          => 'include_sources_admin',
        info        => 'info_admin',
        profile     => 'profile_admin',
        role        => 'role_admin'
    );

    ## mapping between var and tables
    my %map_table = (
        reception   => 'admin_table',
        visibility  => 'admin_table',
        date        => 'admin_table',
        update_date => 'admin_table',
        gecos       => 'admin_table',
        password    => 'user_table',
        email       => 'admin_table',
        subscribed  => 'admin_table',
        included    => 'admin_table',
        id          => 'admin_table',
        info        => 'admin_table',
        profile     => 'admin_table',
        role        => 'admin_table'
    );
#### ??
    ## additional DB fields
    #    if (defined Sympa::Site->db_additional_user_fields) {
    #	foreach my $f (split ',', Sympa::Site->db_additional_user_fields) {
    #	    $map_table{$f} = 'user_table';
    #	    $map_field{$f} = $f;
    #	}
    #    }

    ## Update each table
    foreach $table ('user_table', 'admin_table') {

        my @set_list;
        while (($field, $value) = each %{$values}) {

            unless ($map_field{$field} and $map_table{$field}) {
                $main::logger->do_log(Sympa::Logger::ERR, 'Unknown database field %s',
                    $field);
                next;
            }

            if ($map_table{$field} eq $table) {
                if ($field eq 'date' || $field eq 'update_date') {
                    $value = Sympa::DatabaseManager::get_canonical_write_date(
                        $value);
                } elsif ($value eq 'NULL') {    #get_null_value?
                    if (Sympa::Site->db_type eq 'mysql') {
                        $value = '\N';
                    }
                } else {
                    if ($numeric_field{$map_field{$field}}) {
                        $value ||= 0;           ## Can't have a null value
                    } else {
                        $value = Sympa::DatabaseManager::quote($value);
                    }
                }
                my $set = sprintf "%s=%s", $map_field{$field}, $value;

                push @set_list, $set;
            }
        }
        next unless @set_list;

        ## Update field
        if ($table eq 'user_table') {
            unless (
                $sth = Sympa::DatabaseManager::do_query(
                    "UPDATE %s SET %s WHERE (email_user=%s)",
                    $table,
                    join(',', @set_list),
                    Sympa::DatabaseManager::quote($who)
                )
                ) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Could not update information for admin %s in table %s',
                    $who, $table);
                return undef;
            }

        } elsif ($table eq 'admin_table') {
            if ($who eq '*') {
                unless (
                    $sth = Sympa::DatabaseManager::do_query(
                        "UPDATE %s SET %s WHERE (list_admin=%s AND robot_admin=%s AND role_admin=%s)",
                        $table,
                        join(',', @set_list),
                        Sympa::DatabaseManager::quote($name),
                        Sympa::DatabaseManager::quote($self->domain),
                        Sympa::DatabaseManager::quote($role)
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        'Could not update information for admin %s in table %s for list %s',
                        $who,
                        $table,
                        $self
                    );
                    return undef;
                }
            } else {
                unless (
                    $sth = Sympa::DatabaseManager::do_query(
                        "UPDATE %s SET %s WHERE (user_admin=%s AND list_admin=%s AND robot_admin=%s AND role_admin=%s )",
                        $table,
                        join(',', @set_list),
                        Sympa::DatabaseManager::quote($who),
                        Sympa::DatabaseManager::quote($name),
                        Sympa::DatabaseManager::quote($self->domain),
                        Sympa::DatabaseManager::quote($role)
                    )
                    ) {
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        'Could not update information for admin %s in table %s for list %s',
                        $who,
                        $table,
                        $self
                    );
                    return undef;
                }
            }
        }
    }

    ## Reset session cache
    $self->user($role, $who, undef);
    $self->user($role, $who);

    return 1;
}

## Adds a list member ; no overwrite.
sub add_list_member {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, ...)', @_);
    my ($self, @new_users, $daemon) = @_;    #FIXME: $daemon will be empty

    my $name = $self->name;
    $self->{'add_outcome'}                                   = undef;
    $self->{'add_outcome'}{'added_members'}                  = 0;
    $self->{'add_outcome'}{'expected_number_of_added_users'} = $#new_users;
    $self->{'add_outcome'}{'remaining_members_to_add'} =
        $self->{'add_outcome'}{'expected_number_of_added_users'};

    my $subscriptions              = $self->get_subscription_requests();
    my $current_list_members_count = $self->total;

    foreach my $new_user (@new_users) {
        my $who = Sympa::Tools::clean_email($new_user->{'email'});
        next unless $who;
        unless ($current_list_members_count < $self->max_list_members
            or $self->max_list_members == 0) {
            $self->{'add_outcome'}{'errors'}{'max_list_members_exceeded'} = 1;
            $main::logger->do_log(
                Sympa::Logger::NOTICE,
                'Subscription of user %s failed: max number of subscribers (%s) reached',
                $new_user->{'email'},
                $self->max_list_members
            );
            last;
        }

        # Delete from exclusion_table and force a sync_include if new_user was
        # excluded
        if ($self->insert_delete_exclusion($who, 'delete')) {
            $self->sync_include();
            next if ($self->is_list_member($who));
        }
        $new_user->{'date'} ||= time;
        $new_user->{'update_date'} ||= $new_user->{'date'};

        my %custom_attr = %{$subscriptions->{$who}{'custom_attribute'}}
            if (defined $subscriptions->{$who}{'custom_attribute'});
        $new_user->{'custom_attribute'} ||=
            createXMLCustomAttribute(\%custom_attr);
        $main::logger->do_log(
            Sympa::Logger::DEBUG2,
            'custom_attribute = %s',
            $new_user->{'custom_attribute'}
        );

        $self->user('member', $who, undef);

        ## Either is_included or is_subscribed must be set
        ## default is is_subscriber for backward compatibility reason
        unless ($new_user->{'included'}) {
            $new_user->{'subscribed'} = 1;
        }

        unless ($new_user->{'included'}) {
            ## Is the email in user table?
            ## Insert in User Table
            unless (
                Sympa::User->new(
                    email    => $who,
                    fields   => Sympa::Site->db_additional_user_fields,
                    gecos    => $new_user->{'gecos'},
                    lang     => $new_user->{'lang'},
                    password => $new_user->{'password'}
                )
                ) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Unable to add user %s to user_table.', $who);
                $self->{'add_outcome'}{'errors'}
                    {'unable_to_add_to_database'} = 1;
                next;
            }
        }

        $new_user->{'subscribed'} ||= 0;
        $new_user->{'included'}   ||= 0;

        #Log in stat_table to make statistics
        Sympa::Monitor::db_stat_log(
            'robot'     => $self->domain,
            'list'      => $self->name,
            'operation' => 'add subscriber',
            'mail'      => $new_user->{'email'},
            'daemon'    => $daemon
        );

        ## Update Subscriber Table
        unless (
            Sympa::DatabaseManager::do_query(
                q{INSERT INTO subscriber_table
		  (user_subscriber, comment_subscriber,
		   list_subscriber, robot_subscriber,
		   date_subscriber,
		   update_subscriber,
		   reception_subscriber,
		   topics_subscriber,
		   visibility_subscriber,
		   subscribed_subscriber,
		   included_subscriber,
		   include_sources_subscriber,
		   custom_attribute_subscriber,
		   suspend_subscriber,
		   suspend_start_date_subscriber, suspend_end_date_subscriber)
		  VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %d,
			  %d, %s, %s, %d, %d, %d)},
                Sympa::DatabaseManager::quote($who),
                Sympa::DatabaseManager::quote($new_user->{'gecos'}),
                Sympa::DatabaseManager::quote($name),
                Sympa::DatabaseManager::quote($self->domain),
                Sympa::DatabaseManager::get_canonical_write_date(
                    $new_user->{'date'}
                ),
                Sympa::DatabaseManager::get_canonical_write_date(
                    $new_user->{'update_date'}
                ),
                Sympa::DatabaseManager::quote($new_user->{'reception'}),
                Sympa::DatabaseManager::quote($new_user->{'topics'}),
                Sympa::DatabaseManager::quote($new_user->{'visibility'}),
                ($new_user->{'subscribed'} ? 1 : 0),
                ($new_user->{'included'}   ? 1 : 0),
                Sympa::DatabaseManager::quote($new_user->{'id'}),
                Sympa::DatabaseManager::quote(
                    $new_user->{'custom_attribute'}
                ),
                ($new_user->{'suspend'} ? 1 : 0),
                $new_user->{'startdate'},
                $new_user->{'enddate'}
            )
            ) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Unable to add subscriber %s to table subscriber_table for list %s',
                $who,
                $self
            );
            next;
        }
        $self->{'add_outcome'}{'added_members'}++;
        $self->{'add_outcome'}{'remaining_member_to_add'}--;
        $current_list_members_count++;
    }

    $self->total($self->total + $self->{'add_outcome'}{'added_members'});
    $self->savestats();
    $self->_create_add_error_string() if ($self->{'add_outcome'}{'errors'});
    return 1;
}

sub _create_add_error_string {
    my $self = shift;
    $self->{'add_outcome'}{'errors'}{'error_message'} = '';
    if ($self->{'add_outcome'}{'errors'}{'max_list_members_exceeded'}) {
	$self->{'add_outcome'}{'errors'}{'error_message'} .= $main::language->gettext_sprintf('Attempt to exceed the max number of members (%s) for this list.', $self->max_list_members);
    }
    if ($self->{'add_outcome'}{'errors'}{'unable_to_add_to_database'}) {
        $self->{'add_outcome'}{'error_message'} .=
            ' ' . $main::language->gettext('Attempts to add some users in database failed.');
    }
    $self->{'add_outcome'}{'errors'}{'error_message'} .= ' '. $main::language->gettext_sprintf('Added %s users out of %s required.', $self->{'add_outcome'}{'added_members'},$self->{'add_outcome'}{'expected_number_of_added_users'});
}

## Adds a new list admin user, no overwrite.
sub add_list_admin {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, ...)', @_);
    my ($self, $role, @new_admin_users) = @_;

    my $name  = $self->name;
    my $total = 0;

    foreach my $new_admin_user (@new_admin_users) {
        my $who = Sympa::Tools::clean_email($new_admin_user->{'email'});

        next unless $who;

        $new_admin_user->{'date'} ||= time;
        $new_admin_user->{'update_date'} ||= $new_admin_user->{'date'};

        $self->user($role, $who, undef);

        ##  either is_included or is_subscribed must be set
        ## default is is_subscriber for backward compatibility reason
        unless ($new_admin_user->{'included'}) {
            $new_admin_user->{'subscribed'} = 1;
        }

        unless ($new_admin_user->{'included'}) {
            ## Is the email in user table?
            ## Insert in User Table
            unless (
                Sympa::User->new(
                    email    => $who,
                    fields   => Sympa::Site->db_additional_user_fields,
                    gecos    => $new_admin_user->{'gecos'},
                    lang     => $new_admin_user->{'lang'},
                    password => $new_admin_user->{'password'}
                )
                ) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Unable to add admin %s to user_table', $who);
                next;
            }
        }

        $new_admin_user->{'subscribed'} ||= 0;
        $new_admin_user->{'included'}   ||= 0;

        ## Update Admin Table
        unless (
            Sympa::DatabaseManager::do_query(
                q{INSERT INTO admin_table
		  (user_admin, comment_admin, list_admin, robot_admin,
		   date_admin, update_admin,
		   reception_admin, visibility_admin,
		   subscribed_admin, included_admin, include_sources_admin,
		   role_admin, info_admin, profile_admin)
		  VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %d, %d,
			  %s, %s, %s, %s)},
                Sympa::DatabaseManager::quote($who),
                Sympa::DatabaseManager::quote($new_admin_user->{'gecos'}),
                Sympa::DatabaseManager::quote($name),
                Sympa::DatabaseManager::quote($self->domain),
                Sympa::DatabaseManager::get_canonical_write_date(
                    $new_admin_user->{'date'}
                ),
                Sympa::DatabaseManager::get_canonical_write_date(
                    $new_admin_user->{'update_date'}
                ),
                Sympa::DatabaseManager::quote($new_admin_user->{'reception'}),
                Sympa::DatabaseManager::quote(
                    $new_admin_user->{'visibility'}
                ),
                ($new_admin_user->{'subscribed'} ? 1 : 0),
                ($new_admin_user->{'included'}   ? 1 : 0),
                Sympa::DatabaseManager::quote($new_admin_user->{'id'}),
                Sympa::DatabaseManager::quote($role),
                Sympa::DatabaseManager::quote($new_admin_user->{'info'}),
                Sympa::DatabaseManager::quote($new_admin_user->{'profile'})
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to add admin %s to table admin_table for list %s',
                $who, $self);
            next;
        }
        $total++;
    }

    return $total;
}

#XXX sub rename_list_db

## Does the user have a particular function in the list?
sub am_i {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, %s)', @_);
    my $self     = shift;
    my $function = lc(shift || '');
    my $who      = Sympa::Tools::clean_email(shift || '');
    my $options  = shift || {};

    return undef unless $self and $who;

    ## If 'strict' option is given, then listmaster does not inherit
    ## privileged
    unless ($options->{'strict'}) {
        ## Listmaster has all privileges except editor
        # sa contestable.
        if (($function eq 'owner' || $function eq 'privileged_owner')
            and $self->robot->is_listmaster($who)) {

            #$self->user('owner', $who, { 'profile' => 'privileged' });
            return 1;
        }
    }

    if ($function eq 'privileged_owner') {
        if (    $self->user('owner', $who)
            and $self->user('owner', $who)->{'profile'} eq 'privileged') {
            return 1;
        }
    } elsif ($function eq 'editor') {
        if ($self->user('editor', $who)) {
            return 1;
        }
        ## Check if any editor is defined ; if not owners are editors
        my $editors = $self->get_editors() || [];
        unless (scalar @$editors) {

            # if no editor defined, owners has editor privilege
            if ($self->user('owner', $who)) {
                return 1;
            }
        }
    } elsif ($self->user($function, $who)) {
        return 1;
    }

    return undef;
}

## Initialize internal list cache
sub init_list_cache {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '()');
    foreach my $robot (@{Sympa::VirtualHost::get_robots() || []}) {
        $robot->init_list_cache();
    }
}

## May the indicated user edit the indicated list parameter or not?
sub may_edit {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s)', @_);
    my ($self, $parameter, $who) = @_;

    my $role;

    return undef unless $self;

    my $edit_conf;

    # Load edit_list.conf: track by file, not domain (file may come from
    # server, robot, family or list context)
    my $edit_conf_file = $self->get_etc_filename('edit_list.conf');
    if (!$edit_list_conf{$edit_conf_file}
        || ((stat($edit_conf_file))[9] >
            $mtime{'edit_list_conf'}{$edit_conf_file})
        ) {

        $edit_conf = $edit_list_conf{$edit_conf_file} =
            $self->_load_edit_list_conf();
        $mtime{'edit_list_conf'}{$edit_conf_file} = time;
    } else {
        $edit_conf = $edit_list_conf{$edit_conf_file};
    }

    ## What privilege?
    if ($self->robot->is_listmaster($who)) {
        $role = 'listmaster';
    } elsif ($self->am_i('privileged_owner', $who)) {
        $role = 'privileged_owner';
    } elsif ($self->am_i('owner', $who)) {
        $role = 'owner';
    } elsif ($self->am_i('editor', $who)) {
        $role = 'editor';

        #    } elsif ($self->am_i('subscriber',$who)) {
        #	$role = 'subscriber';
    } else {
        return ('user', 'hidden');
    }

    ## What privilege does he/she has?
    my ($what, @order);

    if (   ($parameter =~ /^(\w+)\.(\w+)$/)
        && ($parameter !~ /\.tt2$/)) {
        my $main_parameter = $1;
        @order = (
            $edit_conf->{$parameter}{$role},
            $edit_conf->{$main_parameter}{$role},
            $edit_conf->{'default'}{$role},
            $edit_conf->{'default'}{'default'}
        );
    } else {
        @order = (
            $edit_conf->{$parameter}{$role},
            $edit_conf->{'default'}{$role},
            $edit_conf->{'default'}{'default'}
        );
    }

    foreach $what (@order) {
        if (defined $what) {
            return ($role, $what);
        }
    }

    return ('user', 'hidden');
}

## May the indicated user edit a parameter while creating a new list
## Dev note: This sub is never called. Shall we remove it?
sub may_create_parameter {

    my ($self, $parameter, $who, $robot) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG3,
        'Sympa::List::may_create_parameter(%s, %s, %s)',
        $parameter, $who, $robot);

    if ($self->robot->is_listmaster($who)) {
        return 1;
    }
    my $edit_conf = $self->_load_edit_list_conf();
    $edit_conf->{$parameter} ||= $edit_conf->{'default'};
    if (!$edit_conf->{$parameter}) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Sympa::Tools::load_edit_list_conf privilege for parameter $parameter undefined'
        );
        return undef;
    }
    if ($edit_conf->{$parameter} =~ /^(owner|privileged_owner)$/i) {
        return 1;
    } else {
        return 0;
    }

}

## May the indicated user do something with the list or not?
## Action can be : send, review, index, get
##                 add, del, reconfirm, purge
sub may_do {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s)', @_);
    my $self   = shift;
    my $action = lc(shift || '');
    my $who    = lc(shift || '');

    my $i;

    ## Just in case.
    return undef unless $self and $action;

    if ($action =~ /^(index|get)$/io) {
        my $arc_access = $self->archive->{'access'};
        if ($arc_access =~ /^public$/io) {
            return 1;
        } elsif ($arc_access =~ /^private$/io) {
            return 1 if ($self->is_list_member($who));
            return $self->am_i('owner', $who);
        } elsif ($arc_access =~ /^owner$/io) {
            return $self->am_i('owner', $who);
        }
        return undef;
    }

    ##XXX Won't work.  Use scenario.
    if ($action =~ /^(review)$/io) {
        foreach $i (@{$self->review}) {
            if ($i =~ /^public$/io) {
                return 1;
            } elsif ($i =~ /^private$/io) {
                return 1 if ($self->is_list_member($who));
                return $self->am_i('owner', $who);
            } elsif ($i =~ /^owner$/io) {
                return $self->am_i('owner', $who);
            }
            return undef;
        }
    }

    ##XXX Won't work.  Use scenario.
    if ($action =~ /^send$/io) {
        if ($self->send =~
            /^(private|privateorpublickey|privateoreditorkey)$/i) {

            return undef
                unless ($self->is_list_member($who)
                || $self->am_i('owner', $who));
        } elsif ($self->send =~ /^(editor|editorkey|privateoreditorkey)$/i) {
            return undef unless ($self->am_i('editor', $who));
        } elsif ($self->send =~ /^(editorkeyonly|publickey|privatekey)$/io) {
            return undef;
        }
        return 1;
    }

    ##XXX Won't work.  Use scenario.
    if ($action =~ /^(add|del|remind|reconfirm|purge)$/io) {
        return $self->am_i('owner', $who);
    }

    if ($action =~ /^(modindex)$/io) {
        return undef unless ($self->am_i('editor', $who));
        return 1;
    }

    ##XXX Won't work.  Use scenario.
    if ($action =~ /^auth$/io) {
        if ($self->send =~ /^(privatekey)$/io) {
            return 1
                if ($self->is_list_member($who)
                || $self->am_i('owner', $who));
        } elsif ($self->send =~ /^(privateorpublickey)$/io) {
            return 1
                unless ($self->is_list_member($who)
                || $self->am_i('owner', $who));
        } elsif ($self->send =~ /^(publickey)$/io) {
            return 1;
        }
        return undef;    #authent
    }
    return undef;
}

## Does the list support digest mode
sub is_digest {
    return shift->digest;
}

## Does the file exist?
sub archive_exist {
    my ($self, $file) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG, 'Sympa::List::archive_exist (%s)',
        $file);

    return undef unless ($self->is_archived());
    my $dir = $self->robot->arc_path . '/' . $self->get_id;
    Sympa::Archive::exist($dir, $file);

}

## List the archived files
sub archive_ls {
    my $self = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sympa::List::archive_ls');

    my $dir = $self->robot->arc_path . '/' . $self->get_id;

    Sympa::Archive::list($dir) if ($self->is_archived());
}

## Archive
sub archive_msg {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my ($self, $message) = @_;

    if ($self->is_archived()) {
        my $msgtostore;    # Stringified message without metadata
        if (    $message->is_encrypted()
            and ($self->archive_crypted_msg eq 'original')) {
            $main::logger->do_log(Sympa::Logger::DEBUG3,
                'Will store encrypted message');
            $msgtostore = $message->as_string();
        } else {
            $main::logger->do_log(Sympa::Logger::DEBUG3,
                'Will store UNencrypted message');
            $msgtostore = $message->as_string();
        }

        my $x_no_archive =
            $message->as_entity()->head->get('X-no-archive');
        my $restrict = $message->as_entity()->head->get('Restrict');
        if (Sympa::Site->ignore_x_no_archive_header_feature ne 'on'
            and (  $x_no_archive and $x_no_archive =~ /yes/i
                or $restrict and $restrict =~ /no\-external\-archive/i)
            ) {
            ## ignoring message with a no-archive flag
            $main::logger->do_log(Sympa::Logger::INFO,
                'Do not archive message with no-archive flag for list %s',
                $self);
        } else {
            my $spoolarchive = Sympa::Spool::File::Message->new(
                name      => 'outgoing',
                directory => Sympa::Site->queueoutgoing()
            );
            unless (
                $spoolarchive->store(
                    $msgtostore,
                    {'list' => $self->name, 'robot' => $self->domain}
                )
                ) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Could not store message %s in archive spool: %s',
                    $message, $ERRNO);
                return undef;
            }
        }
    }
    return 1;
}

## Is the list moderated?
sub is_moderated {
    return 1 if scalar @{shift->editor};
    return 0;
}

## Is the list archived?
sub is_archived {
    if (shift->web_archive->{'access'}) {
        $main::logger->do_log(Sympa::Logger::DEBUG, 'Sympa::List::is_archived : 1');
        return 1;
    }
    return undef;
}

## Is the list web archived?
sub is_web_archived {
    return 1 if shift->web_archive->{'access'};
    return undef;

}

## Returns 1 if the  digest  must be send
sub get_nextdigest {
    my $self = shift;
    my $date = shift;    # the date epoch as stored in the spool database

    $main::logger->do_log(Sympa::Logger::DEBUG3,
        'Sympa::List::get_nextdigest (list = %s)', $self);

    my $digest = $self->digest;

    unless ($digest and scalar keys %$digest) {
        return undef;
    }

    my @days = @{$digest->{'days'}};
    my ($hh, $mm) = ($digest->{'hour'}, $digest->{'minute'});

    my @now        = localtime(time);
    my $today      = $now[6];            # current day
    my @timedigest = localtime($date);

    ## Should we send a digest today
    my $send_digest = 0;
    foreach my $d (@days) {
        if ($d == $today) {
            $send_digest = 1;
            last;
        }
    }

    return undef unless ($send_digest == 1);

    if (($now[2] * 60 + $now[1]) >= ($hh * 60 + $mm)
        and (
            Time::Local::timelocal(0, $mm, $hh, $now[3], $now[4], $now[5]) >
            Time::Local::timelocal(
                0,              $timedigest[1], $timedigest[2],
                $timedigest[3], $timedigest[4], $timedigest[5]
            )
        )
        ) {
        return 1;
    }

    return undef;
}

## Loads all scenarios for an action
sub load_scenario_list {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self   = shift;
    my $action = shift;

    my %list_of_scenario;
    my %skip_scenario;
    my %scenario_alias;

    foreach my $dir (@{$self->get_etc_include_path('scenari')}) {
        next unless -d $dir;

        my $scenario_regexp = Sympa::Tools::get_regexp('scenario');

        while (<$dir/$action.*:ignore>) {
            if (/$action\.($scenario_regexp):ignore$/) {
                my $name = $1;
                $skip_scenario{$name} = 1;
            }
        }

        while (<$dir/$action.*>) {
            next unless (/$action\.($scenario_regexp)$/);
            my $name = $1;

            next if defined $list_of_scenario{$name};
            next if defined $skip_scenario{$name};

            my $scenario = Sympa::Scenario->new(
                that     => $self,
                function => $action,
                name     => $name
            );
            next unless $scenario;

            ## withhold adding aliased scenarios (they may be symlink).
            if ($scenario->{'name'} ne $name) {
                $scenario_alias{$scenario->{'name'}} = $scenario;
            } else {
                $list_of_scenario{$name} = $scenario;
            }
        }
    }

    ## add aliased scenarios if real path was not found.
    foreach my $name (keys %scenario_alias) {
        $list_of_scenario{$name} ||= $scenario_alias{$name};
    }

    return values %list_of_scenario;
}

=over 4

=item get_scenario

Get Scenario object about requested operation.

=back

=cut

sub get_scenario {
    my $self    = shift;
    my $op      = shift;

    return undef unless $op;
    my @op = split /\./, $op;

    my $pinfo = $self->robot->list_params;

    if (scalar @op > 1) {
        ## Structured parameter
        $op = $op[0];
        return undef
            unless exists $pinfo->{$op}
                and ref $pinfo->{$op}{'format'} eq 'HASH'
                and exists $pinfo->{$op}{'format'}{$op[1]}
                and $pinfo->{$op}{'format'}{$op[1]}{'scenario'};
        ## reload cached value if needed
        return $self->$op($self->$op)->{$op[1]};
    } else {
        ## Simple parameter
        return undef
            unless exists $pinfo->{$op} and $pinfo->{$op}{'scenario'};
        ## reload cached value if needed
        return $self->$op($self->$op);
    }
}

sub load_task_list {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self   = shift;
    my $action = shift;

    my %list_of_task;

    foreach my $dir (@{$self->get_etc_include_path('list_task_models')}) {
        next unless (-d $dir);

	LOOP_FOREACH_FILE:
        foreach my $file (<$dir/$action.*>) {
            next unless ($file =~ /$action\.(\w+)\.task$/);
            my $name = $1;

            next if (defined $list_of_task{$name});

            $list_of_task{$name}{'name'} = $name;

            my $titles = Sympa::List::_load_task_title($file);

            ## Set the title in the current language
	    foreach my $lang (
		Sympa::Language::implicated_langs($main::language->get_lang)
	    ) {
		if (exists $titles->{$lang}) {
		    $list_of_task{$name}{'title'} = $titles->{$lang};
		    next LOOP_FOREACH_FILE;
		}
	    }
	    if (exists $titles->{'gettext'}) {
		$list_of_task{$name}{'title'} =
		    $main::language->gettext($titles->{'gettext'});
	    } elsif (exists $titles->{'default'}) {
		$list_of_task{$name}{'title'} = $titles->{'default'};
	    } else {
		$list_of_task{$name}{'title'} = $name;		     
                }
        }
    }

    return \%list_of_task;
}

sub _load_task_title {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $file   = shift;
    my $titles = {};

    unless (open TASK, '<', $file) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unable to open file "%s": %s',
            $file, $ERRNO);
        return undef;
    }

    while (<TASK>) {
        last if /^\s*$/;

	if (/^title\.gettext\s+(.*)\s*$/i) {
	    $titles->{'gettext'} = $1;
	} elsif (/^title\.(\S+)\s+(.*)\s*$/i) {
	     my ($lang, $title) = ($1, $2);
	    # canonicalize lang if possible.
	    $lang = Sympa::Language::canonic_lang($lang) || $lang;
	    $titles->{$lang} = $title;
	} elsif (/^title\s+(.*)\s*$/i) {
	     $titles->{'default'} = $1;
        }
    }

    close TASK;

    return $titles;
}

## Loads all data sources
## n.b. $robot is no longer used.
sub load_data_sources_list {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my ($self, $robot) = @_;

    my %list_of_data_sources;

    foreach my $dir (@{$self->get_etc_include_path('data_sources')}) {
        next unless (-d $dir);

        while (my $f = <$dir/*.incl>) {

            next unless ($f =~ /([\w\-]+)\.incl$/);

            my $name = $1;

            next if (defined $list_of_data_sources{$name});

            $list_of_data_sources{$name}{'title'} = $name;
            $list_of_data_sources{$name}{'name'}  = $name;
        }
    }

    return \%list_of_data_sources;
}

## Loads the statistics information
sub _load_stats_file {
    my $self = shift;

    croak "Invalid parameter: $self"
        unless ref $self;    #prototype changed (6.2)

    my $file = $self->dir . '/stats';
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, file=%s)', $self, $file);

    ## Create the initial stats array.
    my ($stats, $total, $last_sync, $last_sync_admin_user);

    if (open(L, $file)) {
        if (<L> =~
            /^(\d+)\s+(\d+)\s+(\d+)\s+(\d+)(\s+(\d+))?(\s+(\d+))?(\s+(\d+))?/)
        {
            $stats                = [$1, $2, $3, $4];
            $total                = $6;
            $last_sync            = $8;
            $last_sync_admin_user = $10;

        } else {
            $stats                = [0, 0, 0, 0];
            $total                = 0;
            $last_sync            = 0;
            $last_sync_admin_user = 0;
        }
        close(L);
    } else {
        $stats                = [0, 0, 0, 0];
        $total                = 0;
        $last_sync            = 0;
        $last_sync_admin_user = 0;
    }

    $self->{'last_sync'}            = $last_sync;
    $self->{'last_sync_admin_user'} = $last_sync_admin_user;
    $self->{'stats'}                = $stats if defined $stats;
    $self->total($total) if defined $total;
}

## Loads the list of subscribers.
sub _load_list_members_file {
    my $file = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', $file);

    ## Open the file and switch to paragraph mode.
    open(L, $file) || return undef;

    ## Process the lines
    local $RS;
    my $data = <L>;

    my @users;
    foreach (split /\n\n/, $data) {
        my (%user, $email);
        $user{'email'} = $email = $1 if (/^\s*email\s+(.+)\s*$/om);
        $user{'gecos'}       = $1 if (/^\s*gecos\s+(.+)\s*$/om);
        $user{'date'}        = $1 if (/^\s*date\s+(\d+)\s*$/om);
        $user{'update_date'} = $1 if (/^\s*update_date\s+(\d+)\s*$/om);
        $user{'reception'}   = $1
            if (
            /^\s*reception\s+(digest|nomail|summary|notice|txt|html|urlize|not_me)\s*$/om
            );
        $user{'visibility'} = $1
            if (/^\s*visibility\s+(conceal|noconceal)\s*$/om);

        push @users, \%user;
    }
    close(L);

    return @users;
}

## include a remote Sympa list as subscribers.
sub _include_users_remote_sympa_list {
    my ($self, $users, $param, $dir, $robot, $default_user_options, $tied) =
        @_;

    my $host = $param->{'host'};
    my $port = $param->{'port'} || '443';
    my $path = $param->{'path'};
    my $cert = $param->{'cert'} || 'list';

    my $id = Sympa::Datasource::_get_datasource_id($param);

    $main::logger->do_log(Sympa::Logger::DEBUG2, '%s: https://%s:%s/%s using cert %s',
        $self, $host, $port, $path, $cert);

    my $total     = 0;
    my $get_total = 0;

    my $cert_file;
    my $key_file;

    $cert_file = $dir . '/cert.pem';
    $key_file  = $dir . '/private_key';
    if ($cert eq 'list') {
        $cert_file = $dir . '/cert.pem';
        $key_file  = $dir . '/private_key';
    } elsif ($cert eq 'robot') {
        $cert_file = $self->get_etc_filename('cert.pem');
        $key_file  = $self->get_etc_filename('private_key');
    }
    unless ((-r $cert_file) && (-r $key_file)) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Include remote list https://%s:%s/%s using cert %s, unable to open %s or %s',
            $host,
            $port,
            $path,
            $cert,
            $cert_file,
            $key_file
        );
        return undef;
    }

    my $getting_headers = 1;

    my %user;
    my $email;

    foreach my $line (
        Sympa::Fetch::get_https(
            $host, $port, $path,
            $cert_file,
            $key_file,
            {   'key_passwd' => Sympa::Site->key_passwd,
                'cafile'     => Sympa::Site->cafile,
                'capath'     => Sympa::Site->capath
            }
        )
        ) {
        chomp $line;

        if ($getting_headers) {    # ignore HTTP headers
            next
                unless (
                $line =~ /^(date|update_date|email|reception|visibility)/);
        }
        undef $getting_headers;

        if ($line =~ /^\s*email\s+(.+)\s*$/o) {
            $user{'email'} = $email = $1;
            $main::logger->do_log(Sympa::Logger::DEBUG, "email found $email");
            $get_total++;
        }
        $user{'gecos'} = $1 if ($line =~ /^\s*gecos\s+(.+)\s*$/o);

        next unless ($line =~ /^$/);

        unless ($user{'email'}) {
            $main::logger->do_log(Sympa::Logger::DEBUG,
                'ignoring block without email definition');
            next;
        }
        my %u;
        ## Check if user has already been included
        if ($users->{$email}) {
            $main::logger->do_log(Sympa::Logger::DEBUG3,
                'ignore %s because already member', $email);
            if ($tied) {
                %u = split "\n", $users->{$email};
            } else {
                %u = %{$users->{$email}};
            }
        } else {
            $main::logger->do_log(Sympa::Logger::DEBUG3, 'add new subscriber %s',
                $email);
            %u = %{$default_user_options};
            $total++;
        }
        $u{'email'} = $user{'email'};
        $u{'id'}    = join(',', split(',', $u{'id'}), $id);
        $u{'gecos'} = $user{'gecos'};
        delete $user{'gecos'};

        $u{'visibility'} = $default_user_options->{'visibility'}
            if (defined $default_user_options->{'visibility'});
        $u{'reception'} = $default_user_options->{'reception'}
            if (defined $default_user_options->{'reception'});
        $u{'profile'} = $default_user_options->{'profile'}
            if (defined $default_user_options->{'profile'});
        $u{'info'} = $default_user_options->{'info'}
            if (defined $default_user_options->{'info'});

        if ($tied) {
            $users->{$email} = join("\n", %u);
        } else {
            $users->{$email} = \%u;
        }
        delete $user{$email};
        undef $email;

    }
    $main::logger->do_log(Sympa::Logger::INFO,
        'Include %d users from list (%d subscribers) https://%s:%s%s',
        $total, $get_total, $host, $port, $path);
    return $total;
}

## include a list as subscribers.
sub _include_users_list {
    my ($users, $includelistname, $robot, $default_user_options, $tied) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sympa::List::_include_users_list');

    my $total = 0;

    my $includelist;

    ## The included list is local or in another local robot
    if ($includelistname =~ /\@/) {
        $includelist = Sympa::List->new($includelistname);
    } else {
        $includelist = Sympa::List->new($includelistname, $robot);
    }

    unless ($includelist) {
        $main::logger->do_log(Sympa::Logger::INFO, 'Included list %s unknown',
            $includelistname);
        return undef;
    }

    my $id = Sympa::Datasource::_get_datasource_id($includelistname);

    for (
        my $user = $includelist->get_first_list_member();
        $user;
        $user = $includelist->get_next_list_member()
        ) {
        my %u;

        ## Check if user has already been included
        if ($users->{$user->{'email'}}) {
            if ($tied) {
                %u = split "\n", $users->{$user->{'email'}};
            } else {
                %u = %{$users->{$user->{'email'}}};
            }
        } else {
            %u = %{$default_user_options};
            $total++;
        }

        my $email = $u{'email'} = $user->{'email'};
        $u{'gecos'} = $user->{'gecos'};
        $u{'id'} = join(',', split(',', $u{'id'}), $id);

        $u{'visibility'} = $default_user_options->{'visibility'}
            if (defined $default_user_options->{'visibility'});
        $u{'reception'} = $default_user_options->{'reception'}
            if (defined $default_user_options->{'reception'});
        $u{'profile'} = $default_user_options->{'profile'}
            if (defined $default_user_options->{'profile'});
        $u{'info'} = $default_user_options->{'info'}
            if (defined $default_user_options->{'info'});

        if ($tied) {
            $users->{$email} = join("\n", %u);
        } else {
            $users->{$email} = \%u;
        }
    }
    $main::logger->do_log(Sympa::Logger::INFO, "Include %d users from list %s",
        $total, $includelistname);
    return $total;
}

sub _include_users_file {
    my ($users, $filename, $default_user_options, $tied) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG3,
        'Sympa::List::_include_users_file(%s)', $filename);

    my $total = 0;

    unless (open(INCLUDE, "$filename")) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unable to open file "%s"',
            $filename);
        return undef;
    }
    $main::logger->do_log(Sympa::Logger::DEBUG2, 'including file %s', $filename);

    my $id           = Sympa::Datasource::_get_datasource_id($filename);
    my $lines        = 0;
    my $emails_found = 0;
    my $email_regexp = Sympa::Tools::get_regexp('email');

    while (<INCLUDE>) {
        if ($lines > 49 && $emails_found == 0) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Too much errors in file %s (%s lines, %s emails found). Source file probably corrupted. Cancelling.',
                $filename,
                $lines,
                $emails_found
            );
            return undef;
        }

        ## Each line is expected to start with a valid email address
        ## + an optional gecos
        ## Empty lines are skipped
        next if /^\s*$/;
        next if /^\s*\#/;

        ## Skip badly formed emails
        unless (/^\s*($email_regexp)(\s*(\S.*))?\s*$/) {
            $main::logger->do_log(Sympa::Logger::ERR, "Skip badly formed line: '%s'",
                $_);
            next;
        }
        my ($email, $gecos) = ($1, $5);
        $email = Sympa::Tools::clean_email($email);

        unless (Sympa::Tools::valid_email($email)) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "Skip badly formed email address: '%s'", $email);
            next;
        }

        $lines++;
        next unless $email;
        $emails_found++;

        my %u;
        ## Check if user has already been included
        if ($users->{$email}) {
            if ($tied) {
                %u = split "\n", $users->{$email};
            } else {
                %u = %{$users->{$email}};
            }
        } else {
            %u = %{$default_user_options};
            $total++;
        }
        $u{'email'} = $email;
        $u{'gecos'} = $gecos;
        $u{'id'}    = join(',', split(',', $u{'id'}), $id);

        $u{'visibility'} = $default_user_options->{'visibility'}
            if (defined $default_user_options->{'visibility'});
        $u{'reception'} = $default_user_options->{'reception'}
            if (defined $default_user_options->{'reception'});
        $u{'profile'} = $default_user_options->{'profile'}
            if (defined $default_user_options->{'profile'});
        $u{'info'} = $default_user_options->{'info'}
            if (defined $default_user_options->{'info'});

        if ($tied) {
            $users->{$email} = join("\n", %u);
        } else {
            $users->{$email} = \%u;
        }
    }
    close INCLUDE;

    return $total;
}

sub _include_users_remote_file {
    my ($users, $param, $default_user_options, $tied) = @_;

    my $url = $param->{'url'};

    $main::logger->do_log(Sympa::Logger::DEBUG2,
        "Sympa::List::_include_users_remote_file($url)");

    my $total = 0;
    my $id    = Sympa::Datasource::_get_datasource_id($param);

    my $fetch =
        LWP::UserAgent->new(agent => 'Sympa/' . Sympa::Constants::VERSION);

    my $req = HTTP::Request->new(GET => $url);

    if (defined $param->{'user'} && defined $param->{'passwd'}) {

        # FIXME: set agent credentials,
        # requiring to compute realm and net location
    }

    my $res = $fetch->request($req);

    # check the outcome
    if ($res->is_success) {
        my @remote_file  = split(/\n/, $res->content);
        my $lines        = 0;
        my $emails_found = 0;
        my $email_regexp = Sympa::Tools::get_regexp('email');

        # forgot headers (all line before one that contain a email
        foreach my $line (@remote_file) {
            if ($lines > 49 && $emails_found == 0) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'Too much errors in file %s (%s lines, %s emails found). Source file probably corrupted. Cancelling.',
                    $url,
                    $lines,
                    $emails_found
                );
                return undef;
            }

            ## Each line is expected to start with a valid email address
            ## + an optional gecos
            ## Empty lines are skipped
            next if ($line =~ /^\s*$/);
            next if ($line =~ /^\s*\#/);

            ## Skip badly formed emails
            unless ($line =~ /^\s*($email_regexp)(\s*(\S.*))?\s*$/) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Skip badly formed line: '%s'", $line);
                next;
            }
            my ($email, $gecos) = ($1, $5);
            $email = Sympa::Tools::clean_email($email);

            unless (Sympa::Tools::valid_email($email)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Skip badly formed email address: '%s'", $line);
                next;
            }

            $lines++;
            next unless $email;
            $emails_found++;

            my %u;
            ## Check if user has already been included
            if ($users->{$email}) {
                if ($tied) {
                    %u = split "\n", $users->{$email};
                } else {
                    %u = %{$users->{$email}};
                }
            } else {
                %u = %{$default_user_options};
                $total++;
            }
            $u{'email'} = $email;
            $u{'gecos'} = $gecos;
            $u{'id'}    = join(',', split(',', $u{'id'}), $id);

            $u{'visibility'} = $default_user_options->{'visibility'}
                if (defined $default_user_options->{'visibility'});
            $u{'reception'} = $default_user_options->{'reception'}
                if (defined $default_user_options->{'reception'});
            $u{'profile'} = $default_user_options->{'profile'}
                if (defined $default_user_options->{'profile'});
            $u{'info'} = $default_user_options->{'info'}
                if (defined $default_user_options->{'info'});

            if ($tied) {
                $users->{$email} = join("\n", %u);
            } else {
                $users->{$email} = \%u;
            }
        }
    } else {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            "Sympa::List::include_users_remote_file: Unable to fetch remote file $url : %s",
            $res->message()
        );
        return undef;
    }

    $main::logger->do_log(Sympa::Logger::INFO, "include %d users from remote file %s",
        $total, $url);
    return $total;
}

## Returns a list of subscribers extracted from a remote LDAP Directory
sub _include_users_ldap {
    my ($users, $id, $source, $default_user_options, $tied) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sympa::List::_include_users_ldap');

    my $ldap_suffix = $source->{'suffix'};
    my $ldap_filter = $source->{'filter'};
    my $ldap_attrs  = $source->{'attrs'};
    my $ldap_select = $source->{'select'};

    my ($email_attr, $gecos_attr) = split(/\s*,\s*/, $ldap_attrs);
    my @ldap_attrs = ($email_attr);
    push @ldap_attrs, $gecos_attr if ($gecos_attr);

    ## LDAP and query handler
    my $fetch;

    ## Connection timeout (default is 120)
    #my $timeout = 30;

    unless (defined $source && $source->connect()) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unable to connect to the LDAP server '%s'",
            $source->{'host'});
        return undef;
    }
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Searching on server %s ; suffix %s ; filter %s ; attrs: %s',
        $source->{'host'}, $ldap_suffix, $ldap_filter, $ldap_attrs);
    $fetch = $source->{'ldap_handler'}->search(
        base   => "$ldap_suffix",
        filter => "$ldap_filter",
        attrs  => @ldap_attrs,
        scope  => "$source->{'scope'}"
    );
    if ($fetch->code()) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'LDAP search (single level) failed : %s (searching on server %s ; suffix %s ; filter %s ; attrs: %s)',
            $fetch->error(),
            $source->{'host'},
            $ldap_suffix,
            $ldap_filter,
            $ldap_attrs
        );
        return undef;
    }

    ## Counters.
    my $total = 0;
    my @emails;
    my %emailsViewed;

    while (my $e = $fetch->shift_entry) {
        my $emailentry = $e->get_value($email_attr, asref => 1);
        my $gecosentry = $e->get_value($gecos_attr, asref => 1);
        $gecosentry = $gecosentry->[0] if (ref($gecosentry) eq 'ARRAY');

        ## Multiple values
        if (ref($emailentry) eq 'ARRAY') {
            foreach my $email (@{$emailentry}) {
                my $cleanmail = Sympa::Tools::clean_email($email);
                ## Skip badly formed emails
                unless (Sympa::Tools::valid_email($email)) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        "Skip badly formed email address: '%s'", $email);
                    next;
                }

                next if ($emailsViewed{$cleanmail});
                push @emails, [$cleanmail, $gecosentry];
                $emailsViewed{$cleanmail} = 1;
                last if ($ldap_select eq 'first');
            }
        } else {
            my $cleanmail = Sympa::Tools::clean_email($emailentry);
            ## Skip badly formed emails
            unless (Sympa::Tools::valid_email($emailentry)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    "Skip badly formed email address: '%s'", $emailentry);
                next;
            }
            unless ($emailsViewed{$cleanmail}) {
                push @emails, [$cleanmail, $gecosentry];
                $emailsViewed{$cleanmail} = 1;
            }
        }
    }

    unless ($source->disconnect()) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Can\'t unbind from  LDAP server %s',
            $source->{'host'});
        return undef;
    }

    foreach my $emailgecos (@emails) {
        my ($email, $gecos) = @$emailgecos;
        next if ($email =~ /^\s*$/);

        $email = Sympa::Tools::clean_email($email);
        my %u;
        ## Check if user has already been included
        if ($users->{$email}) {
            if ($tied) {
                %u = split "\n", $users->{$email};
            } else {
                %u = %{$users->{$email}};
            }
        } else {
            %u = %{$default_user_options};
            $total++;
        }

        $u{'email'}       = $email;
        $u{'gecos'}       = $gecos if ($gecos);
        $u{'date'}        = time;
        $u{'update_date'} = time;
        $u{'id'}          = join(',', split(',', $u{'id'}), $id);

        $u{'visibility'} = $default_user_options->{'visibility'}
            if (defined $default_user_options->{'visibility'});
        $u{'reception'} = $default_user_options->{'reception'}
            if (defined $default_user_options->{'reception'});
        $u{'profile'} = $default_user_options->{'profile'}
            if (defined $default_user_options->{'profile'});
        $u{'info'} = $default_user_options->{'info'}
            if (defined $default_user_options->{'info'});

        if ($tied) {
            $users->{$email} = join("\n", %u);
        } else {
            $users->{$email} = \%u;
        }
    }

    $main::logger->do_log(Sympa::Logger::DEBUG2, "unbinded from LDAP server %s ",
        $source->{'host'});
    $main::logger->do_log(Sympa::Logger::INFO,
        '%d new users included from LDAP query', $total);

    return $total;
}

## Returns a list of subscribers extracted indirectly from a remote LDAP
## Directory using a two-level query
sub _include_users_ldap_2level {
    my ($users, $id, $source, $default_user_options, $tied) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Sympa::List::_include_users_ldap_2level');

    my $ldap_suffix1 = $source->{'suffix1'};
    my $ldap_filter1 = $source->{'filter1'};
    my $ldap_attrs1  = $source->{'attrs1'};
    my $ldap_select1 = $source->{'select1'};
    my $ldap_scope1  = $source->{'scope1'};
    my $ldap_regex1  = $source->{'regex1'};
    my $ldap_suffix2 = $source->{'suffix2'};
    my $ldap_filter2 = $source->{'filter2'};
    my $ldap_attrs2  = $source->{'attrs2'};
    my $ldap_select2 = $source->{'select2'};
    my $ldap_scope2  = $source->{'scope2'};
    my $ldap_regex2  = $source->{'regex2'};
    my @sync_errors  = ();

    my ($email_attr, $gecos_attr) = split(/\s*,\s*/, $ldap_attrs2);
    my @ldap_attrs2 = ($email_attr);
    push @ldap_attrs2, $gecos_attr if ($gecos_attr);

    ## LDAP and query handler
    my ($ldaph, $fetch);

    unless (defined $source && ($ldaph = $source->connect())) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unable to connect to the LDAP server '%s'",
            $source->{'host'});
        return undef;
    }

    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Searching on server %s ; suffix %s ; filter %s ; attrs: %s',
        $source->{'host'}, $ldap_suffix1, $ldap_filter1, $ldap_attrs1);
    $fetch = $ldaph->search(
        base   => "$ldap_suffix1",
        filter => "$ldap_filter1",
        attrs  => ["$ldap_attrs1"],
        scope  => "$ldap_scope1"
    );
    if ($fetch->code()) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'LDAP search (1st level) failed : %s (searching on server %s ; suffix %s ; filter %s ; attrs: %s)',
            $fetch->error(),
            $source->{'host'},
            $ldap_suffix1,
            $ldap_filter1,
            $ldap_attrs1
        );
        return undef;
    }

    ## Counters.
    my $total = 0;

    ## returns a reference to a HASH where the keys are the DNs
    ##  the second level hash's hold the attributes

    my (@attrs, @emails);

    while (my $e = $fetch->shift_entry) {
        my $entry = $e->get_value($ldap_attrs1, asref => 1);
        ## Multiple values
        if (ref($entry) eq 'ARRAY') {
            foreach my $attr (@{$entry}) {
                next
                    if (($ldap_select1 eq 'regex')
                    && ($attr !~ /$ldap_regex1/));
                push @attrs, $attr;
                last if ($ldap_select1 eq 'first');
            }
        } else {
            push @attrs, $entry
                unless (($ldap_select1 eq 'regex')
                && ($entry !~ /$ldap_regex1/));
        }
    }

    my %emailsViewed;

    my ($suffix2, $filter2);
    foreach my $attr (@attrs) {

        # Escape LDAP characters occuring in attribute
        my $escaped_attr = $attr;
        $escaped_attr =~ s/([\\\(\*\)\0])/sprintf "\\%02X", ord($1)/eg;

        ($suffix2 = $ldap_suffix2) =~ s/\[attrs1\]/$escaped_attr/g;
        ($filter2 = $ldap_filter2) =~ s/\[attrs1\]/$escaped_attr/g;

        $main::logger->do_log(Sympa::Logger::DEBUG2,
            'Searching on server %s ; suffix %s ; filter %s ; attrs: %s',
            $source->{'host'}, $suffix2, $filter2, $ldap_attrs2);
        $fetch = $ldaph->search(
            'base'   => "$suffix2",
            'filter' => "$filter2",
            'attrs'  => @ldap_attrs2,
            'scope'  => "$ldap_scope2"
        );
        if ($fetch->code()) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'LDAP search (2nd level) failed : %s. Node: %s (searching on server %s ; suffix %s ; filter %s ; attrs: %s)',
                $fetch->error(),
                $attr,
                $source->{'host'},
                $suffix2,
                $filter2,
                $ldap_attrs2
            );
            push @sync_errors,
                {
                'error',       $fetch->error(),
                'host',        $source->{'host'},
                'suffix2',     $suffix2,
                'fliter2',     $filter2,
                'ldap_attrs2', $ldap_attrs2
                };
        }

        ## returns a reference to a HASH where the keys are the DNs
        ##  the second level hash's hold the attributes

        while (my $e = $fetch->shift_entry) {
            my $emailentry = $e->get_value($email_attr, asref => 1);
            my $gecosentry = $e->get_value($gecos_attr, asref => 1);
            $gecosentry = $gecosentry->[0] if (ref($gecosentry) eq 'ARRAY');

            ## Multiple values
            if (ref($emailentry) eq 'ARRAY') {
                foreach my $email (@{$emailentry}) {
                    my $cleanmail = Sympa::Tools::clean_email($email);
                    ## Skip badly formed emails
                    unless (Sympa::Tools::valid_email($email)) {
                        $main::logger->do_log(Sympa::Logger::ERR,
                            "Skip badly formed email address: '%s'", $email);
                        next;
                    }

                    next
                        if (($ldap_select2 eq 'regex')
                        && ($cleanmail !~ /$ldap_regex2/));
                    next if ($emailsViewed{$cleanmail});
                    push @emails, [$cleanmail, $gecosentry];
                    $emailsViewed{$cleanmail} = 1;
                    last if ($ldap_select2 eq 'first');
                }
            } else {
                my $cleanmail = Sympa::Tools::clean_email($emailentry);
                ## Skip badly formed emails
                unless (Sympa::Tools::valid_email($emailentry)) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        "Skip badly formed email address: '%s'", $emailentry);
                    next;
                }

                unless (
                    (      ($ldap_select2 eq 'regex')
                        && ($cleanmail !~ /$ldap_regex2/)
                    )
                    || $emailsViewed{$cleanmail}
                    ) {
                    push @emails, [$cleanmail, $gecosentry];
                    $emailsViewed{$cleanmail} = 1;
                }
            }
        }
    }

    unless ($source->disconnect()) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Can\'t unbind from  LDAP server %s',
            $source->{'host'});
        return undef;
    }

    foreach my $emailgecos (@emails) {
        my ($email, $gecos) = @$emailgecos;
        next if ($email =~ /^\s*$/);

        $email = Sympa::Tools::clean_email($email);
        my %u;
        ## Check if user has already been included
        if ($users->{$email}) {
            if ($tied) {
                %u = split "\n", $users->{$email};
            } else {
                %u = %{$users->{$email}};
            }
        } else {
            %u = %{$default_user_options};
            $total++;
        }

        $u{'email'}       = $email;
        $u{'gecos'}       = $gecos if $gecos;
        $u{'date'}        = time;
        $u{'update_date'} = time;
        $u{'id'}          = join(',', split(',', $u{'id'}), $id);

        $u{'visibility'} = $default_user_options->{'visibility'}
            if (defined $default_user_options->{'visibility'});
        $u{'reception'} = $default_user_options->{'reception'}
            if (defined $default_user_options->{'reception'});
        $u{'profile'} = $default_user_options->{'profile'}
            if (defined $default_user_options->{'profile'});
        $u{'info'} = $default_user_options->{'info'}
            if (defined $default_user_options->{'info'});

        if ($tied) {
            $users->{$email} = join("\n", %u);
        } else {
            $users->{$email} = \%u;
        }
    }

    $main::logger->do_log(Sympa::Logger::DEBUG2, "unbinded from LDAP server %s ",
        $source->{'host'});
    $main::logger->do_log(Sympa::Logger::INFO,
        '%d new users included from LDAP query 2level', $total);

    my $result;
    $result->{'total'} = $total;
    if ($#sync_errors > -1) { $result->{'errors'} = \@sync_errors; }
    return $result;
}

sub _include_sql_ca {
    my $source = shift;

    return {} unless ($source->connect());

    $main::logger->do_log(
        Sympa::Logger::DEBUG2,
        '%s, email_entry = %s',
        $source->{'sql_query'},
        $source->{'email_entry'}
    );

    my $sth     = $source->do_query($source->{'sql_query'});
    my $mailkey = $source->{'email_entry'};
    my $ca      = $sth->fetchall_hashref($mailkey);
    my $result;
    foreach my $email (keys %{$ca}) {
        foreach my $custom_attribute (keys %{$ca->{$email}}) {
            $result->{$email}{$custom_attribute}{'value'} =
                $ca->{$email}{$custom_attribute}
                unless ($custom_attribute eq $mailkey);
        }
    }
    return $result;
}

sub _include_ldap_ca {
    my $source = shift;

    return {} unless ($source->connect());

    $main::logger->do_log(
        Sympa::Logger::DEBUG2,
        'server %s ; suffix %s ; filter %s ; attrs: %s',
        $source->{'host'},
        $source->{'suffix'},
        $source->{'filter'},
        $source->{'attrs'}
    );

    my @attrs = split(/\s*,\s*/, $source->{'attrs'});

    my $results = $source->{'ldap_handler'}->search(
        base   => $source->{'suffix'},
        filter => $source->{'filter'},
        attrs  => @attrs,
        scope  => $source->{'scope'}
    );
    if ($results->code()) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'LDAP search (single level) failed : %s (searching on server %s ; suffix %s ; filter %s ; attrs: %s)',
            $results->error(),
            $source->{'host'},
            $source->{'suffix'},
            $source->{'filter'},
            $source->{'attrs'}
        );
        return {};
    }

    my $attributes;
    while (my $entry = $results->shift_entry) {
        my $email = $entry->get_value($source->{'email_entry'});
        next unless ($email);
        foreach my $attr (@attrs) {
            next if ($attr eq $source->{'email_entry'});
            $attributes->{$email}{$attr}{'value'} = $entry->get_value($attr);
        }
    }

    return $attributes;
}

sub _include_ldap_level2_ca {
    my $source = shift;

    return {} unless ($source->connect());

    return {};

    $main::logger->do_log(
        Sympa::Logger::DEBUG2,
        'server %s ; suffix %s ; filter %s ; attrs: %s',
        $source->{'host'},
        $source->{'suffix'},
        $source->{'filter'},
        $source->{'attrs'}
    );

    my @attrs = split(/\s*,\s*/, $source->{'attrs'});

    my $results = $source->{'ldap_handler'}->search(
        base   => $source->{'suffix'},
        filter => $source->{'filter'},
        attrs  => @attrs,
        scope  => $source->{'scope'}
    );
    if ($results->code()) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'LDAP search (single level) failed : %s (searching on server %s ; suffix %s ; filter %s ; attrs: %s)',
            $results->error(),
            $source->{'host'},
            $source->{'suffix'},
            $source->{'filter'},
            $source->{'attrs'}
        );
        return {};
    }

    my $attributes;
    while (my $entry = $results->shift_entry) {
        my $email = $entry->get_value($source->{'email_entry'});
        next unless ($email);
        foreach my $attr (@attrs) {
            next if ($attr eq $source->{'email_entry'});
            $attributes->{$email}{$attr}{'value'} = $entry->get_value($attr);
        }
    }

    return $attributes;
}

## Returns a list of subscribers extracted from an remote Database
sub _include_users_sql {
    my ($users, $id, $source, $default_user_options, $tied, $fetch_timeout) =
        @_;

    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sympa::List::_include_users_sql()');

    unless (ref($source) =~ /DatabaseDriver/) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'source object has not a DatabaseDriver type : %s', $source);
        return undef;
    }

    unless ($source->connect() && ($source->do_query($source->{'sql_query'})))
    {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Unable to connect to SQL datasource with parameters host: %s, database: %s',
            $source->{'host'},
            $source->{'db_name'}
        );
        return undef;
    }
    ## Counters.
    my $total = 0;

    ## Process the SQL results
    $source->set_fetch_timeout($fetch_timeout);
    my $array_of_users = $source->fetch;

    unless (defined $array_of_users && ref($array_of_users) eq 'ARRAY') {
        $main::logger->do_log(Sympa::Logger::ERR, 'Failed to include users from %s',
            $source->{'name'});
        return undef;
    }

    foreach my $row (@{$array_of_users}) {
        my $email = $row->[0];    ## only get first field
        my $gecos = $row->[1];    ## second field (if it exists) is gecos
        ## Empty value
        next if ($email =~ /^\s*$/);

        $email = Sympa::Tools::clean_email($email);

        ## Skip badly formed emails
        unless (Sympa::Tools::valid_email($email)) {
            $main::logger->do_log(Sympa::Logger::ERR,
                "Skip badly formed email address: '%s'", $email);
            next;
        }

        my %u;
        ## Check if user has already been included
        if ($users->{$email}) {
            if ($tied eq 'tied') {
                %u = split "\n", $users->{$email};
            } else {
                %u = %{$users->{$email}};
            }
        } else {
            %u = %{$default_user_options};
            $total++;
        }

        $u{'email'}       = $email;
        $u{'gecos'}       = $gecos if ($gecos);
        $u{'date'}        = time;
        $u{'update_date'} = time;
        $u{'id'}          = join(',', split(',', $u{'id'}), $id);

        $u{'visibility'} = $default_user_options->{'visibility'}
            if (defined $default_user_options->{'visibility'});
        $u{'reception'} = $default_user_options->{'reception'}
            if (defined $default_user_options->{'reception'});
        $u{'profile'} = $default_user_options->{'profile'}
            if (defined $default_user_options->{'profile'});
        $u{'info'} = $default_user_options->{'info'}
            if (defined $default_user_options->{'info'});

        if ($tied eq 'tied') {
            $users->{$email} = join("\n", %u);
        } else {
            $users->{$email} = \%u;
        }
    }
    $source->disconnect();
    $main::logger->do_log(Sympa::Logger::INFO, '%d included users from SQL query',
        $total);
    return $total;
}

## Loads the list of subscribers from an external include source
sub _load_list_members_from_include {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);

    my $self     = shift;
    my $old_subs = shift;
    my $name     = $self->name;
    my $dir      = $self->dir;
    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Loading included users for list %s',
        $self);
    my (%users, $depend_on);
    my $total = 0;
    my @errors;
    my $result;
    my @ex_sources;

    foreach my $type (@sources_providing_listmembers) {

        foreach my $tmp_incl (@{$self->$type}) {

            # Work with a copy of admin hash branch to avoid including
            # temporary variables into the actual admin hash.[bug #3182]
            my $incl      = Sympa::Tools::Data::dup_var($tmp_incl);
            my $source_id = Sympa::Datasource::_get_datasource_id($tmp_incl);
            my $source_is_new = defined $old_subs->{$source_id};

            # Get the list of users.
            # Verify if we can synchronize sources. If it's allowed OR there
            # are new sources, we update the list, and can add subscribers.
            # If we can't synchronize, we make an array with excluded sources.

            my $included;
            if (my $plugin = $self->isPlugin($type)) {
                my $source = $plugin->listSource;
                if ($source->isAllowedToSync || $source_is_new) {
                    $main::logger->do_log(
                        debug => "syncing members from $type");
                    $included = $source->getListMembers(
                        users         => \%users,
                        settings      => $incl,
                        user_defaults => $self->default_user_options
                    );
                    defined $included
                        or push @errors,
                        {type => $type, name => $incl->{name}};
                }
            }    # if (my $plugin = ...)

            ## Get the list of users.
            ## Verify if we can synchronize sources. If it's allowed OR there
            ## are new sources, we update the list, and can add subscribers.
            ## Else if we can't synchronize sources. We make an array with
            ## excluded sources.
            if ($type eq 'include_sql_query') {
                require Sympa::Datasource::SQL;
                my $source = Sympa::Datasource::SQL->new($incl);
                if ($source->is_allowed_to_sync() || $source_is_new) {
                    $main::logger->do_log(Sympa::Logger::DEBUG, 'is_new %d, syncing',
                        $source_is_new);
                    $included =
                        _include_users_sql(\%users, $source_id, $source,
                        $self->default_user_options, 'untied',
                        $self->sql_fetch_timeout);
                    unless (defined $included) {
                        push @errors,
                            {'type' => $type, 'name' => $incl->{'name'}};
                    }
                } else {
                    my $exclusion_data = {
                        'id'          => $source_id,
                        'name'        => $incl->{'name'},
                        'starthour'   => $source->{'starthour'},
                        'startminute' => $source->{'startminute'},
                        'endhour'     => $source->{'endhour'},
                        'endminute'   => $source->{'endminute'}
                    };
                    push @ex_sources, $exclusion_data;
                    $included = 0;
                }
            } elsif ($type eq 'include_ldap_query') {
                require Sympa::Datasource::LDAP;
                my $source = Sympa::Datasource::LDAP->new($incl);
                if ($source->is_allowed_to_sync() || $source_is_new) {
                    $included =
                        _include_users_ldap(\%users, $source_id, $source,
                        $self->default_user_options);
                    unless (defined $included) {
                        push @errors,
                            {'type' => $type, 'name' => $incl->{'name'}};
                    }
                } else {
                    my $exclusion_data = {
                        'id'          => $source_id,
                        'name'        => $incl->{'name'},
                        'starthour'   => $source->{'starthour'},
                        'startminute' => $source->{'startminute'},
                        'endhour'     => $source->{'endhour'},
                        'endminute'   => $source->{'endminute'}
                    };
                    push @ex_sources, $exclusion_data;
                    $included = 0;
                }
            } elsif ($type eq 'include_ldap_2level_query') {
                require Sympa::Datasource::LDAP;
                my $source = Sympa::Datasource::LDAP->new($incl);
                if ($source->is_allowed_to_sync() || $source_is_new) {
                    my $result =
                        _include_users_ldap_2level(\%users, $source_id,
                        $source, $self->default_user_options);
                    if (defined $result) {
                        $included = $result->{'total'};
                        if (defined $result->{'errors'}) {
                            $main::logger->do_log(Sympa::Logger::ERR,
                                'Errors occurred during the second LDAP passe'
                            );
                            push @errors,
                                {'type' => $type, 'name' => $incl->{'name'}};
                        }
                    } else {
                        $included = undef;
                        push @errors,
                            {'type' => $type, 'name' => $incl->{'name'}};
                    }
                } else {
                    my $exclusion_data = {
                        'id'          => $source_id,
                        'name'        => $incl->{'name'},
                        'starthour'   => $source->{'starthour'},
                        'startminute' => $source->{'startminute'},
                        'endhour'     => $source->{'endhour'},
                        'endminute'   => $source->{'endminute'}
                    };
                    push @ex_sources, $exclusion_data;
                    $included = 0;
                }
            } elsif ($type eq 'include_remote_sympa_list') {
                $included =
                    $self->_include_users_remote_sympa_list(\%users, $incl,
                    $dir, $self->domain, $self->default_user_options);
                unless (defined $included) {
                    push @errors,
                        {'type' => $type, 'name' => $incl->{'name'}};
                }
            } elsif ($type eq 'include_list') {
                $depend_on->{$name} = 1;
                if (_inclusion_loop($name, $incl, $depend_on)) {
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        'loop detection in list inclusion : could not include again %s in %s',
                        $incl,
                        $name
                    );
                } else {
                    $depend_on->{$incl} = 1;
                    $included =
                        _include_users_list(\%users, $incl, $self->domain,
                        $self->default_user_options);
                    unless (defined $included) {
                        push @errors, {'type' => $type, 'name' => $incl};
                    }
                }
            } elsif ($type eq 'include_file') {
                $included = _include_users_file(\%users, $incl,
                    $self->default_user_options);
                unless (defined $included) {
                    push @errors, {'type' => $type, 'name' => $incl};
                }
            } elsif ($type eq 'include_remote_file') {
                $included = _include_users_remote_file(\%users, $incl,
                    $self->default_user_options);
                unless (defined $included) {
                    push @errors,
                        {'type' => $type, 'name' => $incl->{'name'}};
                }
            }

            unless (defined $included) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Inclusion %s failed in list %s',
                    $type, $name);
                next;
            }
            $total += $included;
        }
    }

    ## If an error occurred, return an undef value
    $result->{'users'}      = \%users;
    $result->{'errors'}     = \@errors;
    $result->{'exclusions'} = \@ex_sources;
    ##use Data::Dumper;
    ##if(open OUT, '>/tmp/result') { print OUT Dumper $result; close OUT }
    return $result;
}
## Loads the list of admin users from an external include source
sub _load_list_admin_from_include {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);

    my $self  = shift;
    my $role  = shift;
    my $name  = $self->name;
    my $robot = $self->robot;

    my (%admin_users, $depend_on);
    my $total = 0;
    my $dir   = $self->dir;

    #FIXME:check value of $role.
    my $role_include = $role . '_include';
    foreach my $entry (@{$self->$role_include}) {

        next unless (defined $entry);

        my %option;
        $option{'reception'} = $entry->{'reception'}
            if (defined $entry->{'reception'});
        $option{'visibility'} = $entry->{'visibility'}
            if (defined $entry->{'visibility'});
        $option{'profile'} = $entry->{'profile'}
            if (defined $entry->{'profile'} && ($role eq 'owner'));

        my $include_file =
            $self->get_etc_filename("data_sources/$entry->{'source'}\.incl");

        unless (defined $include_file) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'the file %s.incl doesn\'t exist',
                $entry->{'source'});
            return undef;
        }

        my $include_admin_user;
        ## the file has parameters
        if (defined $entry->{'source_parameters'}) {
            my %parsing;

            $parsing{'data'}     = $entry->{'source_parameters'};
            $parsing{'template'} = "$entry->{'source'}\.incl";

            my $name = "$entry->{'source'}\.incl";

            my $include_path = $include_file;
            if ($include_path =~ s/$name$//) {
                $parsing{'include_path'} = $include_path;
                $include_admin_user =
                    _load_include_admin_user_file($robot, $include_path,
                    \%parsing);
            } else {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'errors to get path of the the file %s.incl',
                    $entry->{'source'});
                return undef;
            }
        } else {
            $include_admin_user =
                _load_include_admin_user_file($robot, $include_file);
        }

        foreach my $type (@sources_providing_listmembers) {
            defined $total or last;

            foreach my $tmp_incl (@{$include_admin_user->{$type}}) {

                # Work with a copy of admin hash branch to avoid including
                # temporary variables into the actual admin hash. [bug #3182]
                my $incl = Sympa::Tools::Data::dup_var($tmp_incl);

                # get the list of admin users
                # does it need to define a 'default_admin_user_option'?
                my $included;
                if (my $plugin = $self->isPlugin($type)) {
                    my $source = $plugin->listSource;
                    $main::logger->do_log(
                        debug => "syncing admins from $type");
                    $included = $source->getListMembers(
                        users         => \%admin_users,
                        settings      => $incl,
                        user_defaults => \%option,
                        admin_only    => 1
                    );
                } elsif ($type eq 'include_sql_query') {
                    require Sympa::Datasource::SQL;
                    my $source = Sympa::Datasource::SQL->new($incl);
                    $included =
                        _include_users_sql(\%admin_users, $incl, $source,
                        \%option, 'untied', $self->sql_fetch_timeout);
                } elsif ($type eq 'include_ldap_query') {
                    require Sympa::Datasource::LDAP;
                    my $source = Sympa::Datasource::LDAP->new($incl);
                    $included =
                        _include_users_ldap(\%admin_users, $incl, $source,
                        \%option);
                } elsif ($type eq 'include_ldap_2level_query') {
                    require Sympa::Datasource::LDAP;
                    my $source = Sympa::Datasource::LDAP->new($incl);
                    my $result =
                        _include_users_ldap_2level(\%admin_users, $incl,
                        $source, \%option);
                    if (defined $result) {
                        $included = $result->{'total'};
                        if (defined $result->{'errors'}) {
                            $main::logger->do_log(Sympa::Logger::ERR,
                                'Errors occurred during the second LDAP passe. Please verify your LDAP query.'
                            );
                        }
                    } else {
                        $included = undef;
                    }
                } elsif ($type eq 'include_remote_sympa_list') {
                    $included =
                        $self->_include_users_remote_sympa_list(\%admin_users,
                        $incl, $dir, $self->domain, \%option);
                } elsif ($type eq 'include_list') {
                    $depend_on->{$name} = 1;
                    if (_inclusion_loop($name, $incl, $depend_on)) {
                        $main::logger->do_log(
                            Sympa::Logger::ERR,
                            'loop detection in list inclusion : could not include again %s in %s',
                            $incl,
                            $name
                        );
                    } else {
                        $depend_on->{$incl} = 1;
                        $included = _include_users_list(\%admin_users, $incl,
                            $self->domain, \%option);
                    }
                } elsif ($type eq 'include_file') {
                    $included =
                        _include_users_file(\%admin_users, $incl, \%option);
                } elsif ($type eq 'include_remote_file') {
                    $included =
                        _include_users_remote_file(\%admin_users, $incl,
                        \%option);
                }

                unless (defined $included) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        'Inclusion %s %s failed in list %s',
                        $role, $type, $name);
                    next;
                }
                $total += $included;
            }
        }

        ## If an error occurred, return an undef value
        unless (defined $total) {
            return undef;
        }
    }

    return \%admin_users;
}

# Load an include admin user file (xx.incl)
sub _load_include_admin_user_file {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s)', @_);
    my $robot   = shift;
    my $file    = shift;
    my $parsing = shift;

    my $pinfo = $robot->list_params;
    my %include;
    my (@paragraphs);

    # the file has parameters
    if (defined $parsing) {
        my @data = split(',', $parsing->{'data'});
        my $vars = {'param' => \@data};
        my $output = '';

        unless (
            Sympa::Template::parse_tt2(
                $vars, $parsing->{'template'},
                \$output, [$parsing->{'include_path'}]
            )
            ) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Failed to parse %s',
                $parsing->{'template'}
            );
            return undef;
        }

        my @lines = split('\n', $output);

        my $i = 0;
        foreach my $line (@lines) {
            if ($line =~ /^\s*$/) {
                $i++ if $paragraphs[$i];
            } else {
                push @{$paragraphs[$i]}, $line;
            }
        }
    } else {
        unless (open INCLUDE, $file) {
            $main::logger->do_log(Sympa::Logger::INFO, 'Cannot open %s', $file);
        }

        ## Just in case...
        local $RS = "\n";

        ## Split in paragraphs
        my $i = 0;
        while (<INCLUDE>) {
            if (/^\s*$/) {
                $i++ if $paragraphs[$i];
            } else {
                push @{$paragraphs[$i]}, $_;
            }
        }
        close INCLUDE;
    }

    for my $index (0 .. $#paragraphs) {
        my @paragraph = @{$paragraphs[$index]};

        my $pname;

        ## Clean paragraph, keep comments
        for my $i (0 .. $#paragraph) {
            my $changed = undef;
            for my $j (0 .. $#paragraph) {
                if ($paragraph[$j] =~ /^\s*\#/) {
                    chomp($paragraph[$j]);
                    push @{$include{'comment'}}, $paragraph[$j];
                    splice @paragraph, $j, 1;
                    $changed = 1;
                } elsif ($paragraph[$j] =~ /^\s*$/) {
                    splice @paragraph, $j, 1;
                    $changed = 1;
                }

                last if $changed;
            }

            last unless $changed;
        }

        ## Empty paragraph
        next unless ($#paragraph > -1);

        ## Look for first valid line
        unless ($paragraph[0] =~ /^\s*([\w-]+)(\s+.*)?$/) {
            $main::logger->do_log(Sympa::Logger::INFO, 'Bad paragraph "%s" in %s',
                @paragraph, $file);
            next;
        }

        $pname = $1;

        unless ($config_in_admin_user_file{$pname}) {
            $main::logger->do_log(Sympa::Logger::INFO, 'Unknown parameter "%s" in %s',
                $pname, $file);
            next;
        }

        ## Uniqueness
        if (defined $include{$pname}
            and $pinfo->{$pname}{'occurrence'} !~ /n$/) {
            $main::logger->do_log(Sympa::Logger::INFO,
                'Multiple parameter "%s" in %s',
                $pname, $file);
        }

        ## Line or Paragraph
        if (ref $pinfo->{$pname}{'file_format'} eq 'HASH') {
            ## This should be a paragraph
            unless ($#paragraph > 0) {
                $main::logger->do_log(
                    Sympa::Logger::INFO,
                    'Expecting a paragraph for "%s" parameter in %s, ignore it',
                    $pname,
                    $file
                );
                next;
            }

            ## Skipping first line
            shift @paragraph;

            my %hash;
            for my $i (0 .. $#paragraph) {
                next if ($paragraph[$i] =~ /^\s*\#/);

                unless ($paragraph[$i] =~ /^\s*(\w+)\s*/) {
                    $main::logger->do_log(Sympa::Logger::INFO, 'Bad line "%s" in %s',
                        $paragraph[$i], $file);
                }

                my $key = $1;

                unless (defined $pinfo->{$pname}{'file_format'}{$key}) {
                    $main::logger->do_log(Sympa::Logger::INFO,
                        'Unknown key "%s" in paragraph "%s" in %s',
                        $key, $pname, $file);
                    next;
                }

                unless ($paragraph[$i] =~
                    /^\s*$key\s+($pinfo->{$pname}{'file_format'}{$key}{'file_format'})\s*$/i
                    ) {
                    chomp($paragraph[$i]);
                    $main::logger->do_log(Sympa::Logger::INFO,
                        'Bad entry "%s" for key "%s", paragraph "%s" in %s',
                        $paragraph[$i], $key, $pname, $file);
                    next;
                }

                $hash{$key} =
                    _load_list_param($robot, $key, $1,
                    $pinfo->{$pname}{'file_format'}{$key});
            }

            ## Apply defaults & Check required keys
            my $missing_required_field;
            foreach my $k (keys %{$pinfo->{$pname}{'file_format'}}) {
                ## Default value
##		if (! defined $hash{$k} and
##		    defined $pinfo->{$pname}{'file_format'}{$k}{'default'}) {
##		    $hash{$k} = _load_list_param($robot, $k, 'default',
##			$pinfo->{$pname}{'file_format'}{$k});
##		}
                ## Required fields
                if ($pinfo->{$pname}{'file_format'}{$k}{'occurrence'} eq '1')
                {
                    unless (defined $hash{$k}) {
                        $main::logger->do_log(Sympa::Logger::INFO,
                            'Missing key "%s" in param "%s" in %s',
                            $k, $pname, $file);
                        $missing_required_field++;
                    }
                }
            }

            next if $missing_required_field;

            ## Should we store it in an array
            if (($pinfo->{$pname}{'occurrence'} =~ /n$/)) {
                push @{$include{$pname}}, \%hash;
            } else {
                $include{$pname} = \%hash;
            }
        } else {
            ## This should be a single line
            unless ($#paragraph == 0) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    'Expecting a single line for "%s" parameter in %s',
                    $pname, $file);
            }

            unless ($paragraph[0] =~
                /^\s*$pname\s+($pinfo->{$pname}{'file_format'})\s*$/i) {
                chomp($paragraph[0]);
                $main::logger->do_log(Sympa::Logger::INFO, 'Bad entry "%s" in %s',
                    $paragraph[0], $file);
                next;
            }

            my $value =
                _load_list_param($robot, $pname, $1, $pinfo->{$pname});

            if ($pinfo->{$pname}{'occurrence'} =~ /n$/
                and ref $value ne 'ARRAY') {
                push @{$include{$pname}}, $value;
            } else {
                $include{$pname} = $value;
            }
        }
    }

    return \%include;
}

## Returns a ref to an array containing the ids (as computed by
## Datasource::_get_datasource_id) of the list of members given as argument.
sub get_list_of_sources_id {
    my $self                = shift;
    my $list_of_subscribers = shift;

    my %old_subs_id;
    foreach my $old_sub (keys %{$list_of_subscribers}) {
        next
            unless $list_of_subscribers->{$old_sub}
                and defined $list_of_subscribers->{$old_sub}{'id'};

        my @tmp_old_tab = split /,/, $list_of_subscribers->{$old_sub}{'id'};
        foreach my $raw (@tmp_old_tab) {
            $old_subs_id{$raw} = 1;
        }
    }
    return \%old_subs_id;
}

sub sync_include_ca {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self  = shift;
    my $purge = shift;

    my %users;
    my %changed;

    $self->purge_ca() if $purge;

    for (
        my $user = $self->get_first_list_member();
        $user;
        $user = $self->get_next_list_member()
        ) {
        $users{$user->{'email'}} = $user->{'custom_attribute'};
    }

    foreach my $type ('include_sql_ca') {
        foreach my $tmp_incl (@{$self->$type}) {
            ## Work with a copy of admin hash branch to avoid including
            ## temporary variables into the actual admin hash.[bug #3182]
            my $incl   = Sympa::Tools::Data::dup_var($tmp_incl);
            my $source = undef;
            my $srcca  = undef;
            if ($type eq 'include_sql_ca') {
                require Sympa::Datasource::SQL;
                $source = Sympa::Datasource::SQL->new($incl);
            } elsif (($type eq 'include_ldap_ca')
                or ($type eq 'include_ldap_2level_ca')) {
                require Sympa::Datasource::LDAP;
                $source = Sympa::Datasource::LDAP->new($incl);
            }
            next unless (defined($source));
            if ($source->is_allowed_to_sync()) {
                my $getter = '_' . $type;
                {    # Magic inside
                    no strict "refs";
                    $srcca = &$getter($source);
                }
                if (defined($srcca)) {
                    foreach my $email (keys %$srcca) {
                        $users{$email} = {} unless (defined $users{$email});
                        foreach my $key (keys %{$srcca->{$email}}) {
                            next
                                if ($users{$email}{$key}{'value'} eq
                                $srcca->{$email}{$key}{'value'});
                            $users{$email}{$key} = $srcca->{$email}{$key};
                            $changed{$email} = 1;
                        }
                    }
                }
            }
            unless ($source->disconnect()) {
                $main::logger->do_log(Sympa::Logger::NOTICE,
                    'Can\'t unbind from source %s', $type);
                return undef;
            }
        }
    }

    foreach my $email (keys %changed) {
        if ($self->update_list_member(
                $email,
                {   'custom_attribute' =>
                        createXMLCustomAttribute($users{$email})
                }
            )
            ) {
            $main::logger->do_log(Sympa::Logger::DEBUG, 'Updated user %s', $email);
        } else {
            $main::logger->do_log('error', 'could not update user %s',
                $email);
        }
    }

    return 1;
}

### Purge synced custom attributes from user records, only keep user writable
### ones
sub purge_ca {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    my %userattributes;
    my %users;

    foreach my $attr (@{$self->custom_attribute}) {
        $userattributes{$attr->{'id'}} = 1;
    }

    for (
        my $user = $self->get_first_list_member();
        $user;
        $user = $self->get_next_list_member()
        ) {
        next unless (keys %{$user->{'custom_attribute'}});
        my $attributes;
        foreach my $id (keys %{$user->{'custom_attribute'}}) {
            next unless (defined $userattributes{$id});
            $attributes->{$id} = $user->{'custom_attribute'}{$id};
        }
        $users{$user->{'email'}} = $attributes;
    }

    foreach my $email (keys %users) {
        if ($self->update_list_member(
                $email,
                {   'custom_attribute' =>
                        createXMLCustomAttribute($users{$email})
                }
            )
            ) {
            $main::logger->do_log(Sympa::Logger::DEBUG, 'Updated user %s', $email);
        } else {
            $main::logger->do_log('error', 'could not update user %s',
                $email);
        }
    }

    return 1;
}

sub sync_include {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self   = shift;
    my $option = shift;

    my %old_subscribers;
    my $total           = 0;
    my $errors_occurred = 0;

    ## Load a hash with the old subscribers
    for (
        my $user = $self->get_first_list_member();
        $user;
        $user = $self->get_next_list_member()
        ) {
        $old_subscribers{lc($user->{'email'})} = $user;

        ## User neither included nor subscribed = > set subscribed to 1
        unless ($old_subscribers{lc($user->{'email'})}{'included'}
            || $old_subscribers{lc($user->{'email'})}{'subscribed'}) {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Update user %s neither included nor subscribed',
                $user->{'email'});
            unless (
                $self->update_list_member(
                    lc($user->{'email'}),
                    {   'update_date' => time,
                        'subscribed'  => 1
                    }
                )
                ) {
                $main::logger->do_log(Sympa::Logger::ERR, 'Failed to update %s',
                    $user->{'email'});
                next;
            }
            $old_subscribers{lc($user->{'email'})}{'subscribed'} = 1;
        }

        $total++;
    }

    ## Load a hash with the new subscriber list
    my $new_subscribers;
    unless ($option and $option eq 'purge') {
        my $result =
            $self->_load_list_members_from_include(
            $self->get_list_of_sources_id(\%old_subscribers));
        $new_subscribers = $result->{'users'};
        my @errors     = @{$result->{'errors'}};
        my @exclusions = @{$result->{'exclusions'}};

        ## If include sources were not available, do not update subscribers
        ## Use DB cache instead and warn the listmaster.
        if (@errors) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Errors occurred while synchronizing datasources for list %s',
                $self
            );
            $errors_occurred = 1;
            $self->robot->send_notify_to_listmaster('sync_include_failed',
                {'errors' => \@errors, 'listname' => $self->name});
            foreach my $e (@errors) {
                my $plugin = $self->isPlugin($e->{type}) or next;
                my $source = $plugin->listSource;
                $source->reportListError($self, $e->{name});
            }
            return undef;
        }

        # Feed the new_subscribers hash with users previously subscribed
        # with data sources not used because we were not in the period of
        # time during which synchronization is allowed. This will prevent
        # these users from being unsubscribed.
        if (@exclusions) {
            foreach my $ex_sources (@exclusions) {
                my $id = $ex_sources->{'id'};
                foreach my $email (keys %old_subscribers) {
                    if ($old_subscribers{$email}{'id'} =~ /$id/g) {
                        $new_subscribers->{$email}{'date'} =
                            $old_subscribers{$email}{'date'};
                        $new_subscribers->{$email}{'update_date'} =
                            $old_subscribers{$email}{'update_date'};
                        $new_subscribers->{$email}{'visibility'} =
                            $self->{'default_user_options'}{'visibility'}
                            if (
                            defined $self->{'default_user_options'}
                            {'visibility'});
                        $new_subscribers->{$email}{'reception'} =
                            $self->{'default_user_options'}{'reception'}
                            if (
                            defined $self->{'default_user_options'}
                            {'reception'});
                        $new_subscribers->{$email}{'profile'} =
                            $self->{'default_user_options'}{'profile'}
                            if (
                            defined $self->{'default_user_options'}
                            {'profile'});
                        $new_subscribers->{$email}{'info'} =
                            $self->{'default_user_options'}{'info'}
                            if (
                            defined $self->{'default_user_options'}{'info'});
                        if (defined $new_subscribers->{$email}{'id'}
                            && $new_subscribers->{$email}{'id'} ne '') {
                            $new_subscribers->{$email}{'id'} = join(',',
                                split(',', $new_subscribers->{$email}{'id'}),
                                $id);
                        } else {
                            $new_subscribers->{$email}{'id'} =
                                $old_subscribers{$email}{'id'};
                        }
                    }
                }
            }
        }
    }

    my $data_exclu;
    my @subscriber_exclusion;

    ## Gathering a list of emails for a the list in 'exclusion_table'
    $data_exclu = $self->get_exclusion();

    my $key = 0;
    while ($data_exclu->{'emails'}->[$key]) {
        push @subscriber_exclusion, $data_exclu->{'emails'}->[$key];
        $key = $key + 1;
    }

    my $users_added   = 0;
    my $users_updated = 0;

    ## Get an Exclusive lock
    my $lock_fh =
        Sympa::LockedFile->new($self->dir . '/include', 10 * 60, '+');
    unless ($lock_fh) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Could not create new lock');
        return undef;
    }

    ## Go through previous list of users
    my $users_removed = 0;
    my $user_removed;
    my @deltab;
    foreach my $email (keys %old_subscribers) {
        unless (defined($new_subscribers->{$email})) {
            ## User is also subscribed, update DB entry
            if ($old_subscribers{$email}{'subscribed'}) {
                $main::logger->do_log(Sympa::Logger::DEBUG, 'updating %s to list %s',
                    $email, $self);
                unless (
                    $self->update_list_member(
                        $email,
                        {   'update_date' => time,
                            'included'    => 0,
                            'id'          => ''
                        }
                    )
                    ) {
                    $main::logger->do_log(Sympa::Logger::ERR, 'Failed to update %s',
                        $email);
                    next;
                }

                $users_updated++;

                ## Tag user for deletion
            } else {
                $main::logger->do_log(Sympa::Logger::DEBUG3,
                    'removing %s from list %s',
                    $email, $self);
                @deltab = ($email);
                unless ($user_removed =
                    $self->delete_list_member('users' => \@deltab)) {
                    $main::logger->do_log(Sympa::Logger::ERR, 'Failed to delete %s',
                        $user_removed);
                    return undef;
                }
                if ($user_removed) {
                    $users_removed++;
                    ## Send notification if the list config authorizes it
                    ## only.
                    if ($self->inclusion_notification_feature eq 'on') {
                        unless ($self->send_file('bye', $email)) {
                            $main::logger->do_log(Sympa::Logger::ERR,
                                'Unable to send template "bye" to %s',
                                $email);
                        }
                    }
                }
            }
        }
    }
    if ($users_removed > 0) {
        $main::logger->do_log(Sympa::Logger::NOTICE, '%d users removed',
            $users_removed);
    }

    ## Go through new users
    my @add_tab;
    $users_added = 0;
    foreach my $email (keys %{$new_subscribers}) {
        my $compare = 0;
        foreach my $sub_exclu (@subscriber_exclusion) {
            if ($email eq $sub_exclu) {
                $compare = 1;
                last;
            }
        }
        if ($compare == 1) {
            delete $new_subscribers->{$email};
            next;
        }
        if (defined($old_subscribers{$email})) {
            if ($old_subscribers{$email}{'included'}) {
                ## If one user attribute has changed, then we should update
                ## the user entry
                my $successful_update = 0;
                foreach my $attribute ('id', 'gecos') {
                    if ($old_subscribers{$email}{$attribute} ne
                        $new_subscribers->{$email}{$attribute}) {
                        $main::logger->do_log(Sympa::Logger::DEBUG,
                            'updating %s to list %s',
                            $email, $self);
                        my $update_time =
                            $new_subscribers->{$email}{'update_date'} || time;
                        unless (
                            $self->update_list_member(
                                $email,
                                {   'update_date' => $update_time,
                                    $attribute =>
                                        $new_subscribers->{$email}{$attribute}
                                }
                            )
                            ) {
                            $main::logger->do_log(Sympa::Logger::ERR,
                                'Failed to update %s', $email);
                            next;
                        } else {
                            $successful_update = 1;
                        }
                    }
                }
                $users_updated++ if ($successful_update);
                ## User was already subscribed, update
                ## include_sources_subscriber in DB
            } else {
                $main::logger->do_log(Sympa::Logger::DEBUG, 'updating %s to list %s',
                    $email, $self);
                unless (
                    $self->update_list_member(
                        $email,
                        {   'update_date' => time,
                            'included'    => 1,
                            'id'          => $new_subscribers->{$email}{'id'}
                        }
                    )
                    ) {
                    $main::logger->do_log(Sympa::Logger::ERR, 'Failed to update %s',
                        $email);
                    next;
                }
                $users_updated++;
            }

            ## Add new included user
        } else {
            my $compare = 0;
            foreach my $sub_exclu (@subscriber_exclusion) {
                unless ($compare eq '1') {
                    if ($email eq $sub_exclu) {
                        $compare = 1;
                    } else {
                        next;
                    }
                }
            }
            if ($compare eq '1') {
                next;
            }
            $main::logger->do_log(Sympa::Logger::DEBUG3, 'adding %s to list %s',
                $email, $self);
            my $u = $new_subscribers->{$email};
            $u->{'included'} = 1;
            $u->{'date'}     = time;
            @add_tab         = ($u);
            my $user_added = 0;
            unless ($user_added = $self->add_list_member(@add_tab)) {
                $main::logger->do_log(Sympa::Logger::ERR, 'Failed to add new users');
                return undef;
            }
            if ($user_added) {
                $users_added++;
                ## Send notification if the list config authorizes it only.
                if ($self->inclusion_notification_feature eq 'on') {
                    unless ($self->send_file('welcome', $u->{'email'})) {
                        $main::logger->do_log(Sympa::Logger::ERR,
                            'Unable to send template "welcome" to %s',
                            $u->{'email'});
                    }
                }
            }
        }
    }

    if ($users_added) {
        $main::logger->do_log(Sympa::Logger::NOTICE, '%d users added', $users_added);
    }

    $main::logger->do_log(Sympa::Logger::NOTICE, '%d users updated', $users_updated);

    ## Release lock
    unless ($lock_fh->close()) {
        return undef;
    }

    ## Get and save total of subscribers
    $self->get_real_total;
    $self->{'last_sync'} = time;
    $self->savestats();
    $self->sync_include_ca($option and $option eq 'purge');

    return 1;
}

## The previous function (sync_include) is to be called by the task_manager.
## This one is to be called from anywhere else. This function deletes the
## scheduled
## sync_include task. If this deletion happened in sync_include(), it would
## disturb
## the normal task_manager.pl functioning.

sub on_the_fly_sync_include {
    my $self    = shift;
    my %options = @_;

    my $pertinent_ttl = $self->distribution_ttl || $self->ttl;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Sympa::List::on_the_fly_sync_include(%s)',
        $pertinent_ttl);
    if (   $options{'use_ttl'} != 1
        || $self->{'last_sync'} < time - $pertinent_ttl) {
        $main::logger->do_log(Sympa::Logger::NOTICE, "Synchronizing list members...");
        my $return_value = $self->sync_include();
        if ($return_value == 1) {
            $self->remove_task('sync_include');
            return 1;
        } else {
            return $return_value;
        }
    }
    return 1;
}

sub sync_include_admin {
    my $self   = shift;
    my $option = shift;

    my $name = $self->name;
    $main::logger->do_log(Sympa::Logger::DEBUG2, 'List:sync_include_admin(%s)',
        $name);

    ## don't care about listmaster role
    foreach my $role ('owner', 'editor') {
        my $old_admin_users = {};
        ## Load a hash with the old admin users
        for (
            my $admin_user = $self->get_first_list_admin($role);
            $admin_user;
            $admin_user = $self->get_next_list_admin()
            ) {
            $old_admin_users->{lc($admin_user->{'email'})} = $admin_user;
        }

        ## Load a hash with the new admin user list from an include source(s)
        my $new_admin_users_include;
        ## Load a hash with the new admin user users from the list config
        my $new_admin_users_config;
        unless ($option and $option eq 'purge') {
            $new_admin_users_include =
                $self->_load_list_admin_from_include($role);

            ## If include sources were not available, do not update admin
            ## users
            ## Use DB cache instead
            unless (defined $new_admin_users_include) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Could not get %ss from an include source for list %s',
                    $role, $self);
                $self->robot->send_notify_to_listmaster(
                    'sync_include_admin_failed', [$name]);
                return undef;
            }

            $new_admin_users_config =
                $self->_load_list_admin_from_config($role);

            unless (defined $new_admin_users_config) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Could not get %ss from config for list %s',
                    $role, $self);
                return undef;
            }
        }

        my @add_tab;
        my $admin_users_added   = 0;
        my $admin_users_updated = 0;

        ## Get an Exclusive lock
        my $lock_fh =
            Sympa::LockedFile->new($self->dir . '/include_admin_user',
            20, '+');
        unless ($lock_fh) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Could not create new lock');
            return undef;
        }

        ## Go through new admin_users_include
        foreach my $email (keys %{$new_admin_users_include}) {

            # included and subscribed
            if (defined $new_admin_users_config->{$email}) {
                my $param;
                foreach my $p ('reception', 'visibility', 'gecos', 'info',
                    'profile') {

                    #  config parameters have priority on include parameters
                    #  in case of conflict
                    $param->{$p} = $new_admin_users_config->{$email}{$p}
                        if (defined $new_admin_users_config->{$email}{$p});
                    $param->{$p} ||= $new_admin_users_include->{$email}{$p};
                }

                #Admin User was already in the DB
                if (defined $old_admin_users->{$email}) {

                    $param->{'included'} = 1;
                    $param->{'id'} = $new_admin_users_include->{$email}{'id'};
                    $param->{'subscribed'} = 1;

                    my $param_update =
                        is_update_param($param, $old_admin_users->{$email});

                    # updating
                    if (defined $param_update) {
                        if (%{$param_update}) {
                            $main::logger->do_log(
                                Sympa::Logger::DEBUG,
                                'List:sync_include_admin : updating %s %s to list %s',
                                $role,
                                $email,
                                $name
                            );
                            $param_update->{'update_date'} = time;

                            unless (
                                $self->update_list_admin(
                                    $email, $role, $param_update
                                )
                                ) {
                                $main::logger->do_log(
                                    Sympa::Logger::ERR,
                                    'List:sync_include_admin(%s): Failed to update %s %s',
                                    $name,
                                    $role,
                                    $email
                                );
                                next;
                            }
                            $admin_users_updated++;
                        }
                    }

                    # for the next foreach (sort of new_admin_users_config
                    # that are not included)
                    delete($new_admin_users_config->{$email});

                    # add a new included and subscribed admin user
                } else {
                    $main::logger->do_log(Sympa::Logger::DEBUG2,
                        'List:sync_include_admin: adding %s %s to list %s',
                        $email, $role, $name);

                    foreach my $key (keys %{$param}) {
                        $new_admin_users_config->{$email}{$key} =
                            $param->{$key};
                    }
                    $new_admin_users_config->{$email}{'included'}   = 1;
                    $new_admin_users_config->{$email}{'subscribed'} = 1;
                    push(@add_tab, $new_admin_users_config->{$email});

                    # for the next foreach (sort of new_admin_users_config
                    # that are not included)
                    delete($new_admin_users_config->{$email});
                }

                # only included
            } else {
                my $param = $new_admin_users_include->{$email};

                #Admin User was already in the DB
                if (defined($old_admin_users->{$email})) {

                    $param->{'included'} = 1;
                    $param->{'id'} = $new_admin_users_include->{$email}{'id'};
                    $param->{'subscribed'} = 0;

                    my $param_update =
                        is_update_param($param, $old_admin_users->{$email});

                    # updating
                    if (defined $param_update) {
                        if (%{$param_update}) {
                            $main::logger->do_log(
                                Sympa::Logger::DEBUG,
                                'List:sync_include_admin : updating %s %s to list %s',
                                $role,
                                $email,
                                $name
                            );
                            $param_update->{'update_date'} = time;

                            unless (
                                $self->update_list_admin(
                                    $email, $role, $param_update
                                )
                                ) {
                                $main::logger->do_log(
                                    Sympa::Logger::ERR,
                                    'List:sync_include_admin(%s): Failed to update %s %s',
                                    $name,
                                    $role,
                                    $email
                                );
                                next;
                            }
                            $admin_users_updated++;
                        }
                    }

                    # add a new included admin user
                } else {
                    $main::logger->do_log(Sympa::Logger::DEBUG2,
                        'List:sync_include_admin: adding %s %s to list %s',
                        $role, $email, $name);

                    foreach my $key (keys %{$param}) {
                        $new_admin_users_include->{$email}{$key} =
                            $param->{$key};
                    }
                    $new_admin_users_include->{$email}{'included'} = 1;
                    push(@add_tab, $new_admin_users_include->{$email});
                }
            }
        }

        ## Go through new admin_users_config (that are not included : only
        ## subscribed)
        foreach my $email (keys %{$new_admin_users_config}) {

            my $param = $new_admin_users_config->{$email};

            #Admin User was already in the DB
            if (defined($old_admin_users->{$email})) {

                $param->{'included'}   = 0;
                $param->{'id'}         = '';
                $param->{'subscribed'} = 1;
                my $param_update =
                    is_update_param($param, $old_admin_users->{$email});

                # updating
                if (defined $param_update) {
                    if (%{$param_update}) {
                        $main::logger->do_log(
                            Sympa::Logger::DEBUG,
                            'List:sync_include_admin : updating %s %s to list %s',
                            $role,
                            $email,
                            $name
                        );
                        $param_update->{'update_date'} = time;

                        unless (
                            $self->update_list_admin(
                                $email, $role, $param_update
                            )
                            ) {
                            $main::logger->do_log(
                                Sympa::Logger::ERR,
                                'List:sync_include_admin(%s): Failed to update %s %s',
                                $name,
                                $role,
                                $email
                            );
                            next;
                        }
                        $admin_users_updated++;
                    }
                }

                # add a new subscribed admin user
            } else {
                $main::logger->do_log(Sympa::Logger::DEBUG2,
                    'List:sync_include_admin: adding %s %s to list %s',
                    $role, $email, $name);

                foreach my $key (keys %{$param}) {
                    $new_admin_users_config->{$email}{$key} = $param->{$key};
                }
                $new_admin_users_config->{$email}{'subscribed'} = 1;
                push(@add_tab, $new_admin_users_config->{$email});
            }
        }

        if ($#add_tab >= 0) {
            unless ($admin_users_added =
                $self->add_list_admin($role, @add_tab)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Failed to add new %ss to list %s',
                    $role, $self);
                return undef;
            }
        }

        if ($admin_users_added) {
            $main::logger->do_log(Sympa::Logger::DEBUG,
                'List:sync_include_admin(%s): %d %s(s) added',
                $name, $admin_users_added, $role);
        }

        $main::logger->do_log(Sympa::Logger::DEBUG,
            'List:sync_include_admin(%s): %d %s(s) updated',
            $name, $admin_users_updated, $role);

        ## Go though old list of admin users
        my $admin_users_removed = 0;
        my @deltab;

        foreach my $email (keys %$old_admin_users) {
            unless (defined($new_admin_users_include->{$email})
                || defined($new_admin_users_config->{$email})) {
                $main::logger->do_log(Sympa::Logger::DEBUG2,
                    'List:sync_include_admin: removing %s %s to list %s',
                    $role, $email, $name);
                push(@deltab, $email);
            }
        }

        if ($#deltab >= 0) {
            unless ($admin_users_removed =
                $self->delete_list_admin($role, @deltab)) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'List:sync_include_admin(%s): Failed to delete %s %s',
                    $name, $role, $admin_users_removed);
                return undef;
            }
            $main::logger->do_log(Sympa::Logger::DEBUG,
                'List:sync_include_admin(%s): %d %s(s) removed',
                $name, $admin_users_removed, $role);
        }

        ## Release lock
        unless ($lock_fh->close()) {
            return undef;
        }
    }

    $self->{'last_sync_admin_user'} = time;
    $self->savestats();

    return $self->get_nb_owners;
}

## Load param admin users from the config of the list
sub _load_list_admin_from_config {
    my $self = shift;
    my $role = shift;
    my $name = $self->name;
    my %admin_users;

    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s) for list %s', $role, $name);

    ##FIXME: check $role argument
    foreach my $entry (@{$self->$role}) {
        my $email = lc($entry->{'email'});
        my %u;

        $u{'email'}      = $email;
        $u{'reception'}  = $entry->{'reception'};
        $u{'visibility'} = $entry->{'visibility'};
        $u{'gecos'}      = $entry->{'gecos'};
        $u{'info'}       = $entry->{'info'};
        $u{'profile'}    = $entry->{'profile'} if ($role eq 'owner');

        $admin_users{$email} = \%u;
    }
    return \%admin_users;
}

## return true if new_param has changed from old_param
#  $new_param is changed to return only entries that need to
# be updated (only deals with admin user parameters, editor or owner)
sub is_update_param {
    my $new_param = shift;
    my $old_param = shift;
    my $resul     = {};
    my $update    = 0;

    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Sympa::List::is_update_param ');

    foreach my $p (
        'reception', 'visibility', 'gecos',    'info',
        'profile',   'id',         'included', 'subscribed'
        ) {
        if (defined $new_param->{$p}) {
            if (defined $old_param->{$p}
                && $new_param->{$p} ne $old_param->{$p}) {
                $resul->{$p} = $new_param->{$p};
                $update = 1;
            }
        } else {
            if (defined $old_param->{$p} and $old_param->{$p} ne '') {
                $resul->{$p} = '';
                $update = 1;
            }
        }
    }
    if ($update) {
        return $resul;
    } else {
        return undef;
    }
}

sub _inclusion_loop {

    my $name      = shift;
    my $incl      = shift;
    my $depend_on = shift;

    return 1 if ($depend_on->{$incl});

    return undef;
}

## Writes to disk the stats data for a list.
sub _save_stats_file {
    my $self = shift;

    croak "Invalid parameter: $self"
        unless ref $self;    #prototype changed (6.2)

    unless (defined $self->stats and ref $self->stats eq 'ARRAY') {
        unless ($self->_create_stats_file) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Stats file creation impossible for list %s', $self);
            return undef;
        }
        $self->_load_stats_file;
    }

    my $file                 = $self->dir . '/stats';
    my $stats                = $self->stats;
    my $total                = $self->total;
    my $last_sync            = $self->{'last_sync'};
    my $last_sync_admin_user = $self->{'last_sync_admin_user'};

    $main::logger->do_log(Sympa::Logger::DEBUG3,
        '(file=%s, total=%s, last_sync=%s, last_sync_admin_user=%s)',
        $file, $total, $last_sync, $last_sync_admin_user);
    my $untainted_filename = sprintf("%s", $file);    #XXX required?
    open(L, '>', $untainted_filename) || return undef;
    printf L "%d %.0f %.0f %.0f %d %d %d\n", @{$stats}, $total, $last_sync,
        $last_sync_admin_user;
    close(L);
}

sub _create_stats_file {
    my $self = shift;

    my $file = $self->dir . '/stats';
    $main::logger->do_log(Sympa::Logger::DEBUG3, 'Creating stats file(%s, file=%s)',
        $self, $file);

    if (-f $file) {
        $main::logger->do_log(Sympa::Logger::DEBUG2,
            'File %s already exists. No need to create it.', $file);
        return 1;
    }
    unless (open STATS, ">$file") {
        $main::logger->do_log(Sympa::Logger::ERR, 'Unable to create file %s.', $file);
        return undef;
    }
    print STATS "0 0 0 0 0 0 0\n";
    close STATS;
    return 1;
}

## Writes the user list to disk
sub _save_list_members_file {
    my ($self, $file) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', $file);

    my ($k, $s);

    $main::logger->do_log(Sympa::Logger::DEBUG2, 'Saving user file %s', $file);

    rename("$file", "$file.old");
    open SUB, "> $file" or return undef;

    for (
        $s = $self->get_first_list_member();
        $s;
        $s = $self->get_next_list_member()
        ) {
        foreach $k (
            'date',      'update_date', 'email', 'gecos',
            'reception', 'visibility'
            ) {
            printf SUB "%s %s\n", $k, $s->{$k} unless ($s->{$k} eq '');

        }
        print SUB "\n";
    }
    close SUB;
    return 1;
}

## Store the message in spool digest  by creating a new entry for it or
## updating an existing one for this list
##
sub store_digest {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my ($self, $message) = @_;

    my @now = localtime(time);

    my $digestspool = Sympa::Spool::File::Message->new(
        name      => 'digest', 
        directory => Sympa::Site->queuedigest(),
        selector => {'list' => $self->name, 'robot' => $self->domain}
    );

    # remember that spool->next lock the selected message if any
    my $current_digest = $digestspool->next;

    my $message_as_string;
    if ($current_digest) {
        $message_as_string = $current_digest->{'messageasstring'};
    } else {
        $message_as_string =
            sprintf "\nThis digest for list has been created on %s\n\n",
            POSIX::strftime("%a %b %e %H:%M:%S %Y", @now);
        $message_as_string .= sprintf
            "------- THIS IS A RFC934 COMPLIANT DIGEST, YOU CAN BURST IT -------\n\n";
        $message_as_string .= sprintf "\n%s\n\n",
            Sympa::Tools::get_separator();
    }
    $message_as_string .= $message->as_string();    #without metadata
    $message_as_string .= sprintf "\n%s\n\n", Sympa::Tools::get_separator();

    # update and unlock current digest message or create it
    if ($current_digest) {

        # update does not modify the date field, this is needed in order to
        # send digest when needed.
        unless (
            $digestspool->update(
                {'messagekey' => $current_digest->{'messagekey'}},
                {'message'    => $message_as_string, 'messagelock' => 'NULL'}
            )
            ) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                "could not update digest adding this message (digest spool entry key %s)",
                $current_digest->{'messagekey'}
            );
            return undef;
        }
    } else {
        unless (
            $digestspool->store(
                $message_as_string,
                {'list' => $self->name, 'robot' => $self->domain}
            )
            ) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                "could not store message in digest spool messafge digestkey %s",
                $current_digest->{'messagekey'}
            );
            return undef;
        }
    }
}

=over 4

=item get_lists( [ CONTEXT, [ OPTIONS ] ] )

I<Function>.
List of lists hosted by a family, a robot or whole site.

=over 4

=item CONTEXT

Robot object, Sympa::Family object or Site class (default).

=item OPTIONS

A hashref including options passed to Sympa::List->new() (see load()) and any of
following pairs:

=over 4

=item C<'filter_query' =E<gt> [ KEYS =E<gt> VALS, ... ]>

Filter with list profiles.  When any of items specified by KEYS
(separated by C<"|">) have any of values specified by VALS,
condition by that pair is satisfied.
KEYS prefixed by C<"!"> mean negated condition.
Only lists satisfying all conditions of query are returned.
Currently available keys and values are:

=over 4

=item 'creation' => EPOCH

=item 'creation<' => EPOCH

=item 'creation>' => EPOCH

Creation date is equal to, earlier than or later than the date (epoch).

=item 'member' => EMAIL

=item 'owner' => EMAIL

=item 'editor' => EMAIL

Specified user is a subscriber, owner or editor of the list.

=item 'name' => STRING

=item 'name%' => STRING

=item '%name%' => STRING

Exact, prefixed or substring match against list name,
case-insensitive.

=item 'status' => "STATUS|..."

Status of list.  One of 'open', 'closed', 'pending',
'error_config' and 'family_closed'.

=item 'subject' => STRING

=item 'subject%' => STRING

=item '%subject%' => STRING

Exact, prefixed or substring match against list subject,
case-insensitive (case folding is Unicode-aware).

=item 'topics' => "TOPIC|..."

Exact match against any of list topics.
'others' or 'topicsless' means no topics.

=item 'update' => EPOCH

=item 'update<' => EPOCH

=item 'update>' => EPOCH

Date of last update is equal to, earlier than or later than the date (epoch).

=begin comment

=item 'web_archive' => ( 1 | 0 )

Whether Web archive of the list is available.  1 or 0.

=end comment

=back

=item C<'limit' =E<gt> NUMBER >

Limit the number of results.
C<0> means no limit (default).
Note that this option may be applied prior to C<'order'> option.

=item C<'order' =E<gt> [ KEY, ... ]>

Subordinate sort key(s).  The results are sorted primarily by robot names
then by other key(s).  Keys prefixed by C<"-"> mean descendent ordering.
Available keys are:

=over 4

=item C<'creation'>

Creation date.

=item C<'name'>

List name, case-insensitive.  It is the default.

=item C<'total'>

Estimated number of subscribers.

=item C<'update'>

Date of last update.

=back

=back

=begin comment 

##=item REQUESTED_LISTS
##
##Arrayref to name of requested lists, if any.

=end comment

=back

Returns a ref to an array of List objects.

=back

=cut

sub get_lists {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $that    = shift || 'Site';
    my $options = shift || {};

    my (@lists, @robots, $family_name);

    if (ref $that and ref $that eq 'Sympa::Family') {
        @robots      = ($that->robot);
        $family_name = $that->name;
    } else {
        croak "missing 'that' parameter" unless $that;
        croak "invalid 'robot' parameter" unless
            $that eq '*' or
            (blessed $that and $that->isa('Sympa::VirtualHost'));
        if (ref $that and ref $that eq 'Sympa::VirtualHost') {
            @robots = ($that);
        } elsif ($that eq 'Site') {
            @robots = @{Sympa::VirtualHost::get_robots()};
        } else {
            croak 'bug in logic.  Ask developer';
        }
    }

    # Build query: Perl expression for files and SQL expression for
    # list_table.
    my $cond_perl   = undef;
    my $cond_sql    = undef;
    my $which_role  = undef;
    my $which_user  = undef;
    my @query       = (@{$options->{'filter_query'} || []});
    my @clause_perl = ();
    my @clause_sql  = ();

    ## get family lists
    if ($family_name) {
        push @clause_perl,
            sprintf('$list->family_name and $list->family_name eq "%s"',
            quotemeta $family_name);
        push @clause_sql,
            sprintf('family_list = %s',
            Sympa::DatabaseManager::quote($family_name));
    }

    while (1 < scalar @query) {
        my @expr_perl = ();
        my @expr_sql  = ();

        my $keys = shift @query;
        next unless defined $keys and $keys =~ /\S/;
        $keys =~ s/^(!?)\s*//;
        my $negate = $1;
        my @keys = split /[|]/, $keys;

        my $vals = shift @query;
        next unless defined $vals and length $vals;    # spaces are allowed
        my @vals = split /[|]/, $vals;

        foreach my $k (@keys) {
            next unless $k =~ /\S/;

            my $c = undef;
            my ($b, $a) = ('', '');
            $b = $1 if $k =~ s/^(%)//;
            $a = $1 if $k =~ s/(%)$//;
            if ($b or $a) {
                unless ($a) {
                    $c = '%s eq "%s"';
                } elsif ($b) {
                    $c = 'index(%s, "%s") >= 0';
                } else {
                    $c = 'index(%s, "%s") == 0';
                }
            } elsif ($k =~ s/\s*([<>])\s*$//) {
                $c = '%s ' . $1 . ' %s';
            }

            ## query with single key and single value

            if ($k =~ /^(member|owner|editor)$/) {
                if (defined $which_role) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        "bug in logic. Ask developer");
                    return undef;
                }
                $which_role = $k;
                $which_user = $vals;
                next;
            }

            ## query with single value

            if ($k eq 'name' or $k eq 'subject') {
                my ($vl, $ve, $key_perl, $key_sql);
                if ($k eq 'name') {
                    $key_perl = '$list->name';
                    $key_sql  = 'name_list';
                    $vl       = lc $vals;
                } else {
                    $key_perl = 'Sympa::Tools::Text::foldcase($list->subject)';
                    $key_sql  = 'searchkey_list';
                    $vl       = Sympa::Tools::Text::foldcase($vals);
                }

                ## Perl expression
                $ve = $vl;
                $ve =~ s/([^ \w\x80-\xFF])/\\$1/g;
                push @expr_perl,
                    sprintf(($c ? $c : '%s eq "%s"'), $key_perl, $ve);

                ## SQL expression
                if ($a or $b) {
                    $ve = Sympa::DatabaseManager::quote($vl);
                    $ve =~ s/^["'](.*)['"]$/$1/;
                    $ve =~ s/([%_])/\\$1/g;
                    push @expr_sql,
                        sprintf("%s LIKE '%s'", $key_sql, "$b$ve$a");
                } else {
                    push @expr_sql,
                        sprintf('%s = %s',
                        $key_sql, Sympa::DatabaseManager::quote($vl));
                }

                next;
            }

            foreach my $v (@vals) {
                ## Perl expressions
                if ($k eq 'creation' or $k eq 'update') {
                    push @expr_perl,
                        sprintf(($c ? $c : '%s == %s'),
                        sprintf('$list->%s->{"date_epoch"}', $k), $v);
##		} elsif ($k eq 'web_archive') {
##		    push @expr_perl,
##			 sprintf('%s$list->is_web_archived',
##		    		 ($v+0 ? '' : '! '));
                } elsif ($k eq 'status') {
                    my $ve = lc $v;
                    $ve =~ s/([^ \w\x80-\xFF])/\\$1/g;
                    push @expr_perl, sprintf('$list->status eq "%s"', $ve);
                } elsif ($k eq 'topics') {
                    my $ve = lc $v;
                    if ($ve eq 'others' or $ve eq 'topicsless') {
                        push @expr_perl,
                            '! scalar(grep { $_ ne "others" } @{$list->topics || []})';
                    } else {
                        $ve =~ s/([^ \w\x80-\xFF])/\\$1/g;
                        push @expr_perl,
                            sprintf(
                            'scalar(grep { $_ eq "%s" } @{$list->topics || []})',
                            $ve);
                    }
                } else {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        "bug in logic. Ask developer");
                    return undef;
                }

                ## SQL expressions
                if ($k eq 'creation' or $k eq 'update') {
                    push @expr_sql,
                        sprintf('%s_epoch_list %s %s',
                        $k, ($c ? $c : '='), $v);
##		} elsif ($k eq 'web_archive') {
##                    push @expr_sql,
##			 sprintf('web_archive_list = %d', ($v+0 ? 1 : 0));
                } elsif ($k eq 'status') {
                    push @expr_sql,
                        sprintf('%s_list = %s',
                        $k, Sympa::DatabaseManager::quote($v));
                } elsif ($k eq 'topics') {
                    my $ve = lc $v;
                    if ($ve eq 'others' or $ve eq 'topicsless') {
                        push @expr_sql, "topics_list = ''";
                    } else {
                        $ve = Sympa::DatabaseManager::quote($ve);
                        $ve =~ s/^["'](.*)['"]$/$1/;
                        $ve =~ s/([%_])/\\$1/g;
                        push @expr_sql,
                            sprintf("topics_list LIKE '%%,%s,%%'", $ve);
                    }
                }
            }
        }
        if (scalar @expr_perl) {
            push @clause_perl,
                ($negate ? '! ' : '') . '(' . join(' || ', @expr_perl) . ')';
            push @clause_sql,
                ($negate ? 'NOT ' : '') . '(' . join(' OR ', @expr_sql) . ')';
        }
    }

    if (scalar @clause_perl) {
        $cond_perl = join ' && ',  @clause_perl;
        $cond_sql  = join ' AND ', @clause_sql;
    } else {
        $cond_perl = undef;
        $cond_sql  = undef;
    }
    $main::logger->do_log(Sympa::Logger::DEBUG3, 'filter_query %s; %s',
        $cond_perl, $cond_sql);

    ## Sort order
    my $order_perl;
    my $order_sql;
    my $keys      = $options->{'order'} || [];
    my @keys_perl = ();
    my @keys_sql  = ();
    foreach my $key (@{$keys}) {
        my $desc = ($key =~ s/^\s*-\s*//i);

        if ($key eq 'creation' or $key eq 'update') {
            if ($desc) {
                push @keys_perl,
                    sprintf
                    '$b->%s->{"date_epoch"} <=> $a->%s->{"date_epoch"}', $key,
                    $key;
            } else {
                push @keys_perl,
                    sprintf
                    '$a->%s->{"date_epoch"} <=> $b->%s->{"date_epoch"}', $key,
                    $key;
            }
        } elsif ($key eq 'name') {
            if ($desc) {
                push @keys_perl, '$b->name cmp $a->name';
            } else {
                push @keys_perl, '$a->name cmp $b->name';
            }
        } elsif ($key eq 'total') {
            if ($desc) {
                push @keys_perl, sprintf '$b->total <=> $a->total';
            } else {
                push @keys_perl, sprintf '$a->total <=> $b->total';
            }
        } else {
            $main::logger->do_log(Sympa::Logger::ERR, 'bug in logic.  Ask developer');
            return undef;
        }

        if ($key eq 'creation' or $key eq 'update') {
            push @keys_sql,
                sprintf '%s_epoch_list%s', $key, ($desc ? ' DESC' : '');
        } else {
            push @keys_sql, sprintf '%s_list%s', $key, ($desc ? ' DESC' : '');
        }
    }
    $order_perl = join(' or ', @keys_perl) || undef;
    push @keys_sql, 'name_list'
        unless scalar grep { $_ =~ /name_list/ } @keys_sql;
    $order_sql = join(', ', @keys_sql);
    $main::logger->do_log(Sympa::Logger::DEBUG3, 'order %s; %s', $order_perl,
        $order_sql);

    ## limit number of result
    my $limit = $options->{'limit'} || undef;
    my $count = 0;

    foreach my $robot (@robots) {
        ## Check on-memory cache first
        if (!defined $which_role and $robot->lists_ok) {
            my @all_lists = $robot->lists;
            ## filter list if required.
            my @l = ();
            if (defined $cond_perl) {
                foreach my $list (@all_lists) {
                    next unless eval $cond_perl;
                    push @l, $list;
                    last if $limit and $limit <= ++$count;
                }
            } elsif ($limit) {
                foreach my $list (@all_lists) {
                    push @l, $list;
                    last if $limit <= ++$count;
                }
            } else {
                push @l, @all_lists;
            }

            ## sort
            if ($order_perl) {
                eval 'use sort "stable"';
                push @lists, sort { eval $order_perl } @l;
                eval 'use sort "defaults"';
            } else {
                push @lists, @l;
            }

            last if $limit and $limit <= $count;
            next;    # foreach my $robot
        }

        ## check existence of robot directory
        my $robot_dir = $robot->home;

        ## Files are used instead of list_table DB cache.

        if (   $robot->cache_list_config ne 'database'
            or $options->{'reload_config'}) {
            my %requested_lists = ();

            ## filter by role
            if (defined $which_role) {
                my %r = ();

                push @sth_stack, $sth;

                if ($which_role eq 'member') {
                    $sth = Sympa::DatabaseManager::do_prepared_query(
                        q{SELECT list_subscriber
			  FROM subscriber_table
			  WHERE robot_subscriber = ? AND user_subscriber = ?},
                        $robot->domain, $which_user
                    );
                } else {
                    $sth = Sympa::DatabaseManager::do_prepared_query(
                        q{SELECT list_admin
			  FROM admin_table
			  WHERE robot_admin = ? AND user_admin = ? AND
				role_admin = ?},
                        $robot->domain, $which_user, $which_role
                    );
                }
                unless ($sth) {
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        'failed to get lists with user %s as %s from database: %s',
                        $which_user,
                        $which_role,
                        $EVAL_ERROR
                    );
                    $sth = pop @sth_stack;
                    return undef;
                }
                my @row;
                while (@row = $sth->fetchrow_array) {
                    my $listname = $row[0];
                    $r{$listname} = 1;
                }
                $sth->finish;

                $sth = pop @sth_stack;

                # none found
                next unless %r;    # foreach my $robot
                %requested_lists = %r;
            }

            ## If entire lists on a robot are requested,
            ## check orphan entries on cache.
            my %orphan = ();
            if (!%requested_lists and $options->{'reload_config'}) {
                push @sth_stack, $sth;

                unless (
                    $sth = Sympa::DatabaseManager::do_prepared_query(
                        q{SELECT name_list
			  FROM list_table
			  WHERE robot_list = ?},
                        $robot->domain
                    )
                    ) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        'Failed to get lists from database');
                    $sth = pop @sth_stack;
                    return undef;
                }
                my @row;
                while (@row = $sth->fetchrow_array) {
                    $orphan{$row[0]} = 1;
                }
                $sth->finish;

                $sth = pop @sth_stack;
            }

            unless (opendir(DIR, $robot_dir)) {
                $main::logger->do_log(Sympa::Logger::ERR, 'Unable to open %s',
                    $robot_dir);
                return undef;
            }
            my @l = ();
            foreach my $listname (sort readdir(DIR)) {
                next if $listname =~ /^\.+$/;
                next unless -d "$robot_dir/$listname";
                next unless -f "$robot_dir/$listname/config";

                ## filter lists by role.
                if (%requested_lists) {
                    next unless $requested_lists{$listname};
                }
                ## create object
                my $list = Sympa::List->new($listname, $robot, $options);
                next unless defined $list;

                ## not orphan entry
                delete $orphan{$listname};

                ## filter by condition
                if (defined $cond_perl) {
                    next unless eval $cond_perl;
                }

                push @l, $list;
                last if $limit and $limit <= ++$count;
            }
            closedir DIR;

            ## All lists are in memory cache
            $robot->lists_ok(1)
                unless ($limit and $limit <= $count)
                or %requested_lists;

            ## sort
            if ($order_perl) {
                eval 'use sort "stable"';
                push @lists, sort { eval $order_perl } @l;
                eval 'use sort "defaults"';
            } else {
                push @lists, @l;
            }

            ## clear orphan cache entries in list_table.
            if (    !($limit and $limit <= $count)
                and $options->{'reload_config'}
                and %orphan) {
                foreach my $name (keys %orphan) {
                    $main::logger->do_log(Sympa::Logger::NOTICE,
                        'Clearing orphan list cache on list_table: %s@%s',
                        $name, $robot->domain);
                    Sympa::DatabaseManager::do_prepared_query(
                        q{DELETE from list_table
			  WHERE name_list = ? AND robot_list = ?},
                        $name, $robot->domain
                    );
                }
            }

            last if $limit and $limit <= $count;
            next;    # foreach my $robot
        }

        ## Use list_table DB cache.

        my $table;
        my $cond;
        my $cols;
        if (!defined $which_role) {
            $table = 'list_table';
            $cond  = '';
            $cols  = '';
        } elsif ($which_role eq 'member') {
            $table = 'list_table, subscriber_table';
            $cond  = sprintf q{robot_list = robot_subscriber AND
		  name_list = list_subscriber AND
		  user_subscriber = %s AND }, Sympa::DatabaseManager::quote($which_user);
            $cols = ', ' . _list_member_cols();
        } else {
            $table = 'list_table, admin_table';
            $cond  = sprintf q{robot_list = robot_admin AND
		  name_list = list_admin AND
		  role_admin = %s AND
		  user_admin = %s AND }, Sympa::DatabaseManager::quote($which_role),
                Sympa::DatabaseManager::quote($which_user);
            $cols = ', ' . _list_admin_cols();
        }

        push @sth_stack, $sth;

        if (defined $cond_sql) {
            $sth = Sympa::DatabaseManager::do_query(
                q{SELECT name_list AS name%s
		  FROM %s
		  WHERE %s robot_list = %s AND %s
		  ORDER BY %s},
                $cols,
                $table,
                $cond, Sympa::DatabaseManager::quote($robot->domain),
                $cond_sql,
                $order_sql
            );
        } else {
            $sth = Sympa::DatabaseManager::do_prepared_query(
                sprintf(
                    q{SELECT name_list AS name%s
		      FROM %s
		      WHERE %s robot_list = ?
		      ORDER BY %s},
                    $cols,
                    $table,
                    $cond,
                    $order_sql
                ),
                $robot->domain
            );
        }
        unless ($sth) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Failed to get lists from %s',
                $table);
            $sth = pop @sth_stack;
            return undef;
        }
        my $list;
        my $l;
        my @l = ();
        while ($l = $sth->fetchrow_hashref('NAME_lc')) {
            ## filter by requested_lists
            push @l, $l;
        }
        $sth->finish;

        $sth = pop @sth_stack;

        foreach my $l (@l) {
            unless (
                $list = __PACKAGE__->new(
                    $l->{'name'},
                    $robot,
                    {   %$options,
                        'skip_name_check' => 1,
                        'skip_sync_admin' => 1
                    }
                )
                ) {
                next;
            }

            ## save subscriber/admin information to memory cache.
            if (defined $which_role) {
                delete $l->{'name'};
                $list->user($which_role, $which_user, $l);
            }

            push @lists, $list;
            last if $limit and $limit <= ++$count;
        }

        $robot->lists_ok(1)
            unless ($limit and $limit <= $count)
            or defined $which_role
            or defined $cond_sql;

        last if $limit and $limit <= $count;
    }

    return \@lists;
}

=over 4

=item get_which ( EMAIL, ROBOT, ROLE )

I<Function>.
Get a list of lists where EMAIL assumes this ROLE (owner, editor or member) of
function to any list in ROBOT.

=back

=cut

sub get_which {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my $email = Sympa::Tools::clean_email(shift);
    my $robot = shift;
    my $role  = shift;

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));

    unless ($role eq 'member' or $role eq 'owner' or $role eq 'editor') {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Internal error, unknown or undefined parameter "%s"', $role);
        return undef;
    }

    my $all_lists = get_lists(
        $robot,
        {   'filter_query' => [
                $role      => $email,
                '! status' => 'closed|family_closed'
            ]
        }
    );

    return @{$all_lists || []};
}

## return total of messages awaiting moderation
sub get_mod_spool_size {
    my $self = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG3, 'Sympa::List::get_mod_spool_size()');

    my $modspool = Sympa::Spool::File::Key->new(
        name      => 'mod',
        directory => Sympa::Site->queuemod()
    );
    return $modspool->get_count(
        selector => {
            list      => $self->name,
            robot     => $self->domain,
            validated => ['.distribute', 'ne']
        }
    );
}

### moderation for shared

# return the status of the shared
sub get_shared_status {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self = shift;

    if (-e $self->dir . '/shared') {
        return 'exist';
    } elsif (-e $self->dir . '/pending.shared') {
        return 'deleted';
    } else {
        return 'none';
    }
}

# return the list of documents shared waiting for moderation
sub get_shared_moderated {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);
    my $self      = shift;
    my $shareddir = $self->dir . '/shared';

    unless (-e "$shareddir") {
        return undef;
    }

    ## sort of the shared
    my @mod_dir = sort_dir_to_get_mod("$shareddir");
    return \@mod_dir;
}

# return the list of documents awaiting for moderation in a dir and its
# subdirectories
sub sort_dir_to_get_mod {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s)', @_);

    #dir to explore
    my $dir = shift;

    # listing of all the shared documents of the directory
    unless (opendir DIR, "$dir") {
        $main::logger->do_log(Sympa::Logger::ERR,
            "sort_dir_to_get_mod : cannot open $dir : $ERRNO");
        return undef;
    }

    # array of entry of the directory DIR
    my @tmpdir = readdir DIR;
    closedir DIR;

    # private entry with documents not yet moderated
    my @moderate_dir = grep (/(\.moderate)$/, @tmpdir);
    @moderate_dir = grep (!/^\.desc\./, @moderate_dir);

    foreach my $d (@moderate_dir) {
        $d = "$dir/$d";
    }

    my $path_d;
    foreach my $d (@tmpdir) {

        # current document
        $path_d = "$dir/$d";

        if ($d =~ /^\.+$/) {
            next;
        }

        if (-d $path_d) {
            push(@moderate_dir, sort_dir_to_get_mod($path_d));
        }
    }

    return @moderate_dir;

}

## Get the type of a DB field
sub get_db_field_type {
    my ($table, $field) = @_;
## TODO: Won't work with anything apart from MySQL. should use SDM framework
## subs.
    unless ($sth =
        Sympa::DatabaseManager::do_query("SHOW FIELDS FROM $table")) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'get the list of fields for table %s', $table);
        return undef;
    }

    while (my $ref = $sth->fetchrow_hashref('NAME_lc')) {
        next unless ($ref->{'Field'} eq $field);

        return $ref->{'Type'};
    }

    return undef;
}

## Lowercase field from database
sub lowercase_field {
    my ($table, $field) = @_;

    my $total = 0;

    unless (
        $sth = Sympa::DatabaseManager::do_prepared_query(
            "SELECT $field from $table")
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to get values of field %s for table %s',
            $field, $table);
        return undef;
    }

    while (my $user = $sth->fetchrow_hashref('NAME_lc')) {
        my $lower_cased = lc($user->{$field});
        next if ($lower_cased eq $user->{$field});

        $total++;

        ## Updating Db
        unless (
            $sth = Sympa::DatabaseManager::do_prepared_query(
                sprintf(
                    q{UPDATE %s SET %s = ? WHERE %s = ?},
                    $table, $field, $field
                ),
                $lower_cased,
                $user->{$field}
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to set field % from table %s to value %s',
                $field, $lower_cased, $table);
            next;
        }
    }
    $sth->finish();

    return $total;
}

############ THIS IS RELATED TO NEW LOAD_ADMIN_FILE #############

## Sort function for writing config files
sub by_order {
    ($Sympa::ListDef::pinfo{$main::a}
            {'order'} <=> $Sympa::ListDef::pinfo{$main::b}{'order'})
        || ($main::a cmp $main::b);
}

## Save a parameter
sub _save_list_param {
    my $robot = shift;
    my $key   = shift;
    my $p     = shift;
    my $fd    = shift;

##    ## Ignore default value
##    return 1 if ! ref $defaults and $defaults == 1;
    return 1 unless defined $p;

    my $pinfo = $robot->list_params;
    if (   defined $pinfo->{$key}{'scenario'}
        or defined $pinfo->{$key}{'task'}) {
        return 1 if $p->{'name'} eq 'default';

        $fd->print(sprintf "%s %s\n", $key, $p->{'name'});
        $fd->print("\n");
    } elsif (ref($pinfo->{$key}{'file_format'})) {
        $fd->print(sprintf "%s\n", $key);
        foreach my $k (keys %{$p}) {
            if (defined $pinfo->{$key}{'file_format'}{$k}{'scenario'}) {
                ## Skip if empty value
                next if ($p->{$k}{'name'} =~ /^\s*$/);

                $fd->print(sprintf "%s %s\n", $k, $p->{$k}{'name'});
            } elsif ($pinfo->{$key}{'file_format'}{$k}{'occurrence'} =~ /n$/
                and $pinfo->{$key}{'file_format'}{$k}{'split_char'}) {
                $fd->print(
                    sprintf "%s %s\n",
                    $k,
                    join(
                        $pinfo->{$key}{'file_format'}{$k}{'split_char'},
                        @{$p->{$k}}
                    )
                );
            } else {
                ## Skip if empty value
                next if ($p->{$k} =~ /^\s*$/);

                $fd->print(sprintf "%s %s\n", $k, $p->{$k});
            }
        }
        $fd->print("\n");
    } else {
        if (    $pinfo->{$key}{'occurrence'} =~ /n$/
            and $pinfo->{$key}{'split_char'}) {
            ### " avant de debugger do_edit_list qui crée des nouvelles
            ### entrées vides
            my $string = join($pinfo->{$key}{'split_char'}, @{$p});
            $string =~ s/\,\s*$//;

            $fd->print(sprintf "%s %s\n\n", $key, $string);
        } elsif ($key eq 'digest') {
            my $value = sprintf '%s %d:%d', join(',', @{$p->{'days'}}),
                $p->{'hour'}, $p->{'minute'};
            $fd->print(sprintf "%s %s\n\n", $key, $value);
        } else {
            $fd->print(sprintf "%s %s\n\n", $key, $p);
        }
    }

    return 1;
}

## Load a single line
sub _load_list_param {
    my ($robot, undef, $value, $p, undef) = @_;

    ## Empty value
    if ($value =~ /^\s*$/) {
        return undef;
    }

    ## Default
    if ($value eq 'default') {
        $value = $p->{'default'};
    }

    ## Search configuration file
    if (    ref $value
        and $value->{'conf'}
        and grep { $_->{'name'} and $_->{'name'} eq $value->{'conf'} }
        @Sympa::ConfDef::params) {
        my $param = $value->{'conf'};
        $value = $robot->$param;
    }

    ## Synonyms
    if (defined $value and defined $p->{'synonym'}{$value}) {
        $value = $p->{'synonym'}{$value};
    }

    ## Scenario
    if ($p->{'scenario'}) {
        $value =~ y/,/_/;
        $value = {'name' => $value};
    } elsif ($p->{'task'}) {
        $value = {'name' => $value};
    }

    ## Do we need to split param if it is not already an array
    if (    exists $p->{'occurrence'}
        and $p->{'occurrence'} =~ /n$/
        and $p->{'split_char'}
        and defined $value
        and ref $value ne 'ARRAY') {
        $value =~ s/^\s*(.+)\s*$/$1/;
        return [split /\s*$p->{'split_char'}\s*/, $value];
    } else {
        return $value;
    }
}

## Load the certificat file
sub get_cert {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self   = shift;
    my $format = shift;

    ## Default format is PEM (can be DER)
    $format ||= 'pem';

    # we only send the encryption certificate: this is what the user
    # needs to send mail to the list; if he ever gets anything signed,
    # it will have the respective cert attached anyways.
    # (the problem is that netscape, opera and IE can't only
    # read the first cert in a file)
    my ($certs, undef) = Sympa::Tools::SMIME::find_keys($self->dir, 'encrypt');

    my @cert;
    if ($format eq 'pem') {
        unless (open(CERT, $certs)) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Unable to open %s: %s',
                $certs, $ERRNO);
            return undef;
        }

        my $state;
        while (<CERT>) {
            chomp;
            if ($state == 1) {

                # convert to CRLF for windows clients
                push(@cert, "$_\r\n");
                if (/^-+END/) {
                    pop @cert;
                    last;
                }
            } elsif (/^-+BEGIN/) {
                $state = 1;
            }
        }
        close CERT;
    } elsif ($format eq 'der') {
        unless (open CERT,
            Sympa::Site->openssl . " x509 -in $certs -outform DER|") {
            $main::logger->do_log(Sympa::Logger::ERR,
                Sympa::Site->openssl . " x509 -in $certs -outform DER|");
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to open get %s in DER format: %s',
                $certs, $ERRNO);
            return undef;
        }

        @cert = <CERT>;
        close CERT;
    } else {
        $main::logger->do_log(Sympa::Logger::ERR, 'unknown "%s" certificate format',
            $format);
        return undef;
    }

    return @cert;
}

## Load a config file of a list
sub _load_list_config_file {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s)', @_);
    my $robot     = shift;
    my $directory = shift;
    my $file      = shift;

    my $pinfo       = $robot->list_params;
    my $config_file = $directory . '/' . $file;

    my %admin;
    my (@paragraphs);

    ## Just in case...
    local $RS = "\n";

##    ## Set defaults to 1
##    foreach my $pname (keys %$pinfo) {
##	$admin{'defaults'}{$pname} = 1 unless $pinfo->{$pname}{'internal'};
##    }

    ## Lock file
    my $lock_fh = Sympa::LockedFile->new($config_file, 5, '<');
    unless ($lock_fh) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Could not create new lock on %s',
            $config_file);
        return undef;
    }

    ## Split in paragraphs
    my $i = 0;
    while (<$lock_fh>) {
        if (/^\s*$/) {
            $i++ if $paragraphs[$i];
        } else {
            push @{$paragraphs[$i]}, $_;
        }
    }

    for my $index (0 .. $#paragraphs) {
        my @paragraph = @{$paragraphs[$index]};

        my $pname;

        ## Clean paragraph, keep comments
        for my $i (0 .. $#paragraph) {
            my $changed = undef;
            for my $j (0 .. $#paragraph) {
                if ($paragraph[$j] =~ /^\s*\#/) {
                    chomp($paragraph[$j]);
                    push @{$admin{'comment'}}, $paragraph[$j];
                    splice @paragraph, $j, 1;
                    $changed = 1;
                } elsif ($paragraph[$j] =~ /^\s*$/) {
                    splice @paragraph, $j, 1;
                    $changed = 1;
                }

                last if $changed;
            }

            last unless $changed;
        }

        ## Empty paragraph
        next unless ($#paragraph > -1);

        ## Look for first valid line
        unless ($paragraph[0] =~ /^\s*([\w-]+)(\s+.*)?$/) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Bad paragraph "%s" in %s, ignore it',
                @paragraph, $config_file);
            next;
        }

        $pname = $1;

        ## Parameter aliases (compatibility concerns)
        if (defined $Sympa::ListDef::alias{$pname}) {
            $paragraph[0] =~ s/^\s*$pname/$Sympa::ListDef::alias{$pname}/;
            $pname = $Sympa::ListDef::alias{$pname};
        }

        unless (defined $pinfo->{$pname}) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unknown parameter "%s" in %s, ignore it',
                $pname, $config_file);
            next;
        }

        ## Uniqueness
        if (defined $admin{$pname}
            and $pinfo->{$pname}{'occurrence'} !~ /n$/) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Multiple occurences of a unique parameter "%s" in %s',
                $pname, $config_file);
        }

        ## Line or Paragraph
        if (ref $pinfo->{$pname}{'file_format'} eq 'HASH') {
            ## This should be a paragraph
            unless ($#paragraph > 0) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'Expecting a paragraph for "%s" parameter in %s, ignore it',
                    $pname,
                    $config_file
                );
                next;
            }

            ## Skipping first line
            shift @paragraph;

            my %hash;
            for my $i (0 .. $#paragraph) {
                next if ($paragraph[$i] =~ /^\s*\#/);

                unless ($paragraph[$i] =~ /^\s*(\w+)\s*/) {
                    $main::logger->do_log(Sympa::Logger::ERR, 'Bad line "%s" in %s',
                        $paragraph[$i], $config_file);
                }

                my $key = $1;

                unless (defined $pinfo->{$pname}{'file_format'}{$key}) {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        'Unknown key "%s" in paragraph "%s" in %s',
                        $key, $pname, $config_file);
                    next;
                }

                unless ($paragraph[$i] =~
                    /^\s*$key\s+($pinfo->{$pname}{'file_format'}{$key}{'file_format'})\s*$/i
                    ) {
                    chomp($paragraph[$i]);
                    $main::logger->do_log(
                        Sympa::Logger::ERR,
                        'Bad entry "%s" for key "%s", paragraph "%s" in file "%s"',
                        $paragraph[$i],
                        $key,
                        $pname,
                        $config_file
                    );
                    next;
                }

                $hash{$key} =
                    _load_list_param($robot, $key, $1,
                    $pinfo->{$pname}{'file_format'}{$key}, $directory);
            }

            ## Apply defaults & Check required keys
            my $missing_required_field;
            foreach my $k (keys %{$pinfo->{$pname}{'file_format'}}) {
                ## Default value
##		if (!defined $hash{$k} and
##		    defined $pinfo->{$pname}{'file_format'}{$k}{'default'}) {
##		    $hash{$k} = _load_list_param($robot, $k, 'default',
##			$pinfo->{$pname}{'file_format'}{$k}, $directory);
##		}

                ## Required fields
                if ($pinfo->{$pname}{'file_format'}{$k}{'occurrence'} eq '1')
                {
                    unless (defined $hash{$k}) {
                        $main::logger->do_log(Sympa::Logger::INFO,
                            'Missing key "%s" in param "%s" in %s',
                            $k, $pname, $config_file);
                        $missing_required_field++;
                    }
                }
            }

            next if $missing_required_field;

##	    delete $admin{'defaults'}{$pname};

            ## Should we store it in an array
            if ($pinfo->{$pname}{'occurrence'} =~ /n$/) {
                push @{$admin{$pname}}, \%hash;
            } else {
                $admin{$pname} = \%hash;
            }
        } else {
            ## This should be a single line
            unless ($#paragraph == 0) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    'Expecting a single line for "%s" parameter in %s',
                    $pname, $config_file);
            }

            unless ($paragraph[0] =~
                /^\s*$pname\s+($pinfo->{$pname}{'file_format'})\s*$/i) {
                chomp($paragraph[0]);
                $main::logger->do_log(Sympa::Logger::INFO, 'Bad entry "%s" in %s',
                    $paragraph[0], $config_file);
                next;
            }

            my $value =
                _load_list_param($robot, $pname, $1, $pinfo->{$pname},
                $directory);

##	    delete $admin{'defaults'}{$pname};

            if ($pinfo->{$pname}{'occurrence'} =~ /n$/
                and ref $value ne 'ARRAY') {
                push @{$admin{$pname}}, $value;
            } else {
                $admin{$pname} = $value;
            }
        }
    }

    ## Release the lock
    unless ($lock_fh->close) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Could not remove the read lock on file %s',
            $config_file);
        return undef;
    }

    ## Apply defaults & check required parameters
    foreach my $p (keys %$pinfo) {
        ## Defaults

##	unless (defined $admin{$p}) {
##	    ## Simple (versus structured) parameter case
##	    if (defined $pinfo->{$p}{'default'}) {
####		$admin{$p} = _load_list_param($robot, $p,
####		    $pinfo->{$p}{'default'}, $pinfo->{$p}, $directory);
##
##	    ## Sructured parameters case : the default values are defined at
##	    ## the next level
##	    } elsif (ref($pinfo->{$p}{'format'}) eq 'HASH' and
##		$pinfo->{$p}{'occurrence'} =~ /1$/) {
##		## If the paragraph is not defined, try to apply defaults
##		my $hash;
##
##		foreach my $key (keys %{$pinfo->{$p}{'format'}}) {
##		    ## Skip keys without default value.
##		    unless (defined $pinfo->{$p}{'format'}{$key}{'default'}) {
##			next;
##		    }
##
####		    $hash->{$key} = _load_list_param($robot, $key,
####			$pinfo->{$p}{'format'}{$key}{'default'},
####			$pinfo->{$p}{'format'}{$key}, $directory);
##		}
##
##		$admin{$p} = $hash if defined $hash;
##	    }
##
##	    #	    $admin{'defaults'}{$p} = 1;
##	}

        ## Required fields
        if ($pinfo->{$p}{'occurrence'} =~ /^1(-n)?$/) {
            unless (defined $admin{$p}) {
                $main::logger->do_log(Sympa::Logger::INFO,
                    'Missing parameter "%s" in %s',
                    $p, $config_file);
            }
        }
    }

    ## "Original" parameters
    if (defined($admin{'digest'})) {
        if ($admin{'digest'} =~ /^(.+)\s+(\d+):(\d+)$/) {
            my $digest = {};
            $digest->{'hour'}   = $2;
            $digest->{'minute'} = $3;
            my $days = $1;
            $days =~ s/\s//g;
            @{$digest->{'days'}} = split /,/, $days;

            $admin{'digest'} = $digest;
        }
    }

    # The 'host' parameter is ignored if the list is stored on a
    #  virtual robot directory

    # $admin{'host'} = $self{'domain'} if ($self{'dir'} ne '.');

    if (defined($admin{'custom_subject'})) {
        if ($admin{'custom_subject'} =~ /^\s*\[\s*(\w+)\s*\]\s*$/) {
            $admin{'custom_subject'} = $1;
        }
    }

    ## Format changed for reply_to parameter
    ## New reply_to_header parameter
    if ($admin{'forced_reply_to'} or $admin{'reply_to'}) {
        my ($value, $apply, $other_email);
        $value = $admin{'forced_reply_to'} || $admin{'reply_to'};
        $apply = 'forced' if $admin{'forced_reply_to'};
        if ($value =~ /\@/) {
            $other_email = $value;
            $value       = 'other_email';
        }

        $admin{'reply_to_header'} = {
            'value'       => $value,
            'other_email' => $other_email,
            'apply'       => $apply
        };

        ## delete old entries
        delete $admin{'reply_to'};
        delete $admin{'forced_reply_to'};
    }

    # lang
    # canonicalize language
    unless ($admin{'lang'} = Sympa::Language::canonic_lang($admin{'lang'})) {
	$admin{'lang'} = Conf::get_robot_conf($robot, 'lang');
    }

    ############################################
    ## Below are constraints between parameters
    ############################################

    ## Do we have a database config/access
    unless ($Sympa::DatabaseManager::use_db) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'Sympa not setup to use DBI or no database access');
        ## We should notify the listmaster here...
        #return undef;
    }

    return \%admin;
}

## Save a config file
sub _save_list_config_file {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my $self  = shift;
    my $email = shift;

    my $robot = $self->robot;
    my $pinfo = $robot->list_params;

    ## New and old config file names
    my $config_file     = $self->dir . '/config';
    my $old_config_file = $config_file . '.' . $self->serial;
    ## Update management info
    $self->serial($self->serial + 1);
    my $time = time;
    $self->update(
        {   'email'      => $email,
            'date_epoch' => $time,
            'date'       => $main::language->gettext_strftime(
                "%d %b %Y at %H:%M:%S", localtime($time)
            ),
        }
    );
    ## Get updated config
    my $config = $self->config;
    open OUT, '>/tmp/list-config';
    print OUT Dumper $config, $pinfo;

    ## Now build textized configuration
    my $config_text = '';
    open(my $fd, '>', \$config_text);

    foreach my $c (@{$config->{'comment'} || []}) {
        $fd->print(sprintf "%s\n", $c);
    }
    $fd->print("\n");

    foreach my $key (sort by_order keys %$pinfo) {
        next if $key eq 'comment';
        next unless exists $config->{$key};

        print OUT "KEY=$key#", $config->{$key}, "#",
            $pinfo->{$key}{split_char}, "#\n";
        if (ref($config->{$key}) eq 'ARRAY'
            and !$pinfo->{$key}{'split_char'}) {
            ## Multiple parameter (owner, custom_header,...)
            foreach my $elt (@{$config->{$key}}) {
                print OUT "    save $key, $elt\n";
                _save_list_param($robot, $key, $elt, $fd);
            }
        } else {
            _save_list_param($robot, $key, $config->{$key}, $fd);
        }
    }
    close OUT;
    close ($fd);

    ## Write to file at last.
    unless (rename $config_file, $old_config_file) {
        $main::logger->do_log(
            Sympa::Logger::NOTICE,     'Cannot rename %s to %s',
            $config_file, $old_config_file
        );
        return undef;
    }
    unless (open CONFIG, ">", $config_file) {
        $main::logger->do_log(Sympa::Logger::INFO, 'Cannot open %s', $config_file);
        return undef;
    }
    print CONFIG $config_text;
    close CONFIG;

    return 1;
}

# Is a reception mode in the parameter reception of the available_user_options
# section?
sub is_available_reception_mode {
    my $self = shift;
    my $mode = lc(shift || '');

    return undef unless $self and $mode;

    my @available_mode = @{$self->available_user_options->{'reception'}};

    foreach my $m (@available_mode) {
        if ($m eq $mode) {
            return $mode;
        }
    }

    return undef;
}

# List the parameter reception of the available_user_options section
# Note: Since Sympa 6.2a.33, this returns an array under array context.
sub available_reception_mode {
    my $self = shift;
    return @{$self->available_user_options->{'reception'}}
        if wantarray;
    return join(' ', @{$self->available_user_options->{'reception'}});
}

##############################################################################
#                       FUNCTIONS FOR MESSAGE TOPICS                         #
##############################################################################
#                                                                            #
#                                                                            #

####################################################
# is_there_msg_topic
####################################################
#  Test if some msg_topic are defined
#
# IN : -$self (+): ref(List)
#
# OUT : 1 - some are defined | 0 - not defined
####################################################
sub is_there_msg_topic {
    my ($self) = shift;

    if (scalar @{$self->msg_topic}) {
        return 1;
    }
    return 0;
}

####################################################
# is_available_msg_topic
####################################################
#  Checks for a topic if it is available in the list
# (look foreach list parameter msg_topic.name)
#
# IN : -$self (+): ref(List)
#      -$topic (+): string
# OUT : -$topic if it is available  | undef
####################################################
sub is_available_msg_topic {
    my ($self, $topic) = @_;

    foreach my $msg_topic (@{$self->msg_topic}) {
        return $topic
            if $msg_topic->{'name'} eq $topic;
    }

    return undef;
}

####################################################
# get_available_msg_topic
####################################################
#  Return an array of available msg topics (msg_topic.name)
#
# IN : -$self (+): ref(List)
#
# OUT : -\@topics : ref(ARRAY)
####################################################
sub get_available_msg_topic {
    my $self = shift;

    my @topics;
    foreach my $msg_topic (@{$self->msg_topic}) {
        if ($msg_topic->{'name'}) {
            push @topics, $msg_topic->{'name'};
        }
    }

    return \@topics;
}

####################################################
# is_msg_topic_tagging_required
####################################################
# Checks for the list parameter msg_topic_tagging
# if it is set to 'required'
#
# IN : -$self (+): ref(List)
#
# OUT : 1 - the msg must must be tagged
#       | 0 - the msg can be no tagged
####################################################
sub is_msg_topic_tagging_required {
    my $self = shift;

    if ($self->msg_topic_tagging =~ /required/) {
        return 1;
    } else {
        return 0;
    }
}

####################################################
# automatic_tag
####################################################
#  Compute the topic(s) of the message and tag it.
#
# IN : -$self (+): ref(List)
#      -$message (+): ref(message object)
#      -$robot (+): *** No longer used
#
# OUT : string of tag(s), can be separated by ',', can be empty
#        | undef
####################################################
sub automatic_tag {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my ($self, $message) = @_;
    my $msg_id = $message->get_msg_id;

    my $topic_list = $self->compute_topic($message);

    if ($topic_list) {
        unless ($self->tag_topic($msg_id, $topic_list, 'auto')) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to tag message %s with topic "%s"',
                $msg_id, $topic_list);
            return undef;
        }
    }

    return $topic_list;
}

####################################################
# compute_topic
####################################################
#  Compute the topic of the message. The topic is got
#  from keywords defined in list_parameter
#  msg_topic.keywords. The keyword is applied on the
#  subject and/or the body of the message according
#  to list parameter msg_topic_keywords_apply_on
#
# IN : -$self (+): ref(List)
#      -$message (+): ref(message object)
#      -$robot (+): *** No longer used.
#
# OUT : string of tag(s), can be separated by ',', can be empty
####################################################
sub compute_topic {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my ($self, $message) = @_;

    my @topic_array;
    my %topic_hash;
    my %keywords;

    ## TAGGING INHERITED BY THREAD
    # getting in-reply-to
    my $reply_to          = $message->get_header('In-Reply-To');
    my $info_msg_reply_to = $self->load_msg_topic($reply_to);

    # is msg reply to already tagged?
    if (ref $info_msg_reply_to eq 'HASH') {
        return $info_msg_reply_to->{'topic'};
    }

    ## TAGGING BY KEYWORDS
    # getting keywords
    foreach my $topic (@{$self->msg_topic}) {
        my $list_keyw = Sympa::Tools::Data::get_array_from_splitted_string(
            $topic->{'keywords'});

        foreach my $keyw (@{$list_keyw}) {
            $keywords{$keyw} = $topic->{'name'};
        }
    }

    # getting string to parse
    # We convert it to UTF-8 for case-ignore match with non-ASCII keywords.
    my $mail_string = '';
    if (index($self->msg_topic_keywords_apply_on, 'subject') >= 0) {
        $mail_string = $message->get_decoded_subject() . "\n";
    }
    unless ($self->msg_topic_keywords_apply_on eq 'subject') {

        # get bodies of any text/* parts, not digging nested subparts.
        my @parts;
        if ($message->as_entity()->parts) {
            @parts = $message->as_entity()->parts;
        } else {
            @parts = ($message->as_entity());
        }
        foreach my $part (@parts) {
            next unless $part->effective_type =~ /^text\//i;
            my $charset = $part->head->mime_attr("Content-Type.Charset");
            $charset = MIME::Charset->new($charset);
            $charset->encoder('UTF-8');

            if (defined $part->bodyhandle) {
                my $body = $part->bodyhandle->as_string();
                my $converted;
                eval { $converted = $charset->encode($body); };
                if ($EVAL_ERROR) {
                    $converted = $body;
                    $converted =~ s/[^\x01-\x7F]/?/g;
                }
                $mail_string .= $converted . "\n";
            }
        }
    }

    # foldcase string
    $mail_string = Sympa::Tools::Text::foldcase($mail_string);

    # parsing
    foreach my $keyw (keys %keywords) {
        if (index($mail_string, Sympa::Tools::Text::foldcase($keyw)) >= 0) {
            $topic_hash{$keywords{$keyw}} = 1;
        }
    }

    # for no double
    foreach my $k (keys %topic_hash) {
        push @topic_array, $k if $topic_hash{$k};
    }

    if ($#topic_array < 0) {
        return '';

    } else {
        return (join(',', @topic_array));
    }
}

####################################################
# tag_topic
####################################################
#  tag the message by creating the msg topic file
#
# IN : -$self (+): ref(List)
#      -$msg_id (+): string, msg_id of the msg to tag
#      -$topic_list (+): string (splitted by ',')
#      -$method (+) : 'auto'|'editor'|'sender'
#         the method used for tagging
#
# OUT : string - msg topic messagekey
#       | undef
####################################################
sub tag_topic {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s, %s)', @_);
    my ($self, $msg_id, $topic_list, $method) = @_;

    my $topic_item = sprintf "TOPIC   %s\n", $topic_list;
    $topic_item .= sprintf "METHOD  %s\n", $method;
    my $topicspool = Sympa::Spool::File::Message->new(
        name      => 'topic',
        directory => Sympa::Site->queuetopic()
    );

    return (
        $topicspool->store(
            $topic_item,
            {   'list'      => $self->name,
                'robot'     => $self->domain,
                'messageid' => $msg_id
            }
        )
    );
}

####################################################
# load_msg_topic
####################################################
#  Looks for a msg topic using the msg_id of
# the message, loads it and return contained information
# in a HASH
#
# IN : -$self (+): ref(List)
#      -$msg_id (+): the message ID
#      -$robot (+): the robot  ** No longer used
#
# OUT : ref(HASH) file contents :
#         - topic : string - list of topic name(s)
#         - method : editor|sender|auto - method used to tag
#         - msg_id : the msg_id
#         - filename : name of the file containing this information
#     | undef
####################################################
sub load_msg_topic {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my ($self, $msg_id, $robot) = @_;

    my $topicspool = Sympa::Spool::File::Message->new(
        name      => 'topic',
        directory => Sympa::Site->queuetopic()
    );

    my $topics_from_spool = $topicspool->get_first_raw_entry(
        {   'list'      => $self->name,
            'robot'     => $self->domain,
            'messageid' => $msg_id
        }
    );
    unless ($topics_from_spool) {
        $main::logger->do_log(
            Sympa::Logger::DEBUG,
            'No topic defined ; unable to find topic for message %s / list  %s',
            $msg_id,
            $self
        );
        return undef;
    }

    my %info = ();

    my @topics = split(/\n/, $topics_from_spool->{'messageasstring'});
    foreach my $topic (@topics) {
        next if ($topic =~ /^\s*(\#.*|\s*)$/);

        if ($topic =~ /^(\S+)\s+(.+)$/io) {
            my ($keyword, $value) = ($1, $2);
            $value =~ s/\s*$//;

            if ($keyword eq 'TOPIC') {
                $info{'topic'} = $value;

            } elsif ($keyword eq 'METHOD') {
                if ($value =~ /^(editor|sender|auto)$/) {
                    $info{'method'} = $value;
                } else {
                    $main::logger->do_log(Sympa::Logger::ERR,
                        'syntax error in record %s : %s',
                        $self, $msg_id);
                    return undef;
                }
            }
        }
    }

    if ((exists $info{'topic'}) && (exists $info{'method'})) {
        $info{'msg_id'}     = $msg_id;
        $info{'messagekey'} = $topics_from_spool->{'messagekey'};
        return \%info;
    }
    return undef;
}

####################################################
# modifying_msg_topic_for_list_members()
####################################################
#  Deletes topics subscriber that does not exist anymore
#  and send a notify to concerned subscribers.
#
# IN : -$self (+): ref(List)
#      -$new_msg_topic (+): ref(ARRAY) - new state
#        of msg_topic parameters
#
# OUT : -0 if no subscriber topics have been deleted
#       -1 if some subscribers topics have been deleted
#####################################################
sub modifying_msg_topic_for_list_members() {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s)', @_);
    my ($self, $new_msg_topic) = @_;
    my $deleted = 0;

    my @old_msg_topic_name;
    foreach my $msg_topic (@{$self->msg_topic}) {
        push @old_msg_topic_name, $msg_topic->{'name'};
    }

    my @new_msg_topic_name;
    foreach my $msg_topic (@{$new_msg_topic}) {
        push @new_msg_topic_name, $msg_topic->{'name'};
    }

    my $msg_topic_changes = Sympa::Tools::Data::diff_on_arrays(\@old_msg_topic_name,
        \@new_msg_topic_name);

    if ($#{$msg_topic_changes->{'deleted'}} >= 0) {

        for (
            my $subscriber = $self->get_first_list_member();
            $subscriber;
            $subscriber = $self->get_next_list_member()
            ) {

            if ($subscriber->{'reception'} eq 'mail') {
                my $topics = Sympa::Tools::Data::diff_on_arrays(
                    $msg_topic_changes->{'deleted'},
                    Sympa::Tools::Data::get_array_from_splitted_string(
                        $subscriber->{'topics'}
                    )
                );

                if ($#{$topics->{'intersection'}} >= 0) {
                    my $wwsympa_url = $self->robot->wwsympa_url;
                    unless (
                        $self->send_notify_to_user(
                            'deleted_msg_topics',
                            $subscriber->{'email'},
                            {   'del_topics' => $topics->{'intersection'},
                                'url'        => $wwsympa_url
                                    . '/suboptions/'
                                    . $self->name
                            }
                        )
                        ) {
                        $main::logger->do_log(
                            Sympa::Logger::ERR,
                            '(%s) : impossible to send notify to user about "deleted_msg_topics"',
                            $self
                        );
                    }
                    unless (
                        $self->update_list_member(
                            lc($subscriber->{'email'}),
                            {   'update_date' => time,
                                'topics' => join(',', @{$topics->{'added'}})
                            }
                        )
                        ) {
                        $main::logger->do_log(Sympa::Logger::ERR,
                            '(%s) : impossible to update user "%s"',
                            $self, $subscriber->{'email'});
                    }
                    $deleted = 1;
                }
            }
        }
    }
    return 1 if ($deleted);
    return 0;
}

####################################################
# select_list_members_for_topic
####################################################
# Select users subscribed to a topic that is in
# the topic list incoming when reception mode is 'mail', 'notice', 'not_me',
# 'txt', 'html' or 'urlize', and the other
# subscribers (recpetion mode different from 'mail'), 'mail' and no topic
# subscription
#
# IN : -$self(+) : ref(List)
#      -$string_topic(+) : string splitted by ','
#                          topic list
#      -$subscribers(+) : ref(ARRAY) - list of subscribers(emails)
#
# OUT : @selected_users
#
#
####################################################
sub select_list_members_for_topic {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, ...)', @_);
    my ($self, $string_topic, $subscribers) = @_;

    my @selected_users;
    my $msg_topics;

    if ($string_topic) {
        $msg_topics =
            Sympa::Tools::Data::get_array_from_splitted_string($string_topic);
    }

    foreach my $user (@$subscribers) {

        # user topic
        my $info_user = $self->get_list_member($user);

        if ($info_user->{'reception'} !~
            /^(mail|notice|not_me|txt|html|urlize)$/i) {
            push @selected_users, $user;
            next;
        }
        unless ($info_user->{'topics'}) {
            push @selected_users, $user;
            next;
        }
        my $user_topics = Sympa::Tools::Data::get_array_from_splitted_string(
            $info_user->{'topics'});

        if ($string_topic) {
            my $result =
                Sympa::Tools::Data::diff_on_arrays($msg_topics, $user_topics);
            if ($#{$result->{'intersection'}} >= 0) {
                push @selected_users, $user;
            }
        } else {
            my $result =
                Sympa::Tools::Data::diff_on_arrays(['other'], $user_topics);
            if ($#{$result->{'intersection'}} >= 0) {
                push @selected_users, $user;
            }
        }
    }
    return @selected_users;
}

#
#
#
### END - functions for message topics ###

sub store_subscription_request {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, %s)', @_);
    my ($self, $email, $gecos, $custom_attr) = @_;

    my $subscription_request_spool = Sympa::Spool::File::Subscribe->new(
        name      => 'subscribe',
        directory => Sympa::Site->subscribequeue()
    );

    return 'already_subscribed'
        if (
        $subscription_request_spool->sub_request_exists(
            {   'list'   => $self->name,
                'robot'  => $self->domain,
                'sender' => $email
            },
        )
        );
    $main::logger->do_log(Sympa::Logger::DEBUG,
        'No sub request found for (%s, %s, %s, %s)', @_);
    my $subrequest = sprintf "%s\t%s\n%s\n", $email, $gecos, $custom_attr;
    $subscription_request_spool->store(
        $subrequest,
        {   'list'   => $self->name,
            'robot'  => $self->domain,
            'sender' => $email
        }
    );
    $main::logger->do_log(Sympa::Logger::DEBUG,
        'Sub request stored for (%s, %s, %s, %s)', @_);
    return 1;
}

sub get_subscription_requests {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    my %subscriptions;

    my $subscription_request_spool = Sympa::Spool::File::Subscribe->new(
        name      => 'subscribe',
        directory => Sympa::Site->subscribequeue()
    );
    my @subrequests = $subscription_request_spool->get_raw_entries(
        selector  => {'list' => $self->name, 'robot' => $self->domain},
        selection => '*'
    );

    foreach my $subrequest (@subrequests) {

        my $email            = $subrequest->{'sender'};
        my $gecos            = $subrequest->{'gecos'};
        my $customattributes = $subrequest->{'customattributes'};
        my $user_entry       = $self->get_list_member($email, probe => 1);

        if (defined($user_entry) && ($user_entry->{'subscribed'} == 1)) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'User %s is subscribed to %s already. Deleting subscription request.',
                $email,
                $self
            );
            unless (
                $subscription_request_spool->remove(
                    $subrequest->{'messagekey'}
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'Could not delete subrequest %s for list %s from %s',
                    $subrequest->{'messagekey'},
                    $self,
                    $subrequest->{'sender'}
                );
            }
            next;
        }
        ## Following lines may contain custom attributes in an XML format
        my $xml = parseCustomAttribute($customattributes);

        $subscriptions{$email} = {
            'gecos'            => $gecos,
            'custom_attribute' => $xml
        };
        unless ($subscriptions{$email}{'gecos'}) {
            my $user = Sympa::User->new(
                email  => $email,
                fields => Sympa::Site->db_additional_user_fields
            );
            if ($user->gecos) {
                $subscriptions{$email}{'gecos'} = $user->gecos;
            }
        }
        $subscriptions{$email}{'date'} = $subrequest->{'date'};
    }

    return \%subscriptions;
}

sub get_subscription_request_count {
    my ($self) = shift;

    my $subscription_request_spool = Sympa::Spool::File::Subscribe->new(
        name      => 'subscribe',
        directory => Sympa::Site->subscribequeue()
    );
    return $subscription_request_spool->get_raw_entries(
        selector  => {'list' => $self->name, 'robot' => $self->domain},
        selection => 'count'
    );
}

sub delete_subscription_request {
    my ($self, @list_of_email) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2,
        'Sympa::List::delete_subscription_request(%s, %s)',
        $self->name, join(',', @list_of_email));

    my $subscription_request_spool = Sympa::Spool::File::Subscribe->new(
        name => 'subscribe', directory => Sympa::Site->subscribequeue()
    );

    my $removed = 0;
    foreach my $email (@list_of_email) {
        $main::logger->do_log(Sympa::Logger::DEBUG2, 'Deleting sub request for %s',
            $email);
        if (my $key = $subscription_request_spool->get_file_key(
                {   'list'   => $self->name,
                    'robot'  => $self->domain,
                    'sender' => $email
                }
            )
            ) {
            $removed++
                if $subscription_request_spool->remove($key);
        } else {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Unable to get subscription key for %s', $email);
        }
    }

    unless ($removed > 0) {
        $main::logger->do_log(
            Sympa::Logger::DEBUG2,
            'No pending subscription was found for users %s',
            join(',', @list_of_email)
        );
        return undef;
    }
    return 1;
}

sub store_signoff_request {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my ($self, $email) = @_;

    my $signoff_request_spool = Sympa::Spool::File::Subscribe->new(
        name       => 'signoff',
        directory => Sympa::Site->queuesignoff(),
    );

    if ($signoff_request_spool->get_raw_entries(
        selector => {
            'list'   => $self->name,
            'robot'  => $self->domain,
            'sender' => $email
            },
        selection => 'count'
        ) != 0
        ) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Signoff already requested by %s', $email);
        return undef;
    } else {

        #my $subrequest = sprintf "%s||%s\n", $gecos, $custom_attr;
        $signoff_request_spool->store(
            '',
            {   'list'   => $self->name,
                'robot'  => $self->domain,
                'sender' => $email
            }
        );
    }
    return 1;
}

sub get_signoff_requests {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    my %signoffs;

    my $signoff_request_spool = Sympa::Spool::File::Subscribe->new(
        name      => 'signoff',
        directory => Sympa::Site->queuesignoff(), 
    );
    my @sigrequests           = $signoff_request_spool->get_raw_entries(
        selector  => {'list' => $self->name, 'robot' => $self->domain},
        selection => '*'
    );

    foreach my $sigrequest (@sigrequests) {
        my $email = $sigrequest->{'sender'};
        my $user_entry = $self->get_list_member($email, probe => 1);

        unless (defined $user_entry and $user_entry->{'subscribed'} == 1) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'User %s is unsubscribed from %s already. Deleting signoff request.',
                $email,
                $self
            );
            unless (
                $signoff_request_spool->remove(
                    {'list' => $self, 'sender' => $email, 'just_try' => 1}
                )
                ) {
                $main::logger->do_log(
                    Sympa::Logger::ERR,
                    'Could not delete sigrequest %s for list %s from %s',
                    $sigrequest->{'messagekey'},
                    $self,
                    $sigrequest->{'sender'}
                );
            }
            next;
        }

        $signoffs{$email} = {};
        my $user = Sympa::User->new(
            email  => $email,
            fields => Sympa::Site->db_additional_user_fields
        );
        if ($user->gecos) {
            $signoffs{$email}{'gecos'} = $user->gecos;
        }

        #}
        $signoffs{$email}{'date'} = $sigrequest->{'date'};
    }

    return \%signoffs;
}

sub get_signoff_request_count {
    my $self = shift;

    my $signoff_request_spool = Sympa::Spool::File::Subscribe->new(
        name      => 'signoff',
        directory => Sympa::Site->queuesignoff(), 
    );
    return $signoff_request_spool->get_raw_entries(
        selector  => {'list' => $self->name, 'robot' => $self->domain},
        selection => 'count'
    );
}

sub delete_signoff_request {
    my ($self, @list_of_email) = @_;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', $self,
        join(',', @list_of_email));

    my $signoff_request_spool = Sympa::Spool::File::Subscribe->new(
        name   => 'signoff',
        directory => Sympa::Site->queuesignoff(), 
    );

    my $removed = 0;
    foreach my $email (@list_of_email) {
        $removed++
            if $signoff_request_spool->remove(
            {'list' => $self, 'sender' => $email, 'just_try' => 1});
    }

    unless ($removed > 0) {
        $main::logger->do_log(
            Sympa::Logger::DEBUG2,
            'No pending signoff was found for users %s',
            join(',', @list_of_email)
        );
        return undef;
    }
    return 1;
}

sub get_shared_size {
    my $self = shift;

    return Sympa::Tools::File::get_dir_size($self->dir . '/shared');
}

sub get_arc_size {
    my $self = shift;
    my $dir  = shift;

    return Sympa::Tools::File::get_dir_size($dir . '/' . $self->get_id());
}

# return the date epoch for next delivery planified for a list
sub get_next_delivery_date {
    my $self = shift;

    my $dtime = $self->delivery_time;
    unless (defined $dtime and $dtime =~ /(\d?\d)\:(\d\d)/) {

        # if delivery _time is not defined, the delivery time right now
        return time();
    }
    my $h = $1;
    my $m = $2;
    unless ((($h == 24) && ($m == 0)) || (($h <= 23) && ($m <= 60))) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "ignoring wrong parameter format delivery_time, delivery_tile must be smaller than 24:00"
        );
        return time();
    }
    my $date = time();

    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) =
        localtime($date);

    my $plannified_time = (($h * 60) + $m) * 60;    # plannified time in sec
    my $now_time =
        ((($hour * 60) + $min) * 60) + $sec;    # Now #sec since to day 00:00

    my $result = $date - $now_time + $plannified_time;
    ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) =
        localtime($result);

    if ($now_time <= $plannified_time) {
        return ($date - $now_time + $plannified_time);
    } else {

        # plannified time is past so report to tomorrow
        return ($date - $now_time + $plannified_time + (24 * 3600));
    }
}

## Searches the include datasource corresponding to the provided ID
sub search_datasource {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my ($self, $id) = @_;
    my $pinfo = $self->robot->list_params;

    ## Go through list parameters
    foreach my $p (keys %$pinfo) {
        next unless ($p =~ /^include/);
        if (defined($self->$p)) {
            ## Go through sources
            foreach my $s (@{$self->$p}) {
                if (Sympa::Datasource::_get_datasource_id($s) eq $id) {
                    return {'type' => $p, 'def' => $s};
                }
            }
        }
    }

    return undef;
}

## Return the names of datasources, given a coma-separated list of source ids
# IN : -$class
#      -$id : datasource ids (coma-separated)
# OUT : -$name : datasources names (scalar)
sub get_datasource_name {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my ($self, $id) = @_;
    my %sources;

    my @ids = split /,/, $id;
    foreach my $id (@ids) {
        ## User may come twice from the same datasource
        unless (defined($sources{$id})) {
            my $datasource = $self->search_datasource($id);
            if (defined $datasource) {
                if (ref($datasource->{'def'})) {
                    $sources{$id} = $datasource->{'def'}{'name'}
                        || $datasource->{'def'}{'host'};
                } else {
                    $sources{$id} = $datasource->{'def'};
                }
            }
        }
    }

    return join(', ', values %sources);
}

## Remove a task in the tasks spool
sub remove_task {
    my $self = shift;
    my $task = shift;

    unless (opendir(DIR, Sympa::Site->queuetask)) {
        $main::logger->do_log(Sympa::Logger::ERR, "error : can't open dir %s: %s",
            Sympa::Site->queuetask, $ERRNO);
        return undef;
    }
    my @tasks = grep !/^\.\.?$/, readdir DIR;
    closedir DIR;

    my $list_id = $self->get_id;
    foreach my $task_file (@tasks) {
        if ($task_file =~ /^(\d+)\.\w*\.$task\.$list_id$/) {
            unless (unlink(Sympa::Site->queuetask . "/$task_file")) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'Unable to remove task file %s : %s',
                    $task_file, $ERRNO);
                return undef;
            }
            $main::logger->do_log(Sympa::Logger::NOTICE, 'Removing task file %s',
                $task_file);
        }
    }

    return 1;
}

## Close the list (remove from DB, remove aliases, change status to 'closed'
## or 'family_closed')
sub close_list {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my ($self, $email, $status) = @_;

    return undef unless $self->robot->lists($self->name);

    ## If list is included by another list, then it cannot be removed
    ## TODO : we should also check owner_include and editor_include, but a bit
    ## more tricky
    my $all_lists = get_lists();
    foreach my $list (@{$all_lists}) {
        my $included_lists = $list->include_list;
        next unless @{$included_lists};

        foreach my $included_list_name (@{$included_lists}) {
            if ($included_list_name eq $self->get_id()
                or (    $included_list_name eq $self->name
                    and $list->domain eq $self->domain)
                ) {
                $main::logger->do_log(Sympa::Logger::ERR,
                    'List %s is included by list %s : cannot close it',
                    $self, $list);
                return undef;
            }
        }
    }

    ## Dump subscribers, unless list is already closed
    unless ($self->status eq 'closed') {
        $self->_save_list_members_file(
            $self->dir . '/subscribers.closed.dump');
    }

    ## Delete users
    my @users;
    for (
        my $user = $self->get_first_list_member();
        $user;
        $user = $self->get_next_list_member()
        ) {
        push @users, $user->{'email'};
    }
    $self->delete_list_member('users' => \@users);

    ## Remove entries from admin_table
    foreach my $role ('owner', 'editor') {
        my @admin_users;
        for (
            my $user = $self->get_first_list_admin($role);
            $user;
            $user = $self->get_next_list_admin()
            ) {
            push @admin_users, $user->{'email'};
        }
        $self->delete_list_admin($role, @admin_users);
    }

    ## Change status & save config
    $self->status('closed');

    if (defined $status) {
        foreach my $s ('family_closed', 'closed') {
            if ($status eq $s) {
                $self->status($status);
                last;
            }
        }
    }

    $self->defaults('status', 0);

    $self->save_config($email);
    $self->savestats();

    $self->remove_aliases();

    #log in stat_table to make staistics
    Sympa::Monitor::db_stat_log(
        'robot'     => $self->domain,
        'list'      => $self->name,
        'operation' => 'close_list',
        'mail'      => $email,
        'daemon'    => 'damon_name'
    );    #FIXME: unknown daemon

    return 1;
}

## Remove the list
sub purge {
    my ($self, $email) = @_;

    return undef unless $self->robot->lists($self->name);

    ## Remove tasks for this list
    my $taskspool = Sympa::Spool::File::Task->new(
        name => 'task', directory => Sympa::Site->queuetask()
    );
    foreach my $task (
        $taskspool->get_raw_entries(
            selector  => {'list' => $self->name, 'robot' => $self->domain},
            selection => '*',
        )
        ) {

        unlink $task->{'filepath'};
    }

    ## Close the list first, just in case...
    $self->close_list();

    if ($self->name) {
        my $arc_dir = $self->robot->arc_path;
        Sympa::Tools::File::remove_dir($arc_dir . '/' . $self->get_id);
        Sympa::Tools::File::remove_dir($self->get_bounce_dir());
    }

    ## Clean list table if needed
    if ($self->robot->cache_list_config eq 'database') {
        unless (defined $self->list_cache_purge) {
            do_log(Sympa::Logger::ERR, 'Cannot remove list %s from table', $self);
        }
    }

    ## Clean memory cache
    $self->robot->lists($self->name, undef);

    Sympa::Tools::File::remove_dir($self->dir);

    #log ind stat table to make statistics
    Sympa::Monitor::db_stat_log(
        'robot'     => $self->domain,
        'list'      => $self->name,
        'operation' => 'purge list',
        'mail'      => $email,
        'daemon'    => 'daemon_name'
    );

    return 1;
}

## Remove list aliases
sub remove_aliases {
    my $self = shift;

    return undef if lc(Sympa::Site->sendmail_aliases) eq 'none';

    my $alias_manager = Sympa::Site->alias_manager;
    unless (-x $alias_manager) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Cannot run alias_manager %s',
            $alias_manager);
        return undef;
    }

    system(sprintf '%s del %s %s', $alias_manager, $self->name, $self->host);
    my $status = $CHILD_ERROR >> 8;
    unless ($status == 0) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Failed to remove aliases ; status %d : %s',
            $status, $ERRNO);
        return undef;
    }

    $main::logger->do_log(Sympa::Logger::INFO,
        'Aliases for list %s removed successfully', $self);

    return 1;
}

##
## bounce management actions
##

# Get max bouncers level
sub get_max_bouncers_level {
    my $self  = shift;
    my $pinfo = $self->robot->list_params;

    my $max_level;
    for (my $level = 1; $pinfo->{'bouncers_level' . $level}; $level++) {
        my $bouncers_level_parameter = 'bouncers_level' . $level;
        last unless %{$self->$bouncers_level_parameter};
        $max_level = $level;
    }

    return $max_level;
}

# Sub for removing user
#
sub remove_bouncers {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self   = shift;
    my $reftab = shift;

    ## Log removal
    foreach my $bouncer (@{$reftab}) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Removing bouncing subsrciber of list %s : %s',
            $self, $bouncer);
    }

    unless ($self->delete_list_member('users' => $reftab, 'exclude' => ' 1'))
    {
        $main::logger->do_log(Sympa::Logger::INFO,
            'error while calling sub delete_users');
        return undef;
    }
    return 1;
}

#Sub for notifying users : "Be careful,You're bouncing"
#
sub notify_bouncers {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $self   = shift;
    my $reftab = shift;

    foreach my $user (@$reftab) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'Notifying bouncing subsrciber of list %s : %s',
            $self, $user);
        unless ($self->send_notify_to_user('auto_notify_bouncers', $user, {}))
        {
            $main::logger->do_log(Sympa::Logger::NOTICE,
                'Unable to send notify "auto_notify_bouncers" to %s', $user);
        }
    }
    return 1;
}

## Create the document repository
sub create_shared {
    my $self = shift;

    my $dir = $self->dir . '/shared';

    if (-e $dir) {
        $main::logger->do_log(Sympa::Logger::ERR, '%s already exists', $dir);
        return undef;
    }

    unless (mkdir($dir, 0777)) {
        $main::logger->do_log(Sympa::Logger::ERR, 'unable to create %s : %s',
            $dir, $ERRNO);
        return undef;
    }

    return 1;
}

## check if a list  has include-type data sources
sub has_include_data_sources {
    my $self = shift;

    foreach my $type (@sources_providing_listmembers, @more_data_sources) {
        my $resource = $self->$type || [];
        return 1 if ref $resource eq 'ARRAY' && @$resource;
    }

    return 0;
}

# move a message to a queue or distribute spool
sub move_message {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s)', @_);
    my ($self, $file, $queue) = @_;

    my $dir = $queue || Sympa::Site->queuedistribute;
    my $filename = $self->get_id() . '.' . time . '.' . int(rand(999));

    unless (open OUT, ">$dir/T.$filename") {
        $main::logger->do_log(Sympa::Logger::ERR, 'Cannot create file %s',
            "$dir/T.$filename");
        return undef;
    }

    unless (open IN, $file) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Cannot open file %s', $file);
        return undef;
    }

    print OUT <IN>;
    close IN;
    close OUT;
    unless (rename "$dir/T.$filename", "$dir/$filename") {
        $main::logger->do_log(
            Sympa::Logger::ERR,              'Cannot rename file %s into %s',
            "$dir/T.$filename", "$dir/$filename"
        );
        return undef;
    }
    return 1;
}

## Return the path to the list bounce directory, where bounces are stored
sub get_bounce_dir {
    my $self = shift;

    my $root_dir = $self->robot->bounce_path;

    return $root_dir . '/' . $self->get_id;
}

=over 4

=item get_address ( [ TYPE ] )

Returns the list email address of type TYPE: posting address (default),
"owner", "editor" or (non-VERP) "return_path".

=cut
 
sub get_address {
    my ($self, $type) = @_;

    unless ($type) {
        return $self->name . '@' . $self->host;
    } elsif ($type eq 'owner') {
        return $self->name . '-request' . '@' . $self->host;
    } elsif ($type eq 'editor') {
        return $self->name . '-editor' . '@' . $self->host;
    } elsif ($type eq 'return_path') {
        return
              $self->name
            . $self->robot->return_path_suffix . '@'
            . $self->host;
    } elsif ($type eq 'subscribe') {
        return $self->name . '-subscribe' . '@' . $self->host;
    } elsif ($type eq 'unsubscribe') {
        return $self->name . '-unsubscribe' . '@' . $self->host;
    }

    $main::logger->do_log(Sympa::Logger::ERR,
        'Unknown type of address "%s" for %s.  Ask developer',
        $type, $self);
    return undef;
}

=over 4

=item get_bounce_address ( WHO, [ OPTS, ... ] )

Return the VERP address of the list for the user WHO.

Note that VERP addresses have the name of originating robot, not mail host.

=back

=cut

sub get_bounce_address {
    my $self = shift;
    my $who  = shift;
    my @opts = @_;

    my $escwho = $who;
    $escwho =~ s/\@/==a==/;

    return sprintf('%s+%s@%s',
        Sympa::Site->bounce_email_prefix,
        join('==', $escwho, $self->name, @opts),
        $self->domain);
}

=over 4

=item get_id ( )

Return the list ID, different from the list address (uses the robot name)

=back

=cut

sub get_id {
    my $self = shift;

    ## DO NOT use accessors on List object since $self may not have been
    ## fully initialized.

    return '' unless $self->{'name'} and $self->{'robot'};
    return $self->{'name'} . '@' . $self->{'robot'}->domain;
}

=over 4

=item add_list_header ( HEADER_OBJ, FIELD )

FIXME @todo doc

=back

=cut

sub add_list_header {
    my $self  = shift;
    my $hdr   = shift;
    my $field = shift;
    my $robot = $self->domain;

    if ($field eq 'id') {
        $hdr->add('List-Id', sprintf('<%s.%s>', $self->name, $self->host));
    } elsif ($field eq 'help') {
        $hdr->add(
            'List-Help',
            sprintf(
                '<mailto:%s@%s?subject=help>',
                $self->robot->email, $self->robot->host
            )
        );
    } elsif ($field eq 'unsubscribe') {
        $hdr->add(
            'List-Unsubscribe',
            sprintf(
                '<mailto:%s@%s?subject=unsubscribe%%20%s>',
                $self->robot->email, $self->robot->host, $self->name
            )
        );
    } elsif ($field eq 'subscribe') {
        $hdr->add(
            'List-Subscribe',
            sprintf(
                '<mailto:%s@%s?subject=subscribe%%20%s>',
                $self->robot->email, $self->robot->host, $self->name
            )
        );
    } elsif ($field eq 'post') {
        $hdr->add('List-Post',
            sprintf('<mailto:%s>', $self->get_address()));
    } elsif ($field eq 'owner') {
        $hdr->add('List-Owner',
            sprintf('<mailto:%s>', $self->get_address('owner')));
    } elsif ($field eq 'archive') {
        if (    $self->robot->wwsympa_url
            and $self->is_web_archived()) {
            $hdr->add(
                'List-Archive',
                sprintf(
                    '<%s/arc/%s>', $self->robot->wwsympa_url, $self->name
                )
            );
        } else {
            return 0;
        }
    } elsif ($field eq 'archived_at') {
        if (    $self->robot->wwsympa_url
            and $self->is_web_archived()) {
            my @now  = localtime(time);
            my $yyyy = sprintf '%04d', 1900 + $now[5];
            my $mm   = sprintf '%02d', $now[4] + 1;
            my $archived_msg_url =
                sprintf '%s/arcsearch_id/%s/%s-%s/%s',
                $self->robot->wwsympa_url,
                $self->name, $yyyy, $mm,
                Sympa::Tools::clean_msg_id($hdr->get('Message-Id'));
            $hdr->add('Archived-At', '<' . $archived_msg_url . '>');
        } else {
            return 0;
        }
    } else {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unknown field "%s".  Ask developer', $field);
        return undef;
    }

    return 1;
}

##connect to stat_counter_table and extract data.
sub get_data {
    my ($data, $robotname, $listname) = @_;

    unless (
        $sth = Sympa::DatabaseManager::do_prepared_query(
            q{SELECT *
	      FROM stat_counter_table
	      WHERE data_counter = ? AND
		    robot_counter = ? AND list_counter = ?},
            $data, $robotname, $listname
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to get stat data %s for liste %s@%s',
            $data, $listname, $robotname);
        return undef;
    }
    my $res = $sth->fetchall_hashref('beginning_date_counter');
    return $res;
}

################################################

=head1 ACCESSORS

=over 4

=item E<lt>config parameterE<gt>

=item E<lt>config parameterE<gt>C<( VALUE )>

I<Getters/Setters>.
Get or set list config parameter.
For example C<$list-E<gt>subject> returns "subject" parameter of the list,
and C<$list-E<gt>subject("foo")> also changes it.
Basic list profiles "name", "dir", "robot" and so on have only getters,
so they are read-only.

Some accessors have a bit confusing names: $list->host() gets/sets 'host'
list parameter, not its robot name; $list->update() that gets/sets 'update'
list parameter (actually hashref) won't update the list object itself.

B<NOTE>:
If structured parameters (such as topics, web_archive) were not defined,
C<[]> or C<{}> will be returned instead of C<undef>.

=item dir

=item name

=item robot

=item stats

=item as_x509_cert

I<Getters>.
Gets attributes of the list.

=back

=cut

our $AUTOLOAD;

sub DESTROY { }   # "sub DESTROY;" may cause segfault with Perl around 5.10.1.

sub AUTOLOAD {
    $main::logger->do_log(Sympa::Logger::DEBUG3, 'Autoloading %s', $AUTOLOAD);
    $AUTOLOAD =~ m/^(.*)::(.*)/;
    my $attr = $2;

    croak "Can't locate class method \"$2\" via package \"$1\""
        unless ref $_[0];

    my $p;
    if (grep { $_ eq $attr } qw(name robot dir stats as_x509_cert)) {
        ## getter for list attributes.
        no strict "refs";
        *{$AUTOLOAD} = sub {
            croak "Can't modify \"$attr\" attribute" if scalar @_ > 1;
            shift->{$attr};
        };
    } elsif ($p = $_[0]->{'robot'}->list_params->{$attr}) {
        if (    ref $p->{'format'} eq 'HASH'
            and $p->{'occurrence'}
            and $p->{'occurrence'} =~ /n/) {
            ## getter/setter for structured list parameters.
            no strict "refs";
            *{$AUTOLOAD} = sub {
                my $self = shift;

                croak "Can't call method \"$attr\" on uninitialized "
                    . (ref $self)
                    . " object"
                    unless defined $self->{'config'};
                if (scalar @_) {
                    $self->{'config'}{$attr} = shift || [];
                    delete $self->{'admin'}{$attr};
                }

                unless (exists $self->{'admin'}{$attr}) {
                    my $value = $self->{'config'}{$attr} || [];
##		    ## sort by keys
##		    if (ref $value eq 'ARRAY' and $p->{'sort'}) {
##			eval 'use sort "stable"';
##			$value = [sort
##			    { $a->{$p->{'sort'}} cmp $b->{$p->{'sort'}} }
##			    @$value];
##			eval 'use sort "defaults"';
##		    }

                    ## Apply default
                    my $deflist = [];
                    $self->{'config'}{$attr} = [];
                    $self->{'admin'}{$attr}  = [];
                    foreach my $val (@{$value || []}) {
                        next unless defined $val and ref $val eq 'HASH';

                        my $config_hash = {};
                        my $admin_hash  = {};
                        my $defs =
                            $self->_set_list_param_compound($attr, $val,
                            $p->{'format'}, $config_hash, $admin_hash);

                        push @{$self->{'config'}{$attr}}, $config_hash;
                        push @{$self->{'admin'}{$attr}},  $admin_hash;
                        push @$deflist, $defs;
                    }

                    delete $self->{'config'}{$attr}
                        unless @{$self->{'config'}{$attr}};

                    $self->defaults($attr, $deflist);
                }

                # To avoid "Can't use an undefined value as a XXX reference"
                unless (exists $self->{'admin'}{$attr}) {
                    $self->{'admin'}{$attr} = [];
                }
                $self->{'admin'}{$attr};
            };
        } elsif (ref $p->{'format'} eq 'HASH') {
            ## getter/setter for structured list parameters.
            no strict "refs";
            *{$AUTOLOAD} = sub {
                my $self = shift;

                croak "Can't call method \"$attr\" on uninitialized "
                    . (ref $self)
                    . " object"
                    unless defined $self->{'config'};
                if (scalar @_) {
                    $self->{'config'}{$attr} = shift || [];
                    delete $self->{'admin'}{$attr};
                }

                unless (exists $self->{'admin'}{$attr}) {
                    my $value = $self->{'config'}{$attr} || {};
                    ## Apply default
                    $self->{'config'}{$attr} = {};
                    $self->{'admin'}{$attr}  = {};
                    my $defs = $self->_set_list_param_compound(
                        $attr, $value, $p->{'format'},
                        $self->{'config'}{$attr},
                        $self->{'admin'}{$attr}
                    );

                    delete $self->{'config'}{$attr}
                        unless %{$self->{'config'}{$attr}};

                    $self->defaults($attr, $defs);
                }

                # To avoid "Can't use an undefined value as a XXX reference"
                unless (exists $self->{'admin'}{$attr}) {
                    $self->{'admin'}{$attr} = {};
                }
                $self->{'admin'}{$attr};
            };
        } else {
            ## getter/setter for simple list parameters.
            no strict "refs";
            *{$AUTOLOAD} = sub {
                my $self = shift;

                croak "Can't call method \"$attr\" on uninitialized "
                    . (ref $self)
                    . " object"
                    unless defined $self->{'config'};

                if (scalar @_) {
                    $self->{'config'}{$attr} = shift;
                    delete $self->{'admin'}{$attr};
                }

                unless (exists $self->{'admin'}{$attr}) {
                    my $value = $self->{'config'}{$attr};
##		    ## sort by values
##		    if (ref $value eq 'ARRAY' and $p->{'sort'}) {
##			$value = [sort @$value];
##		    }

                    ## Apply default
                    my $def =
                        $self->_set_list_param($attr, $value, $p,
                        $self->{'config'}, $self->{'admin'}, $attr);
                    $self->defaults($attr, $def);
                }

                # To avoid "Can't use an undefined value as a XXX reference"
                unless (exists $self->{'admin'}{$attr}) {
                    if ($p->{'split_char'}
                        or ($p->{'occurrence'} and $p->{'occurrence'} =~ /n/))
                    {
                        $self->{'admin'}{$attr} = [];
                    } else {
                        $self->{'admin'}{$attr} = undef;
                    }
                }
                $self->{'admin'}{$attr};
            };
        }
    } elsif (index($attr, '_') != 0 and defined $_[0]->{$attr}) {
        ## getter for unknwon list attributes.
        ## XXX This code would be removed later.
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Unconcerned object method "%s" via package "%s".  Though it may not be fatal, you might want to report it developer',
            $2,
            $1
        );
        no strict "refs";
        *{$AUTOLOAD} = sub {
            croak "Can't modify \"$attr\" attribute" if scalar @_ > 1;
            shift->{$attr};
        };
        ## XXX The code above would be removed later.
    } else {
        croak "Can't locate object method \"$2\" via package \"$1\"";
    }
    goto &$AUTOLOAD;
}

sub _set_list_param_compound {
    my $self        = shift;
    my $attr        = shift;
    my $val         = shift;
    my $p           = shift;
    my $config_hash = shift;
    my $admin_hash  = shift;

    my $defs = {};
    foreach my $subattr (keys %$p) {
        my $def =
            $self->_set_list_param($attr, $val->{$subattr}, $p->{$subattr},
            $config_hash, $admin_hash, $subattr);
        $defs->{$subattr} = 1
            if $def and defined $admin_hash->{$subattr};
    }

    ## reception of default_user_options must be one of reception of
    ## available_user_options. If none, warning and put reception of
    ## default_user_options in reception of available_user_options
    if ($attr eq 'available_user_options') {
        $self->{'admin'}{$attr}{'reception'} ||= [];
        unless (grep { $_ eq $self->default_user_options->{'reception'} }
            @{$self->{'admin'}{$attr}{'reception'}}) {
            $main::logger->do_log(
                Sympa::Logger::INFO,
                'reception is not compatible between default_user_options and available_user_options of list %s',
                $self
            );
            push @{$self->{'admin'}{$attr}{'reception'}},
                $self->default_user_options->{'reception'};
            delete $defs->{'reception'};
        }
    }

    if (scalar keys %$defs == scalar keys %$admin_hash) {
        ## All components are defaults.
        $defs = 1;
    } elsif (!%$defs) {
        ## No defaults
        undef $defs;
    }

    ## Fill undefined values
    foreach my $subattr (keys %$p) {
        next if exists $admin_hash->{$subattr};
        if (    $p->{$subattr}->{'occurrence'}
            and $p->{$subattr}->{'occurrence'} =~ /n/) {
            $admin_hash->{$subattr} = [];
        } else {
            $admin_hash->{$subattr} = undef;
        }
    }

    return $defs;
}

sub _set_list_param {
    my $self        = shift;
    my $attr        = shift;
    my $val         = shift;
    my $p           = shift;
    my $config_hash = shift;
    my $admin_hash  = shift;
    my $config_attr = shift;

    ## Reload scenario to get real value
    if ($p->{'scenario'}) {
        if (ref $val eq 'Sympa::Scenario') {
            $val = Sympa::Scenario->new(
                that     => $self,
                function => $p->{'scenario'},
                name     => $val->{'name'}
            );
        } elsif (ref $val eq 'HASH') {
            $val = Sympa::Scenario->new(
                that     => $self,
                function => $p->{'scenario'},
                name     => $val->{'name'}
            );
        }
    }
    ## Canonicalize lang.
    if ($config_attr eq 'lang' and $val) {
        $val = $self->robot->best_language($val);
    }

    ## Apply defaults.

    my $default;
    if (exists $p->{'default'}) {
        $default =
            _load_list_param($self->{'robot'}, $attr, $p->{'default'}, $p,
            $self->{'dir'});
        ## Load scenario to get real default
        if ($p->{'scenario'} and ref $default eq 'HASH') {
            $default = Sympa::Scenario->new(
                that     => $self,
                function => $p->{'scenario'},
                name     => $default->{'name'}
            );
        }
    }

    my $def = undef;
    if (defined $val and defined $default and exists $p->{'default'}) {
        if (    $p->{'scenario'}
            and $val->{'name'}
            and $val->{'name'} eq $default->{'name'}) {
            $def = 1;
        } elsif ($p->{'task'}
            and $val->{'name'}
            and $val->{'name'} eq $default->{'name'}) {
            $def = 1;
        } elsif (
            (      $p->{'split_char'}
                or $p->{'occurrence'} and $p->{'occurrence'} =~ /n/
            )
            and join("\0", sort @$val) eq join("\0", sort @$default)
            ) {
            $def = 1;
        } elsif ($val eq $default) {
            $def = 1;
        }
    } elsif (exists $p->{'default'}) {
        $val = $default;
        $def = 1;
    } else {
        $def = 1 unless defined $val;
    }

    ## Cache non-default and completed values into config and admin hashes.

    if (defined $val) {
        if ($def) {
            delete $config_hash->{$config_attr};
        } elsif ($p->{'scenario'}) {
            $config_hash->{$config_attr} = {'name' => $val->{'name'}};
        } else {
            $config_hash->{$config_attr} = $val;
        }
        $admin_hash->{$config_attr} = Sympa::Tools::Data::dup_var($val);
    } else {
        delete $config_hash->{$config_attr};
        delete $admin_hash->{$config_attr};
    }

    return $def;
}

=over 4

=item admin

I<Getter>.
Configuration information of the list, with defaults applied.

B<Note>:
Use L</config> accessor to get information without defaults.

B<Note>:
L<admin> and L<config> accessors will return the copy of configuration
information.  Modification of them will never affect to actual list
parameters.
Use C<E<lt>config parameterE<gt>> accessors to get or set each list parameter.

=back

=cut

sub admin {
    my $self = shift;
    croak 'Can\'t modify "admin" attribute' if scalar @_;

    my $pinfo = $self->robot->list_params;
    ## apply defaults of all parameters.
    foreach my $p (keys %$pinfo) {
        $self->$p;
    }
    ## get copy to prevent breaking cache
    return Sympa::Tools::Data::dup_var($self->{'admin'});
}

=over 4

=item config

I<Getter/Setter>, I<internal use>.
Gets or sets configuration information, eliminating defaults.

B<Note>:
Use L</admin> accessor to get full configuration informaton.

=back

=cut

sub config {
    my $self = shift;

    if (scalar @_) {
        $self->{'config'} = shift;
        $self->{'admin'}  = {};
    }

    my $pinfo = $self->robot->list_params;
    ## remove defaults of all parameters.
    foreach my $p (keys %$pinfo) {
        $self->$p;
    }
    ## Get copy to prevent breaking config
    return Sympa::Tools::Data::dup_var($self->{'config'});
}

=over 4

=item defaults ( PARAMETER, VALUE )

I<Setter>, I<internal use>.
Set flags to determine default values of list parameters.
If undef is specified as VALUE, that defaut flag will be removed.

=back

=cut

sub defaults {
    my $self = shift;
    my $p    = shift;

    $self->{'admin'}{'defaults'} ||= {};

    if (scalar @_) {
        my $v = shift;
        unless (defined $v) {
            delete $self->{'admin'}{'defaults'}{$p};
        } else {
            $self->{'admin'}{'defaults'}{$p} = $v;
        }
    }
    $self->{'admin'}{'defaults'}{$p};
}

=over 4

=item domain

I<Getter>.
Gets domain (robot name) of the list.

B<Note>:
Use L<robot> accessor to get robot object the list belong to.

=back

=cut

sub domain {
    shift->{'robot'}->domain;
}

=over 4

=item family

I<Getter/Setter>.
Gets or sets Sympa::Family object the list is belonging to.
Returns Sympa::Family object or undef.

=back

=cut

sub family {
    my $self = shift;
    if (scalar @_) {
        my $family = shift;
        if ($family) {
            $self->{'family'}                = $family;
            $self->{'admin'}{'family_name'}  = $family->name;
            $self->{'config'}{'family_name'} = $family->name;
        } else {
            delete $self->{'family'};
            delete $self->{'admin'}{'family_name'};
            delete $self->{'config'}{'family_name'};
        }
    }

    if (ref $self->{'family'} eq 'Sympa::Family') {
        return $self->{'family'};
    } elsif ($self->family_name) {
        return $self->{'family'} =
            Sympa::Family->new($self->family_name, $self->{'robot'});
    } else {
        return undef;
    }
}

=over 4

=item family_name

I<Getter>.
Gets name of family the list is belonging to, or C<undef>.

=back

=cut

sub family_name {
    croak "Can't modify \"family_name\" attribute" if scalar @_ > 1;
    shift->{'admin'}{'family_name'};
}

=over 4

=item total ( [ NUMBER ] )

Handles cached number of subscribers on memory.

I<Getter>.
Gets cached value.

I<Setter>.
Updates both memory and database cache.

Use get_real_total() to recalculate actual value and to renew caches with it.

=back

=cut

sub total {
    my $self = shift;
    if (scalar @_) {
        my $total = shift;
        unless (defined $self->{'total'} and $self->{'total'} == $total) {
            $self->{'total'} = $total;
            $self->list_cache_update_total($total);
        }
    }
    return $self->{'total'};
}

=over 4

=item user ( ROLE, WHO, [ INFO ] )

Handles cached information of list users on memory.

I<Getter>.
Gets cached value on memory.  If memory cache is missed, gets actual value
and updates memory cache.
Returns numeric zero (C<0>) if user WHO is known I<not> to be a user of the
list.  Returns C<undef> on error.

I<Setter>.
Updates memory cache.
If C<0> was given as INFO, negative cache will be set.
If C<undef> was given as INFO, cache entry on the memory will be removed.

=back

=cut

sub user {
    my $self = shift;
    my $role = shift;
    my $who  = Sympa::Tools::clean_email(shift || '');
    my $info;

    unless ($role eq 'member' or $role eq 'owner' or $role eq 'editor') {
        $main::logger->do_log(Sympa::Logger::ERR,
            '"%s" is wrong: must be "member", "owner" or "editor"', $role);
        return undef;
    }
    return undef unless $who;

    if (scalar @_) {
        $info = shift;
        $self->{'user'} ||= {};
        $self->{'user'}{$role} ||= {};

        unless (defined $info) {
            delete $self->{'user'}{$role}{$who};
        } elsif (ref $info) {
            $self->{'user'}{$role}{$who} = $info;
        } elsif ($info) {
            $self->{'user'}{$role}{$who} = $info
                unless $self->{'user'}{$role}{$who};
        } else {
            $self->{'user'}{$role}{$who} = 0;
        }

        return $self->{'user'}{$role}{$who};
    }

    return $self->{'user'}{$role}{$who}
        if defined $self->{'user'}{$role}{$who};

    push @sth_stack, $sth;

    if ($role eq 'member') {
        ## Query the Database
        unless (
            $sth = Sympa::DatabaseManager::do_prepared_query(
                sprintf(
                    q{SELECT %s
		    FROM subscriber_table
		    WHERE list_subscriber = ? AND robot_subscriber = ? AND
			  user_subscriber = ?},
                    _list_member_cols()
                ),
                $self->name,
                $self->domain,
                $who
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to check whether user %s is subscribed to list %s',
                $who, $self);
            $sth = pop @sth_stack;
            return undef;
        }
        $info = $sth->fetchrow_hashref('NAME_lc');
        $sth->finish();

        if (defined $info) {
            $info->{'reception'}   ||= 'mail';
            $info->{'update_date'} ||= $info->{'date'};
            $main::logger->do_log(
                Sympa::Logger::DEBUG3,
                'custom_attribute = (%s)',
                $info->{custom_attribute}
            );
            if (defined $info->{custom_attribute}) {
                $info->{'custom_attribute'} =
                    parseCustomAttribute($info->{'custom_attribute'});
            }
            $info->{'reception'} = $self->default_user_options->{'reception'}
                unless $self->is_available_reception_mode(
                $info->{'reception'});
        } else {
            $main::logger->do_log(Sympa::Logger::DEBUG3,
                'No user with the email %s is subscribed to list %s',
                $who, $self);
            $info = 0;
        }
    } else {
        unless (
            $sth = Sympa::DatabaseManager::do_prepared_query(
                sprintf(
                    'SELECT %s FROM admin_table WHERE user_admin = ? AND list_admin = ? AND robot_admin = ? AND role_admin = ?',
                    _list_admin_cols()),
                $who,
                $self->name,
                $self->domain,
                $role
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to get admin %s for list %s',
                $who, $self);
            $sth = pop @sth_stack;
            return undef;
        }
        $info = $sth->fetchrow_hashref('NAME_lc');
        $sth->finish();

        if (defined $info) {
            $info->{'reception'}   ||= 'mail';
            $info->{'update_date'} ||= $info->{'date'};
        } else {
            $info = 0;
        }
    }

    $sth = pop @sth_stack;

    ## Set cache
    return $self->{'user'}{$role}{$who} = $info;
}

##
## Method for UI
##

sub get_option_title {
    my $self    = shift;
    my $option  = shift;
    my $type    = shift || '';
    my $withval = shift || 0;

    my $map = {
        'reception'  => \%reception_mode,
        'visibility' => \%visibility_mode,
        'status'     => \%list_status,
        }->{$type}
        || \%list_option;
    my $t = $map->{$option} || {};
    if ($t->{'gettext_id'}) {
        my $ret = $main::language->gettext($t->{'gettext_id'});
        $ret =~ s/^\s+//;
        $ret =~ s/\s+$//;
        return sprintf '%s (%s)', $ret, $option if $withval;
        return $ret;
    }
    return $option;
}

=head2 Pluggin data-sources

=head3 $obj->includes(DATASOURCE, [NEW])

More abstract accessor for $list->include_DATASOURCE.  It will return
a LIST of the data.  You may pass a NEW single or ARRAY of values.

=cut

sub includes($;$) {
    my $self   = shift;
    my $source = 'include_' . shift;
    if (@_) {
        my $data = ref $_[0] ? shift : [shift];
        return $self->$source($data);
    }
    @{$self->$source || []};
}

=head3 $class->registerPlugin(CLASS)

CLASS must extend L<Sympa::Plugin::ListSource>

=cut

# We have own plugin administration, not using the ::Plugin::Manager
# until all 'include_' labels are abstracted out into objects.
my %plugins;

sub registerPlugin($$) {
    my ($class, $impl) = @_;
    my $source = 'include_' . $impl->listSourceName;
    push @sources_providing_listmembers, $source;
    $plugins{$source} = $impl;
}

=head3 $obj->isPlugin(DATASOURCE)

=cut

sub isPlugin($) { $plugins{$_[1]} }

###### END of the List package ######

############################################################################
##                       LIST CACHE FUNCTIONS                             ##
############################################################################

## There below are functions to handle external caches.
## They would like to be moved to generalized package.

sub list_cache_fetch {
    my $self        = shift;
    my $m1          = shift;
    my $time_config = shift;
    my $name        = $self->name;
    my $robot       = $self->domain;

    my $cache_list_config = $self->robot->cache_list_config;
    my $config;
    my $time_config_bin;

    if ($cache_list_config eq 'database') {
        my $l;
        push @sth_stack, $sth;

        unless (
            $sth = Sympa::DatabaseManager::do_prepared_query(
                q{SELECT cache_epoch_list AS epoch, total_list AS total,
			 config_list AS "config"
		  FROM list_table
		  WHERE name_list = ? AND robot_list = ? AND
			cache_epoch_list > ? AND ? <= cache_epoch_list},
                $name, $robot, $m1, $time_config
            )
            and $sth->rows
            ) {
            $sth = pop @sth_stack;
            return undef;
        }
        $l = $sth->fetchrow_hashref('NAME_lc');
        $sth->finish;

        $sth = pop @sth_stack;

        return undef unless $l;

        eval { $config = Storable::thaw($l->{'config'}) };
        if ($EVAL_ERROR or !defined $config) {
            $main::logger->do_log(
                Sympa::Logger::ERR, 'Unable to deserialize binary config of %s: %s',
                $self, $EVAL_ERROR || 'possible format error'
            );
            return undef;
        }

        return {
            'epoch'  => $l->{'epoch'},
            'total'  => $l->{'total'},
            'config' => $config
        };
    } elsif ($cache_list_config eq 'binary_file'
        and ($time_config_bin = (stat($self->dir . '/config.bin'))[9]) > $m1
        and $time_config <= $time_config_bin) {
        ## Get a shared lock on config file first
        my $lock_fh = Sympa::LockedFile->new($self->dir . '/config', 5, '<');
        unless ($lock_fh) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Could not create new lock');
            return undef;
        }

        ## Load a binary version of the data structure
        ## unless config is more recent than config.bin
        eval { $config = Storable::retrieve($self->dir . '/config.bin') };
        if ($EVAL_ERROR or !defined $config) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to deserialize config.bin of %s: $EVAL_ERROR',
                $self, $EVAL_ERROR || 'possible format error');
            $lock_fh->close();
            return undef;
        }

        $lock_fh->close();

        $self->get_real_total;
        return {
            'epoch'  => $time_config_bin,
            'total'  => $self->total,
            'config' => $config
        };
    }
    return undef;
}

## Update list cache.
sub list_cache_update_config {
    my ($self) = shift;
    my $cache_list_config = $self->robot->cache_list_config;

    local $Data::Dumper::Sortkeys = 1;
    open CCC, '>', $self->dir . '/admin.dump';
    print CCC Dumper($self->admin);
    close CCC;
    open CCC, '>', $self->dir . '/config.dump';
    print CCC Dumper($self->config);
    close CCC;

    if ($cache_list_config eq 'binary_file') {
        ## Get a shared lock on config file first
        my $lock_fh = Sympa::LockedFile->new($self->dir . '/config', 5, '+');
        unless ($lock_fh) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Could not create new lock');
            return undef;
        }

        eval { Storable::store($self->config, $self->dir . '/config.bin') };
        if ($EVAL_ERROR) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Failed to save the binary config %s. error: %s',
                $self->dir . '/config.bin', $EVAL_ERROR
            );
            $lock_fh->close;
            return undef;
        }

        $lock_fh->close;

        return 1;
    }

    return 1 unless $cache_list_config eq 'database';

    my $config;

    my $name      = $self->name;
    my $searchkey = Sympa::Tools::Text::foldcase($self->subject);
    my $status    = $self->status;
    my $robot     = $self->domain;

    my $family;
    if ($self->family) {
        $family = $self->family->name;
    } else {
        $family = undef;
    }

    my $web_archive = $self->is_web_archived ? 1 : 0;
    my $topics =
        join(',', grep { $_ and $_ ne 'others' } @{$self->topics || []});
    $topics = ",$topics," if length $topics;

    my $creation_epoch = $self->creation->{'date_epoch'};
    my $creation_email = $self->creation->{'email'};
    my $update_epoch   = $self->update->{'date_epoch'};
    my $update_email   = $self->update->{'email'};
##    my $latest_instantiation_epoch =
##	$self->latest_instantiation->{'date_epoch'};
##    my $latest_instantiation_email =
##	$self->latest_instantiation->{'email'};

    eval { $config = Storable::nfreeze($self->config); };
    if ($EVAL_ERROR) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Failed to save the config to database. error: %s', $EVAL_ERROR);
        return undef;
    }

    my $time = time;

    push @sth_stack, $sth;

    ## update database cache
    ## try INSERT then UPDATE
    unless (
        $sth = Sympa::DatabaseManager::do_prepared_query(
            q{UPDATE list_table
	      SET status_list = ?, name_list = ?, robot_list = ?,
	      family_list = ?,
	      creation_epoch_list = ?, creation_email_list = ?,
	      update_epoch_list = ?, update_email_list = ?,
	      searchkey_list = ?, web_archive_list = ?, topics_list = ?,
	      cache_epoch_list = ?, config_list = ?
	      WHERE robot_list = ? AND name_list = ?},
            $status,         $name, $robot, $family,
            $creation_epoch, $creation_email,
            $update_epoch,   $update_email,
            $searchkey, $web_archive, $topics,
            $time,      Sympa::DatabaseManager::AS_BLOB($config),
            $robot,     $name
        )
        and $sth->rows
        or $sth = Sympa::DatabaseManager::do_prepared_query(
            q{INSERT INTO list_table
	      (status_list, name_list, robot_list,
	       family_list,
	       creation_epoch_list, creation_email_list,
	       update_epoch_list, update_email_list,
	       searchkey_list, web_archive_list, topics_list,
	       cache_epoch_list, config_list)
	      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)},
            $status,         $name, $robot, $family,
            $creation_epoch, $creation_email,
            $update_epoch,   $update_email,
            $searchkey, $web_archive, $topics,
            $time,      Sympa::DatabaseManager::AS_BLOB($config)
        )
        and $sth->rows
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to insert list %s in database', $self);
        $sth = pop @sth_stack;
        return undef;
    }

    $sth = pop @sth_stack;

    return 1;
}

sub list_cache_update_total {
    my $self              = shift;
    my $cache_list_config = $self->robot->cache_list_config;

    if ($cache_list_config eq 'database') {
        unless (
            Sympa::DatabaseManager::do_prepared_query(
                q{UPDATE list_table
		  SET total_list = ?
		  WHERE name_list = ? AND robot_list = ?},
                $self->{'total'}, $self->name, $self->domain
            )
            ) {
            $main::logger->do_log(
                Sympa::Logger::ERR,
                'Canot update subscriber count of list %s on database cache',
                $self
            );
        }
    }
}

sub list_cache_purge {
    my $self = shift;

    my $cache_list_config = $self->robot->cache_list_config;
    if ($cache_list_config eq 'binary_file' and -e $self->dir . '/config.bin')
    {
        ## Get a shared lock on config file first
        my $lock_fh = Sympa::LockedFile->new($self->dir . '/config', 5, '+');
        unless ($lock_fh) {
            $main::logger->do_log(Sympa::Logger::ERR, 'Could not create new lock');
            return undef;
        }

        unlink($self->dir . '/config.bin');

        $lock_fh->close;
    }

    return 1 unless $cache_list_config eq 'database';

    return
        defined Sympa::DatabaseManager::do_prepared_query(
        q{DELETE from list_table WHERE name_list = ? AND robot_list = ?},
        $self->name, $self->domain);
}

sub is_scenario_purely_closed {
    my $self   = shift;
    my $action = shift;
    return $self->$action->is_purely_closed;
}

sub get_dkim_parameters {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self = shift;

    my $data;
    my $keyfile;

    $data->{'d'} = $self->dkim_parameters->{'signer_domain'};
    if ($self->dkim_parameters->{'signer_identity'}) {
        $data->{'i'} = $self->dkim_parameters->{'signer_identity'};
    } else {

        # RFC 4871 (page 21)
        $data->{'i'} = $self->get_address('owner');
    }

    $data->{'selector'} = $self->dkim_parameters->{'selector'};
    $keyfile = $self->dkim_parameters->{'private_key_path'};

    unless (open(KEY, $keyfile)) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Could not read DKIM private key %s", $keyfile);
        return undef;
    }
    while (<KEY>) {
        $data->{'private_key'} .= $_;
    }
    close(KEY);

    return $data;
}

## return a hash from the edit_list_conf file
sub _load_edit_list_conf {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s)', @_);
    my $self  = shift;
    my $robot = $self->robot;

    my $file;
    my $conf;

    return undef
        unless ($file = $self->get_etc_filename('edit_list.conf'));

    my $fh;
    unless (open $fh, '<', $file) {
        $main::logger->do_log(Sympa::Logger::INFO, 'Unable to open config file %s',
            $file);
        return undef;
    }

    my $error_in_conf;
    my $roles_regexp =
        'listmaster|privileged_owner|owner|editor|subscriber|default';
    while (<$fh>) {
        next if /^\s*(\#.*|\s*)$/;

        if (/^\s*(\S+)\s+(($roles_regexp)\s*(,\s*($roles_regexp))*)\s+(read|write|hidden)\s*$/i
            ) {
            my ($param, $role, $priv) = ($1, $2, $6);
            my @roles = split /,/, $role;
            foreach my $r (@roles) {
                $r =~ s/^\s*(\S+)\s*$/$1/;
                if ($r eq 'default') {
                    $error_in_conf = 1;
                    $main::logger->do_log(Sympa::Logger::NOTICE,
                        '"default" is no more recognised');
                    foreach
                        my $set ('owner', 'privileged_owner', 'listmaster') {
                        $conf->{$param}{$set} = $priv;
                    }
                    next;
                }
                $conf->{$param}{$r} = $priv;
            }
        } else {
            $main::logger->do_log(Sympa::Logger::INFO,
                'unknown parameter in %s  (Ignored) %s',
                $file, $_);
            next;
        }
    }

    if ($error_in_conf) {
        $robot->send_notify_to_listmaster('edit_list_error', $file);
    }

    close $fh;
    return $conf;
}

sub _get_etc_include_path {
    my ($self, $dir, $lang_dirs) = @_;

    my @include_path;

    my $path_list;
    my $path_family;
    @include_path = $self->robot->_get_etc_include_path(@_);

    if ($dir) {
        $path_list = $self->dir . '/' . $dir;
    } else {
        $path_list = $self->dir;
    }
    if ($lang_dirs) {
        unshift @include_path,
            (map { $path_list . '/' . $_ } @$lang_dirs),
            $path_list;
    } else {
        unshift @include_path, $path_list;
    }

    if (defined $self->family) {
        my $family = $self->family;
        if ($dir) {
            $path_family = $family->dir . '/' . $dir;
        } else {
            $path_family = $family->dir;
        }
        if ($lang_dirs) {
            unshift @include_path,
                (map { $path_family . '/' . $_ } @$lang_dirs),
                $path_family;
        } else {
            unshift @include_path, $path_family;
        }
    }

    return @include_path;
}


1;
