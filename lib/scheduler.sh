#
# scheduler.sh - Every scheduler call gnoto's own scripts make, apart from the
# launcher, the helper and the systemd templates.
#
# Sourced by:  lib/env.sh
# Defines:     scheduler_kind, scheduler_submit, scheduler_cancel,
#              scheduler_job_state, scheduler_local_alive, run_cpu_seconds,
#              cancel_run_tasks
# Requires:    sbatch, squeue, sacct and scancel, through their stand-ins, when
#              Slurm is on; warn and fail from lib/utilities.sh
# Env:         SLURM_ENABLED, SLURM_PARTITION and SLURM_ACCOUNT, from lib/env.sh;
#              GNOTO_HELPER_DIR, from the launcher
#
# Jobs go to Slurm when slurm.enabled is true, and run on this machine
# otherwise. A job is always a gnoto command, run by the code's own launcher.
#
# Slurm runs a copy of a batch script from its spool directory, so a job is
# submitted with --wrap, which names the launcher by its path. Locally, a job is
# queued in the launcher's private directory, and the launcher starts it on the
# host, detached, once the command that queued it has exited: a process started
# in the image would lose the image, and the helper, with that command.

scheduler_kind() {
    if [[ ${SLURM_ENABLED:-false} == true ]]; then
        echo slurm
    else
        echo local
    fi
}

# A word quoted for sh
sh_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Submits a gnoto command as a job, and prints its job ID, or "local":
#   scheduler_submit --name <name> --dir <directory> --log <file> --cpus <n>
#       --mem <memory, such as 8G> [--time <Slurm time>] [--after <dependency>]
#       [--signal <spec>] -- <gnoto command> [arguments]
# --after takes sbatch's --dependency form, such as afterany:123, and --signal
# sbatch's, such as B:TERM@300. Locally, neither applies, and the command runs
# as soon as it's started.
scheduler_submit() {
    local name="" dir="" log="" cpus=1 mem=1G time="" after="" signal="" word wrap id

    while [[ $# -gt 0 ]]; do
        case $1 in
            --name) name=$2; shift 2 ;;
            --dir) dir=$2; shift 2 ;;
            --log) log=$2; shift 2 ;;
            --cpus) cpus=$2; shift 2 ;;
            --mem) mem=$2; shift 2 ;;
            --time) time=$2; shift 2 ;;
            --after) after=$2; shift 2 ;;
            --signal) signal=$2; shift 2 ;;
            --) shift; break ;;
            *) fail "scheduler_submit: unknown option $1" ;;
        esac
    done
    [[ -n $name && -n $dir && -n $log && $# -gt 0 ]] || fail "scheduler_submit: missing arguments"

    if [[ $(scheduler_kind) == local ]]; then
        [[ -n ${GNOTO_HELPER_DIR:-} && -d $GNOTO_HELPER_DIR ]] ||
            fail "Can't start a job on this machine: gnoto's launcher didn't pass its private directory."
        for word in "$dir" "$log" "$@"; do
            [[ $word =~ ^[A-Za-z0-9_./@:+=-]+$ ]] ||
                fail "Can't start a job on this machine with \"$word\": only letters, digits and _ . / @ : + = - can pass to it."
        done
        printf '%s\t%s\t%s\n' "$dir" "$log" "$*" >> "$GNOTO_HELPER_DIR/detach" ||
            fail "Can't queue the job for this machine."
        echo local
        return 0
    fi

    wrap="exec $(sh_quote "$CODE_DIR/gnoto")"
    for word in "$@"; do
        wrap+=" $(sh_quote "$word")"
    done
    local args=(--parsable --job-name="$name" --chdir="$dir" --output="$log" --no-requeue
        --cpus-per-task="$cpus" --mem="$mem")
    [[ -z $time ]] || args+=(--time="$time")
    [[ -z $signal ]] || args+=(--signal="$signal")
    [[ -z $after ]] || args+=(--dependency="$after")
    [[ -z ${SLURM_PARTITION:-} ]] || args+=(--partition="$SLURM_PARTITION")
    [[ -z ${SLURM_ACCOUNT:-} ]] || args+=(--account="$SLURM_ACCOUNT")
    id=$(sbatch "${args[@]}" --wrap "$wrap") || return 1
    id=${id%%;*}
    [[ $id =~ ^[0-9]+$ ]] || { warn "sbatch printed \"$id\" rather than a job ID."; return 1; }
    printf '%s' "$id"
}

scheduler_cancel() {
    scancel "$1" 2> /dev/null
}

# A Slurm job's state, such as PENDING, RUNNING, COMPLETED, FAILED, CANCELLED,
# TIMEOUT, OUT_OF_MEMORY or NODE_FAIL: squeue's while it's queued or running,
# then sacct's. Prints nothing when neither knows it.
scheduler_job_state() {
    local state
    state=$(squeue -h -j "$1" -o %T 2> /dev/null | head -1) || state=""
    if [[ -z $state ]]; then
        state=$(sacct -n -X -P -j "$1" -o State 2> /dev/null | head -1) || state=""
        state=${state%% *}
    fi
    printf '%s' "$state"
}

# True while a local job's process is running, when it ran on this machine.
# Returns 2 when it ran on another.
scheduler_local_alive() {
    local host=$1 pid=$2
    [[ $host == "$(uname -n)" ]] || return 2
    [[ $pid =~ ^[0-9]+$ ]] && ps -p "$pid" > /dev/null 2>&1
}

# CPU-seconds every Slurm job of the run in the current directory has held,
# sacct's CPUTimeRAW, counting each job whose work directory is this one or
# below it, from the time given in any form sacct --starttime takes. Prints
# nothing when sacct can't answer or finds nothing.
run_cpu_seconds() {
    sacct --allocations --noheader --parsable2 --starttime="$1" \
        --format=CPUTimeRAW,WorkDir 2> /dev/null |
        LC_ALL=C awk -F'|' -v here="$PWD" '
            index($2, here) == 1 { total += $1 }
            END { if (total == 0) exit 1; print total }
        '
}

# Cancels every Slurm job still queued or running from below a run directory,
# which is where Nextflow submits its tasks from, and prints each as
# "<job id>\t<job name>". Jobs in the run directory itself, the run's own job
# and followup, are left alone, as are jobs already completing.
cancel_run_tasks() {
    local run_dir="${1%/}" id state name dir

    while IFS='|' read -r id state name dir; do
        [[ "$dir" == "$run_dir"/* && "$state" != "COMPLETING" ]] || continue
        if scancel "$id" 2> /dev/null; then
            printf '%s\t%s\n' "$id" "$name"
        else
            warn "Couldn't cancel job $id ($name) in $dir."
        fi
    done < <(squeue --noheader --user="$(id -un)" --format='%i|%T|%j|%Z' 2> /dev/null)
}
