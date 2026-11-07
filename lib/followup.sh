#
# followup.sh - The followup: settles a run once its head job has ended,
# however it ended.
#
# Sourced by:  lib/main.sh, for the _followup and _local commands that
#              lib/start.sh submits
# Defines:     followup_main
# Requires:    the settings and helpers from lib/env.sh; sacct, squeue and
#              scancel through their stand-ins, with Slurm
# Runs:        present/progress.sh once, for a run that didn't complete
#
# With Slurm, it's submitted with --dependency=afterany on the head job, so it
# runs whether that job succeeded, failed, was cancelled or was killed. A job
# Slurm stopped can't explain itself, so this asks sacct how it ended and
# writes the message, and cancels any task Nextflow left queued or running.
#
# Then, under the run's lock:
#
#   history/<uid>/   gets job.yaml, record.yaml, the final state and, for a run
#                    that didn't complete, error.txt, which outlast the run
#                    directory
#   expiry/<uid>     gets the times the daily timer acts on: remove_utc, when
#                    the results go, from retention, never sooner than
#                    core.expiration_notice_days after the run ended; and
#                    cleanup_utc, when a failed or --debug run's leftovers go,
#                    core.keep_run_days after it ended
#   the run          loses its Nextflow work directory and staged inputs on
#                    success, keeping results/ and the zip. A failed run keeps
#                    its logs, state and every task's .command.* files, and
#                    loses the rest. --debug keeps everything until cleanup_utc.
#
# A run whose Compute finished keeps its results even when Present or Publish
# failed, as "Publish failed". Exits 1 for a run that didn't complete, so
# Slurm's accounting agrees with what's reported.

# Times, in UTC, in the form every gnoto file uses
utc_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# A UTC time plus a span such as "14 days" or "3 months"
utc_plus() {
    date -u -d "$(date -u -d "$1" "+%Y-%m-%d %H:%M:%S") $2" "+%Y-%m-%dT%H:%M:%SZ"
}

# Why Slurm ended the head job, when it ended it, as a sentence
slurm_end_message() {
    local id=$1 state
    [[ -n $id ]] || return 0
    state=$(scheduler_job_state "$id")
    case $state in
        TIMEOUT) echo "The job reached its time limit, slurm.job_time, before it finished." ;;
        OUT_OF_MEMORY) echo "The job ran out of memory." ;;
        CANCELLED) echo "The job was cancelled in Slurm." ;;
        NODE_FAIL) echo "The node running the job failed." ;;
        PREEMPTED) echo "Slurm preempted the job." ;;
        BOOT_FAIL | DEADLINE) echo "Slurm stopped the job: $state." ;;
        FAILED) echo "The job failed without saying why. Its log is job.out." ;;
        "") echo "The job ended, and Slurm has no record of how." ;;
    esac
}

# The work directory of the task that failed, from Nextflow's error report
failed_task_dir() {
    awk '/^Work dir:/ { getline; sub(/^ +/, ""); print; exit }' nextflow.out 2> /dev/null
}

# What went wrong, kept in history after the run directory goes
write_error_summary() {
    local out=$1 dir
    {
        echo "Run ${PWD##*/}, $(state_get version), ended $(state_get ended_utc) as $(get_run_status)"
        echo
        state_get message
        dir=$(failed_task_dir)
        if [[ -n $dir && -r $dir/.command.err ]]; then
            echo
            echo "The last 20 lines of the failing task's .command.err, in $dir:"
            tail -n 20 "$dir/.command.err"
        fi
        if [[ -r nextflow.out ]]; then
            echo
            echo "The end of nextflow.out:"
            tail -n 40 nextflow.out
        fi
    } > "$out" 2> /dev/null
}

# The expiry file the daily timer reads, written by rename
write_expiry() {
    local uid=$1 status=$2 ended=$3 retention remove="" cleanup="" floor file tmp

    retention=$(state_get retention)
    floor=$(utc_plus "$ended" "${EXPIRATION_NOTICE_DAYS:-14} days")
    case $status in
        Completed | "Publish failed")
            case $retention in
                Unlimited) ;;
                *" Month" | *" Months")
                    remove=$(utc_plus "$ended" "${retention%% *} months")
                    [[ $remove > $floor ]] || remove=$floor
                    ;;
                *) remove=$(utc_plus "$ended" "3 months") ;;
            esac
            [[ $(state_get debug) != true ]] || cleanup=$(utc_plus "$ended" "${KEEP_RUN_DAYS:-14} days")
            ;;
        *)
            remove=$(utc_plus "$ended" "${KEEP_RUN_DAYS:-14} days")
            ;;
    esac
    [[ -n $remove || -n $cleanup ]] || return 0
    mkdir -p "$DATA_DIR/expiry" || return 1
    file=$DATA_DIR/expiry/$uid
    tmp=$(mktemp "$file.XXXXXX") && chmod 664 "$tmp" || return 1
    {
        echo "# Written by gnoto when run $uid ended. The daily timer acts on it."
        [[ -z $remove ]] || echo "remove_utc: \"$remove\""
        [[ -z $cleanup ]] || echo "cleanup_utc: \"$cleanup\""
    } > "$tmp" && mv -f "$tmp" "$file"
}

# What a run leaves behind
clean_run() {
    local status=$1
    [[ $(state_get debug) != true ]] || return 0
    rm -rf .nextflow raw-sequences .inputs.list .inputs.sha256
    case $status in
        Completed | "Publish failed")
            rm -rf work
            ;;
        *)
            if [[ -d work ]]; then
                find work -mindepth 1 \( -type f -o -type l \) ! -name '.command.*' ! -name '.exitcode' \
                    -delete 2> /dev/null || :
                find work -mindepth 1 -type d -empty -delete 2> /dev/null || :
            fi
            if [[ -d results ]]; then
                find results -mindepth 1 -maxdepth 1 ! -name pipeline_info ! -name index.html \
                    ! -name progress.json ! -name assets -exec rm -rf {} + 2> /dev/null || :
            fi
            ;;
    esac
}

# followup_main <run directory>
followup_main() {
    local run_dir=${1%/} uid status message ended tasks history

    uid=${run_dir##*/}
    [[ $run_dir == "$DATA_DIR"/runs/* ]] && is_valid_uid "$uid" ||
        fail "$run_dir isn't a run directory, so it isn't cleaned up."
    cd "$run_dir" || fail "Can't enter $run_dir."
    state_present || fail "$run_dir has no run_state.json."

    status=$(get_run_status)
    if [[ $status != Completed ]]; then
        if [[ -e cancel ]]; then
            status=Cancelled
            [[ -n $(state_get message) && $(state_get message) != *stopped* ]] ||
                state_set message "The job was cancelled."
        else
            if [[ $(state_get scheduler.kind) == slurm && -z $(state_get message) ]]; then
                message=$(slurm_end_message "$(state_get scheduler.job_id)")
                [[ -z $message ]] || state_set message "$message"
            fi
            [[ -n $(state_get message) ]] || state_set message "The job ended before it finished. Its log is job.out."
            if [[ -n $(state_get stages.compute) ]]; then
                status="Publish failed"
            elif [[ $status != Cancelled ]]; then
                status=Failed
            fi
        fi
        if [[ $(state_get scheduler.kind) == slurm ]]; then
            tasks=$(cancel_run_tasks "$run_dir" | cut -f2 | paste -sd ',' | sed 's/,/, /g')
            [[ -z $tasks ]] || state_append notes "Tasks still running were cancelled: $tasks."
        fi
        set_run_status "$status"
        case $status in
            Cancelled) state_set stage "Stopped, as asked." ;;
            "Publish failed") state_set stage "The results were made, but building or publishing their pages failed." ;;
            *) state_set stage "The run didn't finish." ;;
        esac
        if [[ -f $CODE_DIR/present/progress.sh ]]; then
            bash "$CODE_DIR/present/progress.sh" > /dev/null 2>&1 || :
        fi
    fi
    ended=$(utc_now)
    state_set ended_utc "$ended"

    (
        flock -w 60 9 || fail "Can't lock run $uid, so it wasn't cleaned up."
        history=$DATA_DIR/history/$uid
        mkdir -p "$history" || fail "Can't create $history."
        cp -f job.yaml record.yaml "$history/" 2> /dev/null || warn "Couldn't copy the job and record into $history."
        cp -f "$RUN_STATE_FILE" "$history/state.json" || warn "Couldn't copy the state into $history."
        [[ $status == Completed ]] || write_error_summary "$history/error.txt"
        write_expiry "$uid" "$status" "$ended" || warn "Couldn't write $DATA_DIR/expiry/$uid."
        clean_run "$status"
        chmod -R g+rwX "$run_dir" "$history" 2> /dev/null || :
        chmod g+s "$history" 2> /dev/null || :
    ) 9>> .lock || exit 1

    log "Run $uid: $status."
    [[ $status == Completed ]]
}
