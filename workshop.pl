#!/usr/bin/perl
# -*- mode: perl; indent-tabs-mode: nil; perl-indent-level: 4 -*-
# vim: autoindent tabstop=4 shiftwidth=4 expandtab softtabstop=4 filetype=perl

use strict;
use warnings;

use Getopt::Long;
use JSON;
use Scalar::Util qw(looks_like_number);

use Data::Dumper;

# disable output buffering
$|++;

my $me = "workshop";
my $indent = "    ";

my %args;
$args{'log-level'} = 'info';
$args{'skip-update'} = 'false';

my @cli_args = ( '--log-level', '--requirements', '--skip-update', '--userenv' );
my %log_levels = ( 'info' => 1, 'verbose' => 1, 'debug' => 1 );
my %update_options = ( 'true' => 1, 'false' => 1 );

my @virtual_fs = ('dev', 'proc', 'sys');

my $command_logger_fmt = "################################################################################\n" .
    "COMMAND:         %s\n" .
    "RETURN CODE:     %d\n" .
    "COMMAND OUTPUT:\n\n%s\n" .
    "********************************************************************************\n";

sub compare_requirement_definition {
    my ($a, $b) = @_;

    if (ref($a) eq 'HASH') {
        if (ref($b) ne 'HASH') {
            return(1);
        }

        if (scalar(keys(%{$a})) != scalar(keys(%{$b}))) {
            return(1);
        }

        foreach my $key (keys %{$a}) {
            if (!exists $b->{$key}) {
                return(1);
            }

            my $ret_val = compare_requirement_definition($a->{$key}, $b->{$key});
            if ($ret_val) {
                return($ret_val);
            }
        }
    } elsif (ref($a) eq 'ARRAY') {
        if (ref($b) ne 'ARRAY') {
            return(1);
        }

        if (scalar(@{$a}) != scalar(@{$b})) {
            return(1);
        }

        for (my $i=0; $i<scalar(@{$a}); $i++) {
            my $ret_val = compare_requirement_definition($$a[$i], $$b[$i]);
            if ($ret_val) {
                return($ret_val);
            }
        }
    } elsif (ref(\$a) eq 'SCALAR') {
        if (ref(\$b) ne 'SCALAR') {
            return(1);
        }

        if (looks_like_number($a)) {
            if (!looks_like_number($b)) {
                return(1);
            }

            if ($a != $b) {
                return(1);
            }
        } else {
            if (looks_like_number($b)) {
                return(1);
            }

            if ($a ne $b) {
                return(1);
            }
        }
    } else {
        logger('error', "Encountered an unknown situation while comparing requirement definitions!\n");
        logger('debug', "A->[" . ref($a) . "]->[" . ref(\$a) . "]->[$a]\n");
        logger('debug', "B->[" . ref($b) . "]->[" . ref(\$b) . "]->[$b]\n");
        return(1);
    }

    return 0;
}

sub run_command {
    my ($command) = @_;

    $command .= " 2>&1";
    my $command_output = `$command`;
    my $rc = $? >> 8;

    return ($command, $command_output, $rc);
}

sub command_logger {
    my ($log_level, $command, $rc, $command_output) = @_;

    logger($log_level, sprintf($command_logger_fmt, $command, $rc, $command_output));
}

sub logger {
    my ($log_level, $log_msg, $indents) = @_;
    $indents //= 0;

    if (!defined($log_msg)) {
        $log_msg = 'log_msg not defined';
    }

    my $tmp_msg = "";
    for (my $i=0; $i<$indents; $i++) {
        $tmp_msg .= $indent;
    }
    $log_msg = $tmp_msg . $log_msg;

    my $log_it = 0;
    my $prefix = "";

    if (($log_level eq 'debug') &&
        ($args{'log-level'} eq 'debug')) {
        $log_it = 1;
        $prefix = "[DEBUG] ";
    } elsif (($log_level eq 'verbose') &&
             (($args{'log-level'} eq 'debug') ||
              ($args{'log-level'} eq 'verbose'))) {
        $log_it = 1;
        $prefix = "[VERBOSE] ";
    } elsif (($log_level eq 'info') &&
             (($args{'log-level'} eq 'debug') ||
              ($args{'log-level'} eq 'verbose') ||
              ($args{'log-level'} eq 'info'))) {
        $log_it = 1;
    } elsif ($log_level eq 'error') {
        $log_it = 1;
        $prefix = "[ERROR] ";
    }

    if (!$log_it) {
        return;
    }

    my $add_newline = 0;
    if ($log_msg =~ /\n$/) {
        $add_newline = 1;
    }

    if ($log_msg eq "") {
        print $prefix;
        return;
    }

    my @lines = split(/\n/, $log_msg);

    my $line_idx = 0;
    for ($line_idx=0; $line_idx<(scalar(@lines) - 1); $line_idx++) {
        print $prefix . $lines[$line_idx] . "\n";
    }

    if ($add_newline) {
        print $prefix . $lines[$line_idx] . "\n";
    } else {
        print $prefix . $lines[$line_idx];
    }
}

sub arg_handler {
    my ($opt_name, $opt_value) = @_;

    if ($opt_name eq "completions") {
        $args{$opt_name} = 1;

        if ($opt_value eq 'all') {
            for (my $i=0; $i<scalar(@cli_args); $i++) {
                print $cli_args[$i] . ' ';
            }
            print "\n";
        } elsif ($opt_value eq '--log-level') {
            foreach my $key (sort (keys %log_levels)) {
                print "$key ";
            }
            print "\n";
        } elsif ($opt_value eq '--skip-update') {
            foreach my $key (sort (keys %update_options)) {
                print "$key ";
            }
            print "\n";
        }
    } elsif ($opt_name eq "label") {
        $args{'label'} = $opt_value;
    } elsif ($opt_name eq "userenv") {
        $args{'userenv'} = $opt_value;

        if (! -e $args{'userenv'}) {
            die("--userenv must be a valid file [not '$args{'userenv'}']");
        }
    } elsif ($opt_name eq "requirements") {
        if (! exists $args{'reqs'}) {
            $args{'reqs'} = ();
        }

        if (! -e $opt_value) {
            die("--requirements must be a valid file [not '$opt_value']");
        }

        push(@{$args{'reqs'}}, $opt_value);
    } elsif ($opt_name eq "skip-update") {
        if (exists ($update_options{$opt_value})) {
            $args{'skip-update'} = $opt_value;
        } else {
            die("--skip-update must be one of 'true' or 'false' [not '$opt_value']");
        }
    } elsif ($opt_name eq "log-level") {
        if (exists($log_levels{$opt_value})) {
            $args{'log-level'} = $opt_value;
        } else {
            my $msg = "";
            my @levels = (keys %log_levels);
            for (my $i=0; $i<scalar(@levels); $i++) {
                if ($i == (scalar(@levels) - 1)) {
                    $msg .= "or '" . $levels[$i] . "'";
                } else {
                    $msg .= "'" . $levels[$i] . "', ";
                }
            }

            die("--log-level must be one of 'info', 'verbose', or 'debug' [not '$opt_value']\n");
        }
    } else {
        die("I'm confused, how did I get here [$opt_name]?");
    }
}

GetOptions("completions=s" => \&arg_handler,
           "log-level=s" => \&arg_handler,
           "requirements=s" => \&arg_handler,
           "skip-update=s" => \&arg_handler,
           "userenv=s" => \&arg_handler,
           "label=s" => \&arg_handler)
    or die("Error in command line arguments");

logger('debug', "Argument Hash:\n");
logger('debug', Dumper(\%args));

if (exists($args{'completions'})) {
    exit 0;
}

if (! exists $args{'userenv'}) {
    logger('error', "You must provide --userenv!\n");
    exit 1;
}

my $userenv_json;

logger('info', "Loading userenv definition from '$args{'userenv'}'...\n");

if (open(my $userenv_fh, "<", $args{'userenv'})) {
    my $file_contents;
    while(<$userenv_fh>) {
        $file_contents .= $_;
    }

    $userenv_json = decode_json($file_contents);

    close($userenv_fh);

    logger('info', "succeeded\n", 1);
    logger('debug', Dumper($userenv_json));
} else {
    logger('info', "failed\n", 1);
    logger('error', "Could not open userenv file '$args{'userenv'}' for reading!\n");
    exit 2;
}

my @all_requirements;
my %active_requirements;

logger('info', "Processing requested requirements...\n");

my $userenv_reqs = { 'filename' => $args{'userenv'},
                    'json' => { 'userenvs' => [
                                    {
                                        "name" => $userenv_json->{'userenv'}{'name'},
                                        "requirements" => []
                                    }
                                ],
                                'requirements' => $userenv_json->{'requirements'}
                    } };
foreach my $req (@{$userenv_reqs->{'json'}{'requirements'}}) {
    push(@{$userenv_reqs->{'json'}{'userenvs'}[0]{'requirements'}}, $req->{'name'});
}
push(@all_requirements, $userenv_reqs);

foreach my $req (@{$args{'reqs'}}) {
    logger('info', "loading '$req'...\n", 1);

    if (open(my $req_fh, "<", $req)) {
        my $file_contents;
        while(<$req_fh>) {
            $file_contents .= $_;
        }

        my $tmp_req = { 'filename' => $req,
                        'json' => decode_json($file_contents) };

        push(@all_requirements, $tmp_req);

        close($req_fh);

        logger('info', "succeeded\n", 2);
    } else {
        logger('info', "failed\n", 2);
        logger('error', "Failed to load requirement file '$req'!\n");
        exit 21;
    }
}

$active_requirements{'hash'} = ();
$active_requirements{'array'} = [];

foreach my $tmp_req (@all_requirements) {
    logger('info', "finding active requirements from '$tmp_req->{'filename'}'...\n", 1);

    my $userenv_idx = -1;
    my $userenv_default_idx = -1;
    my %userenvs;

    for (my $i=0; $i<scalar(@{$tmp_req->{'json'}{'userenvs'}}); $i++) {
        if (exists($userenvs{$tmp_req->{'json'}{'userenvs'}[$i]{'name'}})) {
            logger('info', "failed\n", 2);
            logger('error', "Found duplicate userenv definition for '$tmp_req->{'json'}{'userenv'}[$i]{'name'}' in requirements '$tmp_req->{'filename'}'!\n");
        } else {
            $userenvs{$tmp_req->{'json'}{'userenvs'}[$i]{'name'}} = 1;
        }

        if ($tmp_req->{'json'}{'userenvs'}[$i]{'name'} eq $userenv_json->{'userenv'}{'name'}) {
            $userenv_idx = $i;
        }

        if ($tmp_req->{'json'}{'userenvs'}[$i]{'name'} eq 'default') {
            $userenv_default_idx = $i;
        }
    }

    if ($userenv_idx == -1) {
        if ($userenv_default_idx == -1) {
            logger('info', "failed\n", 2);
            logger('error', "Could not find appropriate userenv match in requirements '$tmp_req->{'name'}' for '$userenv_json->{'userenv'}{'label'}'!\n");
            exit 22;
        } else {
            $userenv_idx = $userenv_default_idx;
        }
    }

    foreach my $req (@{$tmp_req->{'json'}{'userenvs'}[$userenv_idx]{'requirements'}}) {
        my %local_requirements;

        for (my $i=0; $i<scalar(@{$tmp_req->{'json'}{'requirements'}}); $i++) {
            if (exists($local_requirements{$tmp_req->{'json'}{'requirements'}[$i]{'name'}})) {
                logger('info', "failed\n", 2);
                logger('error', "Found multiple requirement definitions for '$tmp_req->{'json'}{'requirements'}[$i]{'name'}' in '$tmp_req->{'filename'}'!\n");
                exit 38;
            } else {
                $local_requirements{$tmp_req->{'json'}{'requirements'}[$i]{'name'}} = 1;
            }

            if ($req eq $tmp_req->{'json'}{'requirements'}[$i]{'name'}) {
                if (exists($active_requirements{'hash'}{$tmp_req->{'json'}{'requirements'}[$i]{'name'}})) {
                    if (compare_requirement_definition($tmp_req->{'json'}{'requirements'}[$i],
                                                       $active_requirements{'array'}[$active_requirements{'hash'}{$tmp_req->{'json'}{'requirements'}[$i]{'name'}}{'array_index'}])) {
                        logger('info', "failed\n", 2);
                        my $conflicts = "";
                        my @tmp_array = (@{$active_requirements{'hash'}{$tmp_req->{'json'}{'requirements'}[$i]{'name'}}{'sources'}});
                        for (my $x=0; $x<scalar(@tmp_array); $x++) {
                            $tmp_array[$x] = "'" . $tmp_array[$x] . "'";
                        }
                        if (scalar(@tmp_array) == 1) {
                            $conflicts = $tmp_array[0];
                        } elsif (scalar(@tmp_array) == 2) {
                            $conflicts = $tmp_array[0] . ' and ' . $tmp_array[1];
                        } elsif (scalar(@tmp_array) > 2) {
                            $conflicts = ', and ' . $tmp_array[scalar(@tmp_array) - 1];
                            for (my $x=scalar(@tmp_array)-2; $x>1; $x--) {
                                $conflicts .= ',' . $tmp_array[$x] . $conflicts;
                            }
                            $conflicts = $tmp_array[0] . $conflicts;
                        }
                        logger('error', "Discovered a conflict between '$tmp_req->{'filename'}' and $conflicts for requirement '$req'!\n");
                        logger('debug', "'" . $tmp_req->{'filename'} . "':\n" . Dumper($tmp_req->{'json'}{'requirements'}[$i]) . "\n");
                        logger('debug', $conflicts . ":\n" . Dumper($active_requirements{'array'}[$active_requirements{'hash'}{$tmp_req->{'json'}{'requirements'}[$i]{'name'}}{'array_index'}]) . "\n");
                        exit 39;
                    } else {
                        push(@{$active_requirements{'hash'}{$tmp_req->{'json'}{'requirements'}[$i]{'name'}}{'sources'}}, $tmp_req->{'filename'});
                    }
                } else {
                    my $insert_index = push(@{$active_requirements{'array'}}, $tmp_req->{'json'}{'requirements'}[$i]) - 1;

                    $active_requirements{'hash'}{$tmp_req->{'json'}{'requirements'}[$i]{'name'}} = { 'sources' => [
                                                                                                         $tmp_req->{'filename'}
                                                                                                         ],
                                                                                                     'array_index' => $insert_index };
                }
            }
        }
    }

    # requirements processing end
    logger('info', "succeeded\n", 2);
}


logger('debug', "All Requirements Hash:\n");
logger('debug', Dumper(\@all_requirements));
logger('debug', "Active Requirements Hash:\n");
logger('debug', Dumper(\%active_requirements));

my $command;
my $command_output;
my $rc;

my $container_mount_point;

# acquire the userenv from the origin
logger('info', "Looking for container base image...\n");
($command, $command_output, $rc) = run_command("buildah images --json $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}");
if ($rc == 0) {
    logger('info', "Found $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'} locally\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
    $userenv_json->{'userenv'}{'origin'}{'local_details'} = decode_json($command_output);
} else {
    command_logger('verbose', $command, $rc, $command_output);
    logger('info', "Could not find $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}, attempting to download...\n", 1);
    ($command, $command_output, $rc) = run_command("buildah pull --quiet $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}");
    if ($rc == 0) {
        logger('info', "succeeded\n", 2);
        command_logger('verbose', $command, $rc, $command_output);

        logger('info', "Querying for information about the image...\n", 1);
        ($command, $command_output, $rc) = run_command("buildah images --json $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}");
        if ($rc == 0) {
            logger('info', "succeeded\n", 2);
            command_logger('verbose', $command, $rc, $command_output);
            $userenv_json->{'userenv'}{'origin'}{'local_details'} = decode_json($command_output);
        } else {
            logger('info', "failed\n", 2);
            command_logger('error', $command, $rc, $command_output);
            logger('error', "Failed to download/query $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}!\n");
            exit 3;
        }
    } else {
        logger('info', "failed\n", 2);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to download $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}!\n");
        exit 4;
    }
}

logger('debug', "Userenv JSON:\n");
logger('debug', Dumper($userenv_json));

my $tmp_container = $me . "_" . $userenv_json->{'userenv'}{'name'};
if (defined $args{'label'}) {
    $tmp_container .= "_" . $args{'label'};
}

# make sure there isn't an old container hanging around
logger('info', "Checking for stale container presence...\n");
($command, $command_output, $rc) = run_command("buildah containers --filter name=$tmp_container --json");
if ($command_output !~ /null/) {
    logger('info', "found\n", 1);
    command_logger('verbose', $command, $rc, $command_output);

    # need to clean up an old container
    logger('info', "Cleaning up old container...\n");
    ($command, $command_output, $rc) = run_command("buildah rm $tmp_container");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Could not clean up old container '$tmp_container'!\n");
        exit 5;
    } else {
        logger('info', "succeeded\n", 1);
        command_logger('verbose', $command, $rc, $command_output);
    }
} else {
    logger('info', "not found\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

# cleanup an existing container image that we are going to replace, if it exists
logger('info', "Checking if container image already exists...\n");
($command, $command_output, $rc) = run_command("buildah images --json $tmp_container");
if ($rc == 0) {
    logger('info', "found\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
    logger('info', "Removing existing container image that I am about to replace [$tmp_container]...\n");
    ($command, $command_output, $rc) = run_command("buildah rmi $tmp_container");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Could not remove existing container image '$tmp_container'!\n");
        exit 11;
    } else {
        logger('info', "succeeded\n", 1);
        command_logger('verbose', $command, $rc, $command_output);
    }
} else {
    logger('info', "not found\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

# create a new container based on the userenv source
logger('info', "Creating temporary container...\n");
($command, $command_output, $rc) = run_command("buildah from --name $tmp_container $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Could not create new container '$tmp_container' from '$userenv_json->{'origin'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}'!\n");
    exit 6;
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

my $update_cmd = "";
my $clean_cmd = "";
if ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq "dnf") {
    $update_cmd = "dnf update --assumeyes";
    $clean_cmd = "dnf clean all";
} elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq "yum") {
    $update_cmd = "yum update --assumeyes";
    $clean_cmd = "yum clean all";
} else {
    logger('error', "Unsupported userenv package manager encountered [$userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'}]\n");
    exit 23;
}

if ($args{'skip-update'} eq 'false') {
    # update the container's existing content
    logger('info', "Updating the temporary container...\n");
    ($command, $command_output, $rc) = run_command("buildah run $tmp_container -- $update_cmd");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Updating the temporary container '$tmp_container' failed!\n");
        exit 7;
    } else {
        logger('info', "succeeded\n", 1);
        command_logger('verbose', $command, $rc, $command_output);
    }

    logger('info', "Cleaning up after the update...\n");
    ($command, $command_output, $rc) = run_command("buildah run $tmp_container -- $clean_cmd");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Updating the temporary container '$tmp_container' failed because it could not clean up after itself!\n");
        exit 12;
    } else {
        logger('info', "succeeded\n", 1);
        command_logger('verbose', $command, $rc, $command_output);
    }
} else {
    logger('info', "Skipping update due to --skip-update\n");
}

# mount the container image
logger('info', "Mounting the temporary container's fileystem...\n");
($command, $command_output, $rc) = run_command("buildah mount $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to mount the temporary container's filesystem!\n");
    exit 13;
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
    chomp($command_output);
    $container_mount_point = $command_output;
}

# bind mount virtual file systems that may be needed
logger('info', "Bind mounting /dev, /proc/, and /sys into the temporary container's filesystem...\n");
my $mount_cmd_log = "";
foreach my $fs (@virtual_fs) {
    logger('info', "mounting '/$fs'...\n", 1);
    ($command, $command_output, $rc) = run_command("mount --verbose --options bind /$fs $container_mount_point/$fs");
    $mount_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
    if ($rc != 0) {
        logger('info', "failed\n", 2);
        logger('error', $mount_cmd_log);
        logger('error', "Failed to mount virtual filesystem '/$fs'!\n");
        exit 31;
    }
}
logger('info', "succeeded\n", 1);
logger('verbose', $mount_cmd_log);

if (-e $container_mount_point . "/etc/resolv.conf") {
    logger('info', "Backing up the temporary container's /etc/resolv.conf...\n");
    ($command, $command_output, $rc) = run_command("mv --verbose " . $container_mount_point . "/etc/resolv.conf " . $container_mount_point . "/etc/resolv.conf." . $me);
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to backup the temporary container's /etc/resolv.conf!\n");
        exit 33;
    }
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

logger('info', "Temporarily copying the host's /etc/resolv.conf to the temporary container...\n");
($command, $command_output, $rc) = run_command("cp --verbose /etc/resolv.conf " . $container_mount_point . "/etc/resolv.conf");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to copy /etc/resolv.conf to the temporary container!\n");
    exit 34;
}
logger('info', "succeeded\n", 1);
command_logger('verbose', $command, $rc, $command_output);

# what follows is a complicated mess of code to chroot into the
# temporary container's filesystem.  Once there all kinds of stuff can
# be done to install packages and make other tweaks to the container
# if necessary.

# capture the current path/pwd and a reference to '/'
if (opendir(NORMAL_ROOT, "/")) {
    my $pwd;
    ($command, $pwd, $rc) = run_command("pwd");
    chomp($pwd);

    # jump into the container image
    if (chroot($container_mount_point)) {
        if (chdir("/root")) {
            logger('info', "Installing Requirements (" . scalar(@{$active_requirements{'array'}}) . ")\n");

            my $distro_installs = 0;
            my $req_counter = 0;
            foreach my $req (@{$active_requirements{'array'}}) {
                $req_counter += 1;
                logger('info', "(" . $req_counter . "/" . scalar(@{$active_requirements{'array'}}) . ") Processing '$req->{'name'}'...\n", 1);

                if ($req->{'type'} eq 'files') {
                    logger('info', "deferring due to type 'files'\n", 2);
                } elsif ($req->{'type'} eq 'distro') {
                    $distro_installs = 1;

                    logger('info', "performing distro package installation...\n", 2);

                    if (exists($req->{'distro_info'}{'packages'})) {
                        foreach my $pkg (@{$req->{'distro_info'}{'packages'}}) {
                            logger('info', "package '$pkg'...\n", 3);

                            my $install_cmd = "";
                            if ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq 'dnf') {
                                $install_cmd = "dnf install --assumeyes " . $pkg;
                            } elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq 'yum') {
                                $install_cmd = "yum install --assumeyes " . $pkg;
                            } else {
                                logger('info', "failed\n", 4);
                                logger('error', "Unsupported userenv package manager encountered [$userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'}]\n");
                                exit 23;
                            }

                            ($command, $command_output, $rc) = run_command("$install_cmd");
                            if ($rc == 0) {
                                logger('info', "succeeded\n", 4);
                                command_logger('verbose', $command, $rc, $command_output);
                            } else {
                                logger('info', "failed [rc=$rc]\n", 4);
                                command_logger('error', $command, $rc, $command_output);
                                logger('error', "Failed to install package '$pkg'\n");
                                exit 24;
                            }
                        }
                    }

                    if (exists($req->{'distro_info'}{'groups'})) {
                        foreach my $grp (@{$req->{'distro_info'}{'groups'}}) {
                            logger('info', "group '$grp'...\n", 3);

                            my $install_cmd = "";
                            if ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq 'dnf') {
                                $install_cmd = "dnf groupinstall --assumeyes " . $grp;
                            } elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq 'yum') {
                                $install_cmd = "yum groupinstall --assumeyes " . $grp;
                            } else {
                                logger('info', "failed\n", 4);
                                logger('error', "Unsupported userenv package manager encountered [$userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'}]\n");
                                exit 23;
                            }

                            ($command, $command_output, $rc) = run_command("$install_cmd");
                            if ($rc == 0) {
                                logger('info', "succeeded\n", 4);
                                command_logger('verbose', $command, $rc, $command_output);
                            } else {
                                logger('info', "failed [rc=$rc]\n", 4);
                                command_logger('error', $command, $rc, $command_output);
                                logger('error', "Failed to install group '$grp'\n");
                                exit 24;
                            }
                        }
                    }
                } elsif ($req->{'type'} eq 'source') {
                    logger('info', "building package '$req->{'name'}' from source for installation...\n", 2);

                    if (chdir('/root')) {
                        logger('info', "downloading...\n", 3);
                        ($command, $command_output, $rc) = run_command("curl --url $req->{'source_info'}{'url'} --output $req->{'source_info'}{'filename'} --location");
                        if ($rc == 0) {
                            logger('info', "getting directory...\n", 3);
                            ($command, $command_output, $rc) = run_command("$req->{'source_info'}{'commands'}{'get_dir'}");
                            my $get_dir = $command_output;
                            chomp($get_dir);
                            if ($rc == 0) {
                                logger('info', "unpacking...\n", 3);
                                ($command, $command_output, $rc) = run_command("$req->{'source_info'}{'commands'}{'unpack'}");
                                if ($rc == 0) {
                                    if (chdir($get_dir)) {
                                        logger('info', "building...\n", 3);
                                        my $build_cmd_log = "";
                                        foreach my $build_cmd (@{$req->{'source_info'}{'commands'}{'commands'}}) {
                                            logger('info', "executing '$build_cmd'...\n", 4);
                                            ($command, $command_output, $rc) = run_command("$build_cmd");
                                            $build_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                                            if ($rc != 0) {
                                                logger('info', "failed\n", 5);
                                                logger('error', $build_cmd_log);
                                                logger('error', "Build failed on command '$build_cmd'!\n");
                                                exit 30;
                                            }
                                        }
                                        logger('info', "succeeded\n", 3);
                                        logger('verbose', $build_cmd_log);
                                    } else {
                                        logger('info', "failed\n", 3);
                                        logger('error', "Could not chdir to '$get_dir'!\n");
                                        exit 29;
                                    }
                                } else {
                                    logger('info', "failed\n", 3);
                                    command_logger('error', $command, $rc, $command_output);
                                    logger('error', "Could not unpack source package!\n");
                                    exit 29;
                                }
                            } else {
                                logger('info', "failed\n", 3);
                                command_logger('error', $command, $rc, $command_output);
                                logger('error', "Could not get unpack directory!\n");
                                exit 28;
                            }
                        } else {
                            logger('info', "failed\n", 3);
                            command_logger('error', $command, $rc, $command_output);
                            logger('error', "Could not download $req->{'source_info'}{'url'}!\n");
                            exit 27;
                        }
                    } else {
                        logger('info', "failed\n", 2);
                        logger('error', "Could not chdir to /root!\n");
                        exit 26;
                    }
                } elsif ($req->{'type'} eq 'manual') {
                    logger('info', "installing package via manually provided commands...\n", 2);

                    my $install_cmd_log = "";
                    foreach my $cmd (@{$req->{'manual_info'}{'commands'}}) {
                        logger('info', "executing '$cmd'...\n", 3);
                        ($command, $command_output, $rc) = run_command("$cmd");
                        $install_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                        if ($rc != 0){
                            logger('info', "failed [rc=$rc]\n", 4);
                            logger('error', $install_cmd_log);
                            logger('error', "Failed to run command '$cmd'\n");
                            exit 25;
                        }
                    }
                    logger('info', "succeeded\n", 2);
                    logger('verbose', $install_cmd_log);
                }
            }

            if ($distro_installs) {
                logger('info', "Cleaning up after performing distro package installations...\n");
                ($command, $command_output, $rc) = run_command("$clean_cmd");
                if ($rc != 0) {
                    logger('info', "failed\n", 2);
                    command_logger('error', $command, $rc, $command_output);
                    logger('error', "Cleaning up after distro package installation failed!\n");
                    exit 26;
                } else {
                    logger('info', "succeeded\n", 2);
                    command_logger('verbose', $command, $rc, $command_output);
                }
            }

            # break out of the chroot and return to the old path/pwd
            if (chdir(*NORMAL_ROOT)) {
                if (chroot(".")) {
                    if (!chdir($pwd)) {
                        logger('error', "Could not chdir back to the original path/pwd!\n");
                        exit 20;
                    }
                } else {
                    logger('error', "Could not chroot out of the chroot!\n");
                    exit 19;
                }
            } else {
                logger('error', "Could not chdir to escape the chroot!\n");
                exit 18;
            }
        } else {
            logger('error', "Could not chdir to temporary container mount point [$container_mount_point]!\n");
            exit 17;
        }
    } else {
        logger('error', "Could not chroot to temporary container mount point [$container_mount_point]!\n");
        exit 16;
    }

    closedir(NORMAL_ROOT);
} else {
    logger('error', "Could not get directory reference to '/'!\n");
    exit 15;
}

# handle file copying requirements.  this must be done outside of the
# chroot so that the source files can be accessed.
logger('info', "Processing deferred file copy requirements...\n");
my $file_copies_found = 0;
foreach my $req (@{$active_requirements{'array'}}) {
    if ($req->{'type'} eq 'files') {
        $file_copies_found += 1;

        logger('info', "Copying files into the temporary container for '$req->{'name'}'...\n", 1);

        foreach my $file (@{$req->{'files_info'}{'files'}}) {
            logger('info', "copying '$file->{'src'}'...\n", 2);
            if ($file->{'type'} eq 'local-copy') {
                if (-e $file->{'src'}) {
                    if (exists($file->{'dst'})) {
                        ($command, $command_output, $rc) = run_command("/bin/cp -LR " .
                                                                       $file->{'src'} .
                                                                       " " . $container_mount_point . "/" .
                                                                       $file->{'dst'});
                        if ($rc != 0) {
                            logger('info', "failed\n", 3);
                            command_logger('error', $command, $rc, $command_output);
                            logger('error', "Failed to copy '$file->{'src'}' to the temporary container!\n");
                            exit 35;
                        } else {
                            logger('info', "succeeded\n", 3);
                            command_logger('verbose', $command, $rc, $command_output);                        }
                    } else {
                        logger('info', "failed\n", 3);
                        command_logger('error', $command, $rc, $command_output);
                        logger('error', "Destination '$file->{'dst'}' not defined!\n");
                        exit 36;
                    }
                } else {
                    logger('info', "failed\n", 3);
                    command_logger('error', $command, $rc, $command_output);
                    logger('error', "Local source file '$file->{'src'}' not found!\n");
                    exit 36;
                }
            } else {
                logger('info', "failed\n", 3);
                logger('error', "File copy type '$file->{'type'}' is not supported!\n");
                exit 36;
            }
        }
    }
}
if ($file_copies_found == 0) {
    logger('info', "none found\n", 1);
}

# unmount virtual file systems that are bind mounted
logger('info', "Unmounting /dev, /proc/, and /sys from the temporary container's filesystem...\n");
my $umount_cmd_log = "";
foreach my $fs (@virtual_fs) {
    logger('info', "unmounting '/$fs'...\n", 1);
    ($command, $command_output, $rc) = run_command("umount --verbose $container_mount_point/$fs");
    $umount_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
    if ($rc != 0) {
        logger('info', "failed\n", 2);
        logger('error', $umount_cmd_log);
        logger('error', "Failed to unmount virtual filesystem '/$fs'!\n");
        exit 32;
    }
}
logger('info', "succeeded\n", 1);
logger('verbose', $umount_cmd_log);

logger('info', "Removing the temporarily assigned /etc/resolv.conf from the temporary container...\n");
($command, $command_output, $rc) = run_command("rm --verbose " . $container_mount_point . "/etc/resolv.conf");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to remove /etc/resolv.conf from the temporary container!\n");
    exit 34;
}
logger('info', "succeeded\n", 1);
command_logger('verbose', $command, $rc, $command_output);

if (-e $container_mount_point . "/etc/resolv.conf." . $me) {
    logger('info', "Restoring the backup of the temporary container's /etc/resolv.conf...\n");
    ($command, $command_output, $rc) = run_command("mv --verbose " . $container_mount_point . "/etc/resolv.conf." . $me . " " . $container_mount_point . "/etc/resolv.conf");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to restore the temporary container's /etc/resolv.conf!\n");
        exit 33;
    }
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

# unmount the container image
logger('info', "Unmounting the temporary container's filesystem...\n");
($command, $command_output, $rc) = run_command("buildah unmount $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to unmount the temporary container's filesystem [$container_mount_point]!\n");
    exit 14;
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

# create the new container image
logger('info', "Creating new container image...\n");
($command, $command_output, $rc) = run_command("buildah commit --quiet $tmp_container $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to create new container image '$tmp_container'!\n");
    exit 8;
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

# clean up the temporary container
logger('info', "Cleaning up the temporary container...\n");
($command, $command_output, $rc) = run_command("buildah rm $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to cleanup temporary container '$tmp_container'!\n");
    exit 9;
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

# give the user information about the new container image
logger('info', "Creation of container image '$tmp_container' is complete.  Retrieving some details about your new image...\n");
($command, $command_output, $rc) = run_command("buildah images --json $tmp_container");
if ($rc == 0) {
    logger('info', "succeeded\n", 1);
    logger('info', "\n$command_output\n");
    exit 0;
} else {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Could not get container image information for '$tmp_container'!  Something must have gone wrong that I don't understand.\n");
    exit 10;
}
