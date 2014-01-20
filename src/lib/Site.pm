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

####
#### Site class
####
#### This implements accessor methods to global config
####
package Site;

use strict;
use warnings;
use Carp qw(croak carp);
use Site_r;

our @ISA = qw(Site_r);

####
#### global variables
####
our $is_initialized;
our $use_db;

=head3 ACCESSORS

=over 4

=item E<lt>config parameterE<gt>

I<Getters>.
Gets global or default config parameters.
For example: C<Site-E<gt>syslog> returns "syslog" global parameter;
C<Site-E<gt>domain> returns default "domain" parameter.

Some parameters may be vary by each robot from default value given by these
methods.  Use C<$robot-E<gt>>E<lt>config parameterE<gt> accessors instead.
See L<Robot/ACCESSORS>.

=item locale2charset

=item robot_by_http_host

=item ... etc.

I<Getters>.
Gets derived config parameters.

=back

=cut

our $AUTOLOAD;

sub DESTROY;

sub AUTOLOAD {
    Sympa::Log::Syslog::do_log('debug3', 'Autoloading %s', $AUTOLOAD);
    $AUTOLOAD =~ m/^(.*)::(.*)/;
    my $pkg  = $1;
    my $attr = $2;

    my $type = {};
    ## getters for site/robot attributes.
    $type->{'RobotAttribute'} = 1
        if grep { $_ eq $attr } qw(etc home name);
    ## getters for site/robot parameters.
    $type->{'RobotParameter'} = 1
        if grep { $_ eq $attr }
            qw(blacklist loging_condition loging_for_module
            trusted_applications)
            or grep { $_->{'name'} and $_->{'name'} eq $attr }
            @confdef::params;
    ## getters for attributes specific to global config.
    $type->{'SiteAttribute'} = 1
        if grep { $_ eq $attr }
            qw(auth_services authentication_info_url
            cas_id cas_number crawlers_detection
            generic_sso_id generic_sso_number
            ldap ldap_export ldap_number
            locale2charset nrcpt_by_domain
            robot_by_http_host robot_by_soap_url
            use_passwd queue queueautomatic);

    unless (scalar keys %$type) {
        ## getter for unknwon list attributes.
        ## XXX This code would be removed later.
        if (index($attr, '_') != 0
            and ((ref $_[0] and exists $_[0]->{$attr})
                or exists $Conf::Conf{$attr})
            ) {
            Sympa::Log::Syslog::do_log(
                'err',
                'Unconcerned object method "%s" via package "%s".  Though it may not be fatal, you might want to report it developer',
                $attr,
                $pkg
            );
            no strict "refs";
            *{$AUTOLOAD} = sub {
                croak "Can't modify \"$attr\" attribute" if scalar @_ > 1;
                shift->{$attr};
            };
            goto &$AUTOLOAD;
        }
        ## XXX Code above would be removed later.

        croak "Can't locate object method \"$2\" via package \"$1\"";
    }

    no strict "refs";
    *{$AUTOLOAD} = sub {
        my $self = shift;

        if (ref $self and ref $self eq 'Robot') {
            if ($type->{'RobotAttribute'}) {
                ## getter for list attributes.
                croak "Can't modify \"$attr\" attribute" if scalar @_ > 1;
                return $self->{$attr};
            } elsif ($type->{'RobotParameter'}) {
                ## getters for robot parameters.
                unless ($self->{'etc'} eq Site->etc
                    or defined Site->robots_config->{$self->{'name'}}) {
                    croak "Can't call method \"$attr\" on uninitialized "
                        . (ref $self)
                        . " object";
                }
                croak "Can't modify \"$attr\" attribute" if scalar @_;

                if ($self->{'etc'} ne Site->etc
                    and defined Site->robots_config->{$self->{'name'}}{$attr})
                {
                    ##FIXME: Might "exists" be used?
                    Site->robots_config->{$self->{'name'}}{$attr};
                } else {
                    Site->$attr;
                }
            } else {
                croak "Can't call method \"$attr\" on "
                    . (ref $self)
                    . " object";
            }
        } elsif ($self eq 'Site') {
            ## getter for internal config parameters.
            croak "Can't call method \"$attr\" on uninitialized $self class"
                unless $Site::is_initialized;
            croak "Can't modify \"$attr\" attribute"
                if scalar @_ > 1;

            my $ret = $Conf::Conf{$attr};

            # To avoid "Can't use an undefined value as a HASH reference"
            if (!defined $ret and $type->{'SiteAttribute'}) {
                return {};
            }
            $ret;
        } else {
            croak 'bug in logic.  Ask developer';
        }
    };
    goto &$AUTOLOAD;
}

=over 4

=item config

XXX I<Not yet implemented>.

I<Getter/Setter>, I<internal use>.
Gets or sets configuration information, eliminating defaults.

B<Note>:
Use L</fullconfig> accessor to get full configuration informaton.

=back

=cut

sub config {
    croak 'Not implemented';
}

=over 4

=item fullconfig

I<Getter>.
Configuration information of the site, with defaults applied.

B<Note>:
Use L</config> accessor to get information without defaults.

B<Note>:
L<fullconfig> and L<config> accessors will return the copy of configuration
information.  Modification of them will never affect to actual site
parameters.
Use C<E<lt>config parameterE<gt>> accessors to get or set each site parameter.

=back

=cut

## TODO: expand scenario parameters.
sub fullconfig {
    my $self       = shift;
    my $fullconfig = {};

    foreach my $p (@confdef::params) {
        next unless $p->{'name'};
        my $attr = $p->{'name'};
        $fullconfig->{$p->{'name'}} = $self->$attr;
    }
    return $fullconfig;
}

=over 4

=item lang

I<Getter>.
Gets "lang" parameter, canonicalized if possible.

=back

=cut

#FIXME: inefficient; would be cached.
sub lang {
    my $self = shift;
    my $lang;

    croak "Can't modify \"lang\" attribute" if scalar @_ > 1;
    if (    ref $self
        and ref $self eq 'Robot'
        and $self->{'etc'} ne Site->etc
        and exists Site->robots_config->{$self->{'name'}}{'lang'}) {
        $lang = Site->robots_config->{$self->{'name'}}{'lang'};
    } elsif (ref $self and ref $self eq 'Robot'
        or !ref $self and $self eq 'Site') {
        croak "Can't call method \"lang\" on uninitialized $self class"
            unless $Site::is_initialized;
        $lang = $Conf::Conf{'lang'};
    } else {
        croak 'bug in loginc.  Ask developer';
    }

    if ($lang) {
        $lang = Language::CanonicLang($lang) || $lang;
    }
    return $lang;
}

=head3 Derived parameters

These are accessors derived from default parameters.
Some of them are obsoleted.

=cut

## DEPRECATED: Use $robot->split_listname().
## sub list_check_regexp ( mailbox )

=over 4

=item listmasters

I<Getter>.
Gets default listmasters.
In array context, returns array of default listmasters.
In scalar context, returns arrayref to them.

=back

=cut

sub listmasters {
    my $self = shift;

    croak "Can't modify \"listmasters\" attribute" if scalar @_ > 1;
    if (ref $self and ref $self eq 'Robot') {
        if (wantarray) {
            @{Site->robots_config->{$self->domain}{'listmasters'} || []};
        } else {
            Site->robots_config->{$self->domain}{'listmasters'};
        }
    } elsif ($self eq 'Site') {
        croak "Can't call method \"listmasters\" on uninitialized $self class"
            unless $Site::is_initialized;

        if (wantarray) {
            @{$Conf::Conf{'listmasters'} || []};
        } else {
            $Conf::Conf{'listmasters'};
        }
    } else {
        croak 'bug in logic.  Ask developer';
    }
}

=over 4

=item request

I<Getter>.
Get E<lt>sympa-requestE<gt> address of robot.

B<Obsoleted>.
This method will be removed in near future.
Use C<get_address('owner')> method intead.

=back

=cut

sub request {
    my $self = shift;

    my $level = $Carp::CarpLevel;
    $Carp::CarpLevel = 1;
    carp "Deprecated: Use get_address('owner') method instead";
    $Carp::CarpLevel = $level;

    return $self->get_address('owner');
}

=over 4

=item supported_languages

I<Getter>.
Gets supported languages, canonicalized.
In array context, returns array of globally supported languages.
In scalar context, returns arrayref to them.

=back

=cut

sub supported_languages {
    my $self           = shift;
    my $supported_lang = $self->supported_lang;

    my $saved_lang = Language::GetLang();
    my @lang_list =
        grep { $_ and $_ = Language::SetLang($_) }
        split /\s*,\s*/, $supported_lang;
    Language::SetLang($saved_lang);

    @lang_list = ('en') unless @lang_list;
    return @lang_list if wantarray;
    return \@lang_list;
}

=over 4

=item sympa

I<Getter>.
Get E<lt>sympaE<gt> address of robot.

B<Obsoleted>.
This method will be removed in near future.
Use C<get_address()> method instead.

=back

=cut

sub sympa {
    my $self = shift;

    my $level = $Carp::CarpLevel;
    $Carp::CarpLevel = 1;
    carp "Deprecated: Use get_address() method instead";
    $Carp::CarpLevel = $level;

    return $self->get_address();
}

=head3 Miscelaneous

=over 4

=item import

XXX @todo doc

=back

=cut

sub import {
    ## register crash handler.
    $SIG{'__DIE__'} = \&_crash_handler;
}

## Handler for $SIG{__DIE__} to generate traceback.
## IN : error message
## OUT : none.  This function exits with status 255 or (if invoked from
## inside eval) simply returns.
sub _crash_handler {
    return if $^S;    # invoked from inside eval.

    my $msg = $_[0];
    chomp $msg;
    Sympa::Log::Syslog::do_log('err', 'DIED: %s', $msg);
    eval { Site->send_notify_to_listmaster(undef, undef, undef, 1); };
    eval { SDM::db_disconnect(); };    # unlock database
    Sys::Syslog::closelog();           # flush log

    ## gather traceback information
    my @calls;
    my @f;
    $_[0] =~ /.+ at (.+? line \d+\.)\n$/s;
    @calls = ($1) if $1;
    for (my $i = 1; @f = caller($i); $i++) {
        $calls[0] = "In $f[3] at $calls[0]" if @calls;
        unshift @calls, "$f[1] line $f[2].";
    }
    $calls[0] = "In (top-level) at $calls[0]";

    print STDERR join "\n", "DIED: $msg", @calls;
    print STDERR "\n";
    exit 255;
}

=over 4

=item robots_config

Get C<'robots'> item of loaded config.

I<NOT RECOMMENDED>.
This class method is prepared for backward compatibility.
L<Robot/get_robots> should be used.

=back

=cut

sub robots_config {
    return $Conf::Conf{'robots'} || {};
}

1;
