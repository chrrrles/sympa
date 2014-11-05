# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: Instruction.pm 11626 2014-11-04 18:05:21Z rousse $

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

Sympa::Rule - A scenario rule

=head1 DESCRIPTION

This class implements a single rule from an authorization scenario.

A L<Sympa::Rule> object has the following attributes:

=over

=item * test: condition

=item * auth_methods: list of supported authentication methods

=item * decision: decision to apply if the test succeeds

=back

=cut

package Sympa::Rule;

use strict;

use Carp qw(croak);
use English qw(-no_match_vars);

=head1 CLASS METHODS

=over

=item Sympa::Rule->new(%parameters)

Creates a new L<Sympa::Rule> object.

Parameters:

=over 4

=item * I<test>: test attribute (mandatory)

=item * I<auth_methods>: auth_methods attribute (mandatory)

=item * I<decision>: decision attribute (mandatory)

=back

Returns a new L<Sympa::Rule> object, otherwise raises an exception.

=cut

sub new {
    my ($class, %params) = @_;
    
    my $test         = $params{test};
    my $auth_methods = $params{auth_methods};
    my $decision     = $params{decision};

    croak "missing 'test' parameter"         unless $test;
    croak "missing 'auth_methods' parameter" unless $auth_methods;
    croak "missing 'decision' parameter"     unless $decision;

    my $self = bless {
        test         => $test,
        auth_methods => $auth_methods,
        decision     => $decision,
    }, $class;

    return $self;
}

=back

=head1 INSTANCE METHODS

=over

=item $rule->get_test()

Get test attribute.

=cut

sub get_test {
    my ($self) = @_;
    return $self->{test};
}

=item $rule->get_auth_methods()

Get auth_methods attribute.

=cut

sub get_auth_methods {
    my ($self) = @_;
    return $self->{auth_methods};
}

=item $rule->get_decision()

Get decision attribute.

=cut

sub get_decision {
    my ($self) = @_;
    return $self->{decision};
}

=back

=cut

1;
