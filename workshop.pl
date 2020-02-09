#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use JSON;

use Data::Dumper;

my $me = "workshop";

my %args;
$args{'log-level'} = 'info';

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

    if ($opt_name eq "target") {
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
	$args{'skip-update'} = 1;
    } elsif ($opt_name eq "log-level") {
	if (($opt_value eq 'info') ||
	    ($opt_value eq 'verbose') ||
	    ($opt_value eq 'debug')) {
	    $args{'log-level'} = $opt_value;
	} else {
	    die("--log-level must be one of 'info', 'verbose', or 'debug' [not '$opt_value']\n");
	}
    } else {
	die("I'm confused, how did I get here [$opt_name]?");
    }
}

GetOptions("log-level=s" => \&arg_handler,
	   "requirements=s" => \&arg_handler,
	   "skip-update" => \&arg_handler,
	   "target=s" => \&arg_handler)
    or die("Error in command line arguments");

logger('debug', "Argument Hash:\n");
logger('debug', Dumper(\%args));

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

logger('debug', "All Requirements Hash:\n");
logger('debug', Dumper(\@all_requirements));

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
	    logger('info', "failed\n");
	    logger('error', "There is a target package conflict between '$tmp_req->{'name'}' and '$active_requirements{'hash'}{$target_package}{'requirement_source'}' for '$target_package'!\n");
	    exit 23;
	}

	$active_requirements{'hash'}{$target_package} = { 'requirement_source' => $tmp_req->{'name'} };

	push(@{$active_requirements{'array'}}, { 'label' => $target_package,
						 'json' => $tmp_req->{'json'}{'packages'}{$target_package} });
    }
}

# requirements processing end
logger('info', "succeeded\n");

logger('debug', "Active Requirements Hash:\n");
logger('debug', Dumper(\%active_requirements));

my $buildah_output;
my $rc;

my $container_mount_point;

# acquire the target source
$buildah_output = `buildah images --json $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} 2>&1`;
$rc = $? >> 8;
if ($rc == 0) {
    logger('info', "Found $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} locally\n");
    logger('verbose', $buildah_output);
    $target_json->{'source'}{'local_details'} = decode_json($buildah_output);
} else {
    logger('info', "Could not find $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}, attempting to download...");
    logger('verbose', $buildah_output);
    $buildah_output = `buildah pull --quiet $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} 2>&1`;
    $rc = $? >> 8;
    if ($rc == 0) {
	logger('info', "succeeded\n");
	logger('verbose', $buildah_output);

	logger('info', "Querying for information about the image...");
	$buildah_output = `buildah images --json $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} 2>&1`;
	$rc = $? >> 8;
	if ($rc == 0) {
	    logger('info', "succeeded\n");
	    loggeR('verbose', $buildah_output);
	    $target_json->{'source'}{'local_details'} = decode_json($buildah_output);
	} else {
	    logger('info', "failed\n");
	    logger('error', $buildah_output);
	    logger('error', "Failed to download/query $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}!\n");
	    exit 3;
	}
    } else {
	logger('info', "failed\n");
	logger('error', $buildah_output);
	logger('error', "Failed to download $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}!\n");
	exit 4;
    }
}

logger('debug', "Target JSON:\n");
logger('debug', Dumper($target_json));

my $tmp_container = $me . "_" . $target_json->{'label'};

# make sure there isn't an old container hanging around
logger('info', "Checking for stale container presence...");
$buildah_output = `buildah containers --filter name=$tmp_container --json 2>&1`;
$rc = $? >> 8;
if ($buildah_output !~ /null/) {
    logger('info', "found\n");
    logger('verbose', $buildah_output);

    # need to clean up an old container
    logger('info', "Cleaning up old container...");
    $buildah_output = `buildah rm $tmp_container 2>&1`;
    $rc = $? >> 8;
    if ($rc != 0) {
	logger('info', "failed\n");
	logger('error', $buildah_output);
	logger('error', "Could not clean up old container '$tmp_container'!\n");
	exit 5;
    } else {
	logger('info', "succeeded\n");
	logger('verbose', $buildah_output);
    }
} else {
    logger('info', "not found\n");
    logger('verbose', $buildah_output);
}

# cleanup an existing container image that we are going to replace, if it exists
logger('info', "Checking if container image already exists...");
$buildah_output = `buildah images --json $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc == 0) {
    logger('info', "found\n");
    logger('verbose', $buildah_output);
    logger('info', "Removing existing container image that I am about to replace [$tmp_container]...");
    $buildah_output = `buildah rmi $tmp_container 2>&1`;
    $rc = $? >> 8;
    if ($rc != 0) {
	logger('info', "failed\n");
	logger('error', $buildah_output);
	logger('error', "Could not remove existing container image '$tmp_container'!\n");
	exit 11;
    } else {
	logger('info', "succeeded\n");
	logger('verbose', $buildah_output);
    }
} else {
    logger('info', "not found\n");
    logger('verbose', $buildah_output);
}

# create a new container based on the target source
logger('info', "Creating temporary container...");
$buildah_output = `buildah from --name $tmp_container $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    logger('info', "failed\n");
    logger('error', $buildah_output);
    logger('error', "Could not create new container '$tmp_container' from '$target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}'!\n");
    exit 6;
} else {
    logger('info', "succeeded\n");
    logger('verbose', $buildah_output);
}

if (!exists($args{'skip-update'})) {
    # update the container's existing content

    my $update_cmd = "";
    my $clean_cmd = "";
    if ($target_json->{'packages'}{'manager'} eq "dnf") {
	$update_cmd = "dnf update --assumeyes";
	$clean_cmd = "dnf clean all";
    } elsif ($target_json->{'packages'}{'manager'} eq "yum") {
	$update_cmd = "yum update --assumeyes";
	$clean_cmd = "yum clean all";
    }

    logger('info', "Updating the temporary container...");
    $buildah_output = `buildah run $tmp_container -- $update_cmd 2>&1`;
    $rc = $? >> 8;
    if ($rc != 0) {
	logger('info', "failed\n");
	logger('error', $buildah_output);
	logger('error', "Updating the temporary container '$tmp_container' failed!\n");
	exit 7;
    } else {
	logger('info', "succeeded\n");
	logger('verbose', $buildah_output);
    }

    logger('info', "Cleaning up after the update...");
    $buildah_output = `buildah run $tmp_container -- $clean_cmd 2>&1`;
    $rc = $? >> 8;
    if ($rc != 0) {
	logger('info', "failed\n");
	logger('error', $buildah_output);
	logger('error', "Updating the temporary container '$tmp_container' failed because it could not clean up after itself!\n");
	exit 12;
    } else {
	logger('info', "succeeded\n");
	logger('verbose', $buildah_output);
    }
} else {
    logger('info', "Skipping update due to --skip-update\n");
}

# mount the container image
logger('info', "Mounting the temporary container's fileystem...");
$buildah_output = `buildah mount $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    logger('info', "failed\n");
    logger('error', $buildah_output);
    logger('error', "Failed to mount the temporary container's filesystem!\n");
    exit 13;
} else {
    logger('info', "succeeded\n");
    logger('verbose', $buildah_output);
    chomp($buildah_output);
    $container_mount_point = $buildah_output;
}

# what follows is a complicated mess of code to chroot into the
# temporary container's filesystem.  Once there all kinds of stuff can
# be done to install packages and make other tweaks to the container
# if necessary.

# capture the current path/pwd and a reference to '/'
if (opendir(NORMAL_ROOT, "/")) {
    my $pwd = `pwd`;
    chomp($pwd);

    # jump into the container image
    if (chroot($container_mount_point)) {
	if (chdir("/root")) {
	    logger('info', "I'm in the container filesystem's /root!\n");
	    logger('info', `ls` . "\n");

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
$buildah_output = `buildah unmount $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    logger('info', "failed\n");
    logger('error', $buildah_output);
    logger('error', "Failed to unmount the temporary container's filesystem [$container_mount_point]!\n");
    exit 14;
} else {
    logger('info', "succeeded\n");
    logger('verbose', $buildah_output);
}

# create the new container image
logger('info', "Creating new container image...");
$buildah_output = `buildah commit --quiet $tmp_container $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    logger('info', "failed\n");
    logger('error', $buildah_output);
    logger('error', "Failed to create new container image '$tmp_container'!\n");
    exit 8;
} else {
    logger('info', "succeeded\n");
    logger('verbose', $buildah_output);
}

# clean up the temporary container
logger('info', "Cleaning up the temporary container...");
$buildah_output = `buildah rm $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    logger('info', "failed\n");
    logger('error', $buildah_output);
    logger('error', "Failed to cleanup temporary container '$tmp_container'!\n");
    exit 9;
} else {
    logger('info', "succeeded\n");
    logger('verbose', $buildah_output);
}

# give the user information about the new container image
logger('info', "Creation of container image '$tmp_container' is complete.  Retreiving some details about your new image...");
$buildah_output = `buildah images --json $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc == 0) {
    logger('info', "succeeded\n");
    logger('info', "\n$buildah_output\n");
    exit 0;
} else {
    logger('info', "failed\n");
    logger('error', $buildah_output);
    logger('error', "Could not get container image information for '$tmp_container'!  Something must have gone wrong that I don't understand.\n");
    exit 10;
}
