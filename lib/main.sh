#!/bin/bash
#
# main.sh - gnoto's entry point inside the image.
#
# Run by:  the gnoto launcher, through apptainer exec
# Usage:   main.sh <command> [arguments]
# Env:     GNOTO_CODE_DIR, GNOTO_INSTALL_DIR, GNOTO_DATA_DIR, GNOTO_DB_DIR and
#          GNOTO_HELPER_DIR, from the launcher
#
# For now the one command is exec, a development aid that runs any command in
# the image with the stand-ins on PATH.

set -euo pipefail

export NXF_HOME=$GNOTO_DATA_DIR/nextflow
export NXF_ASSETS=$NXF_HOME/assets
export NXF_APPTAINER_CACHEDIR=$GNOTO_DATA_DIR/images

COMMAND=${1:-}
case $COMMAND in
    exec)
        shift
        [[ $# -gt 0 ]] || { echo "Usage: gnoto exec <command> [arguments]" >&2; exit 1; }
        exec "$@"
        ;;
    *)
        echo "Usage: gnoto exec <command> [arguments]" >&2
        exit 1
        ;;
esac
