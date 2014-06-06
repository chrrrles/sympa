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

package Sympa::Tools::WWW;

use strict;

use English qw(-no_match_vars);

use Sympa::Constants;
use Sympa::Log::Syslog;
use Sympa::Language;
use Sympa::Site;

# hash of the icons linked with a type of file
my %icons = (
    'unknown'        => 'unknown.png',
    'folder'         => 'folder.png',
    'current_folder' => 'folder.open.png',
    'application'    => 'unknown.png',
    'octet-stream'   => 'binary.png',
    'audio'          => 'sound1.png',
    'image'          => 'image2.png',
    'text'           => 'text.png',
    'video'          => 'movie.png',
    'father'         => 'back.png',
    'sort'           => 'down.png',
    'url'            => 'link.png',
    'left'           => 'left.png',
    'right'          => 'right.png',
);

# lazy loading on demand
my %mime_types;

## Cookie expiration periods with corresponding entry in NLS
my %cookie_period = (
    0     => {'gettext_id' => "session"},
    10    => {'gettext_id' => "10 minutes"},
    30    => {'gettext_id' => "30 minutes"},
    60    => {'gettext_id' => "1 hour"},
    360   => {'gettext_id' => "6 hours"},
    1440  => {'gettext_id' => "1 day"},
    10800 => {'gettext_id' => "1 week"},
    43200 => {'gettext_id' => "30 days"}
);

## Filenames with corresponding entry in NLS set 15
my %filenames = (
    'welcome.tt2'       => {'gettext_id' => "welcome message"},
    'bye.tt2'           => {'gettext_id' => "unsubscribe message"},
    'removed.tt2'       => {'gettext_id' => "deletion message"},
    'message.footer'    => {'gettext_id' => "message footer"},
    'message.header'    => {'gettext_id' => "message header"},
    'remind.tt2'        => {'gettext_id' => "remind message"},
    'reject.tt2'        => {'gettext_id' => "editor rejection message"},
    'invite.tt2'        => {'gettext_id' => "subscribing invitation message"},
    'helpfile.tt2'      => {'gettext_id' => "help file"},
    'lists.tt2'         => {'gettext_id' => "directory of lists"},
    'global_remind.tt2' => {'gettext_id' => "global remind message"},
    'summary.tt2'       => {'gettext_id' => "summary message"},
    'info'              => {'gettext_id' => "list description"},
    'homepage'          => {'gettext_id' => "list homepage"},
    'create_list_request.tt2' =>
        {'gettext_id' => "list creation request message"},
    'list_created.tt2' =>
        {'gettext_id' => "list creation notification message"},
    'your_infected_msg.tt2' => {'gettext_id' => "virus infection message"},
    'list_aliases.tt2'      => {'gettext_id' => "list aliases template"}
);

my %task_flavours = (
    'daily'   => {'gettext_id' => 'daily'},
    'monthly' => {'gettext_id' => 'monthly'},
    'weekly'  => {'gettext_id' => 'weekly'},
);

## Defined in RFC 1893
my %bounce_status = (
    '1.0' => 'Other address status',
    '1.1' => 'Bad destination mailbox address',
    '1.2' => 'Bad destination system address',
    '1.3' => 'Bad destination mailbox address syntax',
    '1.4' => 'Destination mailbox address ambiguous',
    '1.5' => 'Destination mailbox address valid',
    '1.6' => 'Mailbox has moved',
    '1.7' => 'Bad sender\'s mailbox address syntax',
    '1.8' => 'Bad sender\'s system address',
    '2.0' => 'Other or undefined mailbox status',
    '2.1' => 'Mailbox disabled, not accepting messages',
    '2.2' => 'Mailbox full',
    '2.3' => 'Message length exceeds administrative limit',
    '2.4' => 'Mailing list expansion problem',
    '3.0' => 'Other or undefined mail system status',
    '3.1' => 'Mail system full',
    '3.2' => 'System not accepting network messages',
    '3.3' => 'System not capable of selected features',
    '3.4' => 'Message too big for system',
    '4.0' => 'Other or undefined network or routing status',
    '4.1' => 'No answer from host',
    '4.2' => 'Bad connection',
    '4.3' => 'Routing server failure',
    '4.4' => 'Unable to route',
    '4.5' => 'Network congestion',
    '4.6' => 'Routing loop detected',
    '4.7' => 'Delivery time expired',
    '5.0' => 'Other or undefined protocol status',
    '5.1' => 'Invalid command',
    '5.2' => 'Syntax error',
    '5.3' => 'Too many recipients',
    '5.4' => 'Invalid command arguments',
    '5.5' => 'Wrong protocol version',
    '6.0' => 'Other or undefined media error',
    '6.1' => 'Media not supported',
    '6.2' => 'Conversion required and prohibited',
    '6.3' => 'Conversion required but not supported',
    '6.4' => 'Conversion with loss performed',
    '6.5' => 'Conversion failed',
    '7.0' => 'Other or undefined security status',
    '7.1' => 'Delivery not authorized, message refused',
    '7.2' => 'Mailing list expansion prohibited',
    '7.3' => 'Security conversion required but not possible',
    '7.4' => 'Security features not supported',
    '7.5' => 'Cryptographic failure',
    '7.6' => 'Cryptographic algorithm not supported',
    '7.7' => 'Message integrity failure'
);

sub new_passwd {

    my $passwd;
    my $nbchar = int(rand 5) + 6;
    foreach my $i (0 .. $nbchar) {
        $passwd .= chr(int(rand 26) + ord('a'));
    }

    return 'init' . $passwd;
}

sub get_my_url {

    my $return_url;

    ## Mod_ssl sets SSL_PROTOCOL ; apache-ssl sets SSL_PROTOCOL_VERSION
    if ($ENV{'HTTPS'} eq 'on') {
        $return_url = 'https';
    } else {
        $return_url = 'http';
    }

    $return_url .= '://' . main::get_header_field('HTTP_HOST');
    $return_url .= ':' . $ENV{'SERVER_PORT'}
        unless (($ENV{'SERVER_PORT'} eq '80')
        || ($ENV{'SERVER_PORT'} eq '443'));
    $return_url .= $ENV{'REQUEST_URI'};
    return ($return_url);
}

# Uploade source file to the destination on the server
sub upload_file_to_server {
    my $param = shift;
    Sympa::Log::Syslog::do_log(
        Sympa::Log::Syslog::DEBUG,
        "Uploading file from field %s to destination %s",
        $param->{'file_field'},
        $param->{'destination'}
    );
    my $fh;
    unless ($fh = $param->{'query'}->upload($param->{'file_field'})) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG,
            "Cannot upload file from field $param->{'file_field'}");
        return undef;
    }

    unless (open FILE, ">:bytes", $param->{'destination'}) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG,
            "Cannot open file $param->{'destination'} : $ERRNO");
        return undef;
    }
    while (<$fh>) {
        print FILE;
    }
    close FILE;
    return 1;
}

## Useful function to get off the slash at the end of the path
## at its end
sub no_slash_end {
    my $path = shift;

    ## supress ending '/'
    $path =~ s/\/+$//;

    return $path;
}

## return a visible path from a moderated file or not
sub make_visible_path {
    my $path = shift;

    my $visible_path = $path;

    if ($path =~ /\.url(\.moderate)?$/) {
        if ($path =~ /^([^\/]*\/)*([^\/]+)\.([^\/]+)$/) {
            $visible_path =~ s/\.moderate$//;
            $visible_path =~ s/^\.//;
            $visible_path =~ s/\.url$//;
        }

    } elsif ($path =~ /\.moderate$/) {
        if ($path =~ /^(([^\/]*\/)*)([^\/]+)(\/?)$/) {
            my $name = $3;
            $name =~ s/^\.//;
            $name =~ s/\.moderate//;
            $visible_path = "$2" . "$name";
        }
    }

    ## Qdecode the visible path
    return Sympa::Tools::qdecode_filename($visible_path);
}

## returns a mailto according to list spam protection parameter
sub mailto {

    my $list  = shift;
    my $email = shift;
    my $gecos = shift;
    my $next_one;

    my $mailto = '';
    my @addresses;
    my %recipients;

    @addresses = split(',', $email);

    $gecos = $email unless ($gecos);
    $gecos =~ s/&/&amp;/g;
    $gecos =~ s/</&lt;/g;
    $gecos =~ s/>/&gt;/g;
    foreach my $address (@addresses) {

        ($recipients{$address}{'local'}, $recipients{$address}{'domain'}) =
            split('@', $address);
    }

    if ($list->spam_protection eq 'none') {
        $mailto .= "<a href=\"mailto:?";
        foreach my $address (@addresses) {
            $mailto .= "&amp;" if ($next_one);
            $mailto .= "to=$address";
            $next_one = 1;
        }
        $mailto .= "\">$gecos</a>";
    } elsif ($list->spam_protection eq 'javascript') {

        if ($gecos =~ /\@/) {
            $gecos =~ s/@/\" + \"@\" + \"/;
        }

        $mailto .= "<script type=\"text/javascript\">
 <!--
 document.write(\"<a href=\\\"\" + \"mail\" + \"to:?\" + ";
        foreach my $address (@addresses) {
            $mailto .= "\"\&amp\;\" + " if ($next_one);
            $mailto .=
                "\"to=\" + \"$recipients{$address}{'local'}\" + \"@\" + \"$recipients{$address}{'domain'}\" + ";
            $next_one = 1;
        }
        $mailto .= "\"\\\">$gecos<\" + \"/a>\")
 // --></script>";

    } elsif ($list->spam_protection eq 'at') {
        foreach my $address (@addresses) {
            $mailto .= " AND " if ($next_one);
            $mailto .=
                "$recipients{$address}{'local'} AT $recipients{$address}{'domain'}";
            $next_one = 1;
        }
    }
    return $mailto;

}

## return the mode of editing included in $action : 0, 0.5 or 1
sub find_edit_mode {
    my $action = shift;

    my $result;
    if ($action =~ /editor/i) {
        $result = 0.5;
    } elsif ($action =~ /do_it/i) {
        $result = 1;
    } else {
        $result = 0;
    }
    return $result;
}

## return the mode of editing : 0, 0.5 or 1 :
#  do the merging between 2 args of right access edit  : "0" > "0.5" > "1"
#  instead of a "and" between two booleans : the most restrictive right is
#  imposed
sub merge_edit {
    my $arg1 = shift;
    my $arg2 = shift;
    my $result;

    if ($arg1 == 0 || $arg2 == 0) {
        $result = 0;
    } elsif ($arg1 == 0.5 || $arg2 == 0.5) {
        $result = 0.5;
    } else {
        $result = 1;
    }
    return $result;
}

sub get_desc_file {
    my $file = shift;
    my $ligne;
    my %hash;

    open DESC_FILE, "$file";

    while ($ligne = <DESC_FILE>) {
        if ($ligne =~ /^title\s*$/) {

            #case title of the document
            while ($ligne = <DESC_FILE>) {
                last if ($ligne =~ /^\s*$/);
                $ligne =~ /^\s*(\S.*\S)\s*/;
                $hash{'title'} = $hash{'title'} . $1 . " ";
            }
        }

        if ($ligne =~ /^creation\s*$/) {

            #case creation of the document
            while ($ligne = <DESC_FILE>) {
                last if ($ligne =~ /^\s*$/);
                if ($ligne =~ /^\s*email\s*(\S*)\s*/) {
                    $hash{'email'} = $1;
                }
                if ($ligne =~ /^\s*date_epoch\s*(\d*)\s*/) {
                    $hash{'date'} = $1;
                }

            }
        }

        if ($ligne =~ /^access\s*$/) {

            #case access scenarios for the document
            while ($ligne = <DESC_FILE>) {
                last if ($ligne =~ /^\s*$/);
                if ($ligne =~ /^\s*read\s*(\S*)\s*/) {
                    $hash{'read'} = $1;
                }
                if ($ligne =~ /^\s*edit\s*(\S*)\s*/) {
                    $hash{'edit'} = $1;
                }

            }
        }

    }

    close DESC_FILE;

    return %hash;

}

## return a ref on an array of file (or subdirecties) to show to user
sub get_directory_content {
    my $tmpdir = shift;
    my $user   = shift;
    my $list   = shift;
    my $doc    = shift;

    # array of file not hidden
    my @dir = grep !/^\./, @$tmpdir;

    # array with documents not yet moderated
    my @moderate_dir = grep (/(\.moderate)$/, @$tmpdir);
    @moderate_dir = grep (!/^\.desc\./, @moderate_dir);

    # the editor can see file not yet moderated
    # a user can see file not yet moderated if he is th owner of these files
    if ($list->am_i('editor', $user)) {
        push(@dir, @moderate_dir);
    } else {
        my @privatedir = select_my_files($user, $doc, \@moderate_dir);
        push(@dir, @privatedir);
    }

    return \@dir;
}

## return an array that contains only file from @$refdir that belongs to $user
sub select_my_files {
    my ($user, $path, $refdir) = @_;
    my @new_dir;

    foreach my $d (@$refdir) {
        if (-e "$path/.desc.$d") {
            my %desc_hash = get_desc_file("$path/.desc.$d");
            if ($user eq $desc_hash{'email'}) {
                $new_dir[$#new_dir + 1] = $d;
            }
        }
    }
    return @new_dir;
}

sub get_icon {
    my $type = shift;

    return '/icons.' . $icons{$type};
}

sub get_mime_type {
    my $type = shift;

    %mime_types = _load_mime_types() unless %mime_types;

    return $mime_types{$type};
}

sub _load_mime_types {
    my @localisation = (
        '/etc/mime.types',
        '/usr/local/apache/conf/mime.types',
        '/etc/httpd/conf/mime.types',
        'mime.types'
    );

    foreach my $loc (@localisation) {
        next unless (-r $loc);

        unless (open(CONF, $loc)) {
            print STDERR "load_mime_types: unable to open $loc\n";
            return undef;
        }
    }

    my %types;

    while (<CONF>) {
        next if /^\s*\#/;

        if (/^(\S+)\s+(.+)\s*$/i) {
            my ($k, $v) = ($1, $2);

            my @extensions = split / /, $v;

            ## provides file extension, given the content-type
            if ($#extensions >= 0) {
                $types{$k} = $extensions[0];
            }

            foreach my $ext (@extensions) {
                $types{$ext} = $k;
            }
            next;
        }
    }

    close FILE;
    return %types;
}

## return a hash from the edit_list_conf file
sub _load_create_list_conf {
    my $robot = Sympa::Robot::clean_robot(shift);

    my $file;
    my $conf;

    $file = $robot->get_etc_filename('create_list.conf');
    unless ($file) {
        Sympa::Log::Syslog::do_log(
            Sympa::Log::Syslog::INFO,
            'unable to read %s',
            Sympa::Constants::DEFAULTDIR . '/create_list.conf'
        );
        return undef;
    }

    unless (open(FILE, $file)) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO, 'Unable to open config file %s',
            $file);
        return undef;
    }

    while (<FILE>) {
        next if /^\s*(\#.*|\s*)$/;

        if (/^\s*(\S+)\s+(read|hidden)\s*$/i) {
            $conf->{$1} = lc($2);
        } else {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
                'unknown parameter in %s  (Ignored) %s',
                $file, $_);
            next;
        }
    }

    close FILE;
    return $conf;
}

sub get_list_list_tpl {
    my $robot = Sympa::Robot::clean_robot(shift);

    my $list_conf;
    my $list_templates;
    unless ($list_conf = _load_create_list_conf($robot)) {
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

sub get_templates_list {

    my $type    = shift;
    my $robot   = shift;
    my $list    = shift;
    my $options = shift;

    my $listdir;

    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG,
        "get_templates_list ($type, $robot, $list)");
    unless (($type eq 'web') || ($type eq 'mail')) {
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
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
sub get_template_path {
    Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::DEBUG2, '(%s, %s. %s, %s, %s, %s)', @_);
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
        Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::INFO,
            'internal error incorrect parameter');
        return undef;
    }

    my $dir;
    if ($scope eq 'list') {
        unless (ref $list) {
            Sympa::Log::Syslog::do_log(Sympa::Log::Syslog::ERR, 'missing parameter "list"');
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

1;
