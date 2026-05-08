#!/usr/bin/env python3
# -*- mode: python; indent-tabs-mode: nil; python-indent-level: 4 -*-
# vim: autoindent tabstop=4 shiftwidth=4 expandtab softtabstop=4 filetype=python

import argparse
import hashlib
import json
import logging
import os
import re
import shlex
import sys
import time
import uuid
from pathlib import Path

from invoke import run

TOOLBOX_HOME = os.environ.get('TOOLBOX_HOME')
if TOOLBOX_HOME is None:
    print("This script requires libraries that are provided by the toolbox project.")
    print("Toolbox can be acquired from https://github.com/perftool-incubator/toolbox and")
    print("then use 'export TOOLBOX_HOME=/path/to/toolbox' so that it can be located.")
    sys.exit(1)
else:
    p = Path(TOOLBOX_HOME) / 'python'
    if not p.exists() or not p.is_dir():
        print("ERROR: <TOOLBOX_HOME>/python ('%s') does not exist!" % (p))
        sys.exit(2)
    sys.path.append(str(p))

from toolbox.json import load_json_file, validate_schema


###############################################################################
# Logging Setup
###############################################################################

VERBOSE = 15
logging.addLevelName(VERBOSE, "VERBOSE")

def verbose(self, message, *args, **kwargs):
    if self.isEnabledFor(VERBOSE):
        self._log(VERBOSE, message, args, **kwargs)

logging.Logger.verbose = verbose

INDENT = "    "

logger = logging.getLogger(__file__)


class WorkshopFormatter(logging.Formatter):
    """Custom formatter: INFO has no prefix, others get [LEVEL] prefix."""

    def format(self, record):
        if record.levelno == logging.INFO:
            prefix = ""
        elif record.levelno == VERBOSE:
            prefix = "[VERBOSE] "
        elif record.levelno == logging.DEBUG:
            prefix = "[DEBUG] "
        elif record.levelno == logging.ERROR:
            prefix = "[ERROR] "
        else:
            prefix = "[%s] " % record.levelname
        lines = record.getMessage().split('\n')
        return '\n'.join(prefix + line for line in lines)


def log(level, msg, indent=0):
    """Log a message with indentation."""
    indentation = INDENT * indent
    for line in msg.split('\n'):
        logger.log(level, "%s%s", indentation, line)


def command_log(level, command, rc, output):
    """Log a command result in the Perl-style block format."""
    msg = (
        "################################################################################\n"
        "COMMAND:         %s\n"
        "RETURN CODE:     %d\n"
        "COMMAND OUTPUT:\n\n%s\n"
        "********************************************************************************"
    ) % (command, rc, output)
    logger.log(level, "%s", msg)


def log_result(result, level=None):
    """Log an invoke run result."""
    if level is not None:
        log_level = level
    elif result.exited == 0:
        log_level = logging.INFO
    else:
        log_level = logging.ERROR
    msg = "command '%s' exited with rc=%d:\nstdout=[\n%s]\nstderr=[\n%s]" % (
        result.command, result.exited, result.stdout, result.stderr
    )
    logger.log(log_level, "%s", msg)


def setup_logging(log_level_str):
    """Configure logging handler with WorkshopFormatter."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(WorkshopFormatter())

    level_map = {
        'info': logging.INFO,
        'verbose': VERBOSE,
        'debug': logging.DEBUG,
    }
    level = level_map.get(log_level_str, logging.INFO)
    logger.setLevel(level)
    logger.addHandler(handler)
    logger.propagate = False


###############################################################################
# Exit Codes
###############################################################################

EXIT_CODES = {
    'success': 0,
    'no_userenv': 1,
    'config_set_cmd': 2,
    'UNAVAILABLE_1': 3,
    'userenv_failed_validation': 4,
    'failed_opening_userenv': 5,
    'requirement_failed_validation': 6,
    'failed_opening_requirement': 7,
    'userenv_missing': 8,
    'duplicate_requirements': 9,
    'requirement_conflict': 10,
    'image_query': 11,
    'image_origin_pull': 12,
    'old_container_cleanup': 13,
    'remove_existing_container': 14,
    'create_container': 15,
    'unsupported_package_manager': 16,
    'update_failed': 17,
    'update_cleanup': 18,
    'UNAVAILABLE_2': 19,
    'UNAVAILABLE_3': 20,
    'UNAVAILABLE_4': 21,
    'UNAVAILABLE_5': 22,
    'package_install': 23,
    'group_install': 24,
    'build_failed': 25,
    'UNAVAILABLE_6': 26,
    'unpack_failed': 27,
    'unpack_dir_not_found': 28,
    'download_failed': 29,
    'command_run_failed': 30,
    'install_cleanup': 31,
    'UNAVAILABLE_7': 32,
    'UNAVAILABLE_8': 33,
    'UNAVAILABLE_9': 34,
    'UNAVAILABLE_10': 35,
    'UNAVAILABLE_11': 36,
    'UNAVAILABLE_12': 37,
    'UNAVAILABLE_13': 38,
    'config_failed_validation': 39,
    'UNAVAILABLE_14': 40,
    'UNAVAILABLE_15': 41,
    'UNAVAILABLE_16': 42,
    'UNAVAILABLE_17': 43,
    'UNAVAILABLE_18': 44,
    'image_create': 45,
    'new_container_cleanup': 46,
    'config_annotate_fail': 47,
    'get_config_version': 48,
    'UNAVAILABLE_19': 49,
    'failed_opening_config': 50,
    'config_set_entrypoint': 51,
    'config_set_author': 52,
    'config_set_annotation': 53,
    'config_set_env': 54,
    'config_set_port': 55,
    'config_set_label': 56,
    'UNAVAILABLE_20': 57,
    'userenv_invalid_json': 58,
    'requirement_invalid_json': 59,
    'config_invalid_json': 60,
    'UNAVAILABLE_21': 61,
    'UNAVAILABLE_22': 62,
    'UNAVAILABLE_23': 63,
    'requirement_missing': 64,
    'config_missing': 65,
    'cpanm_install_failed': 70,
    'python3_install_failed': 80,
    'npm_install_failed': 90,
    'requirement_definition_missing': 91,
    'no_label': 92,
    'package_remove': 93,
    'group_remove': 94,
    'architecture_query_failed': 95,
    'unsupported_platform_architecture': 96,
    'skopeo_inspect_failed': 97,
    'skopeo_digest_missing': 98,
    'registries_json_failed_validation': 99,
    'registries_json_invalid_json': 100,
    'registries_json_missing': 101,
    'failed_opening_registries_json': 102,
    'UNAVAILABLE_24': 103,
    'UNAVAILABLE_25': 104,
    'UNAVAILABLE_26': 105,
    'pull_token_not_found': 106,
    'set_default_user': 107,
}


def get_exit_code(reason):
    if reason in EXIT_CODES:
        return EXIT_CODES[reason]
    else:
        log(logging.INFO, "Unknown exit code requested [%s]" % reason)
        return -1


###############################################################################
# Utility Functions
###############################################################################

def run_command(command):
    """Run a command via invoke, returning (full_command, stdout, rc)."""
    full_command = command + " 2>&1"
    result = run(full_command, hide=True, warn=True)
    return (full_command, result.stdout, result.exited)


def filter_output(output):
    """Strip lines containing 'level=warning'."""
    lines = output.split('\n')
    filtered = []
    for line in lines:
        if 'level=warning' not in line:
            filtered.append(line)
        else:
            logger.debug("filtering output line=%s", line.rstrip())
    return '\n'.join(filtered)


def param_replacement(input_str, params, indent=0):
    """Substitute --param key=value replacements in a string."""
    result = input_str
    for key, value in params.items():
        logger.verbose("checking for presence of '%s' in '%s'", key, result)
        if key in result:
            log(logging.INFO, "replacing '%s' with '%s' in '%s'" % (key, value, result), indent)
            result = result.replace(key, value)
    return result


def get_volume_opt():
    """Return --volume option for /run/secrets if it exists."""
    if os.path.exists("/run/secrets"):
        return "--volume /run/secrets:/run/secrets"
    return ""


def canonical_json_sha256(obj):
    """Compute SHA-256 of canonically serialized JSON (sorted keys)."""
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


###############################################################################
# Argument Parsing
###############################################################################

CLI_ARGS = [
    '--log-level', '--requirements', '--skip-update', '--userenv',
    '--force', '--config', '--dump-config', '--dump-files',
    '--force-build-policy', '--registries-json',
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build container images using buildah",
        add_help=True,
    )
    parser.add_argument('--userenv', type=str, help='User environment file')
    parser.add_argument('--requirements', type=str, action='append', default=[], help='Requirements file (can be used multiple times)')
    parser.add_argument('--config', type=str, help='Container config file')
    parser.add_argument('--label', type=str, help='Label to apply to container image')
    parser.add_argument('--tag', type=str, help='Tag to apply to container image')
    parser.add_argument('--proj', type=str, help='Project specification [protocol:/][host/]project')
    parser.add_argument('--log-level', type=str, choices=['info', 'verbose', 'debug'], default='info', help='Control logging output')
    parser.add_argument('--skip-update', type=str, choices=['true', 'false'], default='false', help="Should the container run its distro update function")
    parser.add_argument('--force', type=str, choices=['true', 'false'], default='false', help='Force the container build')
    parser.add_argument('--dump-config', type=str, choices=['true', 'false'], default='false', help='Dump the config instead of building the container')
    parser.add_argument('--dump-files', type=str, choices=['true', 'false'], default='false', help='Dump the files that are being manually handled')
    parser.add_argument('--param', type=str, action='append', default=[], help='When <key> is found, substitute <value> for it (key=value)')
    parser.add_argument('--reg-tls-verify', type=str, choices=['true', 'false'], default='true', help='Use TLS for remote registry actions')
    parser.add_argument('--force-build-policy', type=str, choices=['missing', 'ifnewer'], help='Override the userenv build policy')
    parser.add_argument('--registries-json', type=str, help='Configuration file with details on how to access various image registries')
    parser.add_argument('--completions', type=str, nargs='?', const='all', help='Output completion options')

    return parser.parse_args()


def parse_params(param_list):
    """Convert ['k=v', ...] to dict."""
    params = {}
    for item in param_list:
        m = re.match(r'(.+)=(.+)', item)
        if m:
            params[m.group(1)] = m.group(2)
        else:
            log(logging.ERROR, "--param must have a <key>=<value> parameter following it [not '%s']" % item)
            sys.exit(1)
    return params


def parse_proj(proj_str):
    """Parse protocol/host/project from --proj string."""
    m = re.match(r'^(\w+:/){0,1}([^/]+/){0,1}([^/]+){0,1}$', proj_str)
    if not m:
        log(logging.ERROR, "The --proj does not match the pattern [protocol:/][host[:port]/][<project>]: %s" % proj_str)
        sys.exit(1)

    proto = None
    host = 'localhost'
    proj = None

    if m.group(1):
        proto = m.group(1).rstrip('/')
        log(logging.INFO, "proto: %s" % proto)
    if m.group(2):
        host = m.group(2).rstrip('/')
    log(logging.INFO, "host: %s" % host)
    if m.group(3):
        proj = m.group(3)
        log(logging.INFO, "proj: %s" % proj)

    return proto, host, proj


###############################################################################
# JSON Loading
###############################################################################

def load_and_validate_json(filepath, schema_path, file_type):
    """Load a JSON file and validate against schema. Exit on failure."""
    log(logging.INFO, "importing JSON...", 1 if file_type != 'registries' else 1)

    json_obj, err_msg = load_json_file(filepath)
    if json_obj is None:
        log(logging.INFO, "failed", 2)
        if err_msg and 'not find' in err_msg.lower():
            log(logging.ERROR, "%s file %s not found" % (file_type.capitalize(), filepath))
            sys.exit(get_exit_code('%s_missing' % file_type))
        elif err_msg and 'open' in err_msg.lower():
            log(logging.ERROR, "%s file %s open failed" % (file_type.capitalize(), filepath))
            sys.exit(get_exit_code('failed_opening_%s' % file_type))
        else:
            log(logging.ERROR, "%s %s is invalid JSON" % (file_type.capitalize(), filepath))
            sys.exit(get_exit_code('%s_invalid_json' % file_type))

    valid, err_msg = validate_schema(json_obj, schema_path)
    if not valid:
        log(logging.INFO, "failed", 2)
        log(logging.ERROR, "Schema validation for %s '%s' using schema '%s' failed" % (file_type, filepath, schema_path))
        log(logging.ERROR, "%s" % err_msg)
        sys.exit(get_exit_code('%s_failed_validation' % file_type))

    log(logging.INFO, "succeeded", 2)
    return json_obj


###############################################################################
# Requirements Resolution
###############################################################################

def resolve_requirements(all_requirements, userenv_name):
    """Resolve active requirements from all loaded requirement files.

    Returns (active_reqs_list, checksums_list).
    """
    active_hash = {}   # name -> {'sources': [filenames], 'array_index': int}
    active_array = []
    checksums = []

    log(logging.INFO, "Finding active requirements...")

    for tmp_req in all_requirements:
        log(logging.INFO, "processing requirements from '%s'..." % tmp_req['filename'], 1)

        userenv_idx = -1
        userenv_default_idx = -1
        seen_userenvs = {}

        for i, ue in enumerate(tmp_req['json']['userenvs']):
            names = ue['name'] if isinstance(ue['name'], list) else [ue['name']]
            for name in names:
                if name in seen_userenvs:
                    log(logging.INFO, "failed", 2)
                    log(logging.ERROR, "Found duplicate userenv definition for '%s' in requirements '%s'" % (name, tmp_req['filename']))
                else:
                    seen_userenvs[name] = True

                if name == userenv_name:
                    userenv_idx = i

            if ue['name'] == 'default':
                userenv_default_idx = i

        if userenv_idx == -1:
            if userenv_default_idx == -1:
                log(logging.INFO, "failed", 2)
                log(logging.ERROR, "Could not find appropriate userenv match in requirements '%s' for '%s'" % (tmp_req['filename'], userenv_name))
                sys.exit(get_exit_code('userenv_missing'))
            else:
                userenv_idx = userenv_default_idx

        for req_name in tmp_req['json']['userenvs'][userenv_idx]['requirements']:
            local_requirements = {}
            found_req = False

            for i, req_def in enumerate(tmp_req['json']['requirements']):
                if req_def['name'] in local_requirements:
                    log(logging.INFO, "failed", 2)
                    log(logging.ERROR, "Found multiple requirement definitions for '%s' in '%s'" % (req_def['name'], tmp_req['filename']))
                    sys.exit(get_exit_code('duplicate_requirements'))
                else:
                    local_requirements[req_def['name']] = True

                if req_name == req_def['name']:
                    found_req = True

                    if req_def['name'] in active_hash:
                        existing_idx = active_hash[req_def['name']]['array_index']
                        if req_def != active_array[existing_idx]:
                            log(logging.INFO, "failed", 2)
                            sources = active_hash[req_def['name']]['sources']
                            quoted = ["'%s'" % s for s in sources]
                            if len(quoted) == 1:
                                conflicts = quoted[0]
                            elif len(quoted) == 2:
                                conflicts = '%s and %s' % (quoted[0], quoted[1])
                            else:
                                conflicts = ', '.join(quoted[:-1]) + ', and ' + quoted[-1]
                            log(logging.ERROR, "Discovered a conflict between '%s' and %s for requirement '%s'" % (tmp_req['filename'], conflicts, req_name))
                            logger.debug("'%s':\n%s", tmp_req['filename'], json.dumps(req_def, indent=2))
                            logger.debug("%s:\n%s", conflicts, json.dumps(active_array[existing_idx], indent=2))
                            sys.exit(get_exit_code('requirement_conflict'))
                        else:
                            active_hash[req_def['name']]['sources'].append(tmp_req['filename'])
                    else:
                        insert_index = len(active_array)
                        active_array.append(req_def)
                        active_hash[req_def['name']] = {
                            'sources': [tmp_req['filename']],
                            'array_index': insert_index,
                        }

            if not found_req:
                log(logging.INFO, "failed", 2)
                log(logging.ERROR, "Could not find requirement definition '%s' for userenv '%s'" % (
                    req_name, tmp_req['json']['userenvs'][userenv_idx]['name']))
                sys.exit(get_exit_code('requirement_definition_missing'))

        log(logging.INFO, "succeeded", 2)

    for i, req in enumerate(active_array):
        digest = canonical_json_sha256(req)
        active_array[i]['sha256'] = digest
        active_array[i]['index'] = i
        checksums.append(digest)

    logger.debug("Active Requirements:\n%s", json.dumps(active_array, indent=2))

    return active_array, checksums


###############################################################################
# Installer Functions
###############################################################################

def _ensure_opt(container):
    """Ensure /opt exists in the container."""
    volume_opt = get_volume_opt()
    run_command("buildah run %s --isolation chroot %s -- mkdir -p /opt" % (volume_opt, container))


def install_manual(req, container, offset):
    """Install via manually provided commands using buildah run."""
    log(logging.INFO, "installing package via manually provided commands...", offset)

    _ensure_opt(container)
    volume_opt = get_volume_opt()
    install_cmd_log = ""
    for cmd in req['manual_info']['commands']:
        log(logging.INFO, "executing '%s'..." % cmd, offset + 1)
        full_cmd = "buildah run %s --isolation chroot --workingdir /opt %s -- sh -c %s" % (volume_opt, container, shlex.quote(cmd))
        command, command_output, rc = run_command(full_cmd)
        install_cmd_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
        if rc != 0:
            log(logging.INFO, "failed [rc=%d]" % rc, offset + 2)
            log(logging.ERROR, install_cmd_log)
            log(logging.ERROR, "Failed to run command '%s'" % cmd)
            sys.exit(get_exit_code('command_run_failed'))
    log(logging.INFO, "succeeded", offset + 2)
    logger.verbose("%s", install_cmd_log)


def install_cpan(req, container, offset):
    """Install Perl packages via cpanm using buildah run."""
    log(logging.INFO, "installing package via cpan...", offset)

    _ensure_opt(container)
    volume_opt = get_volume_opt()
    cpan_log = ""
    for pkg in req['cpan_info']['packages']:
        log(logging.INFO, "cpan installing '%s'..." % pkg, offset + 1)
        full_cmd = "buildah run %s --isolation chroot --workingdir /opt %s -- cpanm %s" % (volume_opt, container, pkg)
        command, command_output, rc = run_command(full_cmd)
        cpan_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
        if rc != 0:
            log(logging.INFO, "failed [rc=%d]" % rc, offset + 2)
            log(logging.ERROR, cpan_log)
            log(logging.ERROR, "Failed to cpan install perl package '%s'" % pkg)
            sys.exit(get_exit_code('cpanm_install_failed'))
    log(logging.INFO, "succeeded", offset + 2)
    logger.verbose("%s", cpan_log)


def install_node(req, container, offset):
    """Install Node packages via npm using buildah run."""
    log(logging.INFO, "installing package via npm install...", offset)

    _ensure_opt(container)
    volume_opt = get_volume_opt()
    npm_log = ""
    for pkg in req['node_info']['packages']:
        log(logging.INFO, "npm installing '%s'..." % pkg, offset + 1)
        full_cmd = "buildah run %s --isolation chroot --workingdir /opt %s -- npm install %s" % (volume_opt, container, pkg)
        command, command_output, rc = run_command(full_cmd)
        npm_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
        if rc != 0:
            log(logging.INFO, "failed [rc=%d]" % rc, offset + 2)
            log(logging.ERROR, npm_log)
            log(logging.ERROR, "Failed to npm install node package '%s'" % pkg)
            sys.exit(get_exit_code('npm_install_failed'))
    log(logging.INFO, "succeeded", offset + 2)
    logger.verbose("%s", npm_log)


def install_python(req, container, offset):
    """Install Python packages via pip using buildah run."""
    log(logging.INFO, "installing package via python3 pip...", offset)

    _ensure_opt(container)
    volume_opt = get_volume_opt()
    pip_log = ""
    for pkg in req['python3_info']['packages']:
        log(logging.INFO, "python3 pip installing '%s'..." % pkg, offset + 1)
        full_cmd = "buildah run %s --isolation chroot --workingdir /opt %s -- /usr/bin/python3 -m pip install %s" % (volume_opt, container, pkg)
        command, command_output, rc = run_command(full_cmd)
        pip_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
        if rc != 0:
            log(logging.INFO, "failed [rc=%d]" % rc, offset + 2)
            log(logging.ERROR, pip_log)
            log(logging.ERROR, "Failed to python3 pip install python3 package '%s'" % pkg)
            sys.exit(get_exit_code('python3_install_failed'))
    log(logging.INFO, "succeeded", offset + 2)
    logger.verbose("%s", pip_log)


def install_source(req, container, offset):
    """Build package from source using buildah run."""
    log(logging.INFO, "building package '%s' from source for installation..." % req['name'], offset)

    _ensure_opt(container)
    volume_opt = get_volume_opt()
    build_log = ""

    log(logging.INFO, "downloading...", offset + 1)
    max_attempts = 3
    rc = 1
    for attempt in range(1, max_attempts + 1):
        full_cmd = "buildah run %s --isolation chroot --workingdir /opt %s -- curl --fail --url %s --output %s --location" % (
            volume_opt, container, req['source_info']['url'], req['source_info']['filename'])
        command, command_output, rc = run_command(full_cmd)
        build_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
        if rc == 0:
            break
        if attempt < max_attempts:
            time.sleep(1)

    if rc != 0:
        log(logging.INFO, "failed", offset + 2)
        log(logging.ERROR, build_log)
        log(logging.ERROR, "Could not download %s" % req['source_info']['url'])
        sys.exit(get_exit_code('download_failed'))

    log(logging.INFO, "getting directory...", offset + 1)
    get_dir_cmd = "buildah run %s --isolation chroot --workingdir /opt %s -- %s" % (
        volume_opt, container, req['source_info']['commands']['get_dir'])
    command, command_output, rc = run_command(get_dir_cmd)
    build_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
    command_output = filter_output(command_output)
    get_dir = command_output.strip()

    if rc != 0:
        log(logging.INFO, "failed", offset + 2)
        log(logging.ERROR, build_log)
        log(logging.ERROR, "Could not get unpack directory")
        sys.exit(get_exit_code('unpack_dir_not_found'))

    log(logging.INFO, "unpacking...", offset + 1)
    unpack_cmd = "buildah run %s --isolation chroot --workingdir /opt %s -- %s" % (
        volume_opt, container, req['source_info']['commands']['unpack'])
    command, command_output, rc = run_command(unpack_cmd)
    build_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)

    if rc != 0:
        log(logging.INFO, "failed", offset + 2)
        log(logging.ERROR, build_log)
        log(logging.ERROR, "Could not unpack source package")
        sys.exit(get_exit_code('unpack_failed'))

    log(logging.INFO, "building...", offset + 1)
    for build_cmd in req['source_info']['commands']['commands']:
        log(logging.INFO, "executing '%s'..." % build_cmd, offset + 2)
        full_cmd = "buildah run %s --isolation chroot --workingdir /opt %s -- sh -c %s" % (
            volume_opt, container, shlex.quote("cd %s && %s" % (get_dir, build_cmd)))
        command, command_output, rc = run_command(full_cmd)
        build_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
        if rc != 0:
            log(logging.INFO, "failed", offset + 1)
            log(logging.ERROR, build_log)
            log(logging.ERROR, "Build failed on command '%s'" % build_cmd)
            sys.exit(get_exit_code('build_failed'))
    log(logging.INFO, "succeeded", offset + 2)
    logger.verbose("%s", build_log)


def install_files(req, container, params, offset):
    """Copy files into the container using buildah add."""
    for file_entry in req['files_info']['files']:
        src = param_replacement(file_entry['src'], params, 2)
        dst = param_replacement(file_entry.get('dst', ''), params, 2) if 'dst' in file_entry else None

        log(logging.INFO, "copying '%s'..." % src, offset)

        if dst:
            command, command_output, rc = run_command("buildah add %s %s %s" % (container, src, dst))
            if rc != 0:
                log(logging.INFO, "failed", offset + 1)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Failed to copy '%s' to the temporary container" % src)
            else:
                log(logging.INFO, "succeeded", offset + 1)
                command_log(VERBOSE, command, rc, command_output)
        else:
            log(logging.INFO, "failed", offset + 1)
            log(logging.ERROR, "Destination not defined for '%s'" % src)


def install_distro_manual(req, container, userenv_json, offset):
    """Manual distro package installation using buildah run."""
    log(logging.INFO, "performing manual distro package installation...", offset)

    volume_opt = get_volume_opt()
    pkg_type = userenv_json['userenv']['properties']['packages']['type']

    for pkg in req['distro-manual_info']['packages']:
        install_cmd_log = ""
        download_filename = "distro-manual-package"

        log(logging.INFO, "package '%s'..." % pkg, offset + 1)
        log(logging.INFO, "downloading...", offset + 2)

        max_attempts = 3
        rc = 1
        for attempt in range(1, max_attempts + 1):
            full_cmd = "buildah run %s --isolation chroot %s -- curl --fail --url %s --output %s --location" % (
                volume_opt, container, pkg, download_filename)
            command, command_output, rc = run_command(full_cmd)
            install_cmd_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
            if rc != 0:
                if attempt < max_attempts:
                    time.sleep(1)
            else:
                if pkg_type == 'rpm':
                    operation_cmd = "rpm --install --verbose --test %s" % download_filename
                elif pkg_type == 'pkg':
                    operation_cmd = ""
                else:
                    log(logging.INFO, "failed validation", offset + 3)
                    log(logging.ERROR, "Unsupported userenv package type encountered [%s]" % pkg_type)
                    sys.exit(get_exit_code('unsupported_package_manager'))

                if operation_cmd:
                    test_cmd = "buildah run %s --isolation chroot %s -- %s" % (volume_opt, container, operation_cmd)
                    command, command_output, rc = run_command(test_cmd)
                    install_cmd_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)
                    if rc != 0 and attempt < max_attempts:
                        time.sleep(1)

        if rc != 0:
            log(logging.INFO, "failed", offset + 3)
            log(logging.ERROR, install_cmd_log)
            log(logging.ERROR, "Could not download %s" % pkg)
            sys.exit(get_exit_code('download_failed'))

        log(logging.INFO, "succeeded", offset + 3)
        log(logging.INFO, "installing...", offset + 2)

        if pkg_type == 'rpm':
            operation_cmd = "rpm --install --verbose %s" % download_filename
        elif pkg_type == 'pkg':
            operation_cmd = "dpkg --install %s" % download_filename
        else:
            log(logging.INFO, "failed", offset + 3)
            log(logging.ERROR, "Unsupported userenv package type encountered [%s]" % pkg_type)
            sys.exit(get_exit_code('unsupported_package_manager'))

        full_cmd = "buildah run %s --isolation chroot %s -- %s" % (volume_opt, container, operation_cmd)
        command, command_output, rc = run_command(full_cmd)
        install_cmd_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)

        if rc != 0:
            log(logging.INFO, "failed [rc=%d]" % rc, offset + 3)
            log(logging.ERROR, install_cmd_log)
            log(logging.ERROR, "Failed to install package '%s'" % pkg)
            sys.exit(get_exit_code('package_install'))

        log(logging.INFO, "succeeded", offset + 3)
        log(logging.INFO, "cleaning up...", offset + 2)

        cleanup_cmd = "buildah run %s --isolation chroot %s -- rm -v %s" % (volume_opt, container, download_filename)
        command, command_output, rc = run_command(cleanup_cmd)
        install_cmd_log += "COMMAND: %s\nRC: %d\nOUTPUT:\n%s\n" % (command, rc, command_output)

        if rc != 0:
            log(logging.INFO, "failed [rc=%d]" % rc, offset + 3)
            log(logging.ERROR, install_cmd_log)
            log(logging.ERROR, "Failed to cleanup package '%s'" % pkg)
            sys.exit(get_exit_code('install_cleanup'))

        log(logging.INFO, "succeeded", offset + 3)
        logger.verbose("%s", install_cmd_log)


def install_distro(req, container, userenv_json, offset):
    """Install/remove distro packages and groups using buildah run."""
    operation = req['distro_info'].get('operation', 'install')
    volume_opt = get_volume_opt()

    environment = ""
    if 'environment' in req['distro_info']:
        env_parts = ["env"]
        for key, value in req['distro_info']['environment'].items():
            env_parts.append("%s=%s" % (key, value))
        environment = ' '.join(env_parts) + ' '

    log(logging.INFO, "performing distro package %s..." % operation, offset)

    manager = userenv_json['userenv']['properties']['packages']['manager']

    if 'packages' in req['distro_info']:
        for pkg in req['distro_info']['packages']:
            log(logging.INFO, "package '%s'..." % pkg, offset + 1)

            operation_cmd = environment + _get_pkg_cmd(manager, operation, pkg)
            full_cmd = "buildah run %s --isolation chroot %s -- %s" % (volume_opt, container, operation_cmd)
            command, command_output, rc = run_command(full_cmd)

            if rc == 0:
                log(logging.INFO, "succeeded", offset + 2)
                command_log(VERBOSE, command, rc, command_output)
            else:
                log(logging.INFO, "failed [rc=%d]" % rc, offset + 2)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Failed to %s package '%s'" % (operation, pkg))
                sys.exit(get_exit_code('package_%s' % operation))

    if 'groups' in req['distro_info']:
        for grp in req['distro_info']['groups']:
            log(logging.INFO, "group '%s'..." % grp, offset + 1)

            operation_cmd = environment + _get_group_cmd(manager, operation, grp)
            full_cmd = "buildah run %s --isolation chroot %s -- %s" % (volume_opt, container, operation_cmd)
            command, command_output, rc = run_command(full_cmd)

            if rc == 0:
                log(logging.INFO, "succeeded", offset + 2)
                command_log(VERBOSE, command, rc, command_output)
            else:
                log(logging.INFO, "failed [rc=%d]" % rc, offset + 2)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Failed to %s group '%s'" % (operation, grp))
                sys.exit(get_exit_code('group_%s' % operation))

    return True  # distro_installs flag


def _get_pkg_cmd(manager, operation, pkg):
    """Get the package manager command for a package operation."""
    cmds = {
        'dnf': {'install': 'dnf install --allowerasing --assumeyes %s', 'remove': 'dnf remove --assumeyes %s'},
        'yum': {'install': 'yum install --assumeyes %s', 'remove': 'yum remove --assumeyes %s'},
        'apt': {'install': 'apt-get install -y %s', 'remove': 'apt-get remove -y %s'},
        'zypper': {'install': 'zypper install -y %s', 'remove': 'zypper remove -y %s'},
    }
    if manager not in cmds:
        log(logging.ERROR, "Unsupported userenv package manager encountered [%s]" % manager)
        sys.exit(get_exit_code('unsupported_package_manager'))
    return cmds[manager][operation] % pkg


def _get_group_cmd(manager, operation, grp):
    """Get the package manager command for a group operation."""
    cmds = {
        'dnf': {'install': 'dnf groupinstall --allowerasing --assumeyes %s', 'remove': 'dnf groupremove --assumeyes %s'},
        'yum': {'install': 'yum groupinstall --assumeyes %s', 'remove': 'yum groupremove --assumeyes %s'},
        'apt': {'install': 'apt-get install -y --assumeyes %s', 'remove': 'apt-get remove -y --assumeyes %s'},
        'zypper': {'install': 'zypper install -y -t pattern %s', 'remove': 'zypper remove -y -t pattern %s'},
    }
    if manager not in cmds:
        log(logging.ERROR, "Unsupported userenv package manager encountered [%s]" % manager)
        sys.exit(get_exit_code('unsupported_package_manager'))
    return cmds[manager][operation] % grp


###############################################################################
# Build Pipeline Helpers
###############################################################################

def get_update_clean_cmds(userenv_json):
    """Return (getsrc_cmd, update_cmd, clean_cmd) per package manager."""
    manager = userenv_json['userenv']['properties']['packages']['manager']
    getsrc_cmd = None

    if manager == 'dnf':
        update_cmd = "dnf update --assumeyes --allowerasing --nobest"
        clean_cmd = "dnf clean all"
    elif manager == 'yum':
        update_cmd = "yum update --assumeyes"
        clean_cmd = "yum clean all"
    elif manager == 'apt':
        getsrc_cmd = "apt-get update -y"
        update_cmd = "apt-get dist-upgrade -y"
        clean_cmd = "apt-get clean"
    elif manager == 'zypper':
        update_cmd = "zypper update -y"
        clean_cmd = "zypper clean"
    else:
        log(logging.ERROR, "Unsupported userenv package manager encountered [%s]" % manager)
        sys.exit(get_exit_code('unsupported_package_manager'))

    return getsrc_cmd, update_cmd, clean_cmd


def update_container_pkgs(container, skip_update, getsrc_cmd, update_cmd, clean_cmd):
    """Update the container's packages if skip_update is false."""
    volume_opt = get_volume_opt()

    if skip_update == 'false':
        if getsrc_cmd is not None:
            log(logging.INFO, "Getting package-manager sources for the temporary container...")
            full_cmd = "buildah run %s --isolation chroot %s -- %s" % (volume_opt, container, getsrc_cmd)
            command, command_output, rc = run_command(full_cmd)
            if rc != 0:
                log(logging.INFO, "failed", 1)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Updating the temporary container '%s' failed" % container)
                sys.exit(get_exit_code('update_failed'))
            else:
                log(logging.INFO, "succeeded", 1)
                command_log(VERBOSE, command, rc, command_output)

        log(logging.INFO, "Updating the temporary container...")
        full_cmd = "buildah run %s --isolation chroot %s -- %s" % (volume_opt, container, update_cmd)
        command, command_output, rc = run_command(full_cmd)
        if rc != 0:
            log(logging.INFO, "failed", 1)
            command_log(logging.ERROR, command, rc, command_output)
            log(logging.ERROR, "Updating the temporary container '%s' failed" % container)
            sys.exit(get_exit_code('update_failed'))
        else:
            log(logging.INFO, "succeeded", 1)
            command_log(VERBOSE, command, rc, command_output)

        log(logging.INFO, "Cleaning up after the update...")
        full_cmd = "buildah run %s --isolation chroot %s -- %s" % (volume_opt, container, clean_cmd)
        command, command_output, rc = run_command(full_cmd)
        if rc != 0:
            log(logging.INFO, "failed", 1)
            command_log(logging.ERROR, command, rc, command_output)
            log(logging.ERROR, "Updating the temporary container '%s' failed because it could not clean up after itself" % container)
            sys.exit(get_exit_code('update_cleanup'))
        else:
            log(logging.INFO, "succeeded", 1)
            command_log(VERBOSE, command, rc, command_output)
    else:
        log(logging.INFO, "Skipping update due to --skip-update")


def validate_platform(userenv_json):
    """Check uname -m against supported architectures."""
    if 'platform' not in userenv_json['userenv']['properties']:
        return

    log(logging.INFO, "performing userenv platform validation...", 1)
    command, command_output, rc = run_command("uname -m")
    if rc != 0:
        log(logging.INFO, "failed", 2)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Failed to obtain the current system architecture")
        sys.exit(get_exit_code('architecture_query_failed'))

    command_log(VERBOSE, command, rc, command_output)
    command_output = filter_output(command_output)
    my_architecture = command_output.strip()
    log(logging.INFO, "found current system architecture is %s" % my_architecture, 2)

    supported = any(
        p['architecture'] == my_architecture
        for p in userenv_json['userenv']['properties']['platform']
    )

    if supported:
        log(logging.INFO, "succeeded...the userenv is supported for my architecture.", 2)
    else:
        log(logging.INFO, "failed...the userenv is not supported for my architecture.", 2)
        log(logging.ERROR, "The userenv is not supported for my architecture.")
        sys.exit(get_exit_code('unsupported_platform_architecture'))


def resolve_image_naming(args, userenv_json):
    """Resolve host/proj/label/tag defaults. Returns (host, proj, label, tag)."""
    if args.proj is None:
        if args.label is not None:
            host = 'localhost'
            proj = 'workshop'
            label = "%s_%s" % (userenv_json['userenv']['name'], args.label)
        else:
            log(logging.ERROR, "You must provide --label!")
            sys.exit(get_exit_code('no_label'))
    else:
        if args.label is None:
            log(logging.ERROR, "You must provide --label!")
            sys.exit(get_exit_code('no_label'))
        _, host, proj_parsed = parse_proj(args.proj)
        host = host
        proj = proj_parsed
        label = args.label

    tag = args.tag if args.tag else 'latest'
    return host, proj, label, tag


def resolve_pull_token(userenv_json, registries_json, reg_tls_verify):
    """Find auth token for pulling. Returns (tls_verify, authfile_arg)."""
    tls_verify = reg_tls_verify
    authfile_arg = ""

    if userenv_json['userenv']['origin'].get('requires-pull-token') != 'true':
        return tls_verify, authfile_arg

    log(logging.INFO, "Checking registries JSON for a pull token...")

    found_pull_token = False

    if registries_json and 'engines' in registries_json and 'private' in registries_json['engines']:
        private = registries_json['engines']['private']
        if private['url'] == userenv_json['userenv']['origin']['image']:
            found_pull_token = True
            log(logging.INFO, "found %s for %s private engines repository" % (
                private['tokens']['pull'], private['url']), 1)
            authfile_arg = "--authfile=%s" % private['tokens']['pull']
            if 'tls-verify' in private:
                tls_verify = private['tls-verify']
        else:
            logger.debug("does not match %s", private['url'])

    if not found_pull_token and registries_json and 'userenvs' in registries_json:
        for ue in registries_json['userenvs']:
            if ue['url'] == userenv_json['userenv']['origin']['image']:
                found_pull_token = True
                log(logging.INFO, "found %s for %s" % (ue['pull-token'], ue['url']), 1)
                authfile_arg = "--authfile=%s" % ue['pull-token']
                if 'tls-verify' in ue:
                    tls_verify = ue['tls-verify']
            else:
                logger.debug("does not match %s", ue['url'])

    if not found_pull_token:
        log(logging.INFO, "not found", 1)
        log(logging.ERROR, "Failed to locate a pull token for a userenv that requires one")
        sys.exit(get_exit_code('pull_token_not_found'))

    return tls_verify, authfile_arg


def pull_origin_image(userenv_json, tls_verify, authfile_arg):
    """Pull the origin image with buildah. Returns origin_image_id."""
    image = userenv_json['userenv']['origin']['image']
    tag = userenv_json['userenv']['origin']['tag']
    image_ref = "%s:%s" % (image, tag)

    log(logging.INFO, "Attempting to download the latest version of %s..." % image_ref)
    command, command_output, rc = run_command(
        "buildah pull --quiet --policy=ifnewer --tls-verify=%s %s %s" % (tls_verify, authfile_arg, image_ref))

    if rc != 0:
        log(logging.INFO, "failed", 1)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Failed to download %s" % image_ref)
        sys.exit(get_exit_code('image_origin_pull'))

    log(logging.INFO, "succeeded", 1)
    command_log(VERBOSE, command, rc, command_output)

    command_output = filter_output(command_output)
    origin_image_id = command_output.strip()

    log(logging.INFO, "Querying for information about the image...")
    command, command_output, rc = run_command("buildah images --json %s" % origin_image_id)
    if rc == 0:
        log(logging.INFO, "succeeded", 1)
        command_log(VERBOSE, command, rc, command_output)
        command_output = filter_output(command_output)
        userenv_json['userenv']['origin']['local_details'] = json.loads(command_output)
    else:
        log(logging.INFO, "failed", 1)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Failed to query %s (%s)" % (image_ref, origin_image_id))
        sys.exit(get_exit_code('image_query'))

    return origin_image_id


def build_config_checksum(checksums, userenv_json, skip_update):
    """Build composite SHA-256 from all checksums. Returns checksum string."""
    all_checksums = list(checksums)

    log(logging.INFO, "Building image checksum...")

    if skip_update == 'false':
        log(logging.INFO, "obtaining update checksum...", 1)
        digest = hashlib.sha256(str(uuid.uuid4()).encode()).hexdigest()
        all_checksums.append(digest)
        log(logging.INFO, "succeeded", 2)
        logger.debug("The sha256 for updating the image is '%s'", digest)

    # add the base image checksum
    digest = userenv_json['userenv']['origin']['local_details'][0]['digest']
    digest = digest.replace('sha256:', '', 1)
    all_checksums.append(digest)

    log(logging.INFO, "creating image checksum...", 1)
    config_checksum = hashlib.sha256(' '.join(all_checksums).encode()).hexdigest()
    log(logging.INFO, "succeeded", 2)
    logger.debug("The sha256 for the image configuration is '%s'", config_checksum)
    logger.debug("Checksum Array:\n%s", json.dumps(all_checksums, indent=2))

    return config_checksum


def check_existing_image(container_name, config_checksum, force):
    """Check if existing image matches checksum. Returns (should_skip, remove_image)."""
    log(logging.INFO, "Checking if container image already exists...")
    command, command_output, rc = run_command("buildah images --json %s" % container_name)

    if rc != 0:
        log(logging.INFO, "not found", 1)
        command_log(VERBOSE, command, rc, command_output)
        return False, False

    log(logging.INFO, "found", 1)
    command_log(VERBOSE, command, rc, command_output)

    log(logging.INFO, "Checking if the existing container image config version is a match...")
    log(logging.INFO, "getting config version from image...", 1)
    command, command_output, rc = run_command(
        "buildah inspect --type image --format '{{.ImageAnnotations.Workshop_Config_Version}}' %s" % container_name)

    if rc != 0:
        log(logging.INFO, "failed", 2)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Could not obtain container config version information from container image '%s'" % container_name)
        sys.exit(get_exit_code('get_config_version'))

    log(logging.INFO, "succeeded", 2)
    command_log(VERBOSE, command, rc, command_output)
    command_output = filter_output(command_output).strip()

    log(logging.INFO, "comparing config versions...", 1)
    if command_output == config_checksum:
        log(logging.INFO, "match found", 2)
        if force == 'false':
            log(logging.INFO, "Exiting due to config version match -- the container image is already ready")
            log(logging.INFO, "To force rebuild of the container image, rerun with '--force true'.")
            sys.exit(get_exit_code('success'))
        else:
            log(logging.INFO, "Force rebuild requested, ignoring config version match")
    else:
        log(logging.INFO, "match not found", 2)

    return False, True  # don't skip, but do remove


def cleanup_stale_containers(container_name):
    """Remove old containers with the given name."""
    log(logging.INFO, "Checking for stale container presence...")
    command, command_output, rc = run_command("buildah containers --filter name=%s --json" % container_name)

    if 'null' in command_output:
        log(logging.INFO, "not found", 1)
        command_log(VERBOSE, command, rc, command_output)
        return

    command_output_filtered = filter_output(command_output)
    try:
        tmp_json = json.loads(command_output_filtered)
    except json.JSONDecodeError:
        log(logging.INFO, "not found", 1)
        command_log(VERBOSE, command, rc, command_output)
        return

    found = any(c.get('containername') == container_name for c in tmp_json)

    if found:
        log(logging.INFO, "found", 1)
        command_log(VERBOSE, command, rc, command_output)

        log(logging.INFO, "Cleaning up old container...")
        command, command_output, rc = run_command("buildah rm %s" % container_name)
        if rc != 0:
            log(logging.INFO, "failed", 1)
            command_log(logging.ERROR, command, rc, command_output)
            log(logging.ERROR, "Could not clean up old container '%s'" % container_name)
            sys.exit(get_exit_code('old_container_cleanup'))
        else:
            log(logging.INFO, "succeeded", 1)
            command_log(VERBOSE, command, rc, command_output)
    else:
        log(logging.INFO, "not found", 1)
        command_log(VERBOSE, command, rc, command_output)


def create_container(container_name, origin_image_id):
    """Create a container from the origin image."""
    log(logging.INFO, "Creating temporary container...")
    command, command_output, rc = run_command("buildah from --security-opt label=disable --name %s %s" % (container_name, origin_image_id))
    if rc != 0:
        log(logging.INFO, "failed", 1)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Could not create new container '%s' from '%s'" % (container_name, origin_image_id))
        sys.exit(get_exit_code('create_container'))
    else:
        log(logging.INFO, "succeeded", 1)
        command_log(VERBOSE, command, rc, command_output)


def set_default_user(container_name):
    """Set the default user to root for the container."""
    log(logging.INFO, "Setting default user to root for the container...")
    command, command_output, rc = run_command("buildah config --user root %s" % container_name)
    if rc != 0:
        log(logging.INFO, "failed", 1)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Could not set default user to root for the temporary container '%s'" % container_name)
        sys.exit(get_exit_code('set_default_user'))
    else:
        log(logging.INFO, "succeeded", 1)
        command_log(VERBOSE, command, rc, command_output)


def install_all_requirements(active_reqs, container, userenv_json, params):
    """Dispatch installation for all requirements. Returns distro_installs flag."""
    log(logging.INFO, "Installing Requirements")

    distro_installs = False
    total = len(active_reqs)

    for i, req in enumerate(active_reqs):
        log(logging.INFO, "(%d/%d) Processing '%s'..." % (i + 1, total, req['name']), 1)

        req_type = req['type']
        if req_type == 'files':
            install_files(req, container, params, 2)
        elif req_type == 'distro-manual':
            install_distro_manual(req, container, userenv_json, 2)
        elif req_type == 'distro':
            install_distro(req, container, userenv_json, 2)
            distro_installs = True
        elif req_type == 'source':
            install_source(req, container, 2)
        elif req_type == 'python3':
            install_python(req, container, 2)
        elif req_type == 'node':
            install_node(req, container, 2)
        elif req_type == 'manual':
            install_manual(req, container, 2)
        elif req_type == 'cpan':
            install_cpan(req, container, 2)

    return distro_installs


def annotate_config_version(container, checksum):
    """Add Workshop_Config_Version annotation to the container."""
    log(logging.INFO, "Adding config version information to the temporary container...")
    command, command_output, rc = run_command(
        "buildah config --annotation Workshop_Config_Version=%s %s" % (checksum, container))
    if rc != 0:
        log(logging.INFO, "failed", 1)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Failed to add version information to the temporary container '%s' using the config checksum '%s'" % (container, checksum))
        sys.exit(get_exit_code('config_annotate_fail'))
    else:
        log(logging.INFO, "succeeded", 1)
        command_log(VERBOSE, command, rc, command_output)


def apply_container_config(container, config_json):
    """Apply config JSON settings (cmd, entrypoint, author, etc.) to the container."""
    if config_json is None:
        return

    log(logging.INFO, "Adding requested config information to the temporary container...")

    config = config_json.get('config', {})

    if 'cmd' in config:
        log(logging.INFO, "setting cmd...", 1)
        command, command_output, rc = run_command("buildah config --cmd '%s' %s" % (config['cmd'], container))
        if rc != 0:
            log(logging.INFO, "failed", 2)
            command_log(logging.ERROR, command, rc, command_output)
            log(logging.ERROR, "Failed to add requested config cmd to the temporary container '%s'" % container)
            sys.exit(get_exit_code('config_set_cmd'))
        else:
            log(logging.INFO, "succeeded", 2)
            command_log(VERBOSE, command, rc, command_output)

    if 'entrypoint' in config:
        log(logging.INFO, "setting entrypoint...", 1)
        entrypoint = ','.join('"%s"' % arg for arg in config['entrypoint'])
        command, command_output, rc = run_command("buildah config --entrypoint '[%s]' %s" % (entrypoint, container))
        if rc != 0:
            log(logging.INFO, "failed", 2)
            command_log(logging.ERROR, command, rc, command_output)
            log(logging.ERROR, "Failed to add requested config entrypoint to the temporary container '%s'" % container)
            sys.exit(get_exit_code('config_set_entrypoint'))
        else:
            log(logging.INFO, "succeeded", 2)
            command_log(VERBOSE, command, rc, command_output)

    if 'author' in config:
        log(logging.INFO, "setting author...", 1)
        command, command_output, rc = run_command("buildah config --author '%s' %s" % (config['author'], container))
        if rc != 0:
            log(logging.INFO, "failed", 2)
            command_log(logging.ERROR, command, rc, command_output)
            log(logging.ERROR, "Failed to add requested config author to the temporary container '%s'" % container)
            sys.exit(get_exit_code('config_set_author'))
        else:
            log(logging.INFO, "succeeded", 2)
            command_log(VERBOSE, command, rc, command_output)

    if 'annotations' in config:
        log(logging.INFO, "setting annotation(s)...", 1)
        for annotation in config['annotations']:
            log(logging.INFO, "'%s'..." % annotation, 2)
            command, command_output, rc = run_command("buildah config --annotation '%s' %s" % (annotation, container))
            if rc != 0:
                log(logging.INFO, "failed", 3)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Failed to add requested config annotation to the temporary container '%s'" % container)
                sys.exit(get_exit_code('config_set_annotation'))
            else:
                log(logging.INFO, "succeeded", 3)
                command_log(VERBOSE, command, rc, command_output)

    if 'envs' in config:
        log(logging.INFO, "setting environment variable(s)...", 1)
        for env in config['envs']:
            log(logging.INFO, "'%s'..." % env, 2)
            command, command_output, rc = run_command("buildah config --env '%s' %s" % (env, container))
            if rc != 0:
                log(logging.INFO, "failed", 3)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Failed to add requested config environment variable to the temporary container '%s'" % container)
                sys.exit(get_exit_code('config_set_env'))
            else:
                log(logging.INFO, "succeeded", 3)
                command_log(VERBOSE, command, rc, command_output)

    if 'ports' in config:
        log(logging.INFO, "setting port(s)...", 1)
        for port in config['ports']:
            log(logging.INFO, "'%s'..." % port, 2)
            command, command_output, rc = run_command("buildah config --port %s %s" % (port, container))
            if rc != 0:
                log(logging.INFO, "failed", 3)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Failed to add requested config port to the temporary container '%s'" % container)
                sys.exit(get_exit_code('config_set_port'))
            else:
                log(logging.INFO, "succeeded", 3)
                command_log(VERBOSE, command, rc, command_output)

    if 'labels' in config:
        log(logging.INFO, "setting label(s)...", 1)
        for label in config['labels']:
            log(logging.INFO, "'%s'..." % label, 2)
            command, command_output, rc = run_command("buildah config --label %s %s" % (label, container))
            if rc != 0:
                log(logging.INFO, "failed", 3)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Failed to add requested config label to the temporary container '%s'" % container)
                sys.exit(get_exit_code('config_set_label'))
            else:
                log(logging.INFO, "succeeded", 3)
                command_log(VERBOSE, command, rc, command_output)


def commit_container(container):
    """Commit the container to an image."""
    log(logging.INFO, "Creating new container image...")
    command, command_output, rc = run_command("buildah commit --quiet %s %s" % (container, container))
    if rc != 0:
        log(logging.INFO, "failed", 1)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Failed to create new container image '%s'" % container)
        sys.exit(get_exit_code('image_create'))
    else:
        log(logging.INFO, "succeeded", 1)
        command_log(VERBOSE, command, rc, command_output)


def cleanup_container(container):
    """Remove the temporary container."""
    log(logging.INFO, "Cleaning up the temporary container...")
    command, command_output, rc = run_command("buildah rm %s" % container)
    if rc != 0:
        log(logging.INFO, "failed", 1)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Failed to cleanup temporary container '%s'" % container)
        sys.exit(get_exit_code('new_container_cleanup'))
    else:
        log(logging.INFO, "succeeded", 1)
        command_log(VERBOSE, command, rc, command_output)


def display_image_info(container):
    """Display info about the newly created image."""
    log(logging.INFO, "Creation of container image '%s' is complete.  Retrieving some details about your new image..." % container)
    command, command_output, rc = run_command("buildah images --json %s" % container)
    if rc == 0:
        log(logging.INFO, "succeeded", 1)
        log(logging.INFO, "\n%s" % command_output)
        sys.exit(get_exit_code('success'))
    else:
        log(logging.INFO, "failed", 1)
        command_log(logging.ERROR, command, rc, command_output)
        log(logging.ERROR, "Could not get container image information for '%s'!  Something must have gone wrong that I don't understand." % container)
        sys.exit(get_exit_code('image_query'))


###############################################################################
# Main
###############################################################################

def main():
    args = parse_args()
    setup_logging(args.log_level)

    # Handle --completions early exit
    if args.completions is not None:
        if args.completions == 'all':
            print(' '.join(CLI_ARGS))
        elif args.completions == '--log-level':
            print('debug info verbose')
        elif args.completions == '--skip-update':
            print('false true')
        elif args.completions == '--force':
            print('false true')
        sys.exit(get_exit_code('success'))

    # Validate --userenv provided
    if args.userenv is None:
        log(logging.ERROR, "You must provide --userenv!")
        sys.exit(get_exit_code('no_userenv'))

    params = parse_params(args.param)

    dirname = str(Path(__file__).resolve().parent)
    schema_location = dirname + "/schema.json"
    registries_schema_location = dirname + "/registries-schema.json"

    log(logging.INFO, "Using '%s' for JSON input file schema validation" % schema_location)

    # Load userenv JSON
    log(logging.INFO, "Loading userenv definition from '%s'..." % args.userenv)
    userenv_json = load_and_validate_json(args.userenv, schema_location, 'userenv')

    # Apply defaults
    if 'requires-pull-token' not in userenv_json['userenv']['origin']:
        userenv_json['userenv']['origin']['requires-pull-token'] = 'false'

    if 'build-policy' not in userenv_json['userenv']['origin']:
        userenv_json['userenv']['origin']['build-policy'] = 'missing'

    # Validate platform
    validate_platform(userenv_json)

    # Resolve image naming
    host, proj, label, tag = resolve_image_naming(args, userenv_json)
    if args.label:
        log(logging.INFO, "label: %s" % label)

    # Compute userenv SHA-256
    log(logging.INFO, "calculating sha256...", 1)
    userenv_json['sha256'] = canonical_json_sha256(userenv_json)
    log(logging.INFO, "succeeded", 2)

    logger.debug("Userenv JSON:\n%s", json.dumps(userenv_json, indent=2))

    checksums = [userenv_json['sha256']]

    # Load registries JSON (optional)
    registries_json = None
    if args.registries_json:
        log(logging.INFO, "Loading registries JSON...")
        log(logging.INFO, "'%s..." % args.registries_json, 1)
        registries_json = load_and_validate_json(args.registries_json, registries_schema_location, 'registries_json')
        logger.debug("Registries JSON:\n%s", json.dumps(registries_json, indent=2))

    # Load requirements
    log(logging.INFO, "Loading requested requirements...")

    all_requirements = []

    # Build requirements from the userenv itself
    log(logging.INFO, "'%s'..." % args.userenv, 1)
    userenv_reqs = {
        'filename': args.userenv,
        'json': {
            'userenvs': [{
                'name': userenv_json['userenv']['name'],
                'requirements': [r['name'] for r in userenv_json.get('requirements', [])],
            }],
            'requirements': userenv_json.get('requirements', []),
        }
    }
    log(logging.INFO, "succeeded", 2)
    all_requirements.append(userenv_reqs)

    # Load additional requirement files
    for req_file in args.requirements:
        log(logging.INFO, "'%s'..." % req_file, 1)
        req_json = load_and_validate_json(req_file, schema_location, 'requirement')
        tmp_req = {'filename': req_file, 'json': req_json}
        all_requirements.append(tmp_req)

    # Resolve requirements
    active_reqs, req_checksums = resolve_requirements(all_requirements, userenv_json['userenv']['name'])
    checksums.extend(req_checksums)

    # Load config JSON (optional)
    config_json = None
    if args.config:
        log(logging.INFO, "Loading config definition from '%s'..." % args.config)
        config_json = load_and_validate_json(args.config, schema_location, 'config')
        log(logging.INFO, "calculating sha256...", 1)
        config_json['sha256'] = canonical_json_sha256(config_json)
        log(logging.INFO, "succeeded", 2)
        logger.debug("Config JSON:\n%s", json.dumps(config_json, indent=2))
        checksums.append(config_json['sha256'])

    # Resolve pull token
    tls_verify, authfile_arg = resolve_pull_token(userenv_json, registries_json, args.reg_tls_verify)

    # Handle --dump-config early exit
    if args.dump_config == 'true':
        include_digest = False
        if args.force_build_policy:
            include_digest = (args.force_build_policy == 'ifnewer')
        elif userenv_json['userenv']['origin']['build-policy'] == 'ifnewer':
            include_digest = True

        if include_digest:
            image_id = "%s:%s" % (userenv_json['userenv']['origin']['image'], userenv_json['userenv']['origin']['tag'])
            if image_id.startswith('dir:') or image_id.startswith('docker://'):
                skopeo_url = image_id
            else:
                skopeo_url = "docker://%s" % image_id

            log(logging.INFO, "Querying for origin image digest...", 1)
            command, command_output, rc = run_command("skopeo inspect --no-tags %s %s" % (authfile_arg, skopeo_url))
            if rc == 0:
                log(logging.INFO, "succeeded", 2)
                command_log(VERBOSE, command, rc, command_output)
                command_output = filter_output(command_output)
                skopeo_json = json.loads(command_output)
                if 'Digest' in skopeo_json:
                    userenv_json['userenv']['origin']['digest'] = skopeo_json['Digest']
                else:
                    log(logging.ERROR, "Query results do not contain a digest")
                    sys.exit(get_exit_code('skopeo_digest_missing'))
            else:
                log(logging.INFO, "failed", 2)
                command_log(logging.ERROR, command, rc, command_output)
                log(logging.ERROR, "Failed to query %s" % skopeo_url)
                sys.exit(get_exit_code('skopeo_inspect_failed'))

        config_dump = {
            'userenv': userenv_json,
            'requirements': active_reqs,
            'config': config_json,
        }

        # Remove internal variables
        config_dump['userenv'].pop('sha256', None)
        if config_dump['config']:
            config_dump['config'].pop('sha256', None)
        for req in config_dump['requirements']:
            req.pop('index', None)
            req.pop('sha256', None)

        log(logging.INFO, "Config dump:")
        log(logging.INFO, json.dumps(config_dump, indent=2))
        sys.exit()

    # Handle --dump-files early exit
    if args.dump_files == 'true':
        log(logging.INFO, "Files dump:")
        for req in active_reqs:
            if req['type'] == 'files':
                for file_entry in req['files_info']['files']:
                    print(param_replacement(file_entry['src'], params, 0))
        sys.exit()

    # Pull origin image
    origin_image_id = pull_origin_image(userenv_json, tls_verify, authfile_arg)

    logger.debug("Userenv JSON:\n%s", json.dumps(userenv_json, indent=2))

    # Build composite checksum
    config_checksum = build_config_checksum(checksums, userenv_json, args.skip_update)

    # Container name
    tmp_container = "%s/%s/%s:%s" % (host, proj, label, tag)

    # Check existing image
    _, remove_image = check_existing_image(tmp_container, config_checksum, args.force)

    # Cleanup stale containers
    cleanup_stale_containers(tmp_container)

    # Remove old image if needed
    if remove_image:
        log(logging.INFO, "Removing existing container image that I am about to replace [%s]..." % tmp_container)
        command, command_output, rc = run_command("buildah rmi %s" % tmp_container)
        if rc != 0:
            log(logging.INFO, "failed", 1)
            command_log(logging.ERROR, command, rc, command_output)
            log(logging.ERROR, "Could not remove existing container image '%s'" % tmp_container)
            sys.exit(get_exit_code('remove_existing_container'))
        else:
            log(logging.INFO, "succeeded", 1)
            command_log(VERBOSE, command, rc, command_output)

    # Create container, set user, run updates
    create_container(tmp_container, origin_image_id)
    set_default_user(tmp_container)

    getsrc_cmd, update_cmd, clean_cmd = get_update_clean_cmds(userenv_json)
    update_container_pkgs(tmp_container, args.skip_update, getsrc_cmd, update_cmd, clean_cmd)

    # Install all requirements
    distro_installs = install_all_requirements(active_reqs, tmp_container, userenv_json, params)

    # Clean up after distro installs
    if distro_installs:
        log(logging.INFO, "Cleaning up after performing distro package installations...")
        volume_opt = get_volume_opt()
        command, command_output, rc = run_command("buildah run %s --isolation chroot %s -- %s" % (volume_opt, tmp_container, clean_cmd))
        if rc != 0:
            log(logging.INFO, "failed", 1)
            command_log(logging.ERROR, command, rc, command_output)
            log(logging.ERROR, "Cleaning up after distro package installation failed")
            sys.exit(get_exit_code('install_cleanup'))
        else:
            log(logging.INFO, "succeeded", 1)
            command_log(VERBOSE, command, rc, command_output)

    # Annotate, apply config, commit, cleanup, display info
    annotate_config_version(tmp_container, config_checksum)
    apply_container_config(tmp_container, config_json)
    commit_container(tmp_container)
    cleanup_container(tmp_container)
    display_image_info(tmp_container)


if __name__ == "__main__":
    main()
