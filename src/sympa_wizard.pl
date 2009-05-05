#!--PERL--

# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
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

=head1 NAME

sympa_wizard.pl - help perform sympa initial setup

=head1 SYNOPSIS

=over

=item sympa_wizard.pl

Edit current sympa configuration

=item sympa_wizard.pl [--target file] --create <sympa.conf|wwsympa.conf>

Creates a new sympa or wwsympa configuration file

=item sympa_wizard.pl --check

check CPAN modules needed for running sympa

=item sympa_wizard.pl --help

Display usage instructions

=back

=head1 AUTHORS

=over

=item Serge Aumont <sa@cru.fr>

=item Olivier Sala�n <os@cru.fr>

=back

=cut

## Change this to point to your Sympa bin directory
use lib '--pkgdatadir--/lib';
use strict;
use POSIX qw(strftime);
use English qw(-no_match_vars);
use Getopt::Long;
use Pod::Usage;

## sympa configuration files
my $wwsympa_conf = "--WWSCONFIG--";
my $sympa_conf = "--CONFIG--";

my %options;
GetOptions(
    \%options, 
    'target=s',
    'create=s',
    'check',
    'help'
);

if ($options{help}) {
    pod2usage();
} elsif ($options{create}) {
    create_configuration();
} elsif ($options{check}) {
    check_cpan();
} else {
    edit_configuration();
}

exit 0;

sub create_configuration {
    use confdef;

    my $conf;
    if ($options{create} eq 'sympa.conf') {
        $conf = $options{target} ? $options{target} : $sympa_conf;
    } elsif ($options{create} eq 'wwsympa.conf') {
        $conf = $options{target} ? $options{target} : $wwsympa_conf;
    } else {
        pod2usage("$options{create} is not a valid argument");
        exit 1;
    }

    if (-f $conf) {
        print STDERR "$conf file already exists, exiting\n";
        exit 1;
    }

    unless (open (NEWF,"> $conf")){
        die "Unable to open $conf : $!";
    };

    if ($options{create} eq 'sympa.conf') {
        print NEWF <<EOF
## Configuration file for Sympa
## many parameters are optional
## refer to the documentation for a detailed list of parameters

EOF
    }

    foreach my $param (@confdef::params) {

        if ($param->{'title'}) {
            printf NEWF "###\\\\\\\\ %s ////###\n\n", $param->{'title'};
            next;
        }

        next unless ($param->{'file'} eq $options{create});

        next unless (defined $param->{'default'} || defined $param->{'sample'});

        printf NEWF "## %s\n", $param->{'query'}
            if (defined $param->{'query'});

        printf NEWF "## %s\n", $param->{'advice'}
            if (defined $param->{'advice'});

        printf NEWF "%s\t%s\n\n", $param->{'name'}, $param->{'default'}
            if (defined $param->{'default'});

        printf NEWF "#%s\t%s\n\n", $param->{'name'}, $param->{'sample'}
            if (defined $param->{'sample'});
    }

    close NEWF;
    print STDERR "$conf file has been created\n";
}

sub edit_configuration {
    require Conf;

    my $new_wwsympa_conf = '/tmp/wwsympa.conf';
    my $new_sympa_conf = '/tmp/sympa.conf';
    my $wwsconf = {};
    my $somechange = 0;

    ## Load config 
    unless ($wwsconf = wwslib::load_config($wwsympa_conf)) {
        die("Unable to load config file $wwsympa_conf");
    }

    ## Load sympa config
    unless (Conf::load( $sympa_conf )) {
        die("Unable to load sympa config file $sympa_conf");
    }

    my (@new_wwsympa_conf, @new_sympa_conf);

    ## Edition mode
    foreach my $param (@Conf::params) {
        my $desc;

        if ($param->{'title'}) {
            my $title = $param->{'title'};
            printf "\n\n** $title **\n";

            ## write to conf file
            push @new_wwsympa_conf,
                sprintf "###\\\\\\\\ %s ////###\n\n", $param->{'title'};
            push @new_sympa_conf,
                sprintf "###\\\\\\\\ %s ////###\n\n", $param->{'title'};

            next;
        }    

        my $file = $param->{'file'} ;
        my $name = $param->{'name'} ; 
        my $query = $param->{'query'} ;
        my $advice = $param->{'advice'} ;
        my $sample = $param->{'sample'} ;
        my $current_value ;
        if ($file eq 'wwsympa.conf') {	
            $current_value = $wwsconf->{$name} ;
        } elsif ($file eq 'sympa.conf') {
            $current_value = $Conf::Conf{$name}; 
        } else {
            printf STDERR "incorrect definition of $name\n";
        }
        my $new_value;
        if ($param->{'edit'} eq '1') {
            printf "... $advice\n" unless ($advice eq '') ;
            printf "$name: $query \[$current_value\] : ";
            $new_value = <STDIN> ;
            chomp $new_value;
        }
        if ($new_value eq '') {
            $new_value = $current_value;
        }

        ## SKip empty parameters
        next if (($new_value eq '') &&
            ! $sample);

        ## param is an ARRAY
        if (ref($new_value) eq 'ARRAY') {
            $new_value = join ',',@{$new_value};
        }

        if ($file eq 'wwsympa.conf') {
            $desc = \@new_wwsympa_conf;
        }elsif ($file eq 'sympa.conf') {
            $desc = \@new_sympa_conf;
        }else{
            printf STDERR "incorrect parameter $name definition \n";
        }

        if ($new_value eq '') {
            next unless $sample;

            push @{$desc}, sprintf "## $query\n";

            unless ($advice eq '') {
                push @{$desc}, sprintf "## $advice\n";
            }

            push @{$desc}, sprintf "# $name\t$sample\n\n";
        }else {
            push @{$desc}, sprintf "## $query\n";
            unless ($advice eq '') {
                push @{$desc}, sprintf "## $advice\n";
            }

            if ($current_value ne $new_value) {
                push @{$desc}, sprintf "# was $name $current_value\n";
                $somechange = 1;
            }

            push @{$desc}, sprintf "$name\t$new_value\n\n";
        }
    }

    if ($somechange) {

        my $date = strftime("%d.%b.%Y-%H.%M.%S", localtime(time));

        ## Keep old config files
        unless (rename $wwsympa_conf, $wwsympa_conf.'.'.$date) {
            warn "Unable to rename $wwsympa_conf : $!";
        }

        unless (rename $sympa_conf, $sympa_conf.'.'.$date) {
            warn "Unable to rename $sympa_conf : $!";
        }

        ## Write new config files
        unless (open (WWSYMPA,"> $wwsympa_conf")){
            die "unable to open $new_wwsympa_conf : $!";
        };

        unless (open (SYMPA,"> $sympa_conf")){
            die "unable to open $new_sympa_conf : $!";
        };

        print SYMPA @new_sympa_conf;
        print WWSYMPA @new_wwsympa_conf;

        close SYMPA;
        close WWSYMPA;

        printf "$sympa_conf and $wwsympa_conf have been updated.\nPrevious versions have been saved as $sympa_conf.$date and $wwsympa_conf.$date\n";
    }
}

sub check_cpan {
    require CPAN;

    ## assume version = 1.0 if not specified.
    ## 
    my %versions = (
        'perl' => '5.008',
        'Net::LDAP' =>, '0.27', 
        'perl-ldap' => '0.10',
        'Mail::Internet' => '1.51', 
        'DBI' => '1.48',
        'DBD::Pg' => '0.90',
        'DBD::Sybase' => '0.90',
        'DBD::mysql' => '2.0407',
        'FCGI' => '0.67',
        'HTML::StripScripts::Parser' => '1.0',
        'MIME::Tools' => '5.423',
        'File::Spec' => '0.8',
        'Crypt::CipherSaber' => '0.50',
        'CGI' => '3.35',
        'Digest::MD5' => '2.00',
        'DB_File' => '1.75',
        'IO::Socket::SSL' => '0.90',
        'Net::SSLeay' => '1.16',
        'Archive::Zip' => '1.05',
        'Bundle::LWP' => '1.09',
        'SOAP::Lite' => '0.60',
        'MHonArc::UTF8' => '2.6.0',
        'MIME::Base64' => '3.03',
        'MIME::Charset' => '0.04.1',
        'MIME::EncWords' => '0.040',
        'File::Copy::Recursive' => '0.36',
    );

    ### key:left "module" used by SYMPA, 
    ### right CPAN module.		     
    my %req_CPAN = (
        'DB_File' => 'DB_FILE',
        'Digest::MD5' => 'Digest-MD5',
        'Mail::Internet' =>, 'MailTools',
        'IO::Scalar' => 'IO-stringy',
        'MIME::Tools' => 'MIME-tools',
        'MIME::Base64' => 'MIME-Base64',
        'CGI' => 'CGI',
        'File::Spec' => 'File-Spec',
        'Regexp::Common' => 'Regexp-Common',
        'Locale::TextDomain' => 'libintl-perl',
        'Template' => 'Template-Toolkit',
        'Archive::Zip' => 'Archive-Zip',
        'LWP' => 'libwww-perl',
        'XML::LibXML' => 'XML-LibXML',
        'MHonArc::UTF8' => 'MHonArc',
        'FCGI' => 'FCGI',
        'DBI' => 'DBI',
        'DBD::mysql' => 'Msql-Mysql-modules',
        'Crypt::CipherSaber' => 'CipherSaber',
        'Encode' => 'Encode',
        'MIME::Charset' => 'MIME-Charset',
        'MIME::EncWords' => 'MIME-EncWords',
        'HTML::StripScripts::Parser' => 'HTML-StripScripts-Parser',
        'File::Copy::Recursive' => 'File-Copy-Recursive',
    );

    my %opt_CPAN = (
        'DBD::Pg' => 'DBD-Pg',
        'DBD::Oracle' => 'DBD-Oracle',
        'DBD::Sybase' => 'DBD-Sybase',
        'DBD::SQLite' => 'DBD-SQLite',
        'Net::LDAP' =>   'perl-ldap',
        'CGI::Fast' => 'CGI',
        'Net::SMTP' => 'libnet',
        'IO::Socket::SSL' => 'IO-Socket-SSL',
        'Net::SSLeay' => 'NET-SSLeay',
        'Bundle::LWP' => 'LWP',
        'SOAP::Lite' => 'SOAP-Lite',
        'File::NFSLock' => 'File-NFSLock',
        'File::Copy::Recursive' => 'File-Copy-Recursive',
    );

    my %opt_features = (
        'DBI' => 'a generic Database Driver, required by Sympa to access Subscriber information and User preferences. An additional Database Driver is required for each database type you wish to connect to.',
        'DBD::mysql' => 'Mysql database driver, required if you connect to a Mysql database.\nYou first need to install the Mysql server and have it started before installing the Perl DBD module.',
        'DBD::Pg' => 'PostgreSQL database driver, required if you connect to a PostgreSQL database.',
        'DBD::Oracle' => 'Oracle database driver, required if you connect to a Oracle database.',
        'DBD::Sybase' => 'Sybase database driver, required if you connect to a Sybase database.',
        'DBD::SQLite' => 'SQLite database driver, required if you connect to a SQLite database.',
        'Net::LDAP' =>   'required to query LDAP directories. Sympa can do LDAP-based authentication ; it can also build mailing lists with LDAP-extracted members.',
        'CGI::Fast' => 'WWSympa, Sympa\'s web interface can run as a FastCGI (ie: a persistent CGI). If you install this module, you will also need to install the associated mod_fastcgi for Apache.',
        'Crypt::CipherSaber' => 'this module provides reversible encryption of user passwords in the database.',
        'Archive::Zip ' => 'this module provides zip/unzip for archive and shared document download/upload',
        'FCGI' => 'WSympa, Sympa\'s web interface can run as a FastCGI (ie: a persistent CGI). If you install this module, you will also need to install the associated mod_fastcgi for Apache.',
        'Net::SMTP' => 'this is required if you set \'list_check_smtp\' sympa.conf parameter, used to check existing aliases before mailing list creation.',
        'IO::Socket::SSL' => 'required by CAS (single sign-on) and the \'include_remote_sympa_list\' feature that includes members of a list on a remote server, using X509 authentication',
        'Net::SSLeay' => 'required by the \'include_remote_sympa_list\' feature that includes members of a list on a remote server, using X509 authentication',
        'Bundle::LWP' => 'required by the \'include_remote_sympa_list\' feature that includes members of a list on a remote server, using X509 authentication',
        'SOAP::Lite' => 'required if you want to run the Sympa SOAP server that provides ML services via a "web service"',
        'File::NFSLock' => 'required to perform NFS lock ; see also lock_method sympa.conf parameter'
    );

    ### main:
    print "******* Check perl for SYMPA ********\n";
    ### REQ perl version
    print "\nChecking for PERL version:\n-----------------------------\n";
    my $rpv = $versions{"perl"};
    if ($] >= $versions{"perl"}){
        print "your version of perl is OK ($]  >= $rpv)\n";
    }else {
        print "Your version of perl is TOO OLD ($]  < $rpv)\nPlease INSTALL a new one !\n";
    }

    print "\nChecking for REQUIRED modules:\n------------------------------------------\n";
    check_modules('y', \%req_CPAN, \%versions, \%opt_features);
    print "\nChecking for OPTIONAL modules:\n------------------------------------------\n";
    check_modules('n', \%opt_CPAN, \%versions, \%opt_features);

    print <<EOM;
******* NOTE *******
You can retrieve all theses modules from any CPAN server
(for example ftp://ftp.pasteur.fr/pub/computing/CPAN/CPAN.html)
EOM
###--------------------------
# reports modules status
###--------------------------
}

sub check_modules {
    my($default, $todo, $versions, $opt_features) = @_;

    print "perl module          from CPAN       STATUS\n"; 
    print "-----------          ---------       ------\n";

    require UNIVERSAL::require;

    foreach my $mod (sort keys %$todo) {
        printf ("%-20s %-15s", $mod, $todo->{$mod});

        if ($mod->require()) {
            my $vs = "$mod" . "::VERSION";

            $vs = 'mhonarc::VERSION' if $mod =~ /^mhonarc/i;

            my $v;
            {
                no strict 'refs';
                $v = $$vs;
            }
            my $rv = $versions->{$mod} || "1.0" ;
            ### OK: check version
            if ($v ge $rv) {
                printf ("OK (%-6s >= %s)\n", $v, $rv);
                next;
            } else {
                print "version is too old ($v < $rv).\n";
                print ">>>>>>> You must update \"$todo->{$mod}\" to version \"$versions->{$todo->{$mod}}\" <<<<<<.\n";
                install_module($mod, {'default' => $default}, $opt_features);
            }
        } else {
            ### not installed
            print "was not found on this system.\n";
            install_module($mod, {'default' => $default});

        } 
    }
}

##----------------------
# Install a CPAN module
##----------------------
sub install_module {
    my ($module, $options, $opt_features) = @_;

    my $default = $options->{'default'};

    unless ($ENV{'FTP_PASSIVE'} eq 1) {
        $ENV{'FTP_PASSIVE'} = 1;
        print "Setting FTP Passive mode\n";
    }

    ## This is required on RedHat 9 for DBD::mysql installation
    my $lang = $ENV{'LANG'};
    $ENV{'LANG'} = 'C' if ($ENV{'LANG'} =~ /UTF\-8/);

    unless ($EUID == 0) {
        print "\#\# You need root privileges to install $module module. \#\#\n";
        print "\#\# Press the Enter key to continue checking modules. \#\#\n";
        my $t = <STDIN>;
        return undef;
    }

    unless ($options->{'force'}) {
        printf "Description: %s\n", $opt_features->{$module};
        print "Install module $module ? [$default]";
        my $answer = <STDIN>; chomp $answer;
        $answer ||= $default;
        return unless ($answer =~ /^y$/i);
    }

    $CPAN::Config->{'inactivity_timeout'} = 4;
    $CPAN::Config->{'colorize_output'} = 1;

    #CPAN::Shell->clean($module) if ($options->{'force'});

    CPAN::Shell->make($module);

    if ($options->{'force'}) {
        CPAN::Shell->force('test', $module);
    }else {
        CPAN::Shell->test($module);
    }

    CPAN::Shell->install($module); ## Could use CPAN::Shell->force('install') if make test failed

    ## Check if module has been successfuly installed
    unless ($module->require()) {

        ## Prevent recusive calls if already in force mode
        if ($options->{'force'}) {
            print  "Installation of $module still FAILED. You should download the tar.gz from http://search.cpan.org and install it manually.";
            my $answer = <STDIN>;
        }else {
            print  "Installation of $module FAILED. Do you want to force the installation of this module? (y/N) ";
            my $answer = <STDIN>; chomp $answer;
            if ($answer =~ /^y/i) {
                install_module($module, {'force' => 1});
            }
        }
    }

    ## Restore lang
    $ENV{'LANG'} = $lang if (defined $lang);

}
