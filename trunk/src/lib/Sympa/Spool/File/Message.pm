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

package Sympa::Spool::File::Message;

use strict;
use base qw(Sympa::Spool::File);

use Sympa::List;
use Sympa::Log::Syslog;
use Sympa::Robot;

my $filename_regexp = '^(\S+)\.(\d+)\.\w+$';

sub new {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s)', @_);
    my $pkg = shift;
    return $pkg->SUPER::new(
        'msg', shift,
        'sortby'   => 'priority',
        'selector' => {'priority' => ['z', 'ne']},
    );
}

sub is_relevant {
    Sympa::Log::Syslog::do_log('debug3', '(%s, %s)', @_);
    my $self = shift;
    my $key  = shift;

    ## z and Z are a null priority, so file stay in queue and are processed
    ## only if renamed by administrator
    return 0 unless $key =~ /$filename_regexp/;

    ## Don't process temporary files created by queue (T.xxx)
    return 0 if $key =~ /^T\./;

    return 1;
}

sub get_storage_name {
    my $self = shift;
    my $filename;
    my $param = shift;
    if ($param->{'list'} && $param->{'robot'}) {
        $filename =
              $param->{'list'} . '@'
            . $param->{'robot'} . '.'
            . time . '.'
            . int(rand(10000));
    } else {
        Sympa::Log::Syslog::do_log('err',
            'Unsufficient parameters provided to create file name');
        return undef;
    }
    return $filename;
}

sub analyze_file_name {
    Sympa::Log::Syslog::do_log('debug3', '(%s, %s, %s)', @_);
    my $self = shift;
    my $key  = shift;
    my $data = shift;

    unless ($key =~ /$filename_regexp/) {
        Sympa::Log::Syslog::do_log('err',
            'File %s name does not have the proper format', $key);
        return undef;
    }
    ($data->{'list'}, $data->{'robot'}) = split /\@/, $1;

    $data->{'list'}  = lc($data->{'list'});
    $data->{'robot'} = lc($data->{'robot'});
    return undef
        unless $data->{'robot_object'} = Sympa::Robot->new($data->{'robot'});

    my $listname;

    #FIXME: is this always needed?
    ($listname, $data->{'type'}) =
        $data->{'robot_object'}->split_listname($data->{'list'});
    if (defined $listname) {
        $data->{'list_object'} =
            Sympa::List->new($listname, $data->{'robot_object'}, {'just_try' => 1});
    }

    ## Get priority
    #FIXME: is this always needed?
    if ($data->{'type'} and $data->{'type'} eq 'listmaster') {
        ## highest priority
        $data->{'priority'} = 0;
    } elsif ($data->{'type'} and $data->{'type'} eq 'owner') {    # -request
        $data->{'priority'} = $data->{'robot_object'}->request_priority;
    } elsif ($data->{'type'} and $data->{'type'} eq 'return_path') {  # -owner
        $data->{'priority'} = $data->{'robot_object'}->owner_priority;
    } elsif ($data->{'type'} and $data->{'type'} eq 'sympa') {
        $data->{'priority'} = $data->{'robot_object'}->sympa_priority;
    } elsif (ref $data->{'list_object'}
        and $data->{'list_object'}->isa('Sympa::List')) {
        $data->{'priority'} = $data->{'list_object'}->priority;
    } else {
        $data->{'priority'} = $data->{'robot_object'}->default_list_priority;
    }

    Sympa::Log::Syslog::do_log('debug3',
        'messagekey=%s, list=%s, robot=%s, priority=%s',
        $key, $data->{'list'}, $data->{'robot'}, $data->{'priority'});

    ## Get file date

    unless ($key =~ /$filename_regexp/) {
        $data->{'date'} = (stat $data->{'file'})[9];
    } else {
        $data->{'date'} = $2;
    }

    return $data;
}

1;
