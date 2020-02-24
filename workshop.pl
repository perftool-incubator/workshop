#!/usr/bin/perl
# -*- mode: perl; indent-tabs-mode: nil; perl-indent-level: 4 -*-
# vim: autoindent tabstop=4 shiftwidth=4 expandtab softtabstop=4 filetype=perl

use strict;
use warnings;

use Getopt::Long;
use JSON;

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
} else {
    logger('info', "failed\n", 1);
    logger('error', "Could not open userenv file '$args{'userenv'}' for reading!\n");
    exit 2;
}

my @all_requirements;
my %active_requirements;

logger('info', "Processing requested requirements...\n");

my $userenv_reqs = { 'name' => $args{'userenv'},
                    'json' => { 'userenvs' => { $userenv_json->{'label'} => { 'packages' => [] } },
                                'packages' => {} } };

if (exists($userenv_json->{'install'}{'packages'})) {
    logger('info', "userenv requested packages...\n", 1);

    foreach my $pkg (@{$userenv_json->{'install'}{'packages'}}) {
        push(@{$userenv_reqs->{'json'}{'userenvs'}{$userenv_json->{'label'}}{'packages'}}, $pkg);

        $userenv_reqs->{'json'}{'packages'}{$pkg} = { 'type' => 'distro',
                                                     'distro_info' => { 'pkg_name' => $pkg } };
    }
}

if (exists($userenv_json->{'install'}{'groups'})) {
    logger('info', "userenv requested package groups...\n", 1);

    foreach my $pkg (@{$userenv_json->{'install'}{'groups'}}) {
        push(@{$userenv_reqs->{'json'}{'userenvs'}{$userenv_json->{'label'}}{'packages'}}, $pkg);

        $userenv_reqs->{'json'}{'packages'}{$pkg} = { 'type' => 'distro',
                                                     'distro_info' => { 'group_name' => $pkg } };
    }
}

push(@all_requirements, $userenv_reqs);

foreach my $req (@{$args{'reqs'}}) {
    logger('info', "loading '$req'...\n",1);

    if (open(my $req_fh, "<", $req)) {
        my $file_contents;
        while(<$req_fh>) {
            $file_contents .= $_;
        }

        my $tmp_req = { 'name' => $req,
                        'json' => decode_json($file_contents) };

        push(@all_requirements, $tmp_req);

        close($req_fh);
    } else {
        logger('info', "failed\n", 2);
        logger('error', "Failed to load requirement file '$req'!\n");
        exit 21;
    }
}

$active_requirements{'hash'} = ();
$active_requirements{'array'} = [];

foreach my $tmp_req (@all_requirements) {
    my $userenv_label;

    if (exists($tmp_req->{'json'}{'userenvs'}{$userenv_json->{'label'}})) {
        $userenv_label = $userenv_json->{'label'};
    } elsif (exists($tmp_req->{'json'}{'userenvs'}{'default'})) {
        $userenv_label = 'default';
    } else {
        logger('info', "failed\n", 1);
        logger('error', "Could not find appropriate userenv match in requirements '$tmp_req->{'name'}' for '$userenv_json->{'label'}'!\n");
        exit 22;
    }

    for my $userenv_package (@{$tmp_req->{'json'}{'userenvs'}{$userenv_label}{'packages'}}) {
        if (exists($active_requirements{'hash'}{$userenv_package})) {
            if (($tmp_req->{'json'}{'packages'}{$userenv_package}{'type'} eq 'distro') &&
                ($active_requirements{'hash'}{$userenv_package}{'requirement_type'} eq 'distro')) {
                push(@{$active_requirements{'hash'}{$userenv_package}{'requirement_sources'}}, $tmp_req->{'name'});
            } else {
                logger('info', "failed\n", 1);
                logger('debug', "All Requirements Hash:\n");
                logger('debug', Dumper(\@all_requirements));
                logger('error', "There is a userenv package conflict between '$tmp_req->{'name'}' with type '$tmp_req->{'json'}{'packages'}{$userenv_package}{'type'}' and '" .
                       join(',', @{$active_requirements{'hash'}{$userenv_package}{'requirement_sources'}}) .
                       "' with type '$active_requirements{'hash'}{$userenv_package}{'requirement_type'}' for '$userenv_package'!\n");
                exit 23;
            }
        } else {
            $active_requirements{'hash'}{$userenv_package} = { 'requirement_sources' => [
                                                                  $tmp_req->{'name'}
                                                                  ],
                                                              'requirement_type' => $tmp_req->{'json'}{'packages'}{$userenv_package}{'type'} };

            push(@{$active_requirements{'array'}}, { 'label' => $userenv_package,
                                                     'json' => $tmp_req->{'json'}{'packages'}{$userenv_package} });
        }
    }
}

# requirements processing end
logger('info', "succeeded\n", 1);

logger('debug', "All Requirements Hash:\n");
logger('debug', Dumper(\@all_requirements));
logger('debug', "Active Requirements Hash:\n");
logger('debug', Dumper(\%active_requirements));

my $command;
my $command_output;
my $rc;

my $container_mount_point;

# acquire the userenv source
($command, $command_output, $rc) = run_command("buildah images --json $userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'}");
if ($rc == 0) {
    logger('info', "Found $userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'} locally\n");
    command_logger('verbose', $command, $rc, $command_output);
    $userenv_json->{'source'}{'local_details'} = decode_json($command_output);
} else {
    command_logger('verbose', $command, $rc, $command_output);
    logger('info', "Could not find $userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'}, attempting to download...\n");
    ($command, $command_output, $rc) = run_command("buildah pull --quiet $userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'}");
    if ($rc == 0) {
        logger('info', "succeeded\n", 1);
        command_logger('verbose', $command, $rc, $command_output);

        logger('info', "Querying for information about the image...\n");
        ($command, $command_output, $rc) = run_command("buildah images --json $userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'}");
        if ($rc == 0) {
            logger('info', "succeeded\n", 1);
            command_logger('verbose', $command, $rc, $command_output);
            $userenv_json->{'source'}{'local_details'} = decode_json($command_output);
        } else {
            logger('info', "failed\n", 1);
            command_logger('error', $command, $rc, $command_output);
            logger('error', "Failed to download/query $userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'}!\n");
            exit 3;
        }
    } else {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to download $userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'}!\n");
        exit 4;
    }
}

logger('debug', "Userenv JSON:\n");
logger('debug', Dumper($userenv_json));

my $tmp_container = $me . "_" . $userenv_json->{'label'};
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
($command, $command_output, $rc) = run_command("buildah from --name $tmp_container $userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'}");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Could not create new container '$tmp_container' from '$userenv_json->{'source'}{'image'}:$userenv_json->{'source'}{'tag'}'!\n");
    exit 6;
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

my $update_cmd = "";
my $clean_cmd = "";
if ($userenv_json->{'install'}{'manager'} eq "dnf") {
    $update_cmd = "dnf update --assumeyes";
    $clean_cmd = "dnf clean all";
} elsif ($userenv_json->{'install'}{'manager'} eq "yum") {
    $update_cmd = "yum update --assumeyes";
    $clean_cmd = "yum clean all";
} else {
    logger('error', "Unsupported userenv package manager encountered [$userenv_json->{'install'}{'manager'}]\n");
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
                logger('info', "(" . $req_counter . "/" . scalar(@{$active_requirements{'array'}}) . ") Processing $req->{'label'}...\n");

                if ($req->{'json'}{'type'} eq 'distro') {
                    $distro_installs = 1;

                    logger('info', "performing distro package installation...\n", 1);

                    my $install_cmd = "";
                    if ($userenv_json->{'install'}{'manager'} eq 'dnf') {
                        if (exists($req->{'json'}{'distro_info'}{'pkg_name'})) {
                            $install_cmd = "dnf install --assumeyes " . $req->{'json'}{'distro_info'}{'pkg_name'};
                        } elsif (exists($req->{'json'}{'distro_info'}{'group_name'})) {
                            $install_cmd = "dnf groupinstall --assumeyes " . $req->{'json'}{'distro_info'}{'group_name'};
                        }
                    } elsif ($userenv_json->{'install'}{'manager'} eq 'yum') {
                        if (exists($req->{'json'}{'distro_info'}{'pkg_name'})) {
                            $install_cmd = "yum install --assumeyes " . $req->{'json'}{'distro_info'}{'pkg_name'};
                        } elsif (exists($req->{'json'}{'distro_info'}{'group_name'})) {
                            $install_cmd = "yum groupinstall --assumeyes " . $req->{'json'}{'distro_info'}{'group_name'};
                        }
                    } else {
                        logger('info', "failed\n", 2);
                        logger('error', "Unsupported userenv package manager encountered [$userenv_json->{'install'}{'manager'}]\n");
                        exit 23;
                    }

                    ($command, $command_output, $rc) = run_command("$install_cmd");
                    if ($rc == 0) {
                        logger('info', "succeeded\n", 2);
                        command_logger('verbose', $command, $rc, $command_output);
                    } else {
                        logger('info', "failed [rc=$rc]\n", 2);
                        command_logger('error', $command, $rc, $command_output);
                        logger('error', "Failed to install package $req->{'json'}{'distro_info'}{'pkg_name'}\n");
                        exit 24;
                    }

                } elsif ($req->{'json'}{'type'} eq 'source') {
                    logger('info', "building package from source for installation...\n", 1);

                    if (chdir('/root')) {
                        logger('info', "downloading...\n", 2);
                        ($command, $command_output, $rc) = run_command("curl --url $req->{'json'}{'source_info'}{'url'} --output $req->{'json'}{'source_info'}{'filename'} --location");
                        if ($rc == 0) {
                            logger('info', "getting directory...\n", 2);
                            ($command, $command_output, $rc) = run_command("$req->{'json'}{'source_info'}{'commands'}{'get_dir'}");
                            my $get_dir = $command_output;
                            chomp($get_dir);
                            if ($rc == 0) {
                                logger('info', "unpacking...\n", 2);
                                ($command, $command_output, $rc) = run_command("$req->{'json'}{'source_info'}{'commands'}{'unpack'}");
                                if ($rc == 0) {
                                    if (chdir($get_dir)) {
                                        logger('info', "building...\n", 2);
                                        my $build_cmd_log = "";
                                        foreach my $build_cmd (@{$req->{'json'}{'source_info'}{'commands'}{'build'}}) {
                                            logger('info', "executing '$build_cmd'...\n", 3);
                                            ($command, $command_output, $rc) = run_command("$build_cmd");
                                            $build_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                                            if ($rc != 0) {
                                                logger('info', "failed\n", 4);
                                                logger('error', $build_cmd_log);
                                                logger('error', "Build failed on command '$build_cmd'!\n");
                                                exit 30;
                                            }
                                        }
                                        logger('info', "succeeded\n", 2);
                                        logger('verbose', $build_cmd_log);
                                    } else {
                                        logger('info', "failed\n", 2);
                                        logger('error', "Could not chdir to '$get_dir'!\n");
                                        exit 29;
                                    }
                                } else {
                                    logger('info', "failed\n", 2);
                                    command_logger('error', $command, $rc, $command_output);
                                    logger('error', "Could not unpack source package!\n");
                                    exit 29;
                                }
                            } else {
                                logger('info', "failed\n", 2);
                                command_logger('error', $command, $rc, $command_output);
                                logger('error', "Could not get unpack directory!\n");
                                exit 28;
                            }
                        } else {
                            logger('info', "failed\n", 2);
                            command_logger('error', $command, $rc, $command_output);
                            logger('error', "Could not download $req->{'json'}{'source_info'}{'url'}!\n");
                            exit 27;
                        }
                    } else {
                        logger('info', "failed\n", 1);
                        logger('error', "Could not chdir to /root!\n");
                        exit 26;
                    }
                } elsif ($req->{'json'}{'type'} eq 'manual') {
                    logger('info', "installing package via manually provided commands...\n", 1);

                    my $install_cmd_log = "";
                    foreach my $cmd (@{$req->{'json'}{'manual_info'}{'commands'}}) {
                        logger('info', "executing '$cmd'...\n", 2);
                        ($command, $command_output, $rc) = run_command("$cmd");
                        $install_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                        if ($rc != 0){
                            logger('info', "failed [rc=$rc]\n", 3);
                            logger('error', $install_cmd_log);
                            logger('error', "Failed to run command '$cmd'\n");
                            exit 25;
                        }
                    }
                    logger('info', "succeeded\n", 1);
                    logger('verbose', $install_cmd_log);
                }
            }

            if ($distro_installs) {
                logger('info', "Cleaning up after performing distro package installations...\n");
                ($command, $command_output, $rc) = run_command("$clean_cmd");
                if ($rc != 0) {
                    logger('info', "failed\n", 1);
                    command_logger('error', $command, $rc, $command_output);
                    logger('error', "Cleaning up after distro package installation failed!\n");
                    exit 26;
                } else {
                    logger('info', "succeeded\n", 1);
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

# copy over any files from any requirements
foreach my $req (@{$active_requirements{'array'}}) {
    if ($req->{'json'}{'type'} eq 'files') {
        # currently a single, local file is supported
        if ($req->{'json'}{'files_info'}{'type'} eq 'local-copy') {
            if (-e $req->{'json'}{'files_info'}{'src'}) {
                if (defined $req->{'json'}{'files_info'}{'dst'}) {
                    ($command, $command_output, $rc) = run_command("/bin/cp -LR " .
                                                                   $req->{'json'}{'files_info'}{'src'} .
                                                                   " " . $container_mount_point . "/" .
                                                                   $req->{'json'}{'files_info'}{'dst'});
                    if ($rc != 0) {
                        logger('info', "failed\n", 1);
                        command_logger('error', $command, $rc, $command_output);
                        logger('error', "Failed to copy \"$req->{'json'}{'files_info'}{'src'}\" to the temporary container!\n");
                        exit 35;
                    }
                } else {
                    logger('info', "failed\n", 1);
                    command_logger('error', $command, $rc, $command_output);
                    logger('error', "Destination \"$req->{'json'}{'files_info'}{'dst'}\" not defined!\n");
                    exit 36;
                }
            } else {
                logger('info', "failed\n", 1);
                command_logger('error', $command, $rc, $command_output);
                logger('error', "Local source file \"$req->{'json'}{'files_info'}{'src'}\" not found!\n");
                print Dumper $req;
                exit 36;
            }
            logger('info', "succeeded\n", 1);
            command_logger('verbose', $command, $rc, $command_output);
        } else {
            logger('info', "failed\n", 1);
            command_logger('error', $command, $rc, $command_output);
            logger('error', "file requirement type \"$req->{'json'}{'files_info'}{'type'}\" not supported!\n");
            exit 37;
        }
    }
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
logger('info', "Creation of container image '$tmp_container' is complete.  Retreiving some details about your new image...\n");
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
