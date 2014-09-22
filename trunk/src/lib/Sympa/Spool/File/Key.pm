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

package Sympa::Spool::File::Key;

use strict;
use warnings;
use base qw(Sympa::Spool::File);

use English qw(-no_match_vars);

use Sympa::List; # FIXME: circular dependency
use Sympa::Logger;
use Sympa::Robot;

our $filename_regexp = '^(\S+)_(\w+)(\.distribute)?$';

sub new {
    $main::logger->do_log(Sympa::Logger::DEBUG2, '(%s, %s)', @_);
    my ($class, @params) = @_;
    return $class->SUPER::new(@params);
}

sub get_storage_name {
    my $self = shift;
    my $filename;
    my $param = shift;
    if ($param->{'list'} && $param->{'robot'}) {
        $filename =
              $param->{'list'} . '@'
            . $param->{'robot'} . '_'
            . $param->{'authkey'};
    }
    return $filename;
}

sub analyze_file_name {
    $main::logger->do_log(Sympa::Logger::DEBUG3, '(%s, %s, %s)', @_);
    my $self = shift;
    my $key  = shift;
    my $data = shift;

    unless ($key =~ /$filename_regexp/) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'File %s name does not have the proper format', $key);
        return undef;
    }
    my $list_id;
    ($list_id, $data->{'authkey'}, $data->{'validated'}) = ($1, $2, $3);
    ($data->{'list'}, $data->{'robot'}) = split /\@/, $list_id;

    $data->{'list'}  = lc($data->{'list'});
    $data->{'robot'} = lc($data->{'robot'});
    return undef
        unless $data->{'robot_object'} = Sympa::Robot->new($data->{'robot'});

    my $listname;

    #FIXME: is this needed?
    ($listname, $data->{'type'}) =
        $data->{'robot_object'}->split_listname($data->{'list'});    #FIXME
    return undef
        unless defined $listname
            and $data->{'list_object'} =
            Sympa::List->new($listname, $data->{'robot_object'});

    ## Get priority

    $data->{'priority'} = $data->{'list_object'}->priority;

    ## Get file date

    $data->{'date'} = (stat $data->{'file'})[9];

    return $data;
}

## Return messages not validated yet.
sub get_awaiting_messages {
    my $self  = shift;
    my $param = shift;
    $param->{'selector'}{'validated'} = ['.distribute', 'ne'];
    return $self->get_content($param);
}

sub validate_message {
    my $self = shift;
    my $key  = shift;

    unless (
        File::Copy::copy(
            $self->{'dir'} . '/' . $key,
            $self->{'dir'} . '/' . $key . '.distribute'
        )
        ) {
        $main::logger->do_log(Sympa::Logger::ERR, 'Could not rename file %s/%s: %s',
            $self->{'dir'}, $key, $ERRNO);
        return undef;
    }
    unless (unlink($self->{'dir'} . '/' . $key)) {
        $main::logger->do_log(Sympa::Logger::ERR,
            'Could not unlink message %s/%s: %s',
            $self->{'dir'}, $key, $ERRNO);
    }
    return 1;
}

1;
