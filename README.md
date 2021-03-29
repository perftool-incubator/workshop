# workshop
A place to build things

## Introduction
Workshop is a tool for building container images based on specified userenv and requirement definitions.  The tool attempts to intelligently combine the various requirements that come from the single userenv and potentially many requirement definitions that are provided by the user.

### Userenv
A userenv definition specifies a container image as a base on which the User Environment is built.  This is likely an empty (or near empty) basic image from a Linux distribution.  Additionally the userenv document provides some basic information about how to manage that userenv (ex. package type and manager) and any requirements that should be applied to all instances of that userenv.  An example userenv definition is provided for [Fedora 31](userenvs/fedora31.json).

### Requirements
A requirement definition is usually provided by a project that wants to be usable inside a workshop created container image.  The definition specifies one or more userenvs (including the possiblity of a generic 'default' userenv) and what should be installed in that userenv for the project.  Installation of the requirements supports three different methods: distribution provided packages, building from source, manual command execution, and copying files into the image.  An example requirements definition is provided for [Development Tools](requirements/development-tools.json) installation.

## Details

### Definition Files
The userenv and requirement definitions are JSON files that conform to the [schema](schema.json) that is part of this project.

### Running workshop
Workshop has the following runtime behaviors:

- If allowed, which it is by default, workshop will attempt to install distro updates so that the resulting image is running the latest code available from it's upstream source.
- The order of requirement definitions is potentially important and therefore stricly adhered to.  For example, if the first requirement listed is the installation of a library and the second requirement listed is the build of a package that depends on that library then that ordering is very important.  The ordering is determined by a basic hierarchy that goes like this:
  - Requirements listed in userenv definitions are added to the active requirements list in the order they are listed.
  - Requirement definition files are processed in the order they are specified in the argument list.
  - Within requirement definition files the requirements for a matching userenv definition are are added to the active requirements list in the order they are listed.
- Workshop attempts to optimize the image building process by only performing a build when an image that is a match for the current request does not already exist in the local image repository.  This is done by distilling the userenv and requirement definition configuration to a checksum signature that is applied to the image as a version.  If a potential image match is present and the version is the same as what would be built then the build is skipped (this behavior can be modified by forcing the build to occur).  There are certain intricate details that affect this behavior.  When distro updates are applied it is hard, if not impossible, for workshop to track what is being done to the image.  For this reason there is special logic that inserts additional 'bits' into the checksum signature calculation to ensure that a match will never be found which ensures that rebuilds will always occur when distro updates are present (in the existing image and/or the new image build).  The checksum signature is heavily dependent on the ordering of requirement definitions so simply reordering them (either by changing the order on the command line or in the definition files) will result in a new checksum signature and therefore a rebuild.
