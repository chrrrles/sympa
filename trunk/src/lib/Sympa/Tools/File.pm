# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: Tools.pm 10402 2014-03-11 17:09:32Z rousse $

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

package Sympa::Tools::File;

use strict;
use warnings;

use Encode::Guess;
use English qw(-no_match_vars);
use File::Copy::Recursive;
use File::Find;
use POSIX qw(strftime);

use Sympa::Log::Syslog;

## Sets owner and/or access rights on a file.
sub set_file_rights {
    my %param = @_;
    my ($uid, $gid);

    if ($param{'user'}) {
        unless ($uid = (getpwnam($param{'user'}))[2]) {
            Sympa::Log::Syslog::do_log('err',
                "User %s can't be found in passwd file",
                $param{'user'});
            return undef;
        }
    } else {

        # A value of -1 is interpreted by most systems to leave that value
        # unchanged.
        $uid = -1;
    }
    if ($param{'group'}) {
        unless ($gid = (getgrnam($param{'group'}))[2]) {
            Sympa::Log::Syslog::do_log('err', "Group %s can't be found",
                $param{'group'});
            return undef;
        }
    } else {

        # A value of -1 is interpreted by most systems to leave that value
        # unchanged.
        $gid = -1;
    }
    unless (chown($uid, $gid, $param{'file'})) {
        Sympa::Log::Syslog::do_log('err',
            "Can't give ownership of file %s to %s.%s: %s",
            $param{'file'}, $param{'user'}, $param{'group'}, $ERRNO);
        return undef;
    }
    if ($param{'mode'}) {
        unless (chmod($param{'mode'}, $param{'file'})) {
            Sympa::Log::Syslog::do_log('err',
                "Can't change rights of file %s to %o: %s",
                $param{'file'}, $param{'mode'}, $ERRNO);
            return undef;
        }
    }
    return 1;
}

#copy a directory and its content
sub copy_dir {
    my $dir1 = shift;
    my $dir2 = shift;
    Sympa::Log::Syslog::do_log('debug', 'Copy directory %s to %s',
        $dir1, $dir2);

    unless (-d $dir1) {
        Sympa::Log::Syslog::do_log('err',
            "Directory source '%s' doesn't exist. Copy impossible", $dir1);
        return undef;
    }
    return (File::Copy::Recursive::dircopy($dir1, $dir2));
}

#delete a directory and its content
sub del_dir {
    my $dir = shift;
    Sympa::Log::Syslog::do_log('debug', 'del_dir %s', $dir);

    if (opendir DIR, $dir) {
        for (readdir DIR) {
            next if /^\.{1,2}$/;
            my $path = "$dir/$_";
            unlink $path   if -f $path;
            del_dir($path) if -d $path;
        }
        closedir DIR;
        unless (rmdir $dir) {
            Sympa::Log::Syslog::do_log('err',
                'Unable to delete directory %s: %s',
                $dir, $ERRNO);
        }
    } else {
        Sympa::Log::Syslog::do_log(
            'err',
            'Unable to open directory %s to delete the files it contains: %s',
            $dir,
            $ERRNO
        );
    }
}

#to be used before creating a file in a directory that may not exist already.
sub mk_parent_dir {
    my $file = shift;
    $file =~ /^(.*)\/([^\/])*$/;
    my $dir = $1;

    return 1 if (-d $dir);
    mkdir_all($dir, 0755);
}

## Recursively create directory and all parent directories
sub mkdir_all {
    my ($path, $mode) = @_;
    my $status = 1;

    ## Change umask to fully apply modes of mkdir()
    my $saved_mask = umask;
    umask 0000;

    return undef if ($path eq '');
    return 1 if (-d $path);

    ## Compute parent path
    my @token = split /\//, $path;
    pop @token;
    my $parent_path = join '/', @token;

    unless (-d $parent_path) {
        unless (mkdir_all($parent_path, $mode)) {
            $status = undef;
        }
    }

    if (defined $status) {    ## Don't try if parent dir could not be created
        unless (mkdir($path, $mode)) {
            $status = undef;
        }
    }

    ## Restore umask
    umask $saved_mask;

    return $status;
}

# shift file renaming it with date. If count is defined, keep $count file and
# unlink others
sub shift_file {
    my $file  = shift;
    my $count = shift;
    Sympa::Log::Syslog::do_log('debug', "shift_file ($file,$count)");

    unless (-f $file) {
        Sympa::Log::Syslog::do_log('info', "shift_file : unknown file $file");
        return undef;
    }

    my @date = localtime(time);
    my $file_extention = strftime("%Y:%m:%d:%H:%M:%S", @date);

    unless (rename($file, $file . '.' . $file_extention)) {
        Sympa::Log::Syslog::do_log('err',
            "shift_file : Cannot rename file $file to $file.$file_extention");
        return undef;
    }
    if ($count) {
        $file =~ /^(.*)\/([^\/])*$/;
        my $dir = $1;

        unless (opendir(DIR, $dir)) {
            Sympa::Log::Syslog::do_log('err',
                "shift_file : Cannot read directory $dir");
            return ($file . '.' . $file_extention);
        }
        my $i = 0;
        foreach my $oldfile (reverse(sort (grep (/^$file\./, readdir(DIR)))))
        {
            $i++;
            if ($count lt $i) {
                if (unlink($oldfile)) {
                    Sympa::Log::Syslog::do_log('info',
                        "shift_file : unlink $oldfile");
                } else {
                    Sympa::Log::Syslog::do_log('info',
                        "shift_file : unable to unlink $oldfile");
                }
            }
        }
    }
    return ($file . '.' . $file_extention);
}

## Find a file in an ordered list of directories
sub find_file {
    my ($filename, @directories) = @_;
    Sympa::Log::Syslog::do_log(
        'debug3', 'Sympa::Tools::find_file(%s,%s)',
        $filename, join(':', @directories)
    );

    foreach my $d (@directories) {
        if (-f "$d/$filename") {
            return "$d/$filename";
        }
    }

    return undef;
}

## Recursively list the content of a directory
## Return an array of hash, each entry with directory + filename + encoding
sub list_dir {
    my $dir               = shift;
    my $all               = shift;
    my $original_encoding = shift; ## Suspected original encoding of filenames

    my $size = 0;

    if (opendir(DIR, $dir)) {
        foreach my $file (sort grep (!/^\.\.?$/, readdir(DIR))) {

            ## Guess filename encoding
            my ($encoding, $guess);
            my $decoder =
                Encode::Guess::guess_encoding($file, $original_encoding,
                'utf-8');
            if (ref $decoder) {
                $encoding = $decoder->name;
            } else {
                $guess = $decoder;
            }

            push @$all,
                {
                'directory' => $dir,
                'filename'  => $file,
                'encoding'  => $encoding,
                'guess'     => $guess
                };
            if (-d "$dir/$file") {
                list_dir($dir . '/' . $file, $all, $original_encoding);
            }
        }
        closedir DIR;
    }

    return 1;
}

sub get_dir_size {
    my $dir = shift;

    my $size = 0;

    if (opendir(DIR, $dir)) {
        foreach my $file (sort grep (!/^\./, readdir(DIR))) {
            if (-d "$dir/$file") {
                $size += get_dir_size("$dir/$file");
            } else {
                my @info = stat "$dir/$file";
                $size += $info[7];
            }
        }
        closedir DIR;
    }

    return $size;
}

## Function for Removing a non-empty directory
## It takes a variable number of arguments :
## it can be a list of directory
## or few directory paths
sub remove_dir {

    Sympa::Log::Syslog::do_log('debug2', 'remove_dir()');

    foreach my $current_dir (@_) {
        finddepth({wanted => \&del, no_chdir => 1}, $current_dir);
    }

    sub del {
        my $name = $File::Find::name;

        if (!-l && -d _) {
            unless (rmdir($name)) {
                Sympa::Log::Syslog::do_log('err',
                    'Error while removing directory %s', $name);
            }
        } else {
            unless (unlink($name)) {
                Sympa::Log::Syslog::do_log('err',
                    'Error while removing file  %s', $name);
            }
        }
    }
    return 1;
}

####################################################
# a_is_older_than_b
####################################################
# Compares the last modifications date of two files
#
# IN : - a hash with two entries:
#
#        * a_file : the full path to a file
#        * b_file : the full path to a file
#
# OUT : string: 'true' if the last modification date of "a_file" is older than
# "b_file"'s, 'false' otherwise.
#       return undef if the comparison could not be carried on.
#######################################################
sub a_is_older_than_b {
    my $param = shift;
    my ($a_file_readable, $b_file_readable) = (0, 0);
    my $answer = undef;
    if (-r $param->{'a_file'}) {
        $a_file_readable = 1;
    } else {
        Sympa::Log::Syslog::do_log('err',
            'Could not read file "%s". Comparison impossible',
            $param->{'a_file'});
    }
    if (-r $param->{'b_file'}) {
        $b_file_readable = 1;
    } else {
        Sympa::Log::Syslog::do_log('err',
            'Could not read file "%s". Comparison impossible',
            $param->{'b_file'});
    }
    if ($a_file_readable && $b_file_readable) {
        my @a_stats = stat($param->{'a_file'});
        my @b_stats = stat($param->{'b_file'});
        if ($a_stats[9] < $b_stats[9]) {
            $answer = 1;
        } else {
            $answer = 0;
        }
    }
    return $answer;
}

=pod 

=head2 sub CleanSpool(STRING $spool_dir, INT $clean_delay)

Clean all messages in spool $spool_dir older than $clean_delay.

=head3 Arguments 

=over 

=item * I<spool_dir> : a string corresponding to the path to the spool to clean;

=item * I<clean_delay> : the delay between the moment we try to clean spool and the last modification date of a file.

=back

=head3 Return 

=over

=item * 1 if the spool was cleaned withou troubles.

=item * undef if something went wrong.

=back 

=cut 

############################################################
#  CleanDir
############################################################
#  Cleans files older than $clean_delay from spool $spool_dir
#
# IN : -$dir (+): the spool directory
#      -$clean_delay (+): delay in days
#
# OUT : 1
#
##############################################################
sub CleanDir {
    my ($dir, $clean_delay) = @_;
    Sympa::Log::Syslog::do_log('debug', 'CleanSpool(%s,%s)', $dir,
        $clean_delay);

    unless (opendir(DIR, $dir)) {
        Sympa::Log::Syslog::do_log('err', "Unable to open '%s' spool : %s",
            $dir, $ERRNO);
        return undef;
    }

    my @qfile = sort grep (!/^\.+$/, readdir(DIR));
    closedir DIR;

    my ($curlist, $moddelay);
    foreach my $f (sort @qfile) {

        if ((stat "$dir/$f")[9] < (time - $clean_delay * 60 * 60 * 24)) {
            if (-f "$dir/$f") {
                unlink("$dir/$f");
                Sympa::Log::Syslog::do_log('notice', 'Deleting old file %s',
                    "$dir/$f");
            } elsif (-d "$dir/$f") {
                unless (Sympa::Tools::File::remove_dir("$dir/$f")) {
                    Sympa::Log::Syslog::do_log('err',
                        'Cannot remove old directory %s : %s',
                        "$dir/$f", $ERRNO);
                    next;
                }
                Sympa::Log::Syslog::do_log('notice',
                    'Deleting old directory %s', "$dir/$f");
            }
        }
    }
    return 1;
}

1;
