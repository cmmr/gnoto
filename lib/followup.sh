#
# followup.sh - The followup: settles a run once its head job has ended,
# however it ended.
#
# Sourced by:  lib/main.sh, for the _followup and _local commands that
#              lib/start.sh submits, and for remove
# Defines:     followup_main, record_history, utc_now
# Requires:    the settings and helpers from lib/env.sh; sacct, squeue and
#              scancel through their stand-ins, with Slurm; teardown_run from
#              service/expire.sh
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
#                    success, keeping results/ and the zip. A failed or
#                    cancelled run keeps them, and its logs and state, until
#                    cleanup_utc, so gnoto resume has a cache to resume from,
#                    and loses only the results Nextflow publishes again when
#                    it resumes. --debug keeps everything until cleanup_utc.
#
# A run gnoto remove marked while it was still going, with a file named remove
# in its run directory, gets the teardown instead of its expiry and cleanup.
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

# The first database fetch the head job waited for that didn't complete, as its
# job ID and state
failed_fetch() {
    local after id state
    after=$(state_get scheduler.after)
    after=${after#afterok:}
    for id in ${after//:/ }; do
        state=$(scheduler_job_state "$id")
        [[ $state == COMPLETED ]] || { printf '%s, %s' "$id" "${state:-of unknown state}"; return 0; }
    done
}

# Why Slurm ended the head job, when it ended it, as a sentence. Run in the run
# directory.
slurm_end_message() {
    local id=$1 state node fetch
    [[ -n $id ]] || return 0
    node=$(slurm_launch_node "$id" job.out)
    if [[ -n $node ]]; then
        echo "The job never ran. Slurm put it on $node as job $id, and $node couldn't write its log, job.out. $(launch_failure_advice "$node" "$PWD" avoid)"
        return 0
    fi
    state=$(scheduler_job_state "$id")
    if [[ $state == CANCELLED && ! -e job.out ]]; then
        fetch=$(failed_fetch)
        if [[ -n $fetch ]]; then
            echo "Slurm cancelled the job before it ran, because a database fetch it waited for didn't complete: job $fetch. Fetch logs are in $DB_DIR, named <database>.fetch.log."
            return 0
        fi
    fi
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

# What went wrong, kept in history after the run directory goes: the message,
# then Nextflow's report on the failing task, or else the end of its output
write_error_summary() {
    local out=$1 block
    {
        echo "Run ${PWD##*/}, $(state_get version), ended $(state_get ended_utc) as $(get_run_status)"
        echo
        state_get message
        block=$(nextflow_error_block nextflow.out)
        if [[ -n $block ]]; then
            echo
            printf '%s\n' "$block"
        elif [[ -r nextflow.out ]]; then
            echo
            echo "The end of nextflow.out:"
            tail -n 40 nextflow.out
        fi
    } > "$out" 2> /dev/null
}

# What outlasts the run directory, copied into history/<uid>/ from the run
# directory, with the run's lock held: record_history <uid> <status>
record_history() {
    local history=$DATA_DIR/history/$1
    mkdir -p "$history" || return 1
    cp -f job.yaml record.yaml "$history/" 2> /dev/null || warn "Couldn't copy the job and record into $history."
    cp -f "$RUN_STATE_FILE" "$history/state.json" || warn "Couldn't copy the state into $history."
    [[ $2 == Completed ]] || write_error_summary "$history/error.txt"
    chmod -R g+rwX "$history" 2> /dev/null || :
    chmod g+s "$history" 2> /dev/null || :
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
            cleanup=$remove
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

# What a run leaves behind. A failed or cancelled run keeps Nextflow's work
# directory and history, and the staged inputs, which a resumed Nextflow needs
# unchanged to find its cache.
clean_run() {
    local status=$1
    [[ $(state_get debug) != true ]] || return 0
    rm -f .inputs.list .inputs.sha256
    case $status in
        Completed | "Publish failed")
            rm -rf work .nextflow raw-sequences
            ;;
        *)
            if [[ -d results ]]; then
                find results -mindepth 1 -maxdepth 1 ! -name pipeline_info ! -name index.html \
                    ! -name progress.json ! -name assets -exec rm -rf {} + 2> /dev/null || :
            fi
            ;;
    esac
}

# followup_main <run directory>
followup_main() {
    local run_dir=${1%/} uid status message ended tasks

    uid=${run_dir##*/}
    [[ $run_dir == "$DATA_DIR"/runs/* ]] && is_valid_uid "$uid" ||
        fail "$run_dir isn't a run directory, so it isn't cleaned up."
    cd "$run_dir" || fail "Can't enter $run_dir."
    state_present || fail "$run_dir has no run_state.json."
    state_set code_dir.followup "$CODE_DIR"

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
        record_history "$uid" "$status" || fail "Can't create $DATA_DIR/history/$uid."
        if [[ -e remove ]]; then
            teardown_run "$uid" "$(head -n 1 remove)" || :
        else
            write_expiry "$uid" "$status" "$ended" || warn "Couldn't write $DATA_DIR/expiry/$uid."
            clean_run "$status"
            chmod -R g+rwX "$run_dir" 2> /dev/null || :
        fi
    ) 9>> .lock || exit 1

    if [[ -d $run_dir ]]; then
        log "Run $uid: $status."
    else
        log "Run $uid: $status. Its results were removed, as asked."
    fi
    [[ $status == Completed ]]
}
