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

Sympa::Auth - FIXME

=head1 DESCRIPTION

FIXME

=cut

package Sympa::Auth;

use strict;

use Carp qw(croak);
use Digest::MD5;
use POSIX qw();
use Scalar::Util qw(blessed);

use Sympa::DatabaseManager;
use Sympa::Logger;
use Sympa::Report;
use Sympa::Session;
use Sympa::Site;
use Sympa::Tools;
use Sympa::Tools::Data;
use Sympa::Tools::Time;

## return the password finger print (this proc allow futur replacement of md5
## by sha1 or ....)
sub password_fingerprint {

    $main::logger->do_log(Sympa::Logger::DEBUG, 'Sympa::Auth::password_fingerprint');

    my $pwd = shift;
    if (Sympa::Site->password_case eq 'insensitive') {
        return Digest::MD5::md5_hex(lc($pwd));
    } else {
        return Digest::MD5::md5_hex($pwd);
    }
}

## authentication : via email or uid
sub check_auth {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, ...)', @_);
    my $robot = shift;
    my $auth  = shift;                       ## User email or UID
    my $pwd   = shift;                       ## Password

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));

    my ($canonic, $user);

    if (Sympa::Tools::valid_email($auth)) {
        return authentication($robot, $auth, $pwd);
    } else {
        ## This is an UID
        foreach my $ldap (@{Sympa::Site->auth_services->{$robot->domain}}) {

            # only ldap service are to be applied here
            next unless ($ldap->{'auth_type'} eq 'ldap');

            $canonic =
                ldap_authentication($robot, $ldap, $auth, $pwd, 'uid_filter');
            last if ($canonic);    ## Stop at first match
        }
        if ($canonic) {

            unless ($user = Sympa::User::get_global_user($canonic, Sympa::Site->db_additional_user_fields)) {
                $user = {'email' => $canonic};
            }
            return {
                'user'       => $user,
                'auth'       => 'ldap',
                'alt_emails' => {$canonic => 'ldap'}
            };

        } else {
            Sympa::Report::reject_report_web('user', 'incorrect_passwd', {})
                unless ($ENV{'SYMPA_SOAP'});
            $main::logger->do_log(Sympa::Logger::ERR, "Incorrect LDAP password");
            return undef;
        }
    }
}

## This subroutine if Sympa may use its native authentication for a given user
## It might not if no user_table paragraph is found in auth.conf or if the
## regexp or
## negative_regexp exclude this user
## IN : robot, user email
## OUT : boolean
sub may_use_sympa_native_auth {
    my $robot      = shift;
    my $user_email = shift;

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));

    my $ok = 0;
    ## check each auth.conf paragrpah
    foreach my $auth_service (@{Sympa::Site->auth_services->{$robot->domain}}) {
        next unless ($auth_service->{'auth_type'} eq 'user_table');

        next
            if ($auth_service->{'regexp'}
            && ($user_email !~ /$auth_service->{'regexp'}/i));
        next
            if ($auth_service->{'negative_regexp'}
            && ($user_email =~ /$auth_service->{'negative_regexp'}/i));

        $ok = 1;
        last;
    }

    return $ok;
}

sub authentication {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, ...)', @_);
    my $robot = shift;
    my $email = shift;
    my $pwd   = shift;

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));

    my ($user, $canonic);

    unless ($user = Sympa::User::get_global_user($email, Sympa::Site->db_additional_user_fields)) {
        $user = {'email' => $email};
    }
    unless ($user->{'password'}) {
        $user->{'password'} = '';
    }

    if ($user->{'wrong_login_count'} > $robot->max_wrong_password) {

        # too many wrong login attemp
        Sympa::User::update_global_user($email,
            {wrong_login_count => $user->{'wrong_login_count'} + 1});
        Sympa::Report::reject_report_web('user', 'too_many_wrong_login', {})
            unless ($ENV{'SYMPA_SOAP'});
        $main::logger->do_log(Sympa::Logger::ERR,
            'login is blocked : too many wrong password submission for %s',
            $email);
        return undef;
    }
    foreach my $auth_service (@{Sympa::Site->auth_services->{$robot->domain}}) {
        next if ($auth_service->{'auth_type'} eq 'authentication_info_url');
        next if ($email !~ /$auth_service->{'regexp'}/i);
        next
            if (($email =~ /$auth_service->{'negative_regexp'}/i)
            && ($auth_service->{'negative_regexp'}));

        ## Only 'user_table' and 'ldap' backends will need that Sympa collects
        ## the user passwords
        ## Other backends are Single Sign-On solutions
        if ($auth_service->{'auth_type'} eq 'user_table') {
            my $fingerprint = password_fingerprint($pwd);

            if ($fingerprint eq $user->{'password'}) {
                Sympa::User::update_global_user($email, {wrong_login_count => 0});
                return {
                    'user'       => $user,
                    'auth'       => 'classic',
                    'alt_emails' => {$email => 'classic'}
                };
            }
        } elsif ($auth_service->{'auth_type'} eq 'ldap') {
            if ($canonic = ldap_authentication(
                    $robot, $auth_service, $email, $pwd, 'email_filter'
                )
                ) {
                unless ($user = Sympa::User::get_global_user($canonic, Sympa::Site->db_additional_user_fields)) {
                    $user = {'email' => $canonic};
                }
                Sympa::User::update_global_user($canonic, {wrong_login_count => 0});
                return {
                    'user'       => $user,
                    'auth'       => 'ldap',
                    'alt_emails' => {$email => 'ldap'}
                };
            }
        }
    }

    # increment wrong login count.
    Sympa::User::update_global_user($email,
        {wrong_login_count => $user->{'wrong_login_count'} + 1});

    Sympa::Report::reject_report_web('user', 'incorrect_passwd', {})
        unless ($ENV{'SYMPA_SOAP'});
    $main::logger->do_log(Sympa::Logger::ERR,
        'authentication: incorrect password for user %s', $email);

    my $param;
    $param->{'init_email'}         = $email;
    $param->{'escaped_init_email'} = Sympa::Tools::escape_chars($email);
    return undef;
}

sub ldap_authentication {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, ...)', @_);
    my $robot       = shift;
    my $ldap        = shift;
    my $auth        = shift;
    my $pwd         = shift;
    my $whichfilter = shift;

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));

    my ($mesg, $ldap_passwd, $ldap_anonymous);

    unless ($robot->get_etc_filename('auth.conf')) {
        return undef;
    }

    ## No LDAP entry is defined in auth.conf
    if ($#{Sympa::Site->auth_services->{$robot->domain}} < 0) {
        $main::logger->do_log(Sympa::Logger::NOTICE, 'Skipping empty auth.conf');
        return undef;
    }

    # only ldap service are to be applied here
    return undef unless ($ldap->{'auth_type'} eq 'ldap');

    require Sympa::Datasource::LDAP;

    # skip ldap auth service if the an email address was provided
    # and this email address does not match the corresponding regexp
    return undef if ($auth =~ /@/ && $auth !~ /$ldap->{'regexp'}/i);

    my @alternative_conf = split(/,/, $ldap->{'alternative_email_attribute'});
    my $attrs            = $ldap->{'email_attribute'};
    my $filter           = $ldap->{'get_dn_by_uid_filter'}
        if ($whichfilter eq 'uid_filter');
    $filter = $ldap->{'get_dn_by_email_filter'}
        if ($whichfilter eq 'email_filter');
    $filter =~ s/\[sender\]/$auth/ig;

    ## bind in order to have the user's DN
    my $param = Sympa::Tools::Data::dup_var($ldap);
    my $ds    = Sympa::Datasource::LDAP->new($param);

    unless (defined $ds && ($ldap_anonymous = $ds->connect())) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unable to connect to the LDAP server '%s'",
            $ldap->{'host'});
        return undef;
    }

    $mesg = $ldap_anonymous->search(
        base    => $ldap->{'suffix'},
        filter  => "$filter",
        scope   => $ldap->{'scope'},
        timeout => $ldap->{'timeout'}
    );

    if ($mesg->count() == 0) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            'No entry in the Ldap Directory Tree of %s for %s',
            $ldap->{'host'}, $auth);
        $ds->disconnect();
        return undef;
    }

    my $refhash = $mesg->as_struct();
    my (@DN) = keys(%$refhash);
    $ds->disconnect();

    ##  bind with the DN and the pwd

    ## Duplicate structure first
    ## Then set the bind_dn and password according to the current user
    $param                         = Sympa::Tools::Data::dup_var($ldap);
    $param->{'ldap_bind_dn'}       = $DN[0];
    $param->{'ldap_bind_password'} = $pwd;

    $ds = Sympa::Datasource::LDAP->new($param);

    unless (defined $ds && ($ldap_passwd = $ds->connect())) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unable to connect to the LDAP server '%s'",
            $param->{'host'});
        return undef;
    }

    $mesg = $ldap_passwd->search(
        base    => $ldap->{'suffix'},
        filter  => "$filter",
        scope   => $ldap->{'scope'},
        timeout => $ldap->{'timeout'}
    );

    if ($mesg->count() == 0 || $mesg->code() != 0) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            "No entry in the LDAP Directory Tree of %s",
            $ldap->{'host'});
        $ds->disconnect();
        return undef;
    }

    ## To get the value of the canonic email and the alternative email
    my (@canonic_email, @alternative);

    ## Keep previous alt emails not from LDAP source
    my $previous = {};
    foreach my $alt (keys %{$param->{'alt_emails'}}) {
        $previous->{$alt} = $param->{'alt_emails'}{$alt}
            if ($param->{'alt_emails'}{$alt} ne 'ldap');
    }
    $param->{'alt_emails'} = {};

    my $entry = $mesg->entry(0);
    @canonic_email = $entry->get_value($attrs, 'alloptions' => 1);
    foreach my $email (@canonic_email) {
        my $e = lc($email);
        $param->{'alt_emails'}{$e} = 'ldap' if ($e);
    }

    foreach my $attribute_value (@alternative_conf) {
        @alternative = $entry->get_value($attribute_value, 'alloptions' => 1);
        foreach my $alter (@alternative) {
            my $a = lc($alter);
            $param->{'alt_emails'}{$a} = 'ldap' if ($a);
        }
    }

    ## Restore previous emails
    foreach my $alt (keys %{$previous}) {
        $param->{'alt_emails'}{$alt} = $previous->{$alt};
    }

    $ds->disconnect()
        or $main::logger->do_log(Sympa::Logger::NOTICE, "unable to unbind");
    $main::logger->do_log(Sympa::Logger::DEBUG3, "canonic: $canonic_email[0]");
    ## If the identifier provided was a valid email, return the provided
    ## email.
    ## Otherwise, return the canonical email guessed after the login.
    if (Sympa::Tools::valid_email($auth) && !$robot->ldap_force_canonical_email) {
        return ($auth);
    } else {
        return lc($canonic_email[0]);
    }
}

# fetch user email using his cas net_id and the paragrapah number in auth.conf
## NOTE: This might be moved to Robot package.
sub get_email_by_net_id {
    my $robot      = shift;
    my $auth_id    = shift;
    my $attributes = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, uid=%s)',
        $robot, $auth_id, $attributes->{'uid'});

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));

    if (defined Sympa::Site->auth_services->{$robot->domain}[$auth_id]
        {'internal_email_by_netid'}) {
        my $sso_config   = @{Sympa::Site->auth_services->{$robot->domain}}[$auth_id];
        my $netid_cookie = $sso_config->{'netid_http_header'};

        $netid_cookie =~ s/(\w+)/$attributes->{$1}/ig;

        my $email =
            $robot->get_netidtoemail_db($netid_cookie,
            Sympa::Site->auth_services->{$robot->domain}[$auth_id]{'service_id'});

        return $email;
    }

    my $ldap = @{Sympa::Site->auth_services->{$robot->domain}}[$auth_id];

    my $param = Sympa::Tools::Data::dup_var($ldap);
    my $ds    = Sympa::Datasource::LDAP->new($param);
    my $ldap_anonymous;

    unless (defined $ds && ($ldap_anonymous = $ds->connect())) {
        $main::logger->do_log(Sympa::Logger::ERR,
            "Unable to connect to the LDAP server '%s'",
            $ldap->{'ldap_host'});
        return undef;
    }

    my $filter = $ldap->{'ldap_get_email_by_uid_filter'};
    $filter =~ s/\[([\w-]+)\]/$attributes->{$1}/ig;

    #	my @alternative_conf = split(/,/,$ldap->{'alternative_email_attribute'});

    my $emails = $ldap_anonymous->search(
        base    => $ldap->{'ldap_suffix'},
        filter  => $filter,
        scope   => $ldap->{'ldap_scope'},
        timeout => $ldap->{'ldap_timeout'},
        attrs   => [$ldap->{'ldap_email_attribute'}],
    );

    if ($emails->count() == 0) {
        $main::logger->do_log(Sympa::Logger::NOTICE,
            "No entry in the LDAP Directory Tree of %s", $ldap->{'ldap_host'});
        $ds->disconnect();
        return undef;
    }

    $ds->disconnect();

    ## return only the first attribute
    my @results = $emails->entries;
    foreach my $result (@results) {
        return (lc($result->get_value($ldap->{'ldap_email_attribute'})));
    }

}

# check trusted_application_name et trusted_application_password : return 1 or
# undef;
sub remote_app_check_password {
    my $trusted_application_name = shift;
    my $password                 = shift;
    my $robot                    = shift;
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, ..., %s)',
        $trusted_application_name, $robot);

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));

    my $md5 = Digest::MD5::md5_hex($password);

    # seach entry for trusted_application in Conf
    my @trusted_apps;

    # select trusted_apps from robot context or sympa context
    @trusted_apps = @{$robot->trusted_applications};

    foreach my $application (@trusted_apps) {

        if (lc($application->{'name'}) eq lc($trusted_application_name)) {
            if ($md5 eq $application->{'md5password'}) {

                # $main::logger->do_log(Sympa::Logger::DEBUG, 'Sympa::Auth::remote_app_check_password : authentication succeed for %s',$application->{'name'});
                my %proxy_for_vars;
                foreach my $varname (@{$application->{'proxy_for_variables'}})
                {
                    $proxy_for_vars{$varname} = 1;
                }
                return (\%proxy_for_vars);
            } else {
                $main::logger->do_log(Sympa::Logger::INFO,
                    'Sympa::Auth::remote_app_check_password: bad password from %s',
                    $trusted_application_name);
                return undef;
            }
        }
    }

    # no matching application found
    $main::logger->do_log(Sympa::Logger::INFO,
        'Sympa::Auth::remote_app-check_password: unknown application name %s',
        $trusted_application_name);
    return undef;
}

# create new entry in one_time_ticket table using a rand as id so later
# access is authenticated
sub create_one_time_ticket {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s, %s, %s)', @_);
    my $email       = shift;
    my $robot       = shift;
    my $data_string = shift;
    my $remote_addr = shift;
    ## Value may be 'mail' if the IP address is not known

    croak "missing 'robot' parameter" unless $robot;
    croak "invalid 'robot' parameter" unless
        (blessed $robot and $robot->isa('Sympa::VirtualHost'));

    my $ticket = Sympa::Session::get_random();

    my $date = time;
    my $sth;

    unless (
        Sympa::DatabaseManager::do_prepared_query(
            q{INSERT INTO one_time_ticket_table
	  (ticket_one_time_ticket, robot_one_time_ticket,
	   email_one_time_ticket, date_one_time_ticket, data_one_time_ticket,
	   remote_addr_one_time_ticket, status_one_time_ticket)
	  VALUES (?, ?, ?, ?, ?, ?, ?)},
            $ticket, $robot->domain,
            $email,       time, $data_string,
            $remote_addr, 'open'
        )
        ) {
        $main::logger->do_log(
            Sympa::Logger::ERR,
            'Unable to insert new one time ticket for user %s, robot %s in the database',
            $email,
            $robot
        );
        return undef;
    }
    return $ticket;
}

# read one_time_ticket from table and remove it
sub get_one_time_ticket {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my $robot         = shift;
    my $ticket_number = shift;
    my $addr          = shift;

    my $sth;

    unless (
        $sth = Sympa::DatabaseManager::do_prepared_query(
            q{SELECT ticket_one_time_ticket AS ticket,
		 robot_one_time_ticket AS robot,
		 email_one_time_ticket AS email,
		 date_one_time_ticket AS "date",
		 data_one_time_ticket AS data,
		 remote_addr_one_time_ticket AS remote_addr,
		 status_one_time_ticket as status
	  FROM one_time_ticket_table
	  WHERE ticket_one_time_ticket = ? AND robot_one_time_ticket = ?},
            $ticket_number, $robot->domain
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Unable to retrieve one time ticket %s from database',
            $ticket_number);
        return {'result' => 'error'};
    }

    my $ticket = $sth->fetchrow_hashref('NAME_lc');
    $sth->finish;

    unless ($ticket) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'Unable to find one time ticket %s', $ticket);
        return {'result' => 'not_found'};
    }

    my $result;
    my $printable_date = POSIX::strftime(
        "%d %b %Y at %H:%M:%S", localtime($ticket->{'date'}));
    my $lockout = $robot->one_time_ticket_lockout || 'open';
    my $lifetime =
        Sympa::Tools::Time::duration_conv($robot->one_time_ticket_lifetime || 0);

    if ($lockout eq 'one_time' and $ticket->{'status'} ne 'open') {
        $result = 'closed';
        $main::logger->do_log(Sympa::Logger::INFO,
            'ticket %s from %s has been used before (%s)',
            $ticket_number, $ticket->{'email'}, $printable_date);
    } elsif ($lockout eq 'remote_addr'
        and $ticket->{'status'} ne $addr
        and $ticket->{'status'} ne 'open') {
        $result = 'closed';
        $main::logger->do_log(Sympa::Logger::INFO,
            'ticket %s from %s refused because accessed by the other (%s)',
            $ticket_number, $ticket->{'email'}, $printable_date);
    } elsif ($lifetime and $ticket->{'date'} + $lifetime < time) {
        $main::logger->do_log(Sympa::Logger::INFO,
            'ticket %s from %s refused because expired (%s)',
            $ticket_number, $ticket->{'email'}, $printable_date);
        $result = 'expired';
    } else {
        $result = 'success';
    }

    if ($result eq 'success') {
        unless (
            $sth = Sympa::DatabaseManager::do_prepared_query(
                q{UPDATE one_time_ticket_table
	      SET status_one_time_ticket = ?
	      WHERE ticket_one_time_ticket = ? AND robot_one_time_ticket = ?},
                $addr, $ticket_number, $robot->domain
            )
            ) {
            $main::logger->do_log(Sympa::Logger::ERR,
                'Unable to set one time ticket %s status to %s',
                $ticket_number, $addr);
        } elsif (!$sth->rows) {

            # ticket may be removed by task.
            $main::logger->do_log(Sympa::Logger::INFO,
                'Unable to find one time ticket %s',
                $ticket_number);
            return {'result' => 'not_found'};
        }
    }

    $main::logger->do_log(Sympa::Logger::DEBUG, 'ticket : %s; result : %s',
        $ticket_number, $result);
    return {
        'result'      => $result,
        'date'        => $ticket->{'date'},
        'email'       => $ticket->{'email'},
        'remote_addr' => $ticket->{'remote_addr'},
        'robot'       => $robot->domain,
        'data'        => $ticket->{'data'},
        'status'      => $ticket->{'status'}
    };
}

1;
