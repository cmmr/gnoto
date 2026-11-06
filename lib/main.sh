#!/bin/bash
#
# main.sh - gnoto's entry point inside the image.
#
# Run by:  the gnoto launcher, through apptainer exec
# Usage:   main.sh <command> [arguments]
# Env:     GNOTO_CODE_DIR, GNOTO_INSTALL_DIR, GNOTO_DATA_DIR, GNOTO_DB_DIR and
#          GNOTO_HELPER_DIR, from the launcher
#
# Commands so far: config, and exec, a development aid that runs any command in
# the image with the stand-ins on PATH and the settings loaded. gnoto init never
# reaches the image.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/env.sh"

usage() {
    echo "Usage: gnoto init --apptainer=/path/to/apptainer" >&2
    echo "       gnoto config [<section> [--on|--off]]" >&2
    echo "       gnoto exec <command> [arguments]" >&2
    exit 1
}

COMMAND=${1:-}
case $COMMAND in
    config)
        shift
        source "$CODE_DIR/lib/config.sh"
        config_main "$@"
        ;;
    exec)
        shift
        [[ $# -gt 0 ]] || usage
        exec "$@"
        ;;
    *) usage ;;
esac
