# workshop
A place to build things

## Introduction
Workshop is a tool for building container images based on specified target and requirement definitions.

### Targets
A target definition specifies a container image as a base, likely an empty (or near empty) basic image from a Linux distribution and provides some basic information about how to manage that target and if any additional packages should be installed by default.

### Requirements
A requirement definition is usually provided by a project that wants to be usable inside a workshop created container image.  The definition specifies one or more targets (including the possiblity of a generic 'default' target) and what should be installed in that target for the project.  Installation of the requirements supports three different methods: distribution provided packages, building from source, and manual command execution.
