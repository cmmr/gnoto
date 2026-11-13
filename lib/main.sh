#!/bin/bash
#
# main.sh - gnoto's entry point inside the image.
#
# Run by:  the gnoto launcher, through apptainer exec
# Usage:   main.sh <command> [arguments]
# Env:     GNOTO_CODE_DIR, GNOTO_INSTALL_DIR, GNOTO_LAUNCHER, GNOTO_DATA_DIR,
#          GNOTO_DB_DIR, GNOTO_HELPER_DIR and GNOTO_IMAGE, from the launcher,
#          and GNOTO_RESOLVED, when a launcher handed it the command
#
# People's commands are config, lint, new, run, start, status, cancel, resume,
# remove, extend, publish, wrike, upgrade, prune, selftest, and exec, a
# development aid that runs any command in the image with the stand-ins on PATH
# and the settings loaded. gnoto init never reaches the image. The commands
# starting with an underscore are gnoto's own: _current, which the launcher runs
# from the install's files when the current version has no copy; the jobs
# lib/start.sh, lib/databases.sh and gnoto publish submit, _job, the head job;
# _publish, which runs Present and Publish again; _followup; _local, which runs
# a job and its followup one after the other on this machine; _fetch, which
# fetches a database; and _selftest, which writes a selftest's report; and what
# the systemd units run, _daily, _poll, the scan gnoto wrike makes, and
# _listen, the SQS listener.
#
# The launcher acts on --dev, running the install's own files, so here it's a
# flag that's accepted and otherwise ignored.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/env.sh"
source "$CODE_DIR/lib/args.sh"

usage() {
    echo "Usage: gnoto init --apptainer=/path/to/apptainer" >&2
    echo "       gnoto config [<section> [--on|--off] [--<key>=<value> ...]]" >&2
    echo "       gnoto config s3|sqs [--deploy] [--profile=<name>] [--dry-run]" >&2
    echo "       gnoto config systemd [--move] [--dry-run]" >&2
    echo "       gnoto config slurm --probe" >&2
    echo "       gnoto lint [--dev] [--deep] [--yes] [job.yaml]" >&2
    echo "       gnoto lint [--deep] [--yes] --inputs=<dir> record.yaml" >&2
    echo "       gnoto new <pipeline>[@<version>] [--dev] [--<key>=<value> ...] > job.yaml" >&2
    echo "       gnoto run [--debug] [--dev] [--yes] job.yaml" >&2
    echo "       gnoto run [--debug] [--yes] --inputs=<dir> record.yaml" >&2
    echo "       gnoto start <pipeline>[@<version>] [--debug] [--dev] [--yes] [--<key>=<value> ...]" >&2
    echo "       gnoto status [--all] [uid]" >&2
    echo "       gnoto cancel <uid>" >&2
    echo "       gnoto resume [uid]" >&2
    echo "       gnoto remove [--yes] <uid>..." >&2
    echo "       gnoto extend <uid> <YYYY-MM-DD|never>" >&2
    echo "       gnoto publish <uid>" >&2
    echo "       gnoto wrike [task_id]" >&2
    echo "       gnoto upgrade [--yes] [<version>]" >&2
    echo "       gnoto prune [--yes]" >&2
    echo "       gnoto selftest [--dev] [--yes] [<pipeline> ...]" >&2
    echo "       gnoto exec [--dev] <command> [arguments]" >&2
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
    resume)
        source "$CODE_DIR/lib/lint.sh"
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        source "$CODE_DIR/lib/runs.sh"
        source "$CODE_DIR/lib/start.sh"
        resume_main "$@"
        ;;
    status)
        source "$CODE_DIR/lib/runs.sh"
        source "$CODE_DIR/lib/selftest.sh"
        status_main "$@"
        ;;
    cancel)
        source "$CODE_DIR/lib/runs.sh"
        cancel_main "$@"
        ;;
    remove)
        source "$CODE_DIR/lib/runs.sh"
        source "$CODE_DIR/lib/followup.sh"
        source "$CODE_DIR/service/expire.sh"
        remove_main "$@"
        ;;
    extend)
        source "$CODE_DIR/lib/runs.sh"
        source "$CODE_DIR/lib/followup.sh"
        source "$CODE_DIR/service/expire.sh"
        extend_main "$@"
        ;;
    publish)
        source "$CODE_DIR/lib/runs.sh"
        publish_main "$@"
        ;;
    _publish)
        [[ $# -eq 1 ]] || usage
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        source "$CODE_DIR/lib/job.sh"
        job_publish_main "$1"
        ;;
    wrike | _poll | _listen)
        source "$CODE_DIR/lib/lint.sh"
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        source "$CODE_DIR/lib/start.sh"
        source "$CODE_DIR/lib/runs.sh"
        source "$CODE_DIR/lib/followup.sh"
        source "$CODE_DIR/service/expire.sh"
        source "$CODE_DIR/service/daily.sh"
        source "$CODE_DIR/service/wrike/task_handler.sh"
        case $COMMAND in
            wrike) wrike_main "$@" ;;
            _poll) [[ $# -eq 0 ]] || usage; poll_main ;;
            _listen)
                [[ $# -eq 0 ]] || usage
                source "$CODE_DIR/service/access.sh"
                source "$CODE_DIR/service/wrike/listener.sh"
                listen_main
                ;;
        esac
        ;;
    _daily)
        [[ $# -eq 0 ]] || usage
        # lint's Wrike check reads every pipeline's options, through jobfile.sh
        source "$CODE_DIR/lib/lint.sh"
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/runs.sh"
        source "$CODE_DIR/lib/followup.sh"
        source "$CODE_DIR/service/expire.sh"
        source "$CODE_DIR/service/daily.sh"
        daily_main
        ;;
    selftest)
        source "$CODE_DIR/lib/lint.sh"
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        source "$CODE_DIR/lib/start.sh"
        source "$CODE_DIR/lib/selftest.sh"
        selftest_main "$@"
        ;;
    _selftest)
        [[ $# -eq 1 ]] || usage
        source "$CODE_DIR/lib/runs.sh"
        source "$CODE_DIR/service/expire.sh"
        source "$CODE_DIR/lib/selftest.sh"
        selftest_report_main "$1"
        ;;
    upgrade) upgrade_main "$@" ;;
    prune) prune_main "$@" ;;
    _current)
        [[ $# -eq 0 ]] || usage
        current_main
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
        source "$CODE_DIR/service/expire.sh"
        followup_main "$@"
        ;;
    _local)
        # Both in this one process, because nothing else would start the
        # followup. The job runs in a subshell, so its exit leaves this to it.
        source "$CODE_DIR/lib/jobfile.sh"
        source "$CODE_DIR/lib/databases.sh"
        source "$CODE_DIR/lib/job.sh"
        source "$CODE_DIR/lib/followup.sh"
        source "$CODE_DIR/service/expire.sh"
        [[ $# -eq 1 || ( $# -eq 2 && $2 == publish ) ]] || usage
        # In one write, so status never sees the host without the process
        (cd "$1" && state_update '.scheduler.host = $host | .scheduler.pid = $pid' \
            --arg host "$(uname -n)" --arg pid "$$") || fail "Can't record this run's process in $1."
        if [[ ${2:-} == publish ]]; then
            (job_publish_main "$1") || :
        else
            (job_main "$1") || :
        fi
        followup_main "$1"
        ;;
    exec)
        [[ ${1:-} != --dev ]] || shift
        [[ $# -gt 0 ]] || usage
        exec "$@"
        ;;
    *) usage ;;
esac
