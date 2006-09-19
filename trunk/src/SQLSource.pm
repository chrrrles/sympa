# Message.pm - This module includes SQL DB related functions
#<!-- RCS Identication ; $Revision$ --> 

#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
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
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

package SQLSource;

use strict;
require Exporter;
require 'tools.pl';
require 'tt2.pl';
our @ISA = qw(Exporter);
our @EXPORT = qw(%date_format);
our @EXPORT_OK = qw(connect query disconnect fetch create_db ping quote);

use Carp;

use Conf;
use Log;
use List;

our %date_format = (
		   'read' => {
		       'Pg' => 'date_part(\'epoch\',%s)',
		       'mysql' => 'UNIX_TIMESTAMP(%s)',
		       'Oracle' => '((to_number(to_char(%s,\'J\')) - to_number(to_char(to_date(\'01/01/1970\',\'dd/mm/yyyy\'), \'J\'))) * 86400) +to_number(to_char(%s,\'SSSSS\'))',
		       'Sybase' => 'datediff(second, "01/01/1970",%s)',
		       'SQLite' => 'strftime(\'%%s\',%s,\'utc\')'
		       },
		   'write' => {
		       'Pg' => '\'epoch\'::timestamp with time zone + \'%d sec\'',
		       'mysql' => 'FROM_UNIXTIME(%d)',
		       'Oracle' => 'to_date(to_char(round(%s/86400) + to_number(to_char(to_date(\'01/01/1970\',\'dd/mm/yyyy\'), \'J\'))) || \':\' ||to_char(mod(%s,86400)), \'J:SSSSS\')',
		       'Sybase' => 'dateadd(second,%s,"01/01/1970")',
		       'SQLite' => 'datetime(%d,\'unixepoch\',\'localtime\')'
		       }
	       );

############################################################
#  connect
############################################################
#  Connect to an SQL database. This could be called as
#  a SQLSource object member, or as a static sub. 
#  
# IN : -$param_ref : ref to a Hash of config data if statically
#       called
#      -$options : ref to a hash. Options for the connection process.
#         currently accepts 'keep_trying' : wait and retry until
#         db connection is ok (boolean) ; 'warn' : warn
#         listmaster if connection fails (boolean)
# OUT : $dbh
#     | undef
#
##############################################################
sub connect {
    my $self = undef;
    my ($param, $options) = @_;
    # are we called as an instance member ?
    if (ref($param) ne 'HASH') {
    	$self = $param;
    	$param = $self->{'param'};
    }
    
    unless ( eval "require DBI" ){
	do_log('err',"Unable to use DBI library, install DBI (CPAN) first");
	return undef ;
    }
    require DBI;

    $param->{'db_host'} ||= $param->{'host'};
    $param->{'db_user'} ||= $param->{'user'};
    $param->{'db_passwd'} ||= $param->{'passwd'};
    $param->{'db_options'} ||= $param->{'connect_options'};
     
    ## Do we have db_xxx required parameters
    foreach my $db_param ('db_type','db_name') {
	unless ($param->{$db_param}) {
	    do_log('info','Missing parameter %s for DBI connection', $db_param);
	    return undef;
	}
    }
    ## SQLite just need a db_name
    unless ($param->{'db_type'} eq 'SQLite') {
	foreach my $db_param ('db_type','db_name','db_host','db_user') {
	    unless ($param->{$db_param}) {
		do_log('info','Missing parameter %s for DBI connection', $db_param);
		return undef;
	    }
	}
    }

    my $connect_string;
    ## Check if DBD is installed
    unless (eval "require DBD::$param->{'db_type'}") {
	do_log('err',"No Database Driver installed for $param->{'db_type'} ; you should download and install DBD::$param->{'db_type'} from CPAN");
	&List::send_notify_to_listmaster('missing_dbd', $Conf{'domain'},{'db_type' => $param->{'db_type'}});
	return undef;
    }

    if ($param->{'f_dir'}) {
	$connect_string = "DBI:CSV:f_dir=$param->{'f_dir'}";
    }elsif ($param->{'db_type'} eq 'Oracle') {
	$connect_string = "DBI:Oracle:";
	if ($param->{'db_host'} && $param->{'db_name'}) {
	    $connect_string .= "host=$param->{'db_host'};sid=$param->{'db_name'}";
	}
	if (defined $param->{'db_port'}) {
	    $connect_string .= ';port=' . $param->{'db_port'};
	}
    }elsif ($param->{'db_type'} eq 'Pg') {
	$connect_string = "DBI:Pg:dbname=$param->{'db_name'};host=$param->{'db_host'}";
    }elsif ($param->{'db_type'} eq 'Sybase') {
	$connect_string = "DBI:Sybase:database=$param->{'db_name'};server=$param->{'db_host'}";
    }elsif ($param->{'db_type'} eq 'SQLite') {
	$connect_string = "DBI:SQLite:dbname=$param->{'db_name'}";
    }else {
	$connect_string = "DBI:$param->{'db_type'}:$param->{'db_name'}:$param->{'db_host'}";
    }

    if ($param->{'db_options'}) {
	$connect_string .= ';' . $param->{'db_options'};
    }
    if (defined $param->{'db_port'}) {
	$connect_string .= ';port=' . $param->{'db_port'};
    }
 
    ## Set environment variables
    ## Used by Oracle (ORACLE_HOME)
    if ($param->{'db_env'}) {
	foreach my $env (split /;/,$param->{'db_env'}) {
	    my ($key, $value) = split /=/, $env;
	    $ENV{$key} = $value if ($key);
	}
    }

    my $dbh;
    unless ($dbh = DBI->connect($connect_string, $param->{'db_user'}, $param->{'db_passwd'})) {
    	
	unless (! $options->{'warn'} || &List::send_notify_to_listmaster('no_db', $Conf{'domain'},{})) {
	    &do_log('notice',"Unable to send notify 'no_db' to listmaster");
	}
	
	if ($options->{'keep_trying'}) {
	    do_log('err','Can\'t connect to Database %s as %s, still trying...', $connect_string, $param->{'db_user'});
	} else{
	    do_log('err','Can\'t connect to Database %s as %s', $connect_string, $param->{'db_user'});
	    return undef;
	}
	
	## Loop until connect works
	my $sleep_delay = 60;
	while (1) {
	    sleep $sleep_delay;
	    $dbh = DBI->connect($connect_string, $param->{'db_user'}, $param->{'db_passwd'});
	    last if ($dbh && $dbh->ping());
	    $sleep_delay += 10;
	}

	if ($options->{'warn'}) {
	    do_log('notice','Connection to Database %s restored.', $connect_string);
	    unless (&send_notify_to_listmaster('db_restored', $Conf{'domain'},{})) {
	        &do_log('notice',"Unable to send notify 'db_restored' to listmaster");
	    }
	}

    }

    if ($param->{'db_type'} eq 'Pg') { # Configure Postgres to use ISO format dates
       $dbh->do ("SET DATESTYLE TO 'ISO';");
    }

    ## added sybase support
    if ($param->{'db_type'} eq 'Sybase') { 
	my $dbname;
	$dbname="use $param->{'db_name'}";
        $dbh->do ($dbname);
    }

    if ($param->{'db_type'} eq 'SQLite') { # Configure to use sympa database
        eval "$dbh->func( 'func_index', -1, sub { return index($_[0],$_[1]) }, 'create_function' )";
	eval "if(defined $param->{'db_timeout'}) { $dbh->func( param->{'db_timeout'}, 'busy_timeout' ); } else { $dbh->func( 5000, 'busy_timeout' ); }";
    }
    
    $self->{'dbh'} = $dbh if $self;
    
    do_log('debug2','Connected to Database %s',$param->{'db_name'});
    return $dbh;

}

sub query {
    my ($self, $sql_query) = @_;
    unless ($self->{'sth'} = $self->{'dbh'}->prepare($sql_query)) {
        do_log('err','Unable to prepare SQL query : %s', $self->{'dbh'}->errstr);
        return undef;
    }
    unless ($self->{'sth'}->execute) {
        do_log('err','Unable to perform SQL query %s : %s ',$sql_query, $self->{'dbh'}->errstr);
        return undef;
    }

}

sub fetch {
    my $self = shift;
    return $self->{'sth'}->fetchrow_arrayref;
}

sub disconnect {
    my $self = shift;
    $self->{'sth'}->finish if $self->{'sth'};
    $self->{'dbh'}->disconnect;
}

## Try to create the database
sub create_db {
    &do_log('debug3', 'List::create_db()');    

    &do_log('notice','Trying to create %s database...', $Conf{'db_name'});

    unless ($Conf{'db_type'} eq 'mysql') {
	&do_log('err', 'Cannot create %s DB', $Conf{'db_type'});
	return undef;
    }

    my $drh;
    unless ($drh = DBI->connect("DBI:mysql:dbname=mysql;host=localhost", 'root', '')) {
	&do_log('err', 'Cannot connect as root to database');
	return undef;
    }

    ## Create DB
    my $rc = $drh->func("createdb", $Conf{'db_name'}, 'localhost', $Conf{'db_user'}, $Conf{'db_passwd'}, 'admin');
    unless (defined $rc) {
	&do_log('err', 'Cannot create database %s : %s', $Conf{'db_name'}, $drh->errstr);
	return undef;
    }

    ## Re-connect to DB (to prevent "MySQL server has gone away" error)
    unless ($drh = DBI->connect("DBI:mysql:dbname=mysql;host=localhost", 'root', '')) {
	&do_log('err', 'Cannot connect as root to database');
	return undef;
    }

    ## Grant privileges
    unless ($drh->do("GRANT ALL ON $Conf{'db_name'}.* TO $Conf{'db_user'}\@localhost IDENTIFIED BY '$Conf{'db_passwd'}'")) {
	&do_log('err', 'Cannot grant privileges to %s on database %s : %s', $Conf{'db_user'}, $Conf{'db_name'}, $drh->errstr);
	return undef;
    }

    &do_log('notice', 'Database %s created', $Conf{'db_name'});

    ## Reload MysqlD to take changes into account
    my $rc = $drh->func("reload", $Conf{'db_name'}, 'localhost', $Conf{'db_user'}, $Conf{'db_passwd'}, 'admin');
    unless (defined $rc) {
	&do_log('err', 'Cannot reload mysqld : %s', $drh->errstr);
	return undef;
    }

    $drh->disconnect();

    return 1;
}

sub ping {
    my $self = shift;
    return $self->{'dbh'}->ping; 
}

sub quote {
    my ($self, $string, $datatype) = shift;
    
    return $self->{'dbh'}->quote($string, $datatype); 
}

## Packages must return true.
1;
