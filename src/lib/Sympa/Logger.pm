# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: Syslog.pm 10492 2014-03-31 12:43:45Z rousse $

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

Sympa::Logger - An abstract logger

=head1 DESCRIPTION

This is an abstract base class for all logger implementations.

=cut

package Sympa::Logger;

use strict;

use constant {
    ERR    => 0,
    INFO   => 1,
    NOTICE => 2,
    TRACE  => 3,
    DEBUG  => 4,
    DEBUG2 => 5,
    DEBUG3 => 6,
};

use English qw(-no_match_vars);

# map internal constants against sympa 'log_level' directive
my %sympa_levels = (
    Sympa::Logger::ERR    => 0,
    Sympa::Logger::INFO   => 0,
    Sympa::Logger::NOTICE => 0,
    Sympa::Logger::TRACE  => 0,
    Sympa::Logger::DEBUG  => 1,
    Sympa::Logger::DEBUG2 => 2,
    Sympa::Logger::DEBUG3 => 3,
);

# abstract constructor for subclasses
sub _new {
    my ($class, %params) = @_;

    my $self = {
        level => $params{level} || 0
    };
    bless $self, $class;

    return $self;
}

=head1 INSTANCE METHODS

=over

=item $logger->set_level()

=cut

sub set_level {
    my ($self, $level) = @_;

    $self->{level} = $level;
}

=item $logger->get_level()

=cut

sub get_level {
    my ($self) = @_;

    return $self->{level};
}

=item $logger->do_log($level, $message)

=cut

sub do_log {
    my ($self, $level, $message, @args) = @_;

    # do not log if log level is too high regarding the log requested by user
    return if $sympa_levels{$level} > $self->{level};

    # sanitize args
    @args = map { _sanitize_arg($_) } @args;

    ## Determine calling function
    my $caller_string;

    ## If in 'err' level, build a stack trace,
    ## except if syslog has not been setup yet.
    if ($level == ERR) {
        my $go_back = 1;
        my @calls;

        my @f = caller($go_back);
        if ($f[3] =~ /wwslog$/) {   ## If called via wwslog, go one step ahead
            @f = caller(++$go_back);
        }
        @calls = ('#' . $f[2]);
        while (@f = caller(++$go_back)) {
            $calls[0] = $f[3] . $calls[0];
            unshift @calls, '#' . $f[2];
        }
        $calls[0] = '(top-level)' . $calls[0];

        $caller_string = join(' > ', @calls);
    } else {
        my @call = caller(1);

        ## If called via wwslog, go one step ahead
        if ($call[3] and $call[3] =~ /wwslog$/) {
            @call = caller(2);
        }

        $caller_string = ($call[3] || '') . '()';
    }

    $message = $caller_string . ' ' . $message if ($caller_string);

    $self->_do_log($level, $message, @args);
}

sub _sanitize_arg {
    my ($arg) = @_;

    # prevent 'Use of uninitialized value' warning
    return '' if !defined $arg;
    
    my $type = ref $arg;

    return $arg if !$type;

    # array reference
    return '[...]' if $type eq 'ARRAY';

    # hash reference
    return sprintf('{%s}', join('/', keys %{$arg})) if $type eq 'HASH';

    # other unblessed references
    return $arg if $type eq 'Regexp' or $type eq uc($type);

    # object with get_id() method
    return sprintf('%s <%s>', $type, $arg->get_id) if $arg->can('get_id');

    # other kind of object
    return $arg;
}

=back

=cut

1;
