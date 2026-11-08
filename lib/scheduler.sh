#
# scheduler.sh - Every scheduler call gnoto's own scripts make, apart from the
# launcher, the helper and the systemd templates.
#
# Sourced by:  lib/env.sh
# Defines:     scheduler_kind, slurm_time, scheduler_submit, scheduler_cancel,
#              scheduler_job_state, slurm_launch_node, excluded_nodes,
#              excluded_nodes_update, slurm_exclude_list, no_node_left,
#              launch_failure_advice, scheduler_local_alive, run_cpu_seconds,
#              cancel_run_tasks
# Requires:    sbatch, squeue, sacct, sinfo and scancel, through their
#              stand-ins, when Slurm is on; flock; warn and fail from
#              lib/utilities.sh
# Env:         SLURM_ENABLED, SLURM_PARTITION, SLURM_ACCOUNT and DATA_DIR, from
#              lib/env.sh; GNOTO_HELPER_DIR, from the launcher
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

# A time limit as sbatch --time takes it. Slurm's own forms, such as 2-00:00:00,
# 48:00:00 or UNLIMITED, pass as they are, and Nextflow's, such as 48.h or 2.d,
# which slurm.max_time uses, become days-hours:minutes:seconds. Prints nothing
# for nothing, and fails on anything else.
slurm_time() {
    local value=$1 seconds
    if [[ -z $value || $value =~ ^([0-9]+-)?[0-9]+(:[0-9]{1,2}){0,2}$ || $value =~ ^(UNLIMITED|INFINITE)$ ]]; then
        printf '%s' "$value"
    elif [[ $value =~ ^([0-9]+)\.(s|m|h|d)$ ]]; then
        seconds=${BASH_REMATCH[1]}
        case ${BASH_REMATCH[2]} in
            m) seconds=$((seconds * 60)) ;;
            h) seconds=$((seconds * 3600)) ;;
            d) seconds=$((seconds * 86400)) ;;
        esac
        printf '%d-%02d:%02d:%02d' $((seconds / 86400)) $((seconds % 86400 / 3600)) \
            $((seconds % 3600 / 60)) $((seconds % 60))
    else
        return 1
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
    local name="" dir="" log="" cpus=1 mem=1G time="" after="" signal="" word wrap id exclude

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
    # A failed fetch would otherwise leave the job queued for good
    [[ -z $after ]] || args+=(--dependency="$after" --kill-on-invalid-dep=yes)
    [[ -z ${SLURM_PARTITION:-} ]] || args+=(--partition="$SLURM_PARTITION")
    [[ -z ${SLURM_ACCOUNT:-} ]] || args+=(--account="$SLURM_ACCOUNT")
    exclude=$(slurm_exclude_list) || { warn "$(no_node_left)"; return 1; }
    [[ -z $exclude ]] || args+=(--exclude="$exclude")
    id=$(sbatch "${args[@]}" --wrap "$wrap") || return 1
    id=${id%%;*}
    [[ $id =~ ^[0-9]+$ ]] || { warn "sbatch printed \"$id\" rather than a job ID."; return 1; }
    printf '%s' "$id"
}

scheduler_cancel() {
    scancel "$1" 2> /dev/null
}

# A Slurm job's state, such as PENDING, RUNNING, COMPLETED, FAILED, CANCELLED,
# TIMEOUT, OUT_OF_MEMORY or NODE_FAIL: squeue's while it remembers the job,
# then sacct's. Prints nothing when neither knows it.
scheduler_job_state() {
    local state
    state=$(squeue -h -t all -j "$1" -o %T 2> /dev/null | head -1) || state=""
    if [[ -z $state ]]; then
        state=$(sacct -n -X -P -j "$1" -o State 2> /dev/null | head -1) || state=""
        state=${state%% *}
    fi
    printf '%s' "$state"
}

# The node a Slurm job failed on before its script ran. Slurm creates a job's
# log as it starts the job, so a failed job with no log was put on a node that
# couldn't write the log's directory, such as one missing a mount. Prints
# nothing otherwise: slurm_launch_node <job id> <log>
slurm_launch_node() {
    local id=$1 log=$2 facts state node
    [[ $id =~ ^[0-9]+$ && ! -e $log ]] || return 0
    facts=$(squeue -h -t all -j "$id" -o '%T|%N' 2> /dev/null | head -1) || facts=""
    [[ -n $facts ]] || facts=$(sacct -n -X -P -j "$id" -o State,NodeList 2> /dev/null | head -1) || facts=""
    state=${facts%%|*}
    node=${facts#*|}
    [[ ${state%% *} == FAILED && -n $node && $node != "None assigned" ]] || return 0
    printf '%s' "$node"
}

# The nodes gnoto's Slurm jobs avoid, from $DATA_DIR/excluded-nodes, which the
# node checks in lib/nodes.sh and launch failures keep, as
# "<node>\t<date>\t<why>" lines
excluded_nodes() {
    [[ -r $DATA_DIR/excluded-nodes ]] || return 0
    awk -F'\t' '!/^#/ && $1 != ""' "$DATA_DIR/excluded-nodes"
}

# Changes that list under its lock, from lines on stdin: "+<node>\t<why>" adds
# a node, keeping its first date and why if it's there already, and "-<node>"
# takes one off. Leaves the file alone when nothing changes.
excluded_nodes_update() {
    local file=$DATA_DIR/excluded-nodes changes tmp src=/dev/null
    changes=$(cat)
    [[ -n $changes ]] || return 0
    {
        flock -w 30 9 || return 1
        [[ ! -e $file ]] || src=$file
        tmp=$(mktemp "$file.XXXXXX") && chmod 664 "$tmp" || return 1
        if ! {
            echo "# The nodes gnoto's Slurm jobs avoid, with when and why: each couldn't reach"
            echo "# gnoto's directories or had too little free in /tmp. A node comes off once a"
            echo "# check finds it working: gnoto lint, the check before each job, or the probe."
            awk -v today="$(date -u +%Y-%m-%d)" '
                BEGIN { FS = OFS = "\t" }
                NR == FNR {
                    node = substr($1, 2)
                    if (node == "") next
                    if ($1 ~ /^[+]/) { if (!(node in add)) order[++n] = node; add[node] = $2 }
                    else if ($1 ~ /^-/) drop[node] = 1
                    next
                }
                /^#/ || $1 == "" || ($1 in drop) { next }
                { kept[$1] = 1; print }
                END {
                    for (i = 1; i <= n; i++)
                        if (!(order[i] in drop) && !(order[i] in kept)) print order[i], today, add[order[i]]
                }
            ' <(printf '%s\n' "$changes") "$src"
        } > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        if [[ -e $file ]] && cmp -s "$tmp" "$file"; then
            rm -f "$tmp"
        elif [[ ! -e $file && $(grep -vc '^#' "$tmp") == 0 ]]; then
            rm -f "$tmp"
        else
            mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
        fi
    } 9>> "$DATA_DIR/.excluded-nodes.lock"
}

# The nodes on that list that Slurm still has, comma-separated, as sbatch
# --exclude takes them, since sbatch refuses a name it doesn't know. Returns 3
# when they're every node in the partition jobs go to.
slurm_exclude_list() {
    local listed nodes
    listed=$(excluded_nodes | cut -f1)
    [[ -n $listed ]] || return 0
    if ! nodes=$(sinfo -h -N -o '%N %P' 2> /dev/null) || [[ -z $nodes ]]; then
        paste -sd, <<< "$listed"
        return 0
    fi
    awk -v part="${SLURM_PARTITION:-}" '
        NR == FNR { if (!($1 in listed)) order[++n] = $1; listed[$1] = 1; next }
        { known[$1] = 1; p = $2; dflt = sub(/[*]$/, "", p) }
        (part == "" && dflt) || (part != "" && p == part) { inpart++; if (!($1 in listed)) free++ }
        END {
            for (i = 1; i <= n; i++) if (order[i] in known) out = out (out == "" ? "" : ",") order[i]
            if (out != "") print out
            if (inpart > 0 && free == 0) exit 3
        }
    ' <(printf '%s\n' "$listed") <(printf '%s\n' "$nodes")
}

# What to say when slurm_exclude_list leaves no node
no_node_left() {
    printf 'gnoto'"'"'s jobs avoid every node in partition %s, as %s/excluded-nodes says, so none can run. Once they'"'"'re fixed, gnoto lint takes them off.' \
        "${SLURM_PARTITION:-$(sinfo -h -o %P 2> /dev/null | sed -n 's/[*]$//p' | head -1)}" "$DATA_DIR"
}

# What to tell someone whose job died at launch on a node, naming the node and
# the directory it couldn't reach. With "avoid", it first adds the node to the
# ones gnoto's jobs avoid: launch_failure_advice <node> <directory> [avoid]
launch_failure_advice() {
    local node=$1 dir=$2
    if [[ ${3:-} == avoid ]] &&
        printf '+%s\t%s\n' "$node" "a job there couldn't reach $dir" | excluded_nodes_update 2> /dev/null; then
        printf '%s probably can'"'"'t reach %s, so gnoto'"'"'s jobs avoid it from now on, until gnoto lint finds it working.' "$node" "$dir"
    elif excluded_nodes | cut -f1 | grep -qxF -- "$node"; then
        printf '%s probably can'"'"'t reach %s. gnoto'"'"'s jobs avoid it now, until gnoto lint finds it working.' "$node" "$dir"
    else
        printf '%s probably can'"'"'t reach %s. gnoto lint checks every node, and gnoto'"'"'s jobs avoid any it finds can'"'"'t reach its directories.' "$node" "$dir"
    fi
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
