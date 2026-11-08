#
# runs.sh - gnoto status and gnoto cancel: what's running and what ran, and
# stopping a run.
#
# Sourced by:  lib/main.sh, for status and cancel
# Defines:     status_main, cancel_main
# Requires:    jq, flock; squeue and sacct through their stand-ins, with Slurm;
#              the settings and helpers from lib/env.sh
#
# Both read state files rather than asking Slurm for the user's jobs, so they
# see every user's runs. A run the state shows as running is checked against
# its scheduler, and shows as Lost when nothing is running for it, as happens
# when a job and its followup are killed together.
#
# Cancelling writes a cancel file in the run directory: Slurm lets only a job's
# owner, an admin or an account coordinator cancel it, and any member of
# gnoto's group may cancel any run. The run's progress watcher stops it when it
# sees the file, and a job still queued stops as it starts.

FINAL_STATUSES=" Completed Failed Cancelled Lost "

# Seconds as the largest two units, such as 2h 14m
human_duration() {
    local s=$1
    if (( s >= 86400 )); then
        printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
    elif (( s >= 3600 )); then
        printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
    elif (( s >= 60 )); then
        printf '%dm' $((s / 60))
    else
        printf '%ds' "$s"
    fi
}

# A pipeline's version, with a commit cut to its first seven characters
short_version() {
    local version=$1
    if [[ $version =~ ^([^@]+)@([0-9a-f]{40})$ ]]; then
        printf '%s@%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]:0:7}"
    else
        printf '%s' "$version"
    fi
}

# What's running for a run the state shows as running, by asking its scheduler:
# prints its status, or Lost when nothing is, run from the run directory
live_status() {
    local status kind head followup head_state followup_state alive=0

    status=$(get_run_status)
    kind=$(state_get scheduler.kind)
    if [[ $kind == slurm ]]; then
        head=$(state_get scheduler.job_id)
        followup=$(state_get scheduler.followup_id)
        [[ -n $head ]] || { printf '%s' "$status"; return; }
        head_state=$(scheduler_job_state "$head")
        case $head_state in
            PENDING) printf 'Queued'; return ;;
            RUNNING | CONFIGURING | COMPLETING | SUSPENDED) printf '%s' "$status"; return ;;
        esac
        followup_state=""
        [[ -z $followup ]] || followup_state=$(scheduler_job_state "$followup")
        case $followup_state in
            PENDING | RUNNING | CONFIGURING | COMPLETING) printf 'Finishing'; return ;;
        esac
        printf 'Lost'
    else
        scheduler_local_alive "$(state_get scheduler.host)" "$(state_get scheduler.pid)" || alive=$?
        case $alive in
            0) printf '%s' "$status" ;;
            2) printf '%s (on %s)' "$status" "$(state_get scheduler.host)" ;;
            *) printf 'Lost' ;;
        esac
    fi
}

status_main() {
    case ${1:-} in
        "") status_all ;;
        *)
            [[ $# -eq 1 ]] || fail "Usage: gnoto status [uid]"
            status_one "${1,,}"
            ;;
    esac
}

status_all() {
    local dir file now started elapsed state uid version status line ended remove
    local running=() finished=() expiring=()

    now=$(date -u +%s)
    echo "Current version: $(current_commit)"
    echo
    echo "Integrations"
    if [[ -r $DATA_DIR/logs/health.yaml ]]; then
        sed 's/^/  /' "$DATA_DIR/logs/health.yaml"
    else
        echo "  Not checked: the daily timer, which runs lint and records the result, isn't installed."
    fi

    for dir in "$DATA_DIR"/runs/*/; do
        dir=${dir%/}
        uid=${dir##*/}
        is_valid_uid "$uid" && [[ -r $dir/$RUN_STATE_FILE ]] || continue
        status=$(cd "$dir" && get_run_status)
        [[ $FINAL_STATUSES != *" $status "* && $status != "Publish failed" ]] || continue
        status=$(cd "$dir" && live_status)
        started=$(cd "$dir" && state_get started_utc)
        [[ -n $started ]] || started=$(cd "$dir" && state_get created_utc)
        elapsed=$(( now - $(date -u -d "$started" +%s 2> /dev/null || echo "$now") ))
        version=$(cd "$dir" && short_version "$(state_get version)")
        line=$(printf '  %s  %-18s %-15s %-9s %s' "$uid" "$version" "$status" \
            "$(human_duration "$elapsed")" "$(cd "$dir" && state_get stage)")
        running+=("$line")
    done

    for file in "$DATA_DIR"/history/*/state.json; do
        [[ -r $file ]] || continue
        uid=${file%/state.json}
        uid=${uid##*/}
        ended=$(jq -r '.ended_utc // empty' "$file")
        [[ -n $ended ]] || continue
        (( now - $(date -u -d "$ended" +%s) <= 7 * 86400 )) || continue
        status=$(jq -r '.status // ""' "$file")
        if [[ $status == Completed || $status == "Publish failed" ]]; then
            if [[ -f $DATA_DIR/runs/$uid/results/index.html ]]; then
                state=$DATA_DIR/runs/$uid/results/index.html
            else
                state="results removed"
            fi
        else
            state=$(jq -r '.message // ""' "$file" | head -1)
        fi
        line=$(printf '  %s  %-18s %-15s %-9s %s' "$uid" "$(short_version "$(jq -r '.version // ""' "$file")")" \
            "$status" "$(date -u -d "$ended" '+%b %-d')" "$state")
        finished+=("$ended$line")
    done

    for file in "$DATA_DIR"/expiry/*; do
        [[ -r $file ]] || continue
        uid=${file##*/}
        is_valid_uid "$uid" || continue
        remove=$(yq -r '.remove_utc // ""' "$file" 2> /dev/null) || remove=""
        [[ -n $remove ]] || continue
        (( $(date -u -d "$remove" +%s) - now <= ${EXPIRATION_NOTICE_DAYS:-14} * 86400 )) || continue
        expiring+=("$(printf '  %s  results removed after %s' "$uid" "$(date -u -d "$remove" '+%b %-d %Y')")")
    done

    echo
    echo "Running"
    if (( ${#running[@]} == 0 )); then
        echo "  Nothing"
    else
        printf '%s\n' "${running[@]}"
    fi
    echo
    echo "Finished in the last 7 days"
    if (( ${#finished[@]} == 0 )); then
        echo "  Nothing"
    else
        printf '%s\n' "${finished[@]}" | sort -r | cut -c21-
    fi
    if (( ${#expiring[@]} > 0 )); then
        echo
        echo "Expiring within ${EXPIRATION_NOTICE_DAYS:-14} days"
        printf '%s\n' "${expiring[@]}"
    fi
}

status_one() {
    local uid=$1 dir state_dir status kind task_dir file stage logs block job what id log node attempts
    is_valid_uid "$uid" || fail "\"$uid\" isn't a run's uid: those are eight letters and digits, such as k3f9a2qx."
    dir=$DATA_DIR/runs/$uid
    if [[ -r $dir/$RUN_STATE_FILE ]]; then
        state_dir=$dir
    elif [[ -r $DATA_DIR/history/$uid/state.json ]]; then
        state_dir=$DATA_DIR/history/$uid
        RUN_STATE_FILE=state.json
    else
        fail "There's no run $uid."
    fi
    cd "$state_dir" || fail "Can't enter $state_dir."
    status=$(get_run_status)
    if [[ $FINAL_STATUSES != *" $status "* && $status != "Publish failed" && $state_dir == "$dir" ]]; then
        status=$(live_status)
    fi
    kind=$(state_get scheduler.kind)

    echo "Run $uid"
    printf '  %-10s %s\n' Pipeline "$(state_get version)"
    [[ -z $(state_get commit) ]] || printf '  %-10s %s%s\n' Commit "$(state_get commit)" \
        "$([[ $(state_get dev) == true ]] && echo ", with changes (dev)")"
    printf '  %-10s %s\n' Title "$(state_get title)"
    stage=$(state_get stage)
    printf '  %-10s %s\n' Status "$status${stage:+: $stage}"
    attempts=$(state_get_json attempts | jq 'length')
    (( attempts == 0 )) ||
        printf '  %-10s %s\n' Attempt "$((attempts + 1)), resumed $(state_get resumed_utc)"
    printf '  %-10s %s\n' Owner "$(state_get owner)"
    printf '  %-10s %s\n' Created "$(state_get created_utc)"
    [[ -z $(state_get started_utc) ]] || printf '  %-10s %s\n' Started "$(state_get started_utc)"
    [[ -z $(state_get ended_utc) ]] || printf '  %-10s %s\n' Ended "$(state_get ended_utc)"
    if [[ $kind == slurm ]]; then
        printf '  %-10s job %s, followup %s\n' Slurm "$(state_get scheduler.job_id)" "$(state_get scheduler.followup_id)"
    else
        printf '  %-10s on %s, process %s\n' Local "$(state_get scheduler.host)" "$(state_get scheduler.pid)"
    fi
    if [[ -d $dir ]]; then
        printf '  %-10s %s\n' Directory "$dir"
        logs=$(cd "$dir" && ls -1 job.out nextflow.out followup.out 2> /dev/null | paste -sd ' ') || logs=""
        [[ -z $logs ]] || printf '  %-10s %s\n' Logs "$logs"
        [[ ! -f $dir/results/index.html ]] || printf '  %-10s %s\n' Results "$dir/results/index.html"
        file=$(ls -1 "$dir"/*.zip 2> /dev/null | head -1) || file=""
        [[ -z $file ]] || printf '  %-10s %s, %s\n' Download "$file" "$(human_size "$(stat -c %s "$file")")"
    else
        printf '  %-10s %s\n' History "$DATA_DIR/history/$uid"
    fi
    if [[ -r $DATA_DIR/expiry/$uid ]]; then
        file=$(yq -r '.remove_utc // ""' "$DATA_DIR/expiry/$uid" 2> /dev/null) || file=""
        [[ -z $file ]] || printf '  %-10s %s\n' Expires "$file"
    fi
    [[ -z $(state_get message) ]] || printf '  %-10s %s\n' Message "$(state_get message)"
    state_get_json notes | jq -r '.[]? | "  Note       \(.)"'

    # A run is lost when its followup never ran, so nothing recorded why
    if [[ $status == Lost && $kind == slurm ]]; then
        for job in "job $(state_get scheduler.job_id) job.out" "followup $(state_get scheduler.followup_id) followup.out"; do
            read -r what id log <<< "$job"
            node=$(slurm_launch_node "$id" "$log")
            [[ -z $node ]] || printf '  %-10s %s\n' Why "The $what never ran. Slurm put it on $node as job $id, and $node couldn't write its log, $log. $(launch_failure_advice "$node" "$dir")"
        done
    fi

    # Nextflow's own report on the failing task holds its command's output and
    # error, where a tool's message is, while the end of .command.err can be
    # warnings alone
    if [[ $status != Completed && -d $dir ]]; then
        block=$(nextflow_error_block "$dir/nextflow.out")
        task_dir=$(awk '/^Work dir:/ { getline; sub(/^ +/, ""); print; exit }' "$dir/nextflow.out" 2> /dev/null)
        if [[ -n $block ]]; then
            echo
            printf '%s\n' "$block" | sed 's/^/  /'
        elif [[ -n $task_dir && -r $task_dir/.command.err ]]; then
            echo
            echo "The failing task's .command.err, last 20 lines, in $task_dir:"
            tail -n 20 "$task_dir/.command.err" | sed 's/^/  /'
        fi
    elif [[ $status != Completed && -r $DATA_DIR/history/$uid/error.txt ]]; then
        echo
        sed 's/^/  /' "$DATA_DIR/history/$uid/error.txt"
    fi
}

cancel_main() {
    local uid=${1:-} dir status head
    [[ $# -eq 1 ]] || fail "Usage: gnoto cancel <uid>"
    uid=${uid,,}
    is_valid_uid "$uid" || fail "\"$uid\" isn't a run's uid: those are eight letters and digits, such as k3f9a2qx."
    dir=$DATA_DIR/runs/$uid
    if [[ ! -r $dir/$RUN_STATE_FILE ]]; then
        [[ -r $DATA_DIR/history/$uid/state.json ]] && fail "Run $uid has already ended."
        fail "There's no run $uid."
    fi
    cd "$dir" || fail "Can't enter $dir."
    status=$(get_run_status)
    [[ $FINAL_STATUSES != *" $status "* && $status != "Publish failed" ]] ||
        fail "Run $uid has already ended, as $status."
    (
        flock -w 30 9 || fail "Can't lock run $uid."
        : > cancel || fail "Can't write $dir/cancel."
    ) 9>> .lock || exit 1
    state_append notes "Cancelled by $(id -un) at $(date -u '+%Y-%m-%dT%H:%M:%SZ')." || :

    # A job still queued has no watcher yet. It stops as it starts, and its owner
    # can take it out of the queue now.
    if [[ $(state_get scheduler.kind) == slurm ]]; then
        head=$(state_get scheduler.job_id)
        if [[ -n $head && $(scheduler_job_state "$head") == PENDING ]]; then
            scheduler_cancel "$head" || :
        fi
    fi
    echo "Asked run $uid to stop. It stops within a minute, and gnoto status $uid shows when it has."
}
