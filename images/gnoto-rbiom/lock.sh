#!/bin/bash
#
# lock.sh - Remakes pkg.lock, the R packages the gnoto-rbiom image installs.
#
# Run by:    a developer, after changing the base image, SNAPSHOT or RBIOM in the
#            Dockerfile beside it
# Usage:     images/gnoto-rbiom/lock.sh
# Requires:  docker and bash. Works from Git Bash on Windows.
#
# Resolves rbiom, at the commit RBIOM names, and h5lite, with everything they
# need, in the Dockerfile's own base image against Posit's CRAN snapshot of
# SNAPSHOT, so the lockfile matches what the build installs.

set -euo pipefail

export MSYS_NO_PATHCONV=1

DIR=$(cd "$(dirname "$0")" && pwd)
BASE=$(sed -n 's/^FROM //p' "$DIR/Dockerfile")
SNAPSHOT=$(sed -n 's/^ARG SNAPSHOT=//p' "$DIR/Dockerfile")
RBIOM=$(sed -n 's/^ARG RBIOM=//p' "$DIR/Dockerfile")
[[ -n $BASE && -n $SNAPSHOT && -n $RBIOM ]] || { echo "Can't read FROM, SNAPSHOT and RBIOM from $DIR/Dockerfile" >&2; exit 1; }

docker run --rm -v "$DIR:/out" "$BASE" bash -c "
    set -e
    . /etc/os-release
    Rscript -e \"options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/__linux__/\$VERSION_CODENAME/$SNAPSHOT'))\" \
        -e \"install.packages('pak')\" \
        -e \"pak::lockfile_create(c('$RBIOM', 'h5lite'), lockfile = '/out/pkg.lock.new')\""
mv "$DIR/pkg.lock.new" "$DIR/pkg.lock"
echo "Wrote $DIR/pkg.lock"
