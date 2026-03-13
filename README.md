# workshop
A place to build things

## Introduction

Workshop is a tool for building container images based on specified userenv and requirement definitions. It uses [buildah](https://github.com/containers/buildah) as the container build engine and depends on the [toolbox](https://github.com/perftool-incubator/toolbox) project for shared utilities. The tool intelligently combines a single userenv (base image specification) with one or more requirement definitions (software to install) to produce a reproducible container image.

## Prerequisites

### System Tools

- [buildah](https://github.com/containers/buildah) -- container image building
- [skopeo](https://github.com/containers/skopeo) -- remote registry inspection
- curl

### Perl Modules

- JSON
- JSON::Validator
- Getopt::Long
- Digest::SHA
- Data::UUID
- Scalar::Util
- File::Basename

### Toolbox

Workshop requires the [toolbox](https://github.com/perftool-incubator/toolbox) project. Set the `TOOLBOX_HOME` environment variable to point to the toolbox checkout:

```
export TOOLBOX_HOME=/path/to/toolbox
```

Workshop expects `$TOOLBOX_HOME/perl/` to exist and contain the `toolbox::json` and `toolbox::logging` modules.

## Usage

```
workshop.pl --userenv <file> [--requirements <file> ...] [options]
```

### Required Arguments

| Flag | Description |
|------|-------------|
| `--userenv <file>` | Userenv JSON definition file |

### Optional Arguments

| Flag | Description |
|------|-------------|
| `--requirements <file>` | Requirements JSON file (may be specified multiple times) |
| `--config <file>` | Container config JSON file |
| `--label <string>` | Label to apply to the container image |
| `--tag <string>` | Docker image tag |
| `--proj <string>` | Project specification (format: `[protocol://][namespace/]name`) |
| `--log-level <info\|verbose\|debug>` | Controls logging output (default: `info`) |
| `--skip-update <true\|false>` | Skip distro package updates (default: `false`) |
| `--force <true\|false>` | Force the build even if a matching image exists (default: `false`) |
| `--force-build-policy <missing\|ifnewer>` | Override the userenv's build policy |
| `--param <key>=<value>` | Parameter substitution in definition files (may be specified multiple times) |
| `--dump-config <true\|false>` | Dump the resolved config instead of building (default: `false`) |
| `--dump-files <true\|false>` | Dump the files being handled (default: `false`) |
| `--reg-tls-verify <true\|false>` | Use TLS for remote registry actions (default: `true`) |
| `--registries-json <file>` | Registry configuration file for authentication |
| `--completions <all\|...>` | Print available CLI options for shell completions |
| `--help` | Display usage information |

## Userenv

A userenv definition specifies a container image as a base on which the User Environment is built. This is typically a basic image from a Linux distribution. The userenv document also provides information about how to manage that environment (package type and manager) and any requirements that should be applied to all instances of that userenv.

An example userenv definition is provided for [Fedora CI](userenvs/fedora-ci.json).

### Userenv Fields

- **name** -- unique identifier for the userenv
- **label** -- human-readable description
- **origin** -- base image specification:
  - `image` -- container image URL (e.g. `docker.io/library/fedora`)
  - `tag` -- image tag (e.g. `40`)
  - `build-policy` -- `missing` (build only if image does not exist) or `ifnewer` (always rebuild to check for newer versions)
  - `update-policy` -- `always` or `never`
  - `requires-pull-token` -- whether authentication is needed to pull the base image
- **properties** -- system information:
  - `platform` -- array of supported architectures (`x86_64`, `aarch64`)
  - `packages` -- package format (`type`: `rpm`, `pkg`) and manager (`manager`: `dnf`, `yum`, `apt`, `zypper`)

## Requirements

A requirement definition is usually provided by a project that wants to be usable inside a workshop-created container image. The definition specifies one or more userenvs (including a generic `default` userenv) and what should be installed. Installation supports seven different methods:

| Type | Description |
|------|-------------|
| `distro` | Install or remove distribution packages via the package manager. Supports packages, groups, and environment variables during installation. |
| `distro-manual` | Manually download and install distro package files (`.rpm`, `.deb`) from URLs. |
| `manual` | Execute arbitrary shell commands in the container. |
| `source` | Download and build software from a source tarball. Specify URL, unpack command, and build commands. |
| `files` | Copy files from the host into the container image. |
| `cpan` | Install Perl packages via `cpanm`. |
| `python3` | Install Python packages via `pip`. |
| `node` | Install Node.js packages via `npm`. |

An example requirements definition is provided for [Development Tools](requirements/development-tools.json).

## Config Files

An optional config JSON file can be provided via `--config` to set container metadata:

| Field | Type | Description |
|-------|------|-------------|
| `cmd` | string | Default command to run in the container |
| `entrypoint` | string or array | Container entrypoint (executed before cmd) |
| `author` | string | Container author metadata |
| `annotations` | array of `key=value` strings | Container annotations |
| `envs` | array of `KEY=VALUE` strings | Environment variables |
| `ports` | array of integers | Port numbers to expose (1--65536) |
| `labels` | array of strings | Container labels |

Example config files are available in the [configs](configs/) directory.

## Parameter Substitution

The `--param key=value` flag performs string substitution across userenv, requirements, and config files. Every occurrence of `key` in the JSON definitions is replaced with `value`. Multiple `--param` flags can be specified.

This is useful for injecting paths or other values that vary between environments. For example:

```
workshop.pl --userenv my-userenv.json --requirements my-reqs.json --param BASEDIR=/opt/myapp
```

Any occurrence of `BASEDIR` in the definition files will be replaced with `/opt/myapp`.

## Build Behavior

Workshop has the following runtime behaviors:

- If allowed, which it is by default, workshop will attempt to install distro updates so that the resulting image is running the latest code available from its upstream source. Use `--skip-update true` to disable this.
- The order of requirement definitions is potentially important and therefore strictly adhered to. For example, if the first requirement listed is the installation of a library and the second requirement listed is the build of a package that depends on that library then that ordering is very important. The ordering is determined by a basic hierarchy that goes like this:
  - Requirements listed in userenv definitions are added to the active requirements list in the order they are listed.
  - Requirement definition files are processed in the order they are specified in the argument list.
  - Within requirement definition files the requirements for a matching userenv definition are added to the active requirements list in the order they are listed.
- Workshop attempts to optimize the image building process by only performing a build when an image that is a match for the current request does not already exist in the local image repository. This is done by distilling the userenv and requirement definition configuration to a SHA-256 checksum signature that is applied to the image as a version annotation (`Workshop_Config_Version`). If a potential image match is present and the version is the same as what would be built then the build is skipped. This behavior can be modified with `--force true` or by setting the userenv's `build-policy` to `ifnewer`.
- When distro updates are applied it is hard, if not impossible, for workshop to track what is being done to the image. For this reason there is special logic that inserts additional bits into the checksum signature calculation to ensure that a match will never be found, which ensures that rebuilds will always occur when distro updates are present. The checksum signature is heavily dependent on the ordering of requirement definitions so simply reordering them will result in a new checksum signature and therefore a rebuild.
- The `--force-build-policy` flag overrides the build policy specified in the userenv file. Use `missing` (default) to only build when no matching image exists, or `ifnewer` to always rebuild.

## Registry Support

Workshop can interact with remote container registries for pulling base images that require authentication. Use `--registries-json <file>` to provide a registry configuration file containing connection details and pull tokens. The file must conform to the [registries schema](registries-schema.json). TLS verification for registry operations can be controlled with `--reg-tls-verify`.

## Definition Files

The userenv, requirement, and config definitions are JSON files that conform to the [schema](schema.json) that is part of this project.
