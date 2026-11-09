#
# runs.sh - gnoto status, gnoto cancel and gnoto remove: what's running and
# what ran, stopping a run, and deleting its results.
#
# Sourced by:  lib/main.sh, for status, cancel, resume and remove
# Defines:     status_main, cancel_main, remove_main, live_status, run_lock
# Requires:    jq, flock; squeue, sacct and scancel through their stand-ins,
#              with Slurm; the settings and helpers from lib/env.sh; and for
#              remove, record_history and utc_now from lib/followup.sh and
#              teardown_run from service/expire.sh
#
# They read state files rather than asking Slurm for the user's jobs, so they
# see every user's runs. A run the state shows as running is checked against
# its scheduler, and shows as Lost when nothing is running for it, as happens
# when a job and its followup are killed together.
#
# Cancelling writes a cancel file in the run directory: Slurm lets only a job's
# owner, an admin or an account coordinator cancel it, and any member of
# gnoto's group may cancel any run. The run's progress watcher stops it when it
# sees the file, and a job still queued stops as it starts.
#
# Removing deletes a run's results at once, keeping its record in history. A
# run still going gets the cancel file and a remove marker instead, and its
# followup removes the results once it has recorded the run's end.

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

# What's still running for a run, by asking its scheduler, run from the run
# directory: queued or running while its head job is, finishing while only its
# followup is, elsewhere for a local run on another machine, starting before
# its job is recorded, or nothing
run_activity() {
    local head followup state alive=0

    if [[ $(state_get scheduler.kind) == slurm ]]; then
        head=$(state_get scheduler.job_id)
        [[ -n $head ]] || { echo starting; return 0; }
        case $(scheduler_job_state "$head") in
            PENDING) echo queued; return 0 ;;
            RUNNING | CONFIGURING | COMPLETING | SUSPENDED) echo running; return 0 ;;
        esac
        followup=$(state_get scheduler.followup_id)
        state=""
        [[ -z $followup ]] || state=$(scheduler_job_state "$followup")
        case $state in
            PENDING | RUNNING | CONFIGURING | COMPLETING) echo finishing ;;
        esac
    else
        [[ -n $(state_get scheduler.host) ]] || { echo starting; return 0; }
        scheduler_local_alive "$(state_get scheduler.host)" "$(state_get scheduler.pid)" || alive=$?
        case $alive in
            0) echo running ;;
            2) echo elsewhere ;;
        esac
    fi
    return 0
}

# What's running for a run the state shows as running: prints its status, or
# Lost when nothing is, run from the run directory. Takes run_activity's
# answer, when the caller has it.
live_status() {
    local status activity=${1-$(run_activity)}
    status=$(get_run_status)
    case $activity in
        queued) printf 'Queued' ;;
        running | starting) printf '%s' "$status" ;;
        finishing) printf 'Finishing' ;;
        elsewhere) printf '%s (on %s)' "$status" "$(state_get scheduler.host)" ;;
        *) printf 'Lost' ;;
    esac
}

# run_lock <uid>: takes run <uid>'s lock on file descriptor 9, until the
# (sub)shell exits. It's .lock in the run directory, or in history/<uid>/ once
# that has gone. A teardown holds both while the run directory goes, so a
# command that waited on the first finds it gone and takes the second.
run_lock() {
    local dir=$DATA_DIR/runs/$1 history=$DATA_DIR/history/$1 try
    for try in 1 2; do
        if [[ -d $dir ]]; then
            { exec 9>> "$dir/.lock"; } 2> /dev/null && flock -w 30 9 || return 1
            [[ ! -d $dir ]] || return 0
        else
            mkdir -p "$history" && { exec 9>> "$history/.lock"; } 2> /dev/null && flock -w 30 9 || return 1
            [[ -d $dir ]] || return 0
        fi
        exec 9>&-
    done
    return 1
}

# Asks a run that's still going to stop, from its run directory, with its lock
# held: writes the cancel file its progress watcher acts on, and takes a head
# job still queued out of Slurm's queue. Only the job's owner can, and otherwise
# it stops as it starts.
request_stop() {
    local head
    : > cancel || return 1
    if [[ $(state_get scheduler.kind) == slurm ]]; then
        head=$(state_get scheduler.job_id)
        if [[ -n $head && $(scheduler_job_state "$head") == PENDING ]]; then
            scheduler_cancel "$head" || :
        fi
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
    local uid=${1:-} dir status
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
        run_lock "$uid" || fail "Can't lock run $uid."
        [[ -d $dir ]] || fail "Run $uid has been removed."
        request_stop || fail "Can't write $dir/cancel."
    ) || exit 1
    state_append notes "Cancelled by $(id -un) at $(date -u '+%Y-%m-%dT%H:%M:%SZ')." || :
    echo "Asked run $uid to stop. It stops within a minute, and $(gnoto_command status "$uid") shows when it has."
}

# True once a run's followup has recorded its end in history/<uid>/, which it
# does under the run's lock. Run from the run directory.
followup_done() {
    local ended history=$DATA_DIR/history/$1/state.json
    ended=$(state_get ended_utc)
    [[ -n $ended && -r $history && $(jq -r '.ended_utc // ""' "$history" 2> /dev/null) == "$ended" ]]
}

# What remove lists for a run with a run directory: a first line, "going" when
# it's stopped first or "ended", then the run's line
remove_line() (
    local uid=$1 status activity="" going=ended
    cd "$DATA_DIR/runs/$uid" || exit 1
    status=$(get_run_status)
    if ! followup_done "$uid"; then
        activity=$(run_activity)
        status=$(live_status "$activity")
        case $activity in queued | running | finishing | elsewhere) going=going ;; esac
    fi
    echo "$going"
    printf '  %s  %-18s %-15s %-10s %s\n' "$uid" "$(short_version "$(state_get version)")" "$status" \
        "$(state_get owner)" "$(state_get title)"
)

# Removes one run's results, or asks it to stop first: remove_one <uid>. Takes
# the run's lock, so a run's followup and every other command on the run see
# it before or after, and never halfway.
remove_one() (
    local uid=$1 dir=$DATA_DIR/runs/$1 user now status activity
    user=$(id -un)
    now=$(utc_now)
    run_lock "$uid" || { warn "Can't lock run $uid, so it wasn't removed."; return 1; }
    if [[ ! -d $dir ]]; then
        if [[ -e $DATA_DIR/expiry/$uid ]]; then
            teardown_run "$uid" "" || return 1
            echo "Removed run $uid's leftover expiry file. Its results had already gone."
        else
            echo "Run $uid's results have already gone. Its record is in $DATA_DIR/history/$uid."
        fi
        return 0
    fi
    cd "$dir" || { warn "Can't enter $dir, so run $uid wasn't removed."; return 1; }
    status=$(get_run_status)

    if ! followup_done "$uid"; then
        activity=$(run_activity)
        case $activity in
            queued | running | finishing | elsewhere)
                # Deleting the run directory now would delete the cancel file,
                # and the job could go on to publish the results
                if [[ $activity != finishing && $FINAL_STATUSES != *" $status "* ]]; then
                    request_stop || { warn "Can't write $dir/cancel, so run $uid wasn't removed."; return 1; }
                fi
                echo "Results removed once the run ended, as $user asked at $now." > remove ||
                    { warn "Can't write $dir/remove, so run $uid wasn't removed."; return 1; }
                state_append notes "Removal asked by $user at $now. The results go once the run has ended." || :
                case $activity in
                    finishing) echo "Run $uid has ended, and its results go once its followup has finished, within a few minutes." ;;
                    elsewhere)
                        echo "Run $uid runs on $(state_get scheduler.host), so it's asked to stop there, and its results go once it has. If it has already stopped, $(gnoto_command remove "$uid") on $(state_get scheduler.host) removes them."
                        ;;
                    *) echo "Asked run $uid to stop. Its results go once it has, and $(gnoto_command status "$uid") shows when." ;;
                esac
                return 0
                ;;
        esac
        # Nothing is left to record the run's end, so it's recorded here, as its
        # followup would have
        if [[ $FINAL_STATUSES != *" $status "* ]]; then
            set_run_status Lost
            status=Lost
        fi
        [[ -n $(state_get message) ]] || state_set message "Nothing was running for the run when it was removed."
        record_history "$uid" "$status" || { warn "Couldn't record run $uid in history, so it wasn't removed."; return 1; }
    fi

    teardown_run "$uid" "Results removed by $user at $now." || return 1
    echo "Removed run $uid's results. Its record stays in $DATA_DIR/history/$uid."
)

# gnoto remove [--yes] <uid>...
remove_main() {
    local usage="Usage: gnoto remove [--yes] <uid>..." word uid dir line answer stopping=0 failed=0
    local uids=() todo=() lines=() unknown=()

    args_parse "$usage" "yes" "$@"
    [[ ${#ARG_KEYS[@]} -eq 0 ]] || fail "gnoto remove takes --yes, not --${ARG_KEYS[0]}. $usage"
    [[ ${#ARG_WORDS[@]} -gt 0 ]] || fail "$usage"
    for word in "${ARG_WORDS[@]}"; do
        uid=${word,,}
        is_valid_uid "$uid" || fail "\"$word\" isn't a run's uid: those are eight letters and digits, such as k3f9a2qx."
        [[ " ${uids[*]} " == *" $uid "* ]] || uids+=("$uid")
    done

    for uid in "${uids[@]}"; do
        dir=$DATA_DIR/runs/$uid
        if [[ -d $dir ]]; then
            [[ -r $dir/$RUN_STATE_FILE ]] ||
                fail "$dir has no $RUN_STATE_FILE, so gnoto can't tell what it is, and nothing was removed. A run being submitted has one within seconds."
            line=$(remove_line "$uid") || fail "Can't read $dir, so nothing was removed."
            todo+=("$uid")
            lines+=("${line#*$'\n'}")
            [[ ${line%%$'\n'*} != going ]] || stopping=$((stopping + 1))
        elif [[ -e $DATA_DIR/expiry/$uid ]]; then
            todo+=("$uid")
            lines+=("$(printf '  %s  results already gone, and its leftover expiry file goes' "$uid")")
        elif [[ -e $DATA_DIR/history/$uid ]]; then
            echo "Run $uid's results have already gone. Its record is in $DATA_DIR/history/$uid."
        else
            unknown+=("$uid")
        fi
    done
    if (( ${#unknown[@]} == 1 )); then
        fail "There's no run ${unknown[0]}, so nothing was removed."
    elif (( ${#unknown[@]} > 1 )); then
        fail "There are no runs ${unknown[*]}, so nothing was removed."
    fi
    (( ${#todo[@]} > 0 )) || return 0

    if (( ${#todo[@]} == 1 )); then
        echo "Deleting this run's results. Its record stays in $DATA_DIR/history."
    else
        echo "Deleting these ${#todo[@]} runs' results. Their records stay in $DATA_DIR/history."
    fi
    printf '%s\n' "${lines[@]}"
    (( stopping == 0 )) || echo "A run still going is stopped first, and its results go once it has."
    if [[ -z ${ARG_FLAGS[yes]:-} ]]; then
        [[ -t 0 ]] || fail "No terminal to confirm on. Add --yes to remove."
        printf 'Remove %s? [y/N] ' "$( (( ${#todo[@]} == 1 )) && echo it || echo them)" >&2
        read -r answer || answer=""
        [[ $answer == [yY]* ]] || fail "Nothing removed."
    fi
    for uid in "${todo[@]}"; do
        remove_one "$uid" || failed=$((failed + 1))
    done
    (( failed == 0 )) || fail "$failed of the ${#todo[@]} runs couldn't be removed, as the messages above say."
}
