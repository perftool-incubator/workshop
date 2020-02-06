#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use JSON;

use Data::Dumper;

my $me = "workshop";

my %args;

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
    }
}

GetOptions("requirements=s" => \&arg_handler,
	   "target=s" => \&arg_handler)
    or die("Error in command line arguments");

#print Dumper \%args;

if (! exists $args{'target'}) {
    print STDERR "ERROR: You must provide --target!\n";
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
    print STDERR "ERROR: Could not open target file '$args{'target'}' for reading!\n";
    exit 2;
}

my $buildah_output;
my $rc;

my $container_mount_point;

# acquire the target source
$buildah_output = `buildah images --json $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} 2>&1`;
$rc = $? >> 8;
if ($rc == 0) {
    print "Found $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} locally\n";
    $target_json->{'source'}{'local_details'} = decode_json($buildah_output);
} else {
    print "Could not find $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}, attempting to download\n";
    $buildah_output = `buildah pull --quiet $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} 2>&1`;
    $rc = $? >> 8;
    if ($rc == 0) {
	print "Download succeeded\n";
	$buildah_output = `buildah images --json $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} 2>&1`;
	$rc = $? >> 8;
	if ($rc == 0) {
	    $target_json->{'source'}{'local_details'} = decode_json($buildah_output);
	} else {
	    print STDERR "ERROR: Failed to download/query $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}!\n";
	    print STDERR "       output: $buildah_output\n";
	    exit 3;
	}
    } else {
	print STDERR "ERROR: Failed to download $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}!\n";
	print STDERR "       output: $buildah_output\n";
	exit 4;
    }
}

#print Dumper $target_json;

my $tmp_container = $me . "_" . $target_json->{'label'};

# make sure there isn't an old container hanging around
$buildah_output = `buildah containers --filter name=$tmp_container --json 2>&1`;
$rc = $? >> 8;
if ($buildah_output !~ /null/) {
    # need to clean up an old container
    print "Cleaning up old container...";
    $buildah_output = `buildah rm $tmp_container 2>&1`;
    $rc = $? >> 8;
    if ($rc != 0) {
	print "failed\n";
	print STDERR "ERROR: Could not clean up old container '$tmp_container'!\n";
	print STDERR "       output: $buildah_output\n";
	exit 5;
    } else {
	print "succeeded\n";
    }
}

# cleanup an existing container image that we are going to replace, if it exists
$buildah_output = `buildah images --json $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc == 0) {
    print "Removing existing container image that I am about to replace [$tmp_container]...";
    $buildah_output = `buildah rmi $tmp_container 2>&1`;
    $rc = $? >> 8;
    if ($rc != 0) {
	print "failed\n";
	print STDERR "ERROR: Could not remove existing container image '$tmp_container'!\n";
	print STDERR "       output: $buildah_output\n";
	exit 11;
    } else {
	print "succeeded\n";
    }
}

# create a new container based on the target source
print "Creating temporary container...";
$buildah_output = `buildah from --name $tmp_container $target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'} 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    print "failed\n";
    print STDERR "ERROR: Could not create new container '$tmp_container' from '$target_json->{'source'}{'image'}:$target_json->{'source'}{'tag'}'!\n";
    print STDERR "       output: $buildah_output\n";
    exit 6;
} else {
    print "succeeded\n";
}

# update the container's existing content
print "Updating the temporary container...";
my $update_cmd = "";
my $clean_cmd = "";
if ($target_json->{'packages'}{'manager'} eq "dnf") {
    $update_cmd = "dnf update --assumeyes";
    $clean_cmd = "dnf clean all";
} elsif ($target_json->{'packages'}{'manager'} eq "yum") {
    $update_cmd = "yum update --assumeyes";
    $clean_cmd = "yum clean all";
}
$buildah_output = `buildah run $tmp_container -- $update_cmd 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    print "failed\n";
    print STDERR "ERROR: Updating the temporary container '$tmp_container' failed!\n";
    print STDERR "       output: $buildah_output\n";
    exit 7;
} else {
    $buildah_output = `buildah run $tmp_container -- $clean_cmd 2>&1`;
    $rc = $? >> 8;
    if ($rc != 0) {
	print "failed\n";
	print STDERR "ERROR: Updating the temporary container '$tmp_container' failed because it could not clean up after itself!\n";
	print STDERR "       output: $buildah_output\n";
	exit 12;
    } else {
	print "succeeded\n";
    }
}

# mount the container image
print "Mounting the temporary container's fileystem...";
$buildah_output = `buildah mount $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    print "failed\n";
    print STDERR "ERROR: Failed to mount the temporary container's filesystem!\n";
    print STDERR "       output: $buildah_output\n";
    exit 13;
} else {
    print "succeeded\n";
    chomp($buildah_output);
    $container_mount_point = $buildah_output;
}

# what follows is a complicated mess of code to chroot into the
# temporary container's filesystem.  Once their all kinds of stuff can
# be done to install packages and make other tweaks to the container
# if necessary.

# capture the current path/pwd and a reference to '/'
if (opendir(NORMAL_ROOT, "/")) {
    my $pwd = `pwd`;
    chomp($pwd);

    # jump into the container image
    if (chroot($container_mount_point)) {
	if (chdir("/root")) {
	    print "I'm in the container filesystem's /root!\n";
	    print `ls` . "\n";

	    # break out of the chroot and return to the old path/pwd
	    if (chdir(*NORMAL_ROOT)) {
		if (chroot(".")) {
		    if (!chdir($pwd)) {
			print STDERR "ERROR: Could not chdir back to the original path/pwd!\n";
			exit 20;
		    }
		} else {
		    print STDERR "ERROR: Could not chroot out of the chroot!\n";
		    exit 19;
		}
	    } else {
		print STDERR "ERROR: Could not chdir to escape the chroot!\n";
		exit 18;
	    }
	} else {
	    print STDERR "ERROR: Could not chdir to temporary container mount point [$container_mount_point]!\n";
	    exit 17;
	}
    } else {
	print STDERR "ERROR: Could not chroot to temporary container mount point [$container_mount_point]!\n";
	exit 16;
    }

    closedir(NORMAL_ROOT);
} else {
    print STDERR "ERROR: Could not get directory reference to '/'!\n";
    exit 15;
}

# unmount the container image
print "Unmounting the temporary container's filesystem...";
$buildah_output = `buildah unmount $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    print "failed\n";
    print STDERR "ERROR: Failed to unmount the temporary container's filesystem [$container_mount_point]!\n";
    print STDERR "       output: $buildah_output\n";
    exit 14;
} else {
    print "succeeded\n";
}

# create the new container image
print "Creating new container image...";
$buildah_output = `buildah commit --quiet $tmp_container $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    print "failed\n";
    print STDERR "ERROR: Failed to create new container image '$tmp_container'!\n";
    print STDERR "       output: $buildah_output\n";
    exit 8;
} else {
    print "succeeded\n";
}

# clean up the temporary container
print "Cleaning up the temporary container...";
$buildah_output = `buildah rm $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc != 0) {
    print "failed\n";
    print STDERR "ERROR: Failed to cleanup temporary container '$tmp_container'!\n";
    print STDERR "       output: $buildah_output\n";
    exit 9;
} else {
    print "succeeded\n";
}

# give the user information about the new container image
$buildah_output = `buildah images --json $tmp_container 2>&1`;
$rc = $? >> 8;
if ($rc == 0) {
    print "Creation of container image '$tmp_container' is complete.  Here are some details about your new image:\n";
    print "\n$buildah_output\n";
    exit 0;
} else {
    print STDERR "STDERR: Could not get container image information for '$tmp_container'!\n";
    print STDERR "        Something must have gone wrong that I don't understand.\n";
    print STDERR "        output: $buildah_output\n";
    exit 10;
}
