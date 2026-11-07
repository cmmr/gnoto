#!/bin/bash
#
# main.sh - gnoto's entry point inside the image.
#
# Run by:  the gnoto launcher, through apptainer exec
# Usage:   main.sh <command> [arguments]
# Env:     GNOTO_CODE_DIR, GNOTO_INSTALL_DIR, GNOTO_DATA_DIR, GNOTO_DB_DIR and
#          GNOTO_HELPER_DIR, from the launcher
#
# People's commands are config, lint, new, run, start, status, cancel, and exec,
# a development aid that runs any command in the image with the stand-ins on
# PATH and the settings loaded. gnoto init never reaches the image. The commands
# starting with an underscore are jobs, which lib/start.sh and lib/databases.sh
# submit: _job, the head job; _followup; _local, which runs both one after the
# other on this machine; and _fetch, which fetches a database.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/env.sh"
source "$CODE_DIR/lib/args.sh"

usage() {
    echo "Usage: gnoto init --apptainer=/path/to/apptainer" >&2
    echo "       gnoto config [<section> [--on|--off] [--<key>=<value> ...]]" >&2
    echo "       gnoto config slurm --probe" >&2
    echo "       gnoto lint [--yes] [job.yaml]" >&2
    echo "       gnoto new <pipeline>[@<version>] [--<key>=<value> ...] > job.yaml" >&2
    echo "       gnoto run [--debug] [--yes] job.yaml" >&2
    echo "       gnoto start <pipeline>[@<version>] [--debug] [--yes] [--<key>=<value> ...]" >&2
    echo "       gnoto status [uid]" >&2
    echo "       gnoto cancel <uid>" >&2
    echo "       gnoto exec <command> [arguments]" >&2
    exit 1
}

COMMAND=${1:-}
[[ $# -eq 0 ]] || shift
case $COMMAND in
    config)
        source "$CODE_DIR/lib/config.sh"
        config_main "$@"
        ;;
    lint)
        source "$CODE_DIR/lib/lint.sh"
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        lint_main "$@"
        ;;
    new)
        source "$CODE_DIR/lib/jobfile.sh"
        job_new "$@"
        ;;
    run | start)
        source "$CODE_DIR/lib/lint.sh"
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        source "$CODE_DIR/lib/start.sh"
        "${COMMAND}_main" "$@"
        ;;
    status)
        source "$CODE_DIR/lib/runs.sh"
        status_main "$@"
        ;;
    cancel)
        source "$CODE_DIR/lib/runs.sh"
        cancel_main "$@"
        ;;
    _job)
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        source "$CODE_DIR/lib/job.sh"
        job_main "$@"
        ;;
    _fetch)
        source "$CODE_DIR/lib/databases.sh"
        fetch_main "$@"
        ;;
    _followup)
        source "$CODE_DIR/lib/followup.sh"
        followup_main "$@"
        ;;
    _local)
        # Both in this one process, because nothing else would start the
        # followup. The job runs in a subshell, so its exit leaves this to it.
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        source "$CODE_DIR/lib/job.sh"
        source "$CODE_DIR/lib/followup.sh"
        [[ $# -eq 1 ]] || usage
        (cd "$1" && state_set scheduler.host "$(uname -n)" && state_set scheduler.pid "$$") ||
            fail "Can't record this run's process in $1."
        (job_main "$1") || :
        followup_main "$1"
        ;;
    exec)
        [[ $# -gt 0 ]] || usage
        exec "$@"
        ;;
    *) usage ;;
esac
