# CLAUDE.md

## Project Overview

Workshop builds container images using buildah. It combines a userenv (base image spec) with requirement definitions (software to install) to produce reproducible container images. Part of the [perftool-incubator](https://github.com/perftool-incubator) project.

## Implementation

- **`workshop.py`** -- Python 3 implementation (~1800 lines)

## Key Files

- `schema.json` -- JSON schema for userenv/requirements/config validation
- `registries-schema.json` -- JSON schema for registry authentication config
- `userenvs/` -- Userenv definition files (base image specs)
- `requirements/` -- Requirement definition files (software to install)
- `configs/` -- Container config files (entrypoint, env vars, ports, etc.)

## Dependencies

### Python
- Uses `invoke` (for `invoke.run()` shell commands) and `jsonschema` (via toolbox)
- Uses `toolbox.json` (load_json_file, validate_schema) from TOOLBOX_HOME/python/
- Use a `.venv` virtual environment for pip installs, not system pip

### External
- `TOOLBOX_HOME` env var must point to a [toolbox](https://github.com/perftool-incubator/toolbox) checkout
- Requires `buildah` and `skopeo` on the system

## Code Style

- 4-space indentation, no tabs
- Modeline headers for editor configuration
- Python uses a custom `VERBOSE` logging level (15) between DEBUG (10) and INFO (20)
- SHA-256 checksums use canonical/sorted JSON encoding

## CI Workflows

- `workshop-ci.yaml` -- Tests workshop.py on PR
- `crucible-ci.yaml` -- Crucible integration CI on PR
- `crucible-merged.yaml` -- Post-merge crucible CI (pull_request_target: closed)

## Git Conventions

- Main branch: `master`
- Upstream remote: `perftool-incubator/workshop`
- Commit messages: lowercase, imperative mood, concise
