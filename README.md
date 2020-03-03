# workshop
A place to build things

## Introduction
Workshop is a tool for building container images based on specified userenv and requirement definitions.

### Userenv
A userenv definition specifies a container image as a base on which the User Environment is built.  This is likely an empty (or near empty) basic image from a Linux distribution.  Additionally the userenv document provides some basic information about how to manage that target and if any additional packages should be installed by default.

### Requirements
A requirement definition is usually provided by a project that wants to be usable inside a workshop created container image.  The definition specifies one or more userenvs (including the possiblity of a generic 'default' userenv) and what should be installed in that userenv for the project.  Installation of the requirements supports three different methods: distribution provided packages, building from source, manual command execution, and copying files into the image.
