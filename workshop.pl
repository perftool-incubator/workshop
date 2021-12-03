#!/usr/bin/perl
# -*- mode: perl; indent-tabs-mode: nil; perl-indent-level: 4 -*-
# vim: autoindent tabstop=4 shiftwidth=4 expandtab softtabstop=4 filetype=perl

use strict;
use warnings;

use Getopt::Long;
use JSON;
use Scalar::Util qw(looks_like_number);
use File::Basename;
use Digest::SHA qw(sha256_hex);
use Coro;
use JSON::Validator;

use Data::UUID;
my $uuid = Data::UUID->new;

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Pair = ' : ';
$Data::Dumper::Useqq = 1;
$Data::Dumper::Indent = 1;

BEGIN {
    if (!(exists $ENV{'TOOLBOX_HOME'} && -d "$ENV{'TOOLBOX_HOME'}/perl")) {
        print "This script requires libraries that are provided by the toolbox project.\n";
        print "Toolbox can be acquired from https://github.com/perftool-incubator/toolbox and\n";
        print "then use 'export TOOLBOX_HOME=/path/to/toolbox' so that it can be located.\n";
        exit 1;
    }
}
use lib "$ENV{'TOOLBOX_HOME'}/perl";
use toolbox::json;

# disable output buffering
$|++;

my $indent = "    ";

my %args;
$args{'log-level'} = 'info';
$args{'skip-update'} = 'false';
$args{'force'} = 'false';
$args{'dump-config'} = 'false';
$args{'dump-files'} = 'false';
$args{'param'} = {};

my @cli_args = ( '--log-level', '--requirements', '--skip-update', '--userenv', '--force', '--config', '--dump-config', '--dump-files' );
my %log_levels = ( 'info' => 1, 'verbose' => 1, 'debug' => 1 );
my %update_options = ( 'true' => 1, 'false' => 1 );
my %force_options = ( 'true' => 1, 'false' => 1 );
my %dump_config_options = ( 'true' => 1, 'false' => 1);
my %dump_files_options = ( 'true' => 1, 'false' => 1);

my @virtual_fs = ('dev', 'proc', 'sys');

my $command_logger_fmt = "################################################################################\n" .
    "COMMAND:         %s\n" .
    "RETURN CODE:     %d\n" .
    "COMMAND OUTPUT:\n\n%s\n" .
    "********************************************************************************\n";

sub quit_files_coro {
    my ($present, $channel) = @_;

    if ($present) {
        $channel->put('quit');
    }
}

sub get_exit_code {
    my ($exit_reason) = @_;

    my %reasons = (
        'success' => 0,
        'no_userenv' => 1,
        'config_set_cmd' => 2,
        'schema_not_found' => 3,
        'userenv_failed_validation' => 4,
        'failed_opening_userenv' => 5,
        'requirement_failed_validation' => 6,
        'failed_opening_requirement' => 7,
        'userenv_missing' => 8,
        'duplicate_requirements' => 9,
        'requirement_conflict' => 10,
        'image_query' => 11,
        'image_origin_pull' => 12,
        'old_container_cleanup' => 13,
        'remove_existing_container' => 14,
        'create_container' => 15,
        'unsupported_package_manager' => 16,
        'update_failed' => 17,
        'update_cleanup' => 18,
        'container_mount' => 19,
        'virtual_fs_mount' => 20,
        'resolve.conf_backup' => 21,
        'resolv.conf_update' => 22,
        'package_install' => 23,
        'group_install' => 24,
        'build_failed' => 25,
        'chdir_failed' => 26,
        'unpack_failed' => 27,
        'unpack_dir_not_found' => 28,
        'download_failed' => 29,
        'command_run_failed' => 30,
        'install_cleanup' => 31,
        'chroot_escape_1' => 32,
        'chroot_escape_2' => 33,
        'chroot_escape_3' => 34,
        'chroot_failed' => 35,
        'directory_reference' => 36,
        'local-copy_failed' => 37,
        'copy_dst_missing' => 38,
        'config_failed_validation' => 39,
        'copy_type' => 40,
        'virtual_fs_umount' => 41,
        'resolve.conf_remove' => 42,
        'resolve.conf_restore' => 43,
        'container_umount' => 44,
        'image_create' => 45,
        'new_container_cleanup' => 46,
        'config_annotate_fail' => 47,
        'get_config_version' => 48,
        'coro_failure' => 49,
        'failed_opening_config' => 50,
        'config_set_entrypoint' => 51,
        'config_set_author' => 52,
        'config_set_annotation' => 53,
        'config_set_env' => 54,
        'config_set_port' => 55,
        'config_set_label' => 56,
        'schema_invalid_json' => 57,
        'userenv_invalid_json' => 58,
        'requirement_invalid_json' => 59,
        'config_invalid_json' => 60,
        'userenv_not_found' => 61,
        'requirement_not_found' => 62,
        'config_not_found' => 63,
        'requirement_missing' => 64,
        'config_missing' => 65,
        'cpanm_install_failed' => 70,
        'python3_install_failed' => 80,
        'npm_install_failed' => 90,
        'requirement_definition_missing' => 91,
        'no_label' => 92
        );

    if (exists($reasons{$exit_reason})) {
        return($reasons{$exit_reason});
    } else {
        logger('info', "Unknown exit code requested [$exit_reason]\n");
        return(-1);
    }
}

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

sub param_replacement {
    my ($input, $indent) = @_;

    my $str = $input;

    foreach my $key (keys %{$args{'param'}}) {
        logger('verbose', "checking for presence of '" . $key . "' in '" . $str . "'\n");
        if ($str =~ m/$key/) {
            logger('info', "replacing '" . $key . "' with '" . $args{'param'}{$key} . "' in '" . $str . "'\n", $indent);
            $str =~ s/$key/$args{'param'}{$key}/;
        }
    }

    return ($str);
}

sub run_command {
    my ($command) = @_;

    $command .= " 2>&1";
    my $command_output = `. /etc/profile; $command`;
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
        if (@lines == 0) {
            print $prefix . "\n";
        } else {
            print $prefix . $lines[$line_idx] . "\n";
        }
    } else {
        if (@lines == 0) {
            print $prefix;
        } else {
            print $prefix . $lines[$line_idx];
        }
    }
}

sub usage {
    logger("info", "\n");
    logger("info", "Usage: " . __FILE__ . " --userenv <file> [<optional arguments>]\n");
    logger("info", "\n");
    logger("info", "Required arguments:\n");
    logger("info", "\n");
    logger("info", "--userenv <file>                    User environment file\n");
    logger("info", "\n");
    logger("info", "Optional arguments: (* denotes default)\n");
    logger("info", "\n");
    logger("info", "--requirements <file>               Requirements file (can be used multiple times)\n");
    logger("info", "--label <string>                    Label to apply to container image\n");
    logger("info", "--config <file>                     Container config file\n");
    logger("info", "--log-level <info*|verbose|debug>   Control logging output\n");
    logger("info", "--skip-update <true|false*>         Should the container run it's distro update function\n");
    logger("info", "--force <true|false*>               Force the container build\n");
    logger("info", "--dump-config <true|false*>         Dump the config instead of building the container\n");
    logger("info", "--dump-files <true|false*>          Dump the files that are being manually handled\n");
    logger("info", "--param <key>=<value>               When <key> is found in the userenv and/or requirements file, substitute <value> for it\n");
    logger("info", "\n");
}

sub arg_handler {
    my ($opt_name, $opt_value) = @_;

    if ($opt_name eq "help") {
        usage();
        exit();
    } elsif ($opt_name eq "completions") {
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
        } elsif ($opt_value eq '--force') {
            foreach my $key (sort (keys %force_options)) {
                print "$key ";
            }
            print "\n";
        }
    } elsif ($opt_name eq "label") {
        $args{'label'} = $opt_value;
        printf "label: [%s]\n", $args{'label'};
    } elsif ($opt_name eq "tag") {
        $args{'tag'} = $opt_value;
    } elsif ($opt_name eq "proj") {
        if ($opt_value =~ /^(\w+:\/){0,1}([^\/]+\/){0,1}([^\/]+){0,1}$/) {
            if (defined($1)) {
                $args{'proto'} = $1;
                $args{'proto'} =~ s/\/$//;
                printf "proto: [%s]\n", $args{'proto'};
            }
            if (defined($2)) {
                $args{'host'} = $2;
                $args{'host'} =~ s/\/$//;
            } else {
                $args{'host'} = 'localhost';
            }
            printf "host: [%s]\n", $args{'host'};
            if (defined($3)) {
                $args{'proj'} = $3;
                printf "proj: [%s]\n", $args{'proj'};
            }
        } else {
            die "The --proj does not match the pattern [protocol:/][host[:port]/][<project>]: " . $opt_value;
        }
    } elsif ($opt_name eq "config") {
        $args{'config'} = $opt_value;
    } elsif ($opt_name eq "userenv") {
        $args{'userenv'} = $opt_value;
    } elsif ($opt_name eq "requirements") {
        if (! exists $args{'reqs'}) {
            $args{'reqs'} = ();
        }
        push(@{$args{'reqs'}}, $opt_value);
    } elsif ($opt_name eq "skip-update") {
        if (exists ($update_options{$opt_value})) {
            $args{'skip-update'} = $opt_value;
        } else {
            die("--skip-update must be one of 'true' or 'false' [not '$opt_value']");
        }
    } elsif ($opt_name eq "force") {
        if (exists ($force_options{$opt_value})) {
            $args{'force'} = $opt_value;
        } else {
            die("--force must be one of 'true' or 'false' [not '$opt_value']");
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
    } elsif ($opt_name eq "dump-config") {
        if (exists ($dump_config_options{$opt_value})) {
            $args{'dump-config'} = $opt_value;
        } else {
            die("--dump-config must be one of 'true' or 'false' [not '$opt_value']");
        }
    } elsif ($opt_name eq "dump-files") {
        if (exists ($dump_files_options{$opt_value})) {
            $args{'dump-files'} = $opt_value;
        } else {
            die("--dump-files must be one of 'true' or 'false' [not '$opt_value']");
        }
    } elsif ($opt_name eq "param") {
        my $key = "";
        my $value = "";
        if ($opt_value =~ m/(.+)=(.+)/) {
            $key = $1;
            $value = $2;
        }
        if (($key eq "") || ($value eq "")) {
            die("--param must have a <key>=<value> parameter following it [not '$opt_value']");
        } else {
            $args{'param'}{$key} = $value;
        }
    } else {
        die("I'm confused, how did I get here [$opt_name]?");
    }
}

if (!GetOptions("completions=s" => \&arg_handler,
                "config=s" => \&arg_handler,
                "log-level=s" => \&arg_handler,
                "requirements=s" => \&arg_handler,
                "skip-update=s" => \&arg_handler,
                "force=s" => \&arg_handler,
                "userenv=s" => \&arg_handler,
                "label=s" => \&arg_handler,
                "tag=s" => \&arg_handler,
                "proj=s" => \&arg_handler,
                "help" => \&arg_handler,
                "param=s" => \&arg_handler,
                "dump-config=s" => \&arg_handler,
                "dump-files=s" => \&arg_handler)) {
    usage();
    die("Error in command line arguments");
}

logger('debug', "Argument Hash:\n");
logger('debug', Dumper(\%args));

if (exists($args{'completions'})) {
    exit(get_exit_code('success'));
}

if (! exists $args{'userenv'}) {
    logger('error', "You must provide --userenv!\n");
    usage();
    exit(get_exit_code('no_userenv'));
}

my $command;
my $command_output;
my $dirname = dirname(__FILE__);
my $schema_location = $dirname . "/schema.json";

logger('info', "Using '$schema_location' for JSON input file schema validation\n");
logger('info', "Loading userenv definition from '$args{'userenv'}'...\n");
logger('info', "importing JSON...\n", 1);

(my $rc, my $userenv_json) = get_json_file($args{'userenv'}, $schema_location);
if ($rc == 0 and defined $userenv_json) {
    logger('info', "succeeded\n", 2);
} else {
    logger('info', "failed\n", 2);
    if ($rc == 2) {
        logger('error', "Schema file $schema_location not found!\n");
        exit(get_exit_code('schema_not_found'));
    } elsif ($rc == 3) {
        logger('error', "Cannot open schema file: $schema_location\n");
        exit(get_exit_code('failed_opening_schema'));
    } elsif ($rc == 4) {
        logger('error', "Schema $schema_location is invalid JSON!\n");
        exit(get_exit_code('schema_invalid_json'));
    } elsif ($rc == 5) {
        logger('error', "Schema validation for userenv $args{'userenv'} using schema '$schema_location' failed!\n");
        exit(get_exit_code('userenv_failed_validation'));
    } elsif ($rc == 6) {
        logger('error', "Userenv $args{'userenv'} is invalid JSON!\n");
        exit(get_exit_code('userenv_invalid_json'));
    } elsif ($rc == 8) {
        logger('error', "Userenv file $args{'userenv'} not found\n");
        exit(get_exit_code('userenv_missing'));
    } elsif ($rc == 9) {
        logger('error', "Userenv file $args{'userenv'} open failed\n");
        exit(get_exit_code('failed_opening_userenv'));
    } else {
        logger('error', "Unkown error: $rc'\n");
        exit(get_exit_code('failed_opening_userenv'));
    }
}

if (!defined $args{'proj'}) {
    if (defined $args{'label'}) {
        # Support default behavior before --proj was introduced
        $args{'proj'} = "localhost/workshop";
        $args{'label'} = $userenv_json->{'userenv'}{'name'} . "_" . $args{'label'};
    } else {
        logger('error', "You must provide --label!\n");
        usage();
        exit(get_exit_code('no_label'));
    }
} else {
    if (!defined $args{'label'}) {
        logger('error', "You must provide --label!\n");
        usage();
        exit(get_exit_code('no_label'));
    }
}
if (!defined $args{'tag'}) {
    $args{'tag'} = "latest";
}

logger('info', "calculating sha256...\n", 1);
$userenv_json->{'sha256'} = sha256_hex(Dumper($userenv_json));
logger('info', "succeeded\n", 2);

logger('debug', "Userenv Hash:\n");
logger('debug', Dumper($userenv_json));

my @all_requirements;
my %active_requirements;
my @checksums;

push(@checksums, $userenv_json->{'sha256'});

logger('info', "Loading requested requirements...\n");

logger('info', "'$args{'userenv'}'...\n", 1);
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
logger('info', "succeeded\n", 2);
push(@all_requirements, $userenv_reqs);

foreach my $req (@{$args{'reqs'}}) {
    logger('info', "'$req'...\n", 1);

    my $tmp_req = {};
    logger('info', "importing JSON...\n", 2);
    (my $rc, $tmp_req->{'json'}) = get_json_file($req, $schema_location);

    if ($rc == 0 and defined $tmp_req->{'json'}) {
        $tmp_req->{'filename'} = $req;
        logger('info', "succeeded\n", 3);
    } else {
        logger('info', "failed\n", 3);
        #logger('error', "Failed to load requirement file '$req'!\n");
        if ($rc == 2) {
            logger('error', "Schema file '$schema_location' not found!\n");
            exit(get_exit_code('schema_not_found'));
        } elsif ($rc == 3) {
            logger('error', "Cannot open schema file: '$schema_location'\n");
            exit(get_exit_code('failed_opening_schema'));
        } elsif ($rc == 4) {
            logger('error', "Schema '$schema_location' is invalid JSON!\n");
            exit(get_exit_code('schema_invalid_json'));
        } elsif ($rc == 5) {
            logger('error', "Schema validation for '$req' using schema '$schema_location' failed!\n");
            exit(get_exit_code('requirement_failed_validation'));
        } elsif ($rc == 6) {
            logger('error', "Requirement '$req' is invalid JSON!\n");
            exit(get_exit_code('requirement_invalid_json'));
        } elsif ($rc == 8) {
            logger('error', "Requirement file '$req' not found\n");
            exit(get_exit_code('requirement_missing'));
        } else {
            logger('error', "Unkown error'\n");
            exit(get_exit_code('failed_opening_requirement'));
        }
    }

    push(@all_requirements, $tmp_req);
}

$active_requirements{'hash'} = ();
$active_requirements{'array'} = [];

logger('info', "Finding active requirements...\n");
foreach my $tmp_req (@all_requirements) {
    logger('info', "processing requirements from '$tmp_req->{'filename'}'...\n", 1);

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
            logger('error', "Could not find appropriate userenv match in requirements '$tmp_req->{'filename'}' for '$userenv_json->{'userenv'}{'label'}'!\n");
            exit(get_exit_code('userenv_missing'));
        } else {
            $userenv_idx = $userenv_default_idx;
        }
    }

    foreach my $req (@{$tmp_req->{'json'}{'userenvs'}[$userenv_idx]{'requirements'}}) {
        my %local_requirements;
        my $found_req = 0;

        for (my $i=0; $i<scalar(@{$tmp_req->{'json'}{'requirements'}}); $i++) {
            if (exists($local_requirements{$tmp_req->{'json'}{'requirements'}[$i]{'name'}})) {
                logger('info', "failed\n", 2);
                logger('error', "Found multiple requirement definitions for '$tmp_req->{'json'}{'requirements'}[$i]{'name'}' in '$tmp_req->{'filename'}'!\n");
                exit(get_exit_code('duplicate_requirements'));
            } else {
                $local_requirements{$tmp_req->{'json'}{'requirements'}[$i]{'name'}} = 1;
            }

            if ($req eq $tmp_req->{'json'}{'requirements'}[$i]{'name'}) {
                $found_req = 1;

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
                        exit(get_exit_code('requirement_conflict'));
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

        if ($found_req == 0) {
            logger('info', "failed\n", 2);
            logger('error', "Could not find requirement definition '$req' for userenv '$tmp_req->{'json'}{'userenvs'}[$userenv_idx]{'name'}'!\n");
            exit(get_exit_code('requirement_definition_missing'));
        }
    }

    # requirements processing end
    logger('info', "succeeded\n", 2);
}

my $files_requirements_present = 0;

for (my $i=0; $i<scalar(@{$active_requirements{'array'}}); $i++) {
    if ($active_requirements{'array'}[$i]{'type'} eq 'files') {
        $files_requirements_present = 1;
    }

    my $digest = sha256_hex(Dumper($active_requirements{'array'}[$i]));

    $active_requirements{'array'}[$i]{'sha256'} = $digest;
    $active_requirements{'array'}[$i]{'index'} = $i;
    push(@checksums, $digest);
}

logger('debug', "All Requirements Hash:\n");
logger('debug', Dumper(\@all_requirements));
logger('debug', "Active Requirements Hash:\n");
logger('debug', Dumper(\%active_requirements));

my $config_json;

if (exists($args{'config'})) {
    logger('info', "Loading config definition from '$args{'config'}'...\n");

    logger('info', "importing JSON...\n", 1);
    (my $rc, $config_json) = get_json_file($args{'config'}, $schema_location);
    if ($rc == 0 and defined $config_json) {
        logger('info', "succeeded\n", 2);
    } else {
        logger('info', "failed\n", 2);
        if ($rc == 2) {
            logger('error', "Schema file '$schema_location' not found!\n");
            exit(get_exit_code('schema_not_found'));
        } elsif ($rc == 3) {
            logger('error', "Cannot open schema file: '$schema_location'\n");
            exit(get_exit_code('failed_opening_schema'));
        } elsif ($rc == 4) {
            logger('error', "Schema '$schema_location' is invalid JSON!\n");
            exit(get_exit_code('schema_invalid_json'));
        } elsif ($rc == 5) {
            logger('error', "Schema validation for userenv '$args{'config'}' using schema '$schema_location' failed!\n");
            exit(get_exit_code('config_failed_validation'));
        } elsif ($rc == 6) {
            logger('error', "Config '$args{'config'}' is invalid JSON!\n");
            exit(get_exit_code('config_invalid_json'));
        } elsif ($rc == 8) {
            logger('error', "Config file '$args{'userenv'}' not found\n");
            exit(get_exit_code('config_missing'));
        } elsif ($rc == 9) {
            logger('error', "Config file '$args{'userenv'} open failed'\n");
            exit(get_exit_code('failed_opening_config'));
        } else {
            logger('error', "Unkown error'\n");
            exit(get_exit_code('failed_opening_config'));
        }
    }

    logger('info', "calculating sha256...\n", 1);
    $config_json->{'sha256'} = sha256_hex(Dumper($config_json));
    logger('info', "succeeded\n", 2);

    logger('debug', "Config Hash:\n");
    logger('debug', Dumper($config_json));

    push(@checksums, $config_json->{'sha256'});
}

if ($args{'dump-config'} eq 'true') {
    logger('info', "Config dump:\n");

    my %config_dump = ();

    # consolidate information to be dumped
    $config_dump{'userenv'} = $userenv_json;
    $config_dump{'requirements'} = $active_requirements{'array'};
    $config_dump{'config'} = $config_json;

    # remove internal variables
    delete $config_dump{'userenv'}{'sha256'};
    delete $config_dump{'config'}{'sha256'};
    for (my $i=0; $i<@{$config_dump{'requirements'}}; $i++) {
        delete $config_dump{'requirements'}[$i]{'index'};
        delete $config_dump{'requirements'}[$i]{'sha256'};
    }

    logger('info', Data::Dumper->Dump([\%config_dump], [qw(*config_dump)]));

    exit()
}

if ($args{'dump-files'} eq 'true') {
    logger('info', "Files dump:\n");

    foreach my $req (@{$active_requirements{'array'}}) {
        if ($req->{'type'} eq 'files') {
            foreach my $file (@{$req->{'files_info'}{'files'}}) {
                printf "%s\n", param_replacement($file->{'src'}, 0);
            }
        }
    }

    exit()
}

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
            exit(get_exit_code('image_query'));
        }
    } else {
        logger('info', "failed\n", 2);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to download $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}!\n");
        exit(get_exit_code('image_origin_pull'));
    }
}

logger('debug', "Userenv JSON:\n");
logger('debug', Dumper($userenv_json));

my $config_checksum = "";

logger('info', "Building image checksum...\n");

if ($args{'skip-update'} eq 'false') {
    # since we can't really know what happens when we do a distro
    # update, add a checksum to the list that cannot be reproduced.
    # this will cause an image rebuild to always happen when images
    # that have distro updates are being considered.

    logger('info', "obtaining update checksum...\n", 1);
    my $digest = sha256_hex($uuid->create_str());
    push(@checksums, $digest);
    logger('info', "succeeded\n", 2);
    logger('debug', "The sha256 for updating the image is '$digest'\n");
}

# add the base image checksum to the list of checksums
my $digest = $userenv_json->{'userenv'}{'origin'}{'local_details'}[0]{'digest'};
$digest =~ s/^sha256://;
push(@checksums, $digest);

logger('info', "creating image checksum...\n", 1);
$config_checksum = sha256_hex(join(' ', @checksums));
logger('info', "succeeded\n", 2);
logger('debug', "The sha256 for the image configuration is '$config_checksum'\n");

logger('debug', "Checksum Array:\n");
logger('debug', Dumper(\@checksums));

my $tmp_container = $args{'host'} . "/" . $args{'proj'} . "/" . $args{'label'} . ":" . $args{'tag'};

my $remove_image = 0;

# cleanup an existing container image that we are going to replace, if it exists
logger('info', "Checking if container image already exists...\n");
($command, $command_output, $rc) = run_command("buildah images --json $tmp_container");
if ($rc == 0) {
    logger('info', "found\n", 1);
    command_logger('verbose', $command, $rc, $command_output);

    logger('info', "Checking if the existing container image config version is a match...\n");
    logger('info', "getting config version from image...\n", 1);
    ($command, $command_output, $rc) = run_command("buildah inspect --type image --format '{{.ImageAnnotations.Workshop_Config_Version}}' $tmp_container");
    if ($rc != 0) {
        logger('info', "failed\n", 2);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Could not obtain container config version information from container image '$tmp_container'!\n");
        exit(get_exit_code('get_config_version'));
    } else {
        logger('info', "succeeded\n", 2);
        command_logger('verbose', $command, $rc, $command_output);

        chomp($command_output);

        logger('info', "comparing config versions...\n", 1);
        if ($command_output eq $config_checksum) {
            logger('info', "match found\n", 2);
            if ($args{'force'} eq 'false') {
                logger('info', "Exiting due to config version match -- the container image is already ready\n");
                logger('info', "To force rebuild of the container image, rerun with '--force true'.\n");
                exit(get_exit_code('success'));
            } else {
                logger('info', "Force rebuild requested, ignoring config version match\n");
            }
        } else {
            logger('info', "match not found\n", 2);
        }
    }

    $remove_image = 1;
} else {
    logger('info', "not found\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

# make sure there isn't an old container hanging around
logger('info', "Checking for stale container presence...\n");
($command, $command_output, $rc) = run_command("buildah containers --filter name=$tmp_container --json");
if ($command_output !~ /null/) {
    my $tmp_json = decode_json($command_output);

    my $found = 0;
    foreach my $container (@{$tmp_json}) {
        if ($container->{'containername'} eq $tmp_container) {
            $found = 1;
            last;
        }
    }

    if ($found) {
        logger('info', "found\n", 1);
        command_logger('verbose', $command, $rc, $command_output);

        # need to clean up an old container
        logger('info', "Cleaning up old container...\n");
        ($command, $command_output, $rc) = run_command("buildah rm $tmp_container");
        if ($rc != 0) {
            logger('info', "failed\n", 1);
            command_logger('error', $command, $rc, $command_output);
            logger('error', "Could not clean up old container '$tmp_container'!\n");
            exit(get_exit_code('old_container_cleanup'));
        } else {
            logger('info', "succeeded\n", 1);
            command_logger('verbose', $command, $rc, $command_output);
        }
    } else {
        logger('info', "not found\n", 1);
        command_logger('verbose', $command, $rc, $command_output);
    }
} else {
    logger('info', "not found\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

if ($remove_image) {
    logger('info', "Removing existing container image that I am about to replace [$tmp_container]...\n");
    ($command, $command_output, $rc) = run_command("buildah rmi $tmp_container");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Could not remove existing container image '$tmp_container'!\n");
        exit(get_exit_code('remove_existing_container'));
    } else {
        logger('info', "succeeded\n", 1);
        command_logger('verbose', $command, $rc, $command_output);
    }
}

# create a new container based on the userenv source
logger('info', "Creating temporary container...\n");
($command, $command_output, $rc) = run_command("buildah from --name $tmp_container $userenv_json->{'userenv'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Could not create new container '$tmp_container' from '$userenv_json->{'origin'}{'origin'}{'image'}:$userenv_json->{'userenv'}{'origin'}{'tag'}'!\n");
    exit(get_exit_code('create_container'));
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

my $getsrc_cmd;
my $update_cmd = "";
my $clean_cmd = "";
if ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq "dnf") {
    $update_cmd = "dnf update --assumeyes";
    $clean_cmd = "dnf clean all";
} elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq "yum") {
    $update_cmd = "yum update --assumeyes";
    $clean_cmd = "yum clean all";
} elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq "apt") {
    $getsrc_cmd = "apt-get update -y";
    $update_cmd = "apt-get dist-upgrade -y";
    $clean_cmd = "apt-get clean";
} elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq "zypper") {
    $update_cmd = "zypper update -y";
    $clean_cmd = "zypper clean";
} else {
    logger('error', "Unsupported userenv package manager encountered [$userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'}]\n");
    exit(get_exit_code('unsupported_package_manager'));
}

if (defined $getsrc_cmd) {
    # get package-manager files list
    logger('info', "Getting package-manager sources for the temporary container...\n");
    ($command, $command_output, $rc) = run_command("buildah run --isolation chroot $tmp_container -- $getsrc_cmd");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Updating the temporary container '$tmp_container' failed!\n");
        exit(get_exit_code('update_failed'));
    } else {
        logger('info', "succeeded\n", 1);
        command_logger('verbose', $command, $rc, $command_output);
    }
}

if ($args{'skip-update'} eq 'false') {
    # update the container's existing content
    logger('info', "Updating the temporary container...\n");
    ($command, $command_output, $rc) = run_command("buildah run --isolation chroot $tmp_container -- $update_cmd");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Updating the temporary container '$tmp_container' failed!\n");
        exit(get_exit_code('update_failed'));
    } else {
        logger('info', "succeeded\n", 1);
        command_logger('verbose', $command, $rc, $command_output);
    }

    logger('info', "Cleaning up after the update...\n");
    ($command, $command_output, $rc) = run_command("buildah run --isolation chroot $tmp_container -- $clean_cmd");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Updating the temporary container '$tmp_container' failed because it could not clean up after itself!\n");
        exit(get_exit_code('update_cleanup'));
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
    exit(get_exit_code('container_mount'));
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
    chomp($command_output);
    $container_mount_point = $command_output;
}

# bind mount virtual file systems that may be needed
logger('info', "Bind mounting /dev, /proc/, and /sys into the temporary container's filesystem...\n");
foreach my $fs (@virtual_fs) {
    logger('info', "mounting '/$fs'...\n", 1);
    ($command, $command_output, $rc) = run_command("mount --verbose --options bind /$fs $container_mount_point/$fs");
    if ($rc != 0) {
        logger('info', "failed\n", 2);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to mount virtual filesystem '/$fs'!\n");
        exit(get_exit_code('virtual_fs_mount'));
    } else {
        logger('info', "succeeded\n", 2);
        command_logger('verbose', $command, $rc, $command_output);
    }
}

if (-e $container_mount_point . "/etc/resolv.conf") {
    logger('info', "Backing up the temporary container's /etc/resolv.conf...\n");
    ($command, $command_output, $rc) = run_command("/bin/cp --verbose --force " . $container_mount_point . "/etc/resolv.conf " . $container_mount_point . "/etc/resolv.conf.workshop");
    ($command, $command_output, $rc) = run_command("/bin/rm --verbose --force " . $container_mount_point . "/etc/resolv.conf");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to backup the temporary container's /etc/resolv.conf!\n");
        exit(get_exit_code('resolve.conf_backup'));
    }
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

logger('info', "Temporarily copying the host's /etc/resolv.conf to the temporary container...\n");
($command, $command_output, $rc) = run_command("/bin/cp --verbose /etc/resolv.conf " . $container_mount_point . "/etc/resolv.conf");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to copy /etc/resolv.conf to the temporary container!\n");
    exit(get_exit_code('resolv.conf_update'));
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

    my $files_channel;
    my $return_channel;
    if ($files_requirements_present) {
        $files_channel = new Coro::Channel(1);
        $return_channel = new Coro::Channel(1);

        async {
            my $dir_handle;
            my $cur_pwd;

            Coro::on_enter {
                ($command, $cur_pwd, $rc) = run_command("pwd");
                chomp($cur_pwd);

                if (!chdir(*NORMAL_ROOT)) {
                    logger('error', "Failed to chdir to root during async/coro enter!\n");
                    $return_channel->put(get_exit_code('coro_failure'));
                }
                if (!chroot(".")) {
                    logger('error', "Failed to chroot to '.' during async/coro enter!\n");
                    $return_channel->put(get_exit_code('coro_failure'));
                }
                if (!chdir($pwd)) {
                    logger('error', "Failed to chdir to previous working directory '$pwd' during async/coro enter!\n");
                    $return_channel->put(get_exit_code('coro_failure'));
                }
            };

            Coro::on_leave {
                if (!chroot($container_mount_point)) {
                    logger('error', "Failed to chroot back to the container mount point during async/coro exit!\n");
                    $return_channel->put(get_exit_code('coro_failure'));
                }
                if (!chdir($cur_pwd)) {
                    logger('error', "Failed to chdir to previous working directory '$cur_pwd' during async/coro exit!\n");
                    $return_channel->put(get_exit_code('coro_failure'));
                }
            };

            my $msg = '';

            while($msg ne 'quit') {
                $msg = $files_channel->get;

                if ($msg ne 'quit') {
                    my $req = $active_requirements{'array'}[$msg];
                    my $command;
                    my $command_output;
                    my $rc;

                    foreach my $file (@{$req->{'files_info'}{'files'}}) {
                        $file->{'src'} = param_replacement($file->{'src'}, 2);
                        if (exists($file->{'dst'})) {
                            $file->{'dst'} = param_replacement($file->{'dst'}, 2);
                        }
                        logger('info', "copying '$file->{'src'}'...\n", 2);

                        if (exists($file->{'dst'})) {
                            ($command, $command_output, $rc) = run_command("buildah add $tmp_container $file->{'src'} $file->{'dst'}");
                            if ($rc != 0) {
                                logger('info', "failed\n", 3);
                                command_logger('error', $command, $rc, $command_output);
                                logger('error', "Failed to copy '$file->{'src'}' to the temporary container!\n");
                                $return_channel->put(get_exit_code('local-copy_failed'));
                            } else {
                                logger('info', "succeeded\n", 3);
                                command_logger('verbose', $command, $rc, $command_output);
                            }
                        } else {
                            logger('info', "failed\n", 3);
                            command_logger('error', $command, $rc, $command_output);
                            logger('error', "Destination '$file->{'dst'}' not defined!\n");
                            $return_channel->put(get_exit_code('copy_dst_missing'));
                        }
                    }
                }
                $return_channel->put('go');
            }
        };
    }

    # jump into the container image
    if (chroot($container_mount_point)) {
        if (chdir("/root")) {
            logger('info', "Installing Requirements\n");

            my $distro_installs = 0;
            my $req_counter = 0;
            foreach my $req (@{$active_requirements{'array'}}) {
                $req_counter += 1;
                logger('info', "(" . $req_counter . "/" . scalar(@{$active_requirements{'array'}}) . ") Processing '$req->{'name'}'...\n", 1);

                if ($req->{'type'} eq 'files') {
                    $files_channel->put($req->{'index'});
                    my $msg = $return_channel->get;
                    if ($msg ne 'go') {
                        exit($msg);
                    }
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
                            } elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq 'apt') {
                                $install_cmd = "apt-get install -y " . $pkg;
                            } elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq 'zypper') {
                                $install_cmd = "zypper install -y " . $pkg;
                            } else {
                                logger('info', "failed\n", 4);
                                logger('error', "Unsupported userenv package manager encountered [$userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'}]\n");
                                quit_files_coro($files_requirements_present, $files_channel);
                                exit(get_exit_code('unsupported_package_manager'));
                            }

                            ($command, $command_output, $rc) = run_command("$install_cmd");
                            if ($rc == 0) {
                                logger('info', "succeeded\n", 4);
                                command_logger('verbose', $command, $rc, $command_output);
                            } else {
                                logger('info', "failed [rc=$rc]\n", 4);
                                command_logger('error', $command, $rc, $command_output);
                                logger('error', "Failed to install package '$pkg'\n");
                                quit_files_coro($files_requirements_present, $files_channel);
                                exit(get_exit_code('package_install'));
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
                            } elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq 'apt') {
                                # The equivalent of 'groupinstall' is just meta-packages for apt, so no special option needed
                                $install_cmd = "apt-get install -y --assumeyes " . $grp;
                            } elsif ($userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'} eq 'zypper') {
                                $install_cmd = "zypper install -y -t pattern " . $grp;
                            } else {
                                logger('info', "failed\n", 4);
                                logger('error', "Unsupported userenv package manager encountered [$userenv_json->{'userenv'}{'properties'}{'packages'}{'manager'}]\n");
                                quit_files_coro($files_requirements_present, $files_channel);
                                exit(get_exit_code('unsupported_package_manager'));
                            }

                            ($command, $command_output, $rc) = run_command("$install_cmd");
                            if ($rc == 0) {
                                logger('info', "succeeded\n", 4);
                                command_logger('verbose', $command, $rc, $command_output);
                            } else {
                                logger('info', "failed [rc=$rc]\n", 4);
                                command_logger('error', $command, $rc, $command_output);
                                logger('error', "Failed to install group '$grp'\n");
                                quit_files_coro($files_requirements_present, $files_channel);
                                exit(get_exit_code('group_install'));
                            }
                        }
                    }
                } elsif ($req->{'type'} eq 'source') {
                    logger('info', "building package '$req->{'name'}' from source for installation...\n", 2);

                    if (chdir('/root')) {
                        my $build_cmd_log = "";
                        logger('info', "downloading...\n", 3);
                        ($command, $command_output, $rc) = run_command("curl --url $req->{'source_info'}{'url'} --output $req->{'source_info'}{'filename'} --location");
                        $build_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                        if ($rc == 0) {
                            logger('info', "getting directory...\n", 3);
                            ($command, $command_output, $rc) = run_command("$req->{'source_info'}{'commands'}{'get_dir'}");
                            $build_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                            my $get_dir = $command_output;
                            chomp($get_dir);
                            if ($rc == 0) {
                                logger('info', "unpacking...\n", 3);
                                ($command, $command_output, $rc) = run_command("$req->{'source_info'}{'commands'}{'unpack'}");
                                $build_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                                if ($rc == 0) {
                                    if (chdir($get_dir)) {
                                        logger('info', "building...\n", 3);
                                        foreach my $build_cmd (@{$req->{'source_info'}{'commands'}{'commands'}}) {
                                            logger('info', "executing '$build_cmd'...\n", 4);
                                            ($command, $command_output, $rc) = run_command("$build_cmd");
                                            $build_cmd_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                                            if ($rc != 0) {
                                                logger('info', "failed\n", 5);
                                                logger('error', $build_cmd_log);
                                                logger('error', "Build failed on command '$build_cmd'!\n");
                                                quit_files_coro($files_requirements_present, $files_channel);
                                                exit(get_exit_code('build_failed'));
                                            }
                                        }
                                        logger('info', "succeeded\n", 3);
                                        logger('verbose', $build_cmd_log);
                                    } else {
                                        logger('info', "failed\n", 3);
                                        logger('error', $build_cmd_log);
                                        logger('error', "Could not chdir to '$get_dir'!\n");
                                        quit_files_coro($files_requirements_present, $files_channel);
                                        exit(get_exit_code('chdir_failed'));
                                    }
                                } else {
                                    logger('info', "failed\n", 3);
                                    logger('error', $build_cmd_log);
                                    logger('error', "Could not unpack source package!\n");
                                    quit_files_coro($files_requirements_present, $files_channel);
                                    exit(get_exit_code('unpack_failed'));
                                }
                            } else {
                                logger('info', "failed\n", 3);
                                logger('error', $build_cmd_log);
                                logger('error', "Could not get unpack directory!\n");
                                quit_files_coro($files_requirements_present, $files_channel);
                                exit(get_exit_code('unpack_dir_not_found'));
                            }
                        } else {
                            logger('info', "failed\n", 3);
                            logger('error', $build_cmd_log);
                            logger('error', "Could not download $req->{'source_info'}{'url'}!\n");
                            quit_files_coro($files_requirements_present, $files_channel);
                            exit(get_exit_code('download_failed'));
                        }
                    } else {
                        logger('info', "failed\n", 2);
                        logger('error', "Could not chdir to /root!\n");
                        quit_files_coro($files_requirements_present, $files_channel);
                        exit(get_exit_code('chdir_failed'));
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
                            quit_files_coro($files_requirements_present, $files_channel);
                            exit(get_exit_code('command_run_failed'));
                        }
                    }
                    logger('info', "succeeded\n", 2);
                    logger('verbose', $install_cmd_log);
                } elsif ($req->{'type'} eq 'cpan') {
                    logger('info', "installing package via cpan...\n", 2);

                    my $cpan_install_log = "";
                    foreach my $cpan_package (@{$req->{'cpan_info'}{'packages'}}) {
                        logger('info', "cpan installing '$cpan_package'...\n", 3);
                        ($command, $command_output, $rc) = run_command("cpanm $cpan_package");
                        $cpan_install_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                        if ($rc != 0){
                            logger('info', "failed [rc=$rc]\n", 4);
                            logger('error', $cpan_install_log);
                            logger('error', "Failed to cpan install perl package '$cpan_package'\n");
                            quit_files_coro($files_requirements_present, $files_channel);
                            exit(get_exit_code('cpanm_install_failed'));
                        }
                    }
                    logger('info', "succeeded\n", 2);
                    logger('verbose', $cpan_install_log);
                  } elsif ($req->{'type'} eq 'node') {
                      logger('info', "installing package via npm install...\n", 2);
 
                      my $npm_install_log = "";
                      foreach my $node_package (@{$req->{'node_info'}{'packages'}}) {
                          logger('info', "npm installing '$node_package'...\n", 3);
                          ($command, $command_output, $rc) = run_command("npm install $node_package");
                          $npm_install_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                          if ($rc != 0){
                              logger('info', "failed [rc=$rc]\n", 4);
                              logger('error', $npm_install_log);
                              logger('error', "Failed to npm install node package '$node_package'\n");
                              quit_files_coro($files_requirements_present, $files_channel);
                              exit(get_exit_code('npm_install_failed'));
                          }
                      }
                      logger('info', "succeeded\n", 2);
                      logger('verbose', $npm_install_log);
                  } elsif ($req->{'type'} eq 'python3') {
                      logger('info', "installing package via python3 pip...\n", 2);

                      my $python3_install_log = "";
                      foreach my $python3_package (@{$req->{'python3_info'}{'packages'}}) {
                          logger('info', "python3 pip installing '$python3_package'...\n", 3);
                          ($command, $command_output, $rc) = run_command("/usr/bin/python3 -m pip install $python3_package");
                          $python3_install_log .= sprintf($command_logger_fmt, $command, $rc, $command_output);
                          if ($rc != 0){
                              logger('info', "failed [rc=$rc]\n", 4);
                              logger('error', $python3_install_log);
                              logger('error', "Failed to python3 pip install python3 package '$python3_package'\n");
                              quit_files_coro($files_requirements_present, $files_channel);
                              exit(get_exit_code('python3_install_failed'));
                          }
                      }
                      logger('info', "succeeded\n", 2);
                      logger('verbose', $python3_install_log);
                }
            }

            if ($distro_installs) {
                logger('info', "Cleaning up after performing distro package installations...\n");
                ($command, $command_output, $rc) = run_command("$clean_cmd");
                if ($rc != 0) {
                    logger('info', "failed\n", 1);
                    command_logger('error', $command, $rc, $command_output);
                    logger('error', "Cleaning up after distro package installation failed!\n");
                    quit_files_coro($files_requirements_present, $files_channel);
                    exit(get_exit_code('install_cleanup'));
                } else {
                    logger('info', "succeeded\n", 1);
                    command_logger('verbose', $command, $rc, $command_output);
                }
            }

            quit_files_coro($files_requirements_present, $files_channel);

            # break out of the chroot and return to the old path/pwd
            if (chdir(*NORMAL_ROOT)) {
                if (chroot(".")) {
                    if (!chdir($pwd)) {
                        logger('error', "Could not chdir back to the original path/pwd!\n");
                        exit(get_exit_code('chroot_escape_1'));
                    }
                } else {
                    logger('error', "Could not chroot out of the chroot!\n");
                    exit(get_exit_code('chroot_escape_2'));
                }
            } else {
                logger('error', "Could not chdir to escape the chroot!\n");
                exit(get_exit_code('chroot_escape_3'));
            }
        } else {
            logger('error', "Could not chdir to temporary container mount point [$container_mount_point]!\n");
            quit_files_coro($files_requirements_present, $files_channel);
            exit(get_exit_code('chdir_failed'));
        }
    } else {
        logger('error', "Could not chroot to temporary container mount point [$container_mount_point]!\n");
        quit_files_coro($files_requirements_present, $files_channel);
        exit(get_exit_code('chroot_failed'));
    }

    closedir(NORMAL_ROOT);
} else {
    logger('error', "Could not get directory reference to '/'!\n");
    exit(get_exit_code('directory_reference'));
}

# unmount virtual file systems that are bind mounted
logger('info', "Unmounting /dev, /proc/, and /sys from the temporary container's filesystem...\n");
my $umount_cmd_log = "";
foreach my $fs (@virtual_fs) {
    logger('info', "unmounting '/$fs'...\n", 1);
    ($command, $command_output, $rc) = run_command("umount --verbose $container_mount_point/$fs");
    if ($rc != 0) {
        logger('info', "failed\n", 2);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to unmount virtual filesystem '/$fs'!\n");
        exit(get_exit_code('virtual_fs_umount'));
    } else {
        logger('info', "succeeded\n", 2);
        command_logger('verbose', $command, $rc, $command_output);
    }
}

logger('info', "Removing the temporarily assigned /etc/resolv.conf from the temporary container...\n");
($command, $command_output, $rc) = run_command("/bin/rm --verbose --force " . $container_mount_point . "/etc/resolv.conf");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to remove /etc/resolv.conf from the temporary container!\n");
    exit(get_exit_code('resolve.conf_remove'));
}
logger('info', "succeeded\n", 1);
command_logger('verbose', $command, $rc, $command_output);

if (-e $container_mount_point . "/etc/resolv.conf.workshop") {
    logger('info', "Restoring the backup of the temporary container's /etc/resolv.conf...\n");
    ($command, $command_output, $rc) = run_command("/bin/cp --verbose --force " . $container_mount_point . "/etc/resolv.conf.workshop " . $container_mount_point . "/etc/resolv.conf");
    if ($rc != 0) {
        logger('info', "failed\n", 1);
        command_logger('error', $command, $rc, $command_output);
        logger('error', "Failed to restore the temporary container's /etc/resolv.conf!\n");
        exit(get_exit_code('resolve.conf_restore'));
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
    exit(get_exit_code('container_umount'));
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

# add version information to new container image
logger('info', "Adding config version information to the temporary container...\n");
($command, $command_output, $rc) = run_command("buildah config --annotation Workshop_Config_Version=$config_checksum $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to add version information to the temporary container '$tmp_container' using the config checksum '$config_checksum'!\n");
    exit(get_exit_code('config_annotate_fail'));
} else {
    logger('info', "succeeded\n", 1);
    command_logger('verbose', $command, $rc, $command_output);
}

if (exists($args{'config'})) {
    logger('info', "Adding requested config information to the temporary container...\n");

    if (exists($config_json->{'config'}{'cmd'})) {
        logger('info', "setting cmd...\n", 1);
        ($command, $command_output, $rc) = run_command("buildah config --cmd '$config_json->{'config'}{'cmd'}' $tmp_container");
        if ($rc != 0) {
            logger('info', "failed\n", 2);
            command_logger('error', $command, $rc, $command_output);
            logger('error', "Failed to add requested config cmd to the temporary container '$tmp_container'!\n");
            exit(get_exit_code('config_set_cmd'));
        } else {
            logger('info', "succeeded\n", 2);
            command_logger('verbose', $command, $rc, $command_output);
        }
    }

    if (exists($config_json->{'config'}{'entrypoint'})) {
        logger('info', "setting entrypoint...\n", 1);
        my $entrypoint = "";
        foreach my $entrypoint_arg (@{$config_json->{'config'}{'entrypoint'}}) {
            $entrypoint .= '"' . $entrypoint_arg . '",';
        }
        $entrypoint =~ s/,$//;
        ($command, $command_output, $rc) = run_command("buildah config --entrypoint '[$entrypoint]' $tmp_container");
        if ($rc != 0) {
            logger('info', "failed\n", 2);
            command_logger('error', $command, $rc, $command_output);
            logger('error', "Failed to add requested config entrypoint to the temporary container '$tmp_container'!\n");
            exit(get_exit_code('config_set_entrypoint'));
        } else {
            logger('info', "succeeded\n", 2);
            command_logger('verbose', $command, $rc, $command_output);
        }
    }

    if (exists($config_json->{'config'}{'author'})) {
        logger('info', "setting author...\n", 1);
        ($command, $command_output, $rc) = run_command("buildah config --author '$config_json->{'config'}{'author'}' $tmp_container");
        if ($rc != 0) {
            logger('info', "failed\n", 2);
            command_logger('error', $command, $rc, $command_output);
            logger('error', "Failed to add requested config author to the temporary container '$tmp_container'!\n");
            exit(get_exit_code('config_set_author'));
        } else {
            logger('info', "succeeded\n", 2);
            command_logger('verbose', $command, $rc, $command_output);
        }
    }

    if (exists($config_json->{'config'}{'annotations'})) {
        logger('info', "setting annotation(s)...\n", 1);

        for my $annotation (@{$config_json->{'config'}{'annotations'}}) {
            logger('info', "'$annotation'...\n", 2);
            ($command, $command_output, $rc) = run_command("buildah config --annotation '$annotation' $tmp_container");
            if ($rc != 0) {
                logger('info', "failed\n", 3);
                command_logger('error', $command, $rc, $command_output);
                logger('error', "Failed to add requested config annotation to the temporary container '$tmp_container'!\n");
                exit(get_exit_code('config_set_annotation'));
            } else {
                logger('info', "succeeded\n", 3);
                command_logger('verbose', $command, $rc, $command_output);
            }
        }
    }

    if (exists($config_json->{'config'}{'envs'})) {
        logger('info', "setting environment variable(s)...\n", 1);

        for my $env (@{$config_json->{'config'}{'envs'}}) {
            logger('info', "'$env'...\n", 2);
            ($command, $command_output, $rc) = run_command("buildah config --env '$env' $tmp_container");
            if ($rc != 0) {
                logger('info', "failed\n", 3);
                command_logger('error', $command, $rc, $command_output);
                logger('error', "Failed to add requested config environment variable to the temporary container '$tmp_container'!\n");
                exit(get_exit_code('config_set_env'));
            } else {
                logger('info', "succeeded\n", 3);
                command_logger('verbose', $command, $rc, $command_output);
            }
        }
    }

    if (exists($config_json->{'config'}{'ports'})) {
        logger('info', "setting port(s)...\n", 1);

        for my $port (@{$config_json->{'config'}{'ports'}}) {
            logger('info', "'$port'...\n", 2);
            ($command, $command_output, $rc) = run_command("buildah config --port $port $tmp_container");
            if ($rc != 0) {
                logger('info', "failed\n", 3);
                command_logger('error', $command, $rc, $command_output);
                logger('error', "Failed to add requested config port to the temporary container '$tmp_container'!\n");
                exit(get_exit_code('config_set_port'));
            } else {
                logger('info', "succeeded\n", 3);
                command_logger('verbose', $command, $rc, $command_output);
            }
        }
    }

    if (exists($config_json->{'config'}{'labels'})) {
        logger('info', "setting label(s)...\n", 1);

        for my $label (@{$config_json->{'config'}{'labels'}}) {
            logger('info', "'$label'...\n", 2);
            ($command, $command_output, $rc) = run_command("buildah config --label $label $tmp_container");
            if ($rc != 0) {
                logger('info', "failed\n", 3);
                command_logger('error', $command, $rc, $command_output);
                logger('error', "Failed to add requested config label to the temporary container '$tmp_container'!\n");
                exit(get_exit_code('config_set_label'));
            } else {
                logger('info', "succeeded\n", 3);
                command_logger('verbose', $command, $rc, $command_output);
            }
        }
    }
}

# create the new container image
logger('info', "Creating new container image...\n");
($command, $command_output, $rc) = run_command("buildah commit --quiet $tmp_container $tmp_container");
if ($rc != 0) {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Failed to create new container image '$tmp_container'!\n");
    exit(get_exit_code('image_create'));
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
    exit(get_exit_code('new_container_cleanup'));
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
    exit(get_exit_code('success'));
} else {
    logger('info', "failed\n", 1);
    command_logger('error', $command, $rc, $command_output);
    logger('error', "Could not get container image information for '$tmp_container'!  Something must have gone wrong that I don't understand.\n");
    exit(get_exit_code('image_query'));
}
