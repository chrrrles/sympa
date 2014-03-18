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

package Sympa::Tools;

use strict;
use English qw(-no_match_vars);
use Carp qw(croak);
use Time::Local;
use File::Find;
use Digest::MD5;
use HTML::StripScripts::Parser;
use File::Copy::Recursive;
use POSIX qw(strftime mkfifo strtod);
use Sys::Hostname;
use Mail::Header;
use Encode::Guess;    ## Useful when encoding should be guessed
use Encode::MIME::Header;
use Text::LineFold;
use MIME::Lite::HTML;
use Proc::ProcessTable;
##use if (5.008 < $] && $] < 5.016), qw(Unicode::CaseFold fc);

use Sympa::Conf;
use Sympa::Language;
use Sympa::LockedFile;
##use Sympa::Log::Syslog;
##use Sympa::Constants;
use Sympa::Message;
use Sympa::Tools::File;
##use Sympa::DatabaseManager;

## global var to store a CipherSaber object
my $cipher;

my $separator =
    "------- CUT --- CUT --- CUT --- CUT --- CUT --- CUT --- CUT -------";

## Regexps for list params
## Caution : if this regexp changes (more/less parenthesis), then regexp using
## it should
## also be changed
my $time_regexp       = '[012]?[0-9](?:\:[0-5][0-9])?';
my $time_range_regexp = $time_regexp . '-' . $time_regexp;
my %regexp            = (
    'email'       => '([\w\-\_\.\/\+\=\'\&]+|\".*\")\@[\w\-]+(\.[\w\-]+)+',
    'family_name' => '[a-z0-9][a-z0-9\-\.\+_]*',
    'template_name' => '[a-zA-Z0-9][a-zA-Z0-9\-\.\+_\s]*',    ## Allow \s
    'host'          => '[\w\.\-]+',
    'multiple_host_with_port' => '[\w\.\-]+(:\d+)?(,[\w\.\-]+(:\d+)?)*',
    'listname'                => '[a-z0-9][a-z0-9\-\.\+_]{0,49}',
    'sql_query'               => '(SELECT|select).*',
    'scenario'                => '[\w,\.\-]+',
    'task'                    => '\w+',
    'datasource'              => '[\w-]+',
    'uid'                     => '[\w\-\.\+]+',
    'time'                    => $time_regexp,
    'time_range'              => $time_range_regexp,
    'time_ranges'             => $time_range_regexp 
        . '(?:\s+'
        . $time_range_regexp . ')*',
    're' =>
        '(?i)(?:AW|(?:\xD0\x9D|\xD0\xBD)(?:\xD0\x90|\xD0\xB0)|Re(?:\^\d+|\*\d+|\*\*\d+|\[\d+\])?|Rif|SV|VS)\s*:',
);

my %openssl_errors = (
    1 => 'an error occurred parsing the command options',
    2 => 'one of the input files could not be read',
    3 =>
        'an error occurred creating the PKCS#7 file or when reading the MIME message',
    4 => 'an error occurred decrypting or verifying the message',
    5 =>
        'the message was verified correctly but an error occurred writing out the signers certificates'
);

## Returns an HTML::StripScripts::Parser object built with  the parameters
## provided as arguments.
sub _create_xss_parser {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Sympa::Log::Syslog::do_log('debug3', '(%s)', $robot);

    my $http_host_re = $robot->http_host;
    $http_host_re =~ s/([^\s\w\x80-\xFF])/\\$1/g;
    my $hss = HTML::StripScripts::Parser->new(
        {   Context  => 'Document',
            AllowSrc => 1,
            Rules    => {'*' => {src => qr{^http://$http_host_re},},},
        }
    );
    return $hss;
}

## Returns sanitized version (using StripScripts) of the string provided as
## argument.
sub sanitize_html {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Sympa::Log::Syslog::do_log('debug3', '(string=%s, robot=%s)',
        $parameters{'string'}, $robot);

    unless (defined $parameters{'string'}) {
        Sympa::Log::Syslog::do_log('err', "No string provided.");
        return undef;
    }

    my $hss = _create_xss_parser('robot' => $robot);
    unless (defined $hss) {
        Sympa::Log::Syslog::do_log('err', "Can't create StripScript parser.");
        return undef;
    }
    my $string = $hss->filter_html($parameters{'string'});
    return $string;
}

## Returns sanitized version (using StripScripts) of the content of the file
## whose path is provided as argument.
sub sanitize_html_file {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Sympa::Log::Syslog::do_log('debug3', '(file=%s, robot=%s)',
        $parameters{'file'}, $robot);

    unless (defined $parameters{'file'}) {
        Sympa::Log::Syslog::do_log('err', "No path to file provided.");
        return undef;
    }

    my $hss = _create_xss_parser('robot' => $robot);
    unless (defined $hss) {
        Sympa::Log::Syslog::do_log('err', "Can't create StripScript parser.");
        return undef;
    }
    $hss->parse_file($parameters{'file'});
    return $hss->filtered_document;
}

## Sanitize all values in the hash $var, starting from $level
sub sanitize_var {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Sympa::Log::Syslog::do_log('debug3', '(var=%s, level=%s, robot=%s)',
        $parameters{'var'}, $parameters{'level'}, $robot);
    unless (defined $parameters{'var'}) {
        Sympa::Log::Syslog::do_log('err', 'Missing var to sanitize.');
        return undef;
    }
    unless (defined $parameters{'htmlAllowedParam'}
        && $parameters{'htmlToFilter'}) {
        Sympa::Log::Syslog::do_log(
            'err',
            'Missing var *** %s *** %s *** to ignore.',
            $parameters{'htmlAllowedParam'},
            $parameters{'htmlToFilter'}
        );
        return undef;
    }
    my $level = $parameters{'level'};
    $level |= 0;

    if (ref($parameters{'var'})) {
        if (ref($parameters{'var'}) eq 'ARRAY') {
            foreach my $index (0 .. $#{$parameters{'var'}}) {
                if (   (ref($parameters{'var'}->[$index]) eq 'ARRAY')
                    || (ref($parameters{'var'}->[$index]) eq 'HASH')) {
                    sanitize_var(
                        'var'              => $parameters{'var'}->[$index],
                        'level'            => $level + 1,
                        'robot'            => $robot,
                        'htmlAllowedParam' => $parameters{'htmlAllowedParam'},
                        'htmlToFilter'     => $parameters{'htmlToFilter'},
                    );
                } elsif (ref($parameters{'var'}->[$index])) {
                    $parameters{'var'}->[$index] =
                        ref($parameters{'var'}->[$index]);
                } elsif (defined $parameters{'var'}->[$index]) {
                    $parameters{'var'}->[$index] =
                        escape_html($parameters{'var'}->[$index]);
                }
            }
        } elsif (ref($parameters{'var'}) eq 'HASH') {
            foreach my $key (keys %{$parameters{'var'}}) {
                if (   (ref($parameters{'var'}->{$key}) eq 'ARRAY')
                    || (ref($parameters{'var'}->{$key}) eq 'HASH')) {
                    sanitize_var(
                        'var'              => $parameters{'var'}->{$key},
                        'level'            => $level + 1,
                        'robot'            => $robot,
                        'htmlAllowedParam' => $parameters{'htmlAllowedParam'},
                        'htmlToFilter'     => $parameters{'htmlToFilter'},
                    );
                } elsif (ref($parameters{'var'}->{$key})) {
                    $parameters{'var'}->{$key} =
                        ref($parameters{'var'}->{$key});
                } elsif (defined $parameters{'var'}->{$key}) {
                    unless ($parameters{'htmlAllowedParam'}{$key}
                        or $parameters{'htmlToFilter'}{$key}) {
                        $parameters{'var'}->{$key} =
                            escape_html($parameters{'var'}->{$key});
                    }
                    if ($parameters{'htmlToFilter'}{$key}) {
                        $parameters{'var'}->{$key} = sanitize_html(
                            'string' => $parameters{'var'}->{$key},
                            'robot'  => $robot
                        );
                    }
                }

            }
        }
    } else {
        Sympa::Log::Syslog::do_log('err',
            'Variable is neither a hash nor an array.');
        return undef;
    }
    return 1;
}

## Sort subroutine to order files in sympa spool by date
sub by_date {
    my @a_tokens = split /\./, $a;
    my @b_tokens = split /\./, $b;

    ## File format : list@dom.date.pid
    my $a_time = $a_tokens[$#a_tokens - 1];
    my $b_time = $b_tokens[$#b_tokens - 1];

    return $a_time <=> $b_time;

}

## Safefork does several tries before it gives up.
## Do 3 trials and wait 10 seconds * $i between each.
## Exit with a fatal error is fork failed after all
## tests have been exhausted.
sub safefork {
    my ($i, $pid);

    my $err;
    for ($i = 1; $i < 4; $i++) {
        my ($pid) = fork;
        return $pid if (defined($pid));

        $err = $ERRNO;
        Sympa::Log::Syslog::do_log('warn',
            'Cannot create new process in safefork: %s', $err);
        ## FIXME:should send a mail to the listmaster
        sleep(10 * $i);
    }
    croak sprintf('Exiting because cannot create new process in safefork: %s',
        $err);
    ## No return.
}

####################################################
# checkcommand
####################################################
# Checks for no command in the body of the message.
# If there are some command in it, it return true
# and send a message to $sender
#
# IN : -$msg (+): ref(MIME::Entity) - message to check
#      -$sender (+): the sender of $msg
#      -$robot (+) : robot
#
# OUT : -1 if there are some command in $msg
#       -0 else
#
######################################################
sub checkcommand {
    my ($msg, $sender, $robot) = @_;

    my ($avoid, $i);

    ## Check for commands in the subject.
    my $subject = $msg->head->get('Subject');
    chomp $subject if $subject;

    Sympa::Log::Syslog::do_log('debug3',
        'Sympa::Tools::checkcommand(msg->head->get(subject): %s,%s)',
        $subject, $sender);

    if ($subject) {
        if (Sympa::Site->misaddressed_commands_regexp) {
            my $misaddressed_commands_regexp =
                Sympa::Site->misaddressed_commands_regexp;
            if ($subject =~ /^$misaddressed_commands_regexp\b/im) {
                return 1;
            }
        }
    }

    return 0 if ($#{$msg->body} >= 5);    ## More than 5 lines in the text.

    foreach $i (@{$msg->body}) {
        if (Sympa::Site->misaddressed_commands_regexp) {
            my $misaddressed_commands_regexp =
                Sympa::Site->misaddressed_commands_regexp;
            if ($i =~ /^$misaddressed_commands_regexp\b/im) {
                return 1;
            }
        }

        ## Control is only applied to first non-blank line
        last unless $i =~ /^\s*$/;
    }
    return 0;
}

## return a hash from the edit_list_conf file
## NOTE: this might be moved to List only where this is used.
sub load_edit_list_conf {
    Sympa::Log::Syslog::do_log('debug2', '(%s)', @_);
    my $self  = shift;
    my $robot = $self->robot;

    my $file;
    my $conf;

    return undef
        unless ($file = $self->get_etc_filename('edit_list.conf'));

    my $fh;
    unless (open $fh, '<', $file) {
        Sympa::Log::Syslog::do_log('info', 'Unable to open config file %s',
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
                    Sympa::Log::Syslog::do_log('notice',
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
            Sympa::Log::Syslog::do_log('info',
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

## return a hash from the edit_list_conf file
## NOTE: This might be moved to wwslib along with get_list_list_tpl().
sub load_create_list_conf {
    my $robot = Sympa::Robot::clean_robot(shift);

    my $file;
    my $conf;

    $file = $robot->get_etc_filename('create_list.conf');
    unless ($file) {
        Sympa::Log::Syslog::do_log(
            'info',
            'unable to read %s',
            Sympa::Constants::DEFAULTDIR . '/create_list.conf'
        );
        return undef;
    }

    unless (open(FILE, $file)) {
        Sympa::Log::Syslog::do_log('info', 'Unable to open config file %s',
            $file);
        return undef;
    }

    while (<FILE>) {
        next if /^\s*(\#.*|\s*)$/;

        if (/^\s*(\S+)\s+(read|hidden)\s*$/i) {
            $conf->{$1} = lc($2);
        } else {
            Sympa::Log::Syslog::do_log('info',
                'unknown parameter in %s  (Ignored) %s',
                $file, $_);
            next;
        }
    }

    close FILE;
    return $conf;
}

## NOTE: This might be moved to wwslib.
sub get_list_list_tpl {
    my $robot = Sympa::Robot::clean_robot(shift);

    my $list_conf;
    my $list_templates;
    unless ($list_conf = load_create_list_conf($robot)) {
        return undef;
    }

    foreach my $dir (
        reverse @{$robot->get_etc_include_path('create_list_templates')}) {
        if (opendir(DIR, $dir)) {
            foreach my $template (sort grep (!/^\./, readdir(DIR))) {

                my $status = $list_conf->{$template}
                    || $list_conf->{'default'};

                next if ($status eq 'hidden');

                $list_templates->{$template}{'path'} = $dir;

                my $locale =
                    Sympa::Language::Lang2Locale_old(
                    Sympa::Language::GetLang());
                ## FIXME: lang should be used instead of "locale".
                ## Look for a comment.tt2 in the appropriate locale first
                if (  -r $dir . '/'
                    . $template . '/'
                    . $locale
                    . '/comment.tt2') {
                    $list_templates->{$template}{'comment'} =
                        $template . '/' . $locale . '/comment.tt2';
                } elsif (-r $dir . '/' . $template . '/comment.tt2') {
                    $list_templates->{$template}{'comment'} =
                        $template . '/comment.tt2';
                }
            }
            closedir(DIR);
        }
    }

    return ($list_templates);
}

## NOTE: this might be moved to wwslib.
sub get_templates_list {

    my $type    = shift;
    my $robot   = shift;
    my $list    = shift;
    my $options = shift;

    my $listdir;

    Sympa::Log::Syslog::do_log('debug',
        "get_templates_list ($type, $robot, $list)");
    unless (($type eq 'web') || ($type eq 'mail')) {
        Sympa::Log::Syslog::do_log('info',
            'get_templates_list () : internal error incorrect parameter');
    }

    my $distrib_dir = Sympa::Constants::DEFAULTDIR . '/' . $type . '_tt2';
    my $site_dir    = Sympa::Site->etc . '/' . $type . '_tt2';
    my $robot_dir   = Sympa::Site->etc . '/' . $robot . '/' . $type . '_tt2';

    my @try;

    ## The 'ignore_global' option allows to look for files at list level only
    unless ($options->{'ignore_global'}) {
        push @try, $distrib_dir;
        push @try, $site_dir;
        push @try, $robot_dir;
    }

    if (defined $list) {
        $listdir = $list->dir . '/' . $type . '_tt2';
        push @try, $listdir;
    }

    my $i = 0;
    my $tpl;

    foreach my $dir (@try) {
        next unless opendir(DIR, $dir);
        foreach my $file (grep (!/^\./, readdir(DIR))) {
            ## Subdirectory for a lang
            if (-d $dir . '/' . $file) {
                my $lang_dir = $file;
                my $lang     = Sympa::Language::CanonicLang($lang_dir);
                next unless $lang;
                next unless opendir(LANGDIR, $dir . '/' . $lang_dir);

                foreach my $file (grep (!/^\./, readdir(LANGDIR))) {
                    next unless $file =~ /\.tt2$/;
                    if ($dir eq $distrib_dir) {
                        $tpl->{$file}{'distrib'}{$lang} =
                            $dir . '/' . $lang_dir . '/' . $file;
                    }
                    if ($dir eq $site_dir) {
                        $tpl->{$file}{'site'}{$lang} =
                            $dir . '/' . $lang_dir . '/' . $file;
                    }
                    if ($dir eq $robot_dir) {
                        $tpl->{$file}{'robot'}{$lang} =
                            $dir . '/' . $lang_dir . '/' . $file;
                    }
                    if ($dir eq $listdir) {
                        $tpl->{$file}{'list'}{$lang} =
                            $dir . '/' . $lang_dir . '/' . $file;
                    }
                }
                closedir LANGDIR;

            } else {
                next unless ($file =~ /\.tt2$/);
                if ($dir eq $distrib_dir) {
                    $tpl->{$file}{'distrib'}{'default'} = $dir . '/' . $file;
                }
                if ($dir eq $site_dir) {
                    $tpl->{$file}{'site'}{'default'} = $dir . '/' . $file;
                }
                if ($dir eq $robot_dir) {
                    $tpl->{$file}{'robot'}{'default'} = $dir . '/' . $file;
                }
                if ($dir eq $listdir) {
                    $tpl->{$file}{'list'}{'default'} = $dir . '/' . $file;
                }
            }
        }
        closedir DIR;
    }
    return ($tpl);

}

# return the path for a specific template
## NOTE: this might be moved to wwslib.
sub get_template_path {
    Sympa::Log::Syslog::do_log('debug2', '(%s, %s. %s, %s, %s, %s)', @_);
    my $type  = shift;
    my $robot = shift;
    my $scope = shift;
    my $tpl   = shift;
    my $lang  = shift || 'default';
    my $list  = shift;

    ##FIXME: path is fixed to older "locale".
    my $locale;
    $locale = Sympa::Language::Lang2Locale_old($lang)
        unless $lang eq 'default';

    unless ($type eq 'web' or $type eq 'mail') {
        Sympa::Log::Syslog::do_log('info',
            'internal error incorrect parameter');
        return undef;
    }

    my $dir;
    if ($scope eq 'list') {
        unless (ref $list) {
            Sympa::Log::Syslog::do_log('err', 'missing parameter "list"');
            return undef;
        }
        $dir = $list->dir;
    } elsif ($scope eq 'robot' and $robot->etc ne Sympa::Site->etc) {
        $dir = $robot->etc;
    } elsif ($scope eq 'site') {
        $dir = Sympa::Site->etc;
    } elsif ($scope eq 'distrib') {
        $dir = Sympa::Constants::DEFAULTDIR;
    } else {
        return undef;
    }

    $dir .= '/' . $type . '_tt2';
    $dir .= '/' . $locale unless $lang eq 'default';
    return $dir . '/' . $tpl;
}

## Escape characters before using a string within a regexp parameter
## Escaped characters are : @ $ [ ] ( ) ' ! '\' * . + ?
sub escape_regexp {
    my $s = shift;
    my @escaped =
        ("\\", '@', '$', '[', ']', '(', ')', "'", '!', '*', '.', '+', '?');
    my $backslash = "\\";    ## required in regexp

    foreach my $escaped_char (@escaped) {
        $s =~ s/$backslash$escaped_char/\\$escaped_char/g;
    }

    return $s;
}

## Escape weird characters
sub escape_chars {
    my $s          = shift;
    my $except     = shift;                               ## Exceptions
    my $ord_except = ord($except) if (defined $except);

    ## Escape chars
    ##  !"#$%&'()+,:;<=>?[] AND accented chars
    ## escape % first
    foreach my $i (
        0x25,
        0x20 .. 0x24,
        0x26 .. 0x2c,
        0x3a .. 0x3f,
        0x5b, 0x5d,
        0x80 .. 0x9f,
        0xa0 .. 0xff
        ) {
        next if ($i == $ord_except);
        my $hex_i = sprintf "%lx", $i;
        $s =~ s/\x$hex_i/%$hex_i/g;
    }
    $s =~ s/\//%a5/g unless ($except eq '/');    ## Special treatment for '/'

    return $s;
}

## Escape shared document file name
## Q-decode it first
sub escape_docname {
    my $filename = shift;
    my $except   = shift;                        ## Exceptions

    ## Q-decode
    $filename = MIME::EncWords::decode_mimewords($filename);

    ## Decode from FS encoding to utf-8
    #$filename = Encode::decode(Sympa::Site->filesystem_encoding, $filename);

    ## escape some chars for use in URL
    return escape_chars($filename, $except);
}

## Convert from Perl Unicode encoding to UTF-8
sub unicode_to_utf8 {
    my $s = shift;

    if (Encode::is_utf8($s)) {
        return Encode::encode_utf8($s);
    }

    return $s;
}

## Q-Encode web file name
sub qencode_filename {
    my $filename = shift;

    ## We don't use MIME::Words here because it does not encode properly
    ## Unicode
    ## Check if string is already Q-encoded first
    ## Also check if the string contains 8bit chars
    unless ($filename =~ /\=\?UTF-8\?/
        || $filename =~ /^[\x00-\x7f]*$/) {

        ## Don't encode elements such as .desc. or .url or .moderate
        ## or .extension
        my $part = $filename;
        my ($leading, $trailing);
        $leading  = $1 if ($part =~ s/^(\.desc\.)//);    ## leading .desc
        $trailing = $1 if ($part =~ s/((\.\w+)+)$//);    ## trailing .xx

        my $encoded_part = MIME::EncWords::encode_mimewords(
            $part,
            Charset    => 'utf8',
            Encoding   => 'q',
            MaxLineLen => 1000,
            Minimal    => 'NO'
        );

        $filename = $leading . $encoded_part . $trailing;
    }

    return $filename;
}

## Q-Decode web file name
sub qdecode_filename {
    my $filename = shift;

    ## We don't use MIME::Words here because it does not encode properly
    ## Unicode
    ## Check if string is already Q-encoded first
    #if ($filename =~ /\=\?UTF-8\?/) {
    $filename = Encode::encode_utf8(Encode::decode('MIME-Q', $filename));

    #}

    return $filename;
}

## Unescape weird characters
sub unescape_chars {
    my $s = shift;

    $s =~ s/%a5/\//g;    ## Special treatment for '/'
    foreach my $i (0x20 .. 0x2c, 0x3a .. 0x3f, 0x5b, 0x5d, 0x80 .. 0x9f,
        0xa0 .. 0xff) {
        my $hex_i = sprintf "%lx", $i;
        my $hex_s = sprintf "%c",  $i;
        $s =~ s/%$hex_i/$hex_s/g;
    }

    return $s;
}

sub escape_html {
    my $s = shift;

    $s =~ s/\"/\&quot\;/gm;
    $s =~ s/\</&lt\;/gm;
    $s =~ s/\>/&gt\;/gm;

    return $s;
}

sub unescape_html {
    my $s = shift;

    $s =~ s/\&quot\;/\"/g;
    $s =~ s/&lt\;/\</g;
    $s =~ s/&gt\;/\>/g;

    return $s;
}

# create a cipher
sub cookie_changed {
    my $current = shift;
    my $changed = 1;
    if (-f Sympa::Site->etc . '/cookies.history') {
        unless (open COOK, '<', Sympa::Site->etc . '/cookies.history') {
            Sympa::Log::Syslog::do_log('err',
                'Unable to read %s/cookies.history',
                Sympa::Site->etc);
            return undef;
        }
        my $oldcook = <COOK>;
        close COOK;

        my @cookies = split(/\s+/, $oldcook);

        if ($cookies[$#cookies] eq $current) {
            Sympa::Log::Syslog::do_log('debug2', "cookie is stable");
            $changed = 0;

            #	}else{
            #	    push @cookies, $current ;
            #	    unless (open COOK, '>', Sympa::Site->etc . '/cookies.history') {
            #		Sympa::Log::Syslog::do_log('err',
            #		"Unable to create %s/cookies.history", Sympa::Site->etc);
            #		return undef ;
            #	    }
            #	    print COOK join(" ", @cookies);
            #
            #	    close COOK;
        }
        return $changed;
    } else {
        my $umask = umask 037;
        unless (open COOK, '>', Sympa::Site->etc . '/cookies.history') {
            umask $umask;
            Sympa::Log::Syslog::do_log('err',
                'Unable to create %s/cookies.history',
                Sympa::Site->etc);
            return undef;
        }
        umask $umask;
        chown [getpwnam(Sympa::Constants::USER)]->[2],
            [getgrnam(Sympa::Constants::GROUP)]->[2],
            Sympa::Site->etc . '/cookies.history';
        print COOK "$current ";
        close COOK;
        return (0);
    }
}

sub load_mime_types {
    my $types = {};

    my @localisation = (
        '/etc/mime.types',            '/usr/local/apache/conf/mime.types',
        '/etc/httpd/conf/mime.types', 'mime.types'
    );

    foreach my $loc (@localisation) {
        next unless (-r $loc);

        unless (open(CONF, $loc)) {
            print STDERR "load_mime_types: unable to open $loc\n";
            return undef;
        }
    }

    while (<CONF>) {
        next if /^\s*\#/;

        if (/^(\S+)\s+(.+)\s*$/i) {
            my ($k, $v) = ($1, $2);

            my @extensions = split / /, $v;

            ## provides file extension, given the content-type
            if ($#extensions >= 0) {
                $types->{$k} = $extensions[0];
            }

            foreach my $ext (@extensions) {
                $types->{$ext} = $k;
            }
            next;
        }
    }

    close FILE;
    return $types;
}

## Q-encode a complete file hierarchy
## Useful to Q-encode subshared documents
sub qencode_hierarchy {
    my $dir = shift;    ## Root directory
    my $original_encoding =
        shift;          ## Suspected original encoding of file names

    my $count;
    my @all_files;
    Sympa::Tools::File::list_dir($dir, \@all_files, $original_encoding);

    foreach my $f_struct (reverse @all_files) {

        ## At least one 8bit char
        next
            unless ($f_struct->{'filename'} =~ /[^\x00-\x7f]/);

        my $new_filename = $f_struct->{'filename'};
        my $encoding     = $f_struct->{'encoding'};
        Encode::from_to($new_filename, $encoding, 'utf8') if $encoding;

        ## Q-encode file name to escape chars with accents
        $new_filename = Sympa::Tools::qencode_filename($new_filename);

        my $orig_f = $f_struct->{'directory'} . '/' . $f_struct->{'filename'};
        my $new_f  = $f_struct->{'directory'} . '/' . $new_filename;

        ## Rename the file using utf8
        Sympa::Log::Syslog::do_log('notice', "Renaming %s to %s",
            $orig_f, $new_f);
        unless (rename $orig_f, $new_f) {
            Sympa::Log::Syslog::do_log('err',
                'Failed to rename %s to %s : %s',
                $orig_f, $new_f, $ERRNO);
            next;
        }
        $count++;
    }

    return $count;
}

# input user agent string and IP. return 1 if suspected to be a crawler.
# initial version based on crawlers_detection.conf file only
# later : use Session table to identify those who create a lot of sessions
##FIXME:per-robot config should be available.
sub is_a_crawler {
    my $robot = shift;
    my $context = shift || {};

    return Sympa::Site->crawlers_detection->{'user_agent_string'}
        {$context->{'user_agent_string'} || ''};
}

sub get_message_id {
    my $robot = shift;
    my $domain;
    unless ($robot) {
        $domain = Sympa::Site->domain;
    } elsif (ref $robot and ref $robot eq 'Sympa::Robot') {
        $domain = $robot->domain;
    } elsif ($robot eq 'Site') {
        $domain = Sympa::Site->domain;
    } else {
        $domain = $robot;
    }
    my $id = sprintf '<sympa.%d.%d.%d@%s>', time, $PID, int(rand(999)),
        $domain;

    return $id;
}

## Basic check of an email address
sub valid_email {
    my $email = shift;

    unless (defined $email and $email =~ /^$regexp{'email'}$/) {
        Sympa::Log::Syslog::do_log('err', "Invalid email address '%s'",
            $email);
        return undef;
    }

    ## Forbidden characters
    if ($email =~ /[\|\$\*\?\!]/) {
        Sympa::Log::Syslog::do_log('err', "Invalid email address '%s'",
            $email);
        return undef;
    }

    return 1;
}

## Clean email address
sub clean_email {
    my $email = shift;

    ## Lower-case
    $email = lc($email);

    ## remove leading and trailing spaces
    $email =~ s/^\s*//;
    $email =~ s/\s*$//;

    return $email;
}

## Return canonical email address (lower-cased + space cleanup)
## It could also support alternate email
sub get_canonical_email {
    my $email = shift;

    ## Remove leading and trailing white spaces
    $email =~ s/^\s*(\S.*\S)\s*$/$1/;

    ## Lower-case
    $email = lc($email);

    return $email;
}

####################################################
# clean_msg_id
####################################################
# clean msg_id to use it without  \n, \s or <,>
#
# IN : -$msg_id (+) : the msg_id
#
# OUT : -$msg_id : the clean msg_id
#
######################################################
sub clean_msg_id {
    my $msg_id = shift;

    chomp $msg_id;

    if ($msg_id =~ /\<(.+)\>/) {
        $msg_id = $1;
    }

    return $msg_id;
}

## Change X-Sympa-To: header field in the message
sub change_x_sympa_to {
    my ($file, $value) = @_;

    ## Change X-Sympa-To
    unless (open FILE, $file) {
        Sympa::Log::Syslog::do_log('err', "Unable to open '%s' : %s",
            $file, $ERRNO);
        next;
    }
    my @content = <FILE>;
    close FILE;

    unless (open FILE, ">$file") {
        Sympa::Log::Syslog::do_log('err', "Unable to open '%s' : %s",
            "$file", $ERRNO);
        next;
    }
    foreach (@content) {
        if (/^X-Sympa-To:/i) {
            $_ = "X-Sympa-To: $value\n";
        }
        print FILE;
    }
    close FILE;

    return 1;
}

## Compare 2 versions of Sympa
sub lower_version {
    my ($v1, $v2) = @_;

    my @tab1 = split /\./, $v1;
    my @tab2 = split /\./, $v2;

    my $max = $#tab1;
    $max = $#tab2 if ($#tab2 > $#tab1);

    for my $i (0 .. $max) {

        if ($tab1[0] =~ /^(\d*)a$/) {
            $tab1[0] = $1 - 0.5;
        } elsif ($tab1[0] =~ /^(\d*)b$/) {
            $tab1[0] = $1 - 0.25;
        }

        if ($tab2[0] =~ /^(\d*)a$/) {
            $tab2[0] = $1 - 0.5;
        } elsif ($tab2[0] =~ /^(\d*)b$/) {
            $tab2[0] = $1 - 0.25;
        }

        if ($tab1[0] eq $tab2[0]) {

            #printf "\t%s = %s\n",$tab1[0],$tab2[0];
            shift @tab1;
            shift @tab2;
            next;
        }
        return ($tab1[0] < $tab2[0]);
    }

    return 0;
}

sub add_in_blacklist {
    my $entry = shift;
    my $robot = shift;
    my $list  = shift;

    Sympa::Log::Syslog::do_log('info',
        "Sympa::Tools::add_in_blacklist(%s,%s,%s)",
        $entry, $robot, $list->name);
    $entry = lc($entry);
    chomp $entry;

    # robot blacklist not yet available
    unless ($list) {
        Sympa::Log::Syslog::do_log('info',
            "Sympa::Tools::add_in_blacklist: robot blacklist not yet availible, missing list parameter"
        );
        return undef;
    }
    unless (($entry) && ($robot)) {
        Sympa::Log::Syslog::do_log('info',
            "Sympa::Tools::add_in_blacklist:  missing parameters");
        return undef;
    }
    if ($entry =~ /\*.*\*/) {
        Sympa::Log::Syslog::do_log('info',
            "Sympa::Tools::add_in_blacklist: incorrect parameter $entry");
        return undef;
    }
    my $dir = $list->dir . '/search_filters';
    unless ((-d $dir) || mkdir($dir, 0755)) {
        Sympa::Log::Syslog::do_log('info',
            'do_blacklist : unable to create directory %s', $dir);
        return undef;
    }
    my $file = $dir . '/blacklist.txt';

    if (open BLACKLIST, "$file") {
        while (<BLACKLIST>) {
            next if (/^\s*$/o || /^[\#\;]/o);
            my $regexp = $_;
            chomp $regexp;
            $regexp =~ s/\*/.*/;
            $regexp = '^' . $regexp . '$';
            if ($entry =~ /$regexp/i) {
                Sympa::Log::Syslog::do_log('notice',
                    'do_blacklist : %s already in blacklist(%s)',
                    $entry, $_);
                return 0;
            }
        }
        close BLACKLIST;
    }
    unless (open BLACKLIST, ">> $file") {
        Sympa::Log::Syslog::do_log('info', 'do_blacklist : append to file %s',
            $file);
        return undef;
    }
    print BLACKLIST "$entry\n";
    close BLACKLIST;

}

############################################################
#  md5_fingerprint                                         #
############################################################
#  The algorithm MD5 (Message Digest 5) is a cryptographic #
#  hash function which permit to obtain                    #
#  the fingerprint of a file/data                          #
#                                                          #
# IN : a string                                            #
#                                                          #
# OUT : MD5 digest                                         #
#     | undef                                              #
#                                                          #
############################################################
sub md5_fingerprint {

    my $input_string = shift;
    return undef unless (defined $input_string);
    chomp $input_string;

    my $digestmd5 = Digest::MD5->new;
    $digestmd5->reset;
    $digestmd5->add($input_string);
    return (unpack("H*", $digestmd5->digest));
}

sub get_separator {
    return $separator;
}

## Return the Sympa regexp corresponding to the input param
sub get_regexp {
    my $type = shift;

    if (defined $regexp{$type}) {
        return $regexp{$type};
    } else {
        return '\w+';    ## default is a very strict regexp
    }

}

#*******************************************
# Function : addrencode
# Description : return formatted (and encoded) name-addr as RFC5322 3.4.
## IN : addr, [phrase, [charset]]
#*******************************************
sub addrencode {
    my $addr    = shift;
    my $phrase  = (shift || '');
    my $charset = (shift || 'utf8');

    return undef unless $addr =~ /\S/;

    if ($phrase =~ /[^\s\x21-\x7E]/) {
        $phrase = MIME::EncWords::encode_mimewords(
            Encode::decode('utf8', $phrase),
            'Encoding'    => 'A',
            'Charset'     => $charset,
            'Replacement' => 'FALLBACK',
            'Field'       => 'Resent-Sender',    # almost longest
            'Minimal'     => 'DISPNAME'
        );
        return "$phrase <$addr>";
    } elsif ($phrase =~ /\S/) {
        $phrase =~ s/([\\\"])/\\$1/g;
        return "\"$phrase\" <$addr>";
    } else {
        return "<$addr>";
    }
}

# Generate a newsletter from an HTML URL or a file path.
sub create_html_part_from_web_page {
    my $param = shift;
    Sympa::Log::Syslog::do_log('debug', "Creating HTML MIME part. Source: %s",
        $param->{'source'});
    my $mailHTML = MIME::Lite::HTML->new(
        {   From         => $param->{'From'},
            To           => $param->{'To'},
            Headers      => $param->{'Headers'},
            Subject      => $param->{'Subject'},
            HTMLCharset  => 'utf-8',
            TextCharset  => 'utf-8',
            TextEncoding => '8bit',
            HTMLEncoding => '8bit',
            remove_jscript => '1',    #delete the scripts in the html
        }
    );

    # parse return the MIME::Lite part to send
    my $part = $mailHTML->parse($param->{'source'});
    unless (defined($part)) {
        Sympa::Log::Syslog::do_log('err',
            'Unable to convert file %s to a MIME part',
            $param->{'source'});
        return undef;
    }
    return $part->as_string();
}

1;
