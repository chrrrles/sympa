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

use Carp qw(croak);
use Encode qw();
use English qw(-no_match_vars);
use HTML::StripScripts::Parser;
use MIME::Lite::HTML;

##use if (5.008 < $] && $] < 5.016), qw(Unicode::CaseFold fc);

use Sympa::Constants;
use Sympa::LockedFile;
use Sympa::Log::Syslog;
use Sympa::Tools::File;

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

## Returns an HTML::StripScripts::Parser object built with  the parameters
## provided as arguments.
sub _create_xss_parser {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG3, '(%s)', $robot);

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
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG3, '(string=%s, robot=%s)',
        $parameters{'string'}, $robot);

    unless (defined $parameters{'string'}) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, "No string provided.");
        return undef;
    }

    my $hss = _create_xss_parser('robot' => $robot);
    unless (defined $hss) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, "Can't create StripScript parser.");
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
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG3, '(file=%s, robot=%s)',
        $parameters{'file'}, $robot);

    unless (defined $parameters{'file'}) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, "No path to file provided.");
        return undef;
    }

    my $hss = _create_xss_parser('robot' => $robot);
    unless (defined $hss) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, "Can't create StripScript parser.");
        return undef;
    }
    $hss->parse_file($parameters{'file'});
    return $hss->filtered_document;
}

## Sanitize all values in the hash $var, starting from $level
sub sanitize_var {
    my %parameters = @_;
    my $robot      = $parameters{'robot'};
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG3, '(var=%s, level=%s, robot=%s)',
        $parameters{'var'}, $parameters{'level'}, $robot);
    unless (defined $parameters{'var'}) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'Missing var to sanitize.');
        return undef;
    }
    unless (defined $parameters{'htmlAllowedParam'}
        && $parameters{'htmlToFilter'}) {
        Sympa::Log::Syslog::do_log(
            Sympa::Log::Syslog::ERR,
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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
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
    my ($msg, $sender) = @_;

    my $i;

    ## Check for commands in the subject.
    my $subject = $msg->head->get('Subject');
    chomp $subject if $subject;

    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG3,
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
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
                'Unable to read %s/cookies.history',
                Sympa::Site->etc);
            return undef;
        }
        my $oldcook = <COOK>;
        close COOK;

        my @cookies = split(/\s+/, $oldcook);

        if ($cookies[$#cookies] eq $current) {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2, "cookie is stable");
            $changed = 0;

            #	}else{
            #	    push @cookies, $current ;
            #	    unless (open COOK, '>', Sympa::Site->etc . '/cookies.history') {
            #		Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
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
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::NOTICE, "Renaming %s to %s",
            $orig_f, $new_f);
        unless (rename $orig_f, $new_f) {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
                'Failed to rename %s to %s : %s',
                $orig_f, $new_f, $ERRNO);
            next;
        }
        $count++;
    }

    return $count;
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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, "Invalid email address '%s'",
            $email);
        return undef;
    }

    ## Forbidden characters
    if ($email =~ /[\|\$\*\?\!]/) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, "Invalid email address '%s'",
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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, "Unable to open '%s' : %s",
            $file, $ERRNO);
        next;
    }
    my @content = <FILE>;
    close FILE;

    unless (open FILE, ">$file") {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, "Unable to open '%s' : %s",
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

sub add_in_blacklist {
    my $entry = shift;
    my $robot = shift;
    my $list  = shift;

    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
        "Sympa::Tools::add_in_blacklist(%s,%s,%s)",
        $entry, $robot, $list->name);
    $entry = lc($entry);
    chomp $entry;

    # robot blacklist not yet available
    unless ($list) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
            "Sympa::Tools::add_in_blacklist: robot blacklist not yet availible, missing list parameter"
        );
        return undef;
    }
    unless (($entry) && ($robot)) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
            "Sympa::Tools::add_in_blacklist:  missing parameters");
        return undef;
    }
    if ($entry =~ /\*.*\*/) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
            "Sympa::Tools::add_in_blacklist: incorrect parameter $entry");
        return undef;
    }
    my $dir = $list->dir . '/search_filters';
    unless ((-d $dir) || mkdir($dir, 0755)) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
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
                Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::NOTICE,
                    'do_blacklist : %s already in blacklist(%s)',
                    $entry, $_);
                return 0;
            }
        }
        close BLACKLIST;
    }
    unless (open BLACKLIST, ">> $file") {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO, 'do_blacklist : append to file %s',
            $file);
        return undef;
    }
    print BLACKLIST "$entry\n";
    close BLACKLIST;
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
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG, "Creating HTML MIME part. Source: %s",
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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR,
            'Unable to convert file %s to a MIME part',
            $param->{'source'});
        return undef;
    }
    return $part->as_string();
}

1;
