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

package Sympa::SubscribeSpool;

use strict;
use warnings;
use base qw(Sympa::ClassicSpool);

use Data::Dumper;

use Sympa::Log::Syslog;

sub new {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s)', @_);
    return shift->SUPER::new('subscribe', shift);
}

sub sub_request_exists {
    my $self     = shift;
    my $selector = shift;
    if ($self->get_message($selector)) {
        Sympa::Log::Syslog::do_log('notice',
            'Subscription already requested by %s',
            $selector->{'sender'});
        return 1;
    }
    return 0;
}

sub get_subscription_request_details {
    my $self   = shift;
    my $string = shift;
    my $result;
    if ($string =~ /(.*)\t(.*)\n(.*)\n/) {
        $result->{'sender'}           = $1;
        $result->{'gecos'}            = $2;
        $result->{'customattributes'} = $3;
    } else {
        Sympa::Log::Syslog::do_log('err',
            "Failed to parse subscription request %s", $string);
    }
    return $result;
}

sub get_additional_details {
    my $self = shift;
    my $key  = shift;
    my $data = shift;
    $data = $self->parse_file_content($key, $data);
    my $details;
    unless ($details =
        $self->get_subscription_request_details($data->{'messageasstring'})) {
        Sympa::Log::Syslog::do_log('err',
            'File %s exists but its content is unparsable', $key);
        return undef;
    }
    my %tmp_hash = (%$data, %$details);
    %$data = %tmp_hash;
    return $data;
}

1;
