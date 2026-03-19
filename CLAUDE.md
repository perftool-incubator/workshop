# CLAUDE.md

## Project Overview

Workshop builds container images using buildah. It combines a userenv (base image spec) with requirement definitions (software to install) to produce reproducible container images. Part of the [perftool-incubator](https://github.com/perftool-incubator) project.

## Implementations

There are two coexisting implementations:

- **`workshop.pl`** -- Original Perl implementation (~2200 lines)
- **`workshop.py`** -- Python 3 reimplementation (~1800 lines)

Both should be kept functionally equivalent. Changes to build logic should be applied to both implementations unless otherwise specified.

## Key Files

- `schema.json` -- JSON schema for userenv/requirements/config validation
- `registries-schema.json` -- JSON schema for registry authentication config
- `userenvs/` -- Userenv definition files (base image specs)
- `requirements/` -- Requirement definition files (software to install)
- `configs/` -- Container config files (entrypoint, env vars, ports, etc.)

## Dependencies

### Perl
- Requires modules: JSON, JSON::Validator, Getopt::Long, Digest::SHA, Data::UUID, etc.
- Uses `toolbox::json` and `toolbox::logging` from TOOLBOX_HOME/perl/

### Python
- Uses `invoke` (for `invoke.run()` shell commands) and `jsonschema` (via toolbox)
- Uses `toolbox.json` (load_json_file, validate_schema) from TOOLBOX_HOME/python/
- Use a `.venv` virtual environment for pip installs, not system pip

### External
- `TOOLBOX_HOME` env var must point to a [toolbox](https://github.com/perftool-incubator/toolbox) checkout
- Requires `buildah` and `skopeo` on the system

## Code Style

- 4-space indentation, no tabs (both Perl and Python)
- Both files include modeline headers for editor configuration
- Python uses a custom `VERBOSE` logging level (15) between DEBUG (10) and INFO (20)
- SHA-256 checksums use canonical/sorted JSON encoding

## CI Workflows

- `workshop-ci.yaml` -- Tests both Perl and Python implementations on PR
- `crucible-ci.yaml` -- Crucible integration CI on PR
- `crucible-merged.yaml` -- Post-merge crucible CI (pull_request_target: closed)
- Workflow trigger paths must include both `workshop.pl` and `workshop.py`

## Git Conventions

- Main branch: `master`
- Upstream remote: `perftool-incubator/workshop`
- Commit messages: lowercase, imperative mood, concise
