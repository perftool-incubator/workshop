# workshop.json Reference

The `workshop.json` file declares what software must be installed in a
container image built by workshop. It is used by benchmarks, tools,
and core subprojects to specify their build dependencies. Workshop
validates this file against `schema.json` in the workshop repo root.

## Structure

```json
{
    "workshop": {
        "schema": { "version": "2020.03.02" }
    },
    "userenvs": [
        {
            "name": "default",
            "requirements": ["<requirement-name>", ...]
        }
    ],
    "requirements": [ ... ]
}
```

The `userenvs` array maps environment names to lists of requirements.
The `"default"` userenv is used automatically if a matching
definition for the requested userenv is not found.

## Requirement types

Each requirement has a `name`, a `type`, and a type-specific info
object. The `name` is referenced from the `userenvs` entries to
select which requirements apply to a given environment.

**No dependencies** (nothing beyond the base image is needed):
```json
"requirements": []
```

**distro** -- install distribution packages:
```json
{
    "name": "build-tools",
    "type": "distro",
    "distro_info": {
        "packages": ["gcc", "make", "automake"]
    }
}
```

**source** -- build from a source tarball:
```json
{
    "name": "mybench_src",
    "type": "source",
    "source_info": {
        "url": "https://github.com/example/mybench/archive/v1.0.tar.gz",
        "filename": "mybench.tar.gz",
        "commands": {
            "unpack": "tar -xzf mybench.tar.gz",
            "get_dir": "tar -tzf mybench.tar.gz | head -n 1",
            "commands": [
                "./configure",
                "make",
                "make install",
                "mybench --version"
            ]
        }
    }
}
```

**python3** -- install pip packages:
```json
{
    "name": "python-deps",
    "type": "python3",
    "python3_info": {
        "packages": ["numpy", "pandas"]
    }
}
```

**cpan** -- install Perl modules:
```json
{
    "name": "perl-deps",
    "type": "cpan",
    "cpan_info": {
        "packages": ["JSON::XS", "Data::Dumper"]
    }
}
```

**manual** -- run arbitrary commands:
```json
{
    "name": "custom-setup",
    "type": "manual",
    "manual_info": {
        "commands": ["git clone https://...", "cd repo && make install"]
    }
}
```

**files** -- copy files into the image:
```json
{
    "name": "config-files",
    "type": "files",
    "files_info": {
        "files": [
            { "src": "%bench-dir%/myconfig.conf", "dst": "/etc/mybench/" }
        ]
    }
}
```

**node** -- install Node.js packages via npm:
```json
{
    "name": "node-deps",
    "type": "node",
    "node_info": {
        "packages": ["express", "lodash"]
    }
}
```

**distro-manual** -- manually download and install package files:
```json
{
    "name": "custom-rpms",
    "type": "distro-manual",
    "distro-manual_info": {
        "packages": ["https://example.com/package-1.0.rpm"]
    }
}
```

## Multiple userenvs

When different base images need different build steps, define
multiple entries in the `userenvs` array. The `name` field can be a
single string or an array of strings to match multiple environments:

```json
"userenvs": [
    {
        "name": "default",
        "requirements": ["build-tools", "mybench_src"]
    },
    {
        "name": ["centos7", "rhubi7"],
        "requirements": ["build-tools", "mybench_src_older"]
    }
]
```

## Schema versions

The `workshop.schema.version` field must be one of the versions
recognized by the workshop schema. Current valid versions include:
`2020.03.02`, `2020.04.30`, `2022.07.25`, `2023.02.16`,
`2024.03.22`, `2024.08.07`, `2025.07.25`.

## Examples

For real-world examples of `workshop.json` files, see:

- **No dependencies**: `bench-sleep/workshop.json`
- **Source build**: `bench-uperf/workshop.json`
- **Multiple userenvs with patches**: `bench-cyclictest/workshop.json`
- **Complex multi-dependency**: `bench-fio/workshop.json`
- **Crucible controller** (most complex usage): `crucible/workshop/fedora.json` (userenv) and `crucible/workshop/controller-workshop.json` (requirements)
