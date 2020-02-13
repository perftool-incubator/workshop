#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use JSON;

use Data::Dumper;

my $me = "workshop";

my %args;
$args{'log-level'} = 'info';
$args{'skip-update'} = 'false';

my @cli_args = ( '--log-level', '--requirements', '--skip-update', '--target' );
my %log_levels = ( 'info' => 1, 'verbose' => 1, 'debug' => 1 );
my %update_options = ( 'true' => 1, 'false' => 1 );

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
    my ($log_level, $log_msg) = @_;

    if (!defined($log_msg)) {
	$log_msg = 'log_msg not defined';
    }

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
    } elsif ($opt_name eq "target") {
	$args{'target'} = $opt_value;

	if (! -e $args{'target'}) {
	    die("--target must be a valid file [not '$args{'target'}']");
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
	   "target=s" => \&arg_handler)
    or die("Error in command line arguments");

logger('debug', "Argument Hash:\n");
logger('debug', Dumper(\%args));

if (exists($args{'completions'})) {
    exit 0;
}

if (! exists $args{'target'}) {
    logger('error', "You must provide --target!\n");
    exit 1;
}

my $target_json;

if (open(my $target_fh, "<", $args{'target'})) {
    my $file_contents;
    while(<$target_fh>) {
	$file_contents .= $_;
    }

    $target_json = decode_json($file_contents);

    close($target_fh);
} else {
    logger('error', "Could not open target file '$args{'target'}' for reading!\n");
    exit 2;
}

my @all_requirements;
my %active_requirements;

logger('info', 'Processing requested requirements...');

my $target_reqs = { 'name' => $args{'target'},
		    'json' => { 'targets' => { $target_json->{'label'} => { 'packages' => [] } },
				'packages' => {} } };

if (exists($target_json->{'install'}{'packages'})) {
    foreach my $pkg (@{$target_json->{'install'}{'packages'}}) {
	push(@{$target_reqs->{'json'}{'targets'}{$target_json->{'label'}}{'packages'}}, $pkg);

	$target_reqs->{'json'}{'packages'}{$pkg} = { 'type' => 'distro',
						     'distro_info' => { 'pkg_name' => $pkg } };
    }
}

if (exists($target_json->{'install'}{'groups'})) {
    foreach my $pkg (@{$target_json->{'install'}{'groups'}}) {
	push(@{$target_reqs->{'json'}{'targets'}{$target_json->{'label'}}{'packages'}}, $pkg);

	$target_reqs->{'json'}{'packages'}{$pkg} = { 'type' => 'distro',
						     'distro_info' => { 'group_name' => $pkg } };
    }
}

push(@all_requirements, $target_reqs);

foreach my $req (@{$args{'reqs'}}) {
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
	logger('info', "failed\n");
	logger('error', "Failed to load requirement file '$req'!\n");
	exit 21;
    }
}

$active_requirements{'hash'} = ();
$active_requirements{'array'} = [];

foreach my $tmp_req (@all_requirements) {
    my $target_label;

    if (exists($tmp_req->{'json'}{'targets'}{$target_json->{'label'}})) {
	$target_label = $target_json->{'label'};
    } elsif (exists($tmp_req->{'json'}{'targets'}{'default'})) {
	$target_label = 'default';
    } else {
	logger('info', "failed\n");
	logger('error', "Could not find appropriate target match in requirements '$tmp_req->{'name'}' for '$target_json->{'label'}'!\n");
	exit 22;
    }

    for my $target_package (@{$tmp_req->{'json'}{'targets'}{$target_label}{'packages'}}) {
	if (exists($active_requirements{'hash'}{$target_package})) {
	    if (($tmp_req->{'json'}{'packages'}{$target_package}{'type'} eq 'distro') &&
		($active_requirements{'hash'}{$target_package}{'requirement_type'} eq 'distro')) {
		push(@{$active_requirements{'hash'}{$target_package}{'requirement_sources'}}, $tmp_req->{'name'});
	    } else {
		logger('info', "failed\n");
		logger('debug', "All Requirements Hash:\n");
		logger('debug', Dumper(\@all_requirements));
		logger('error', "There is a target package conflict between '$tmp_req->{'name'}' with type '$tmp_req->{'json'}{'packages'}{$target_package}{'type'}' and '" .
		       join(',', @{$active_requirements{'hash'}{$target_package}{'requirement_sources'}}) .
		       "' with type '$active_requirements{'hash'}{$target_package}{'requirement_type'}' for '$target_package'!\n");
		exit 23;
	    }
	} else {
	    $active_requirements{'hash'}{$target_package} = { 'requirement_sources' => [
								  $tmp_req->{'name'}
								  ],
							      'requirement_type' => $tmp_req->{'json'}{'packages'}{$target_package}{'type'} };

	    push(@{$active_requirements{'array'}}, { 'label' => $target_package,
						     'json' => $tmp_req->{'json'}{'packages'}{$target_package} });
	}
    }
}

# requirements processing end
logger('info', "succeeded\n");

logger('debug', "All Requirements Hash:\n");
logger('debug', Dumper(\@all_requirements));
logger('debug', "Active Requirements Hash:\n");
logger('debug', Dumper(\%active_requirements));

my $command;
my $command_output;
my $rc;

my $container_mount_point;

# acquire the target source
($command, $command_output, $rc) = run_command("buildah images --json $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}");
if ($rc == 0) {
    logger('info', "Found $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} locally\n");
    command_logger('verbose', $command, $rc, $command_output);
    $target_json->{'source'}{'local_details'} = decode_json($command_output);
} else {
    logger('info', "Could not find $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}, attempting to download...");
    command_logger('verbose', $command, $rc, $command_output);
    ($command, $command_output, $rc) = run_command("buildah pull --quiet $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}");
    if ($rc == 0) {
	logger('info', "succeeded\n");
	command_logger('verbose', $command, $rc, $command_output);

	logger('info', "Querying for information about the image...");
	($command, $command_output, $rc) = run_command("buildah images --json $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}");
	if ($rc == 0) {
	    logger('info', "succeeded\n");
	    command_logger('verbose', $command, $rc, $command_output);
	    $target_json->{'source'}{'local_details'} = decode_json($command_output);
	} else {
	    logger('info', "failed\n");
	    command_logger('error', $command, $rc, $command_output);
	    logger('error', "Failed to download/query $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}!\n");
	    exit 3;
	}
    } else {
	logger('info', "failed\n");
	command_logger('error', $command, $rc, $command_output);
	logger('error', "Failed to download $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}!\n");
	exit 4;
    }
}

logger('debug', "Target JSON:\n");
logger('debug', Dumper($target_json));

my $tmp_container = $me . "_" . $target_json->{'label'};

# make sure there isn't an old container hanging around
logger('info', "Checking for stale container presence...");
($command, $command_output, $rc) = run_command("buildah containers --filter name=$tmp_container --json");
if ($command_output !~ /null/) {
    logger('info', "found\n");
    command_logger('verbose', $command, $rc, $command_output);

    # need to clean up an old container
    logger('info', "Cleaning up old container...");
    ($command, $command_output, $rc) = run_command("buildah rm $tmp_container");
    if ($rc != 0) {
	logger('info', "failed\n");
	command_logger('error', $command, $rc, $command_output);
	logger('error', "Could not clean up old container '$tmp_container'!\n");
	exit 5;
    } else {
	logger('info', "succeeded\n");
	command_logger('verbose', $command, $rc, $command_output);
    }
} else {
    logger('info', "not found\n");
    command_logger('verbose', $command, $rc, $command_output);
}

# cleanup an existing container image that we are going to replace, if it exists
logger('info', "Checking if container image already exists...");
($command, $command_output, $rc) = run_command("buildah images --json $tmp_container");
if ($rc == 0) {
    logger('info', "found\n");
    command_logger('verbose', $command, $rc, $command_output);
    logger('info', "Removing existing container image that I am about to replace [$tmp_container]...");
    ($command, $command_output, $rc) = run_command("buildah rmi $tmp_container");
    if ($rc != 0) {
	logger('info', "failed\n");
	command_logger('error', $command, $rc, $command_output);
	logger('error', "Could not remove existing container image '$tmp_container'!\n");
	exit 11;
    } else {
	logger('info', "succeeded\n");
	command_logger('verbose', $command, $rc, $command_output);
    }
} else {
    logger('info', "not found\n");
    command_logger('verbose', $command, $rc, $command_output);
}

# create a new container based on the target source
logger('info', "Creating temporary container...");
($command, $command_output, $rc) = run_command("buildah from --name $tmp_container $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}");
if ($rc != 0) {
    logger('info', "failed\n");
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Could not create new container '$tmp_container' from '$target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}'!\n");
    exit 6;
} else {
    logger('info', "succeeded\n");
    command_logger('verbose', $command, $rc, $command_output);
}

my $update_cmd = "";
my $clean_cmd = "";
if ($target_json->{'install'}{'manager'} eq "dnf") {
    $update_cmd = "dnf update --assumeyes";
    $clean_cmd = "dnf clean all";
} elsif ($target_json->{'install'}{'manager'} eq "yum") {
    $update_cmd = "yum update --assumeyes";
    $clean_cmd = "yum clean all";
} else {
    logger('error', "Unsupported target package manager encountered [$target_json->{'install'}{'manager'}]\n");
    exit 23;
}

if ($args{'skip-update'} eq 'false') {
    # update the container's existing content
    logger('info', "Updating the temporary container...");
    ($command, $command_output, $rc) = run_command("buildah run $tmp_container -- $update_cmd");
    if ($rc != 0) {
	logger('info', "failed\n");
	command_logger('error', $command, $rc, $command_output);
	logger('error', "Updating the temporary container '$tmp_container' failed!\n");
	exit 7;
    } else {
	logger('info', "succeeded\n");
	command_logger('verbose', $command, $rc, $command_output);
    }

    logger('info', "Cleaning up after the update...");
    ($command, $command_output, $rc) = run_command("buildah run $tmp_container -- $clean_cmd");
    if ($rc != 0) {
	logger('info', "failed\n");
	command_logger('error', $command, $rc, $command_output);
	logger('error', "Updating the temporary container '$tmp_container' failed because it could not clean up after itself!\n");
	exit 12;
    } else {
	logger('info', "succeeded\n");
	command_logger('verbose', $command, $rc, $command_output);
    }
} else {
    logger('info', "Skipping update due to --skip-update\n");
}

# mount the container image
logger('info', "Mounting the temporary container's fileystem...");
($command, $command_output, $rc) = run_command("buildah mount $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n");
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to mount the temporary container's filesystem!\n");
    exit 13;
} else {
    logger('info', "succeeded\n");
    command_logger('verbose', $command, $rc, $command_output);
    chomp($command_output);
    $container_mount_point = $command_output;
}

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
	    logger('info', "Installing Requirements\n");

	    my $distro_installs = 0;
	    foreach my $req (@{$active_requirements{'array'}}) {
		logger('info', "Processing $req->{'label'}...");

		if ($req->{'json'}{'type'} eq 'distro') {
		    $distro_installs = 1;

		    logger('info', "performing distro package installation...");

		    my $install_cmd = "";
		    if ($target_json->{'install'}{'manager'} eq 'dnf') {
			if (exists($req->{'json'}{'distro_info'}{'pkg_name'})) {
			    $install_cmd = "dnf install --assumeyes " . $req->{'json'}{'distro_info'}{'pkg_name'};
			} elsif (exists($req->{'json'}{'distro_info'}{'group_name'})) {
			    $install_cmd = "dnf groupinstall --assumeyes " . $req->{'json'}{'distro_info'}{'group_name'};
			}
		    } elsif ($target_json->{'install'}{'manager'} eq 'yum') {
			if (exists($req->{'json'}{'distro_info'}{'pkg_name'})) {
			    $install_cmd = "yum install --assumeyes " . $req->{'json'}{'distro_info'}{'pkg_name'};
			} elsif (exists($req->{'json'}{'distro_info'}{'group_name'})) {
			    $install_cmd = "yum groupinstall --assumeyes " . $req->{'json'}{'distro_info'}{'group_name'};
			}
		    } else {
			logger('info', "failed\n");
			logger('error', "Unsupported target package manager encountered [$target_json->{'install'}{'manager'}]\n");
			exit 23;
		    }

		    ($command, $command_output, $rc) = run_command("$install_cmd");
		    if ($rc == 0) {
			logger('info', "succeeded\n");
			command_logger('verbose', $command, $rc, $command_output);
		    } else {
			logger('info', "failed [rc=$rc]\n");
			command_logger('error', $command, $rc, $command_output);
			logger('error', "Failed to install package $req->{'json'}{'distro_info'}{'pkg_name'}\n");
			exit 24;
		    }

		} elsif ($req->{'json'}{'type'} eq 'source') {
		    logger('info', "building package from source for installation...");

		    if (chdir('/root')) {
			logger('info', 'downloading...');
			($command, $command_output, $rc) = run_command("curl --url $req->{'json'}{'source_info'}{'url'} --output $req->{'json'}{'source_info'}{'filename'} --location");
			if ($rc == 0) {
			    logger('info', 'getting directory...');
			    ($command, $command_output, $rc) = run_command("$req->{'json'}{'source_info'}{'commands'}{'get_dir'}");
			    my $get_dir = $command_output;
			    chomp($get_dir);
			    if ($rc == 0) {
				logger('info', 'unpacking...');
				($command, $command_output, $rc) = run_command("$req->{'json'}{'source_info'}{'commands'}{'unpack'}");
				if ($rc == 0) {
				    if (chdir($get_dir)) {
					logger('info', 'building...');
					my $build_cmd_log = "";
					foreach my $build_cmd (@{$req->{'json'}{'source_info'}{'commands'}{'build'}}) {
					    ($command, $command_output, $rc) = run_command("$build_cmd");
					    $build_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
					    if ($rc != 0) {
						logger('info', "failed\n");
						logger('error', $build_cmd_log);
						logger('error', "Build failed on command '$build_cmd'!\n");
						exit 30;
					    }
					}
					logger('info', "succeeded\n");
					logger('verbose', $build_cmd_log);
				    } else {
					logger('info', "failed\n");
					logger('error', "Could not chdir to '$get_dir'!\n");
					exit 29;
				    }
				} else {
				    logger('info', "failed\n");
				    command_logger('error', $command, $rc, $command_output);
				    logger('error', "Could not unpack source package!\n");
				    exit 29;
				}
			    } else {
				logger('info', "failed\n");
				command_logger('error', $command, $rc, $command_output);
				logger('error', "Could not get unpack directory!\n");
				exit 28;
			    }

			} else {
			    logger('info', "failed\n");
			    command_logger('error', $command, $rc, $command_output);
			    logger('error', "Could not download $req->{'json'}{'source_info'}{'url'}!\n");
			    exit 27;
			}
		    } else {
			logger('info', "failed\n");
			logger('error', "Could not chdir to /root!\n");
			exit 26;
		    }
		} elsif ($req->{'json'}{'type'} eq 'manual') {
		    logger('info', "installing package via manually provided commands...");

		    my $install_cmd_log = "";
		    foreach my $cmd (@{$req->{'json'}{'manual_info'}{'commands'}}) {
			logger('info', "executing '$cmd'...");
			($command, $command_output, $rc) = run_command("$cmd");
			$install_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
			if ($rc != 0){
			    logger('info', "failed [rc=$rc]\n");
			    logger('error', $install_cmd_log);
			    logger('error', "Failed to run command '$cmd'\n");
			    exit 25;
			}
		    }
		    logger('info', "succeeded\n");
		    logger('verbose', $install_cmd_log);
		}
	    }

	    if ($distro_installs) {
		logger('info', "Cleaning up after performing distro package installations...");
		($command, $command_output, $rc) = run_command("$clean_cmd");
		if ($rc != 0) {
		    logger('info', "failed\n");
		    command_logger('error', $command, $rc, $command_output);
		    logger('error', "Cleaning up after distro package installation failed!\n");
		    exit 26;
		} else {
		    logger('info', "succeeded\n");
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

# unmount the container image
logger('info', "Unmounting the temporary container's filesystem...");
($command, $command_output, $rc) = run_command("buildah unmount $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n");
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to unmount the temporary container's filesystem [$container_mount_point]!\n");
    exit 14;
} else {
    logger('info', "succeeded\n");
    command_logger('verbose', $command, $rc, $command_output);
}

# create the new container image
logger('info', "Creating new container image...");
($command, $command_output, $rc) = run_command("buildah commit --quiet $tmp_container $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n");
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to create new container image '$tmp_container'!\n");
    exit 8;
} else {
    logger('info', "succeeded\n");
    command_logger('verbose', $command, $rc, $command_output);
}

# clean up the temporary container
logger('info', "Cleaning up the temporary container...");
($command, $command_output, $rc) = run_command("buildah rm $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n");
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to cleanup temporary container '$tmp_container'!\n");
    exit 9;
} else {
    logger('info', "succeeded\n");
    command_logger('verbose', $command, $rc, $command_output);
}

# give the user information about the new container image
logger('info', "Creation of container image '$tmp_container' is complete.  Retreiving some details about your new image...");
($command, $command_output, $rc) = run_command("buildah images --json $tmp_container");
if ($rc == 0) {
    logger('info', "succeeded\n");
    logger('info', "\n$command_output\n");
    exit 0;
} else {
    logger('info', "failed\n");
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Could not get container image information for '$tmp_container'!  Something must have gone wrong that I don't understand.\n");
    exit 10;
}
