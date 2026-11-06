#
# scheduler.sh - Every Slurm call gnoto's own scripts make, apart from the
# launcher, the helper and the systemd templates.
#
# Sourced by:  lib/env.sh
# Defines:     run_cpu_seconds, cancel_run_tasks
# Requires:    sacct, squeue and scancel, through their stand-ins; warn from
#              lib/utilities.sh

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
