#
# expire.sh - The teardown that deletes a run's results, which gnoto remove and
# a run's followup share. Phase 7 adds the daily expiry check, which runs it
# when a run's removal time passes.
#
# Sourced by:  lib/main.sh, for remove, _followup and _local
# Defines:     teardown_run
# Requires:    flock; the settings and helpers from lib/env.sh, and
#              state_append from lib/run_state.sh
#
# The run directory goes, with results/ and the deliverables zip in it, and so
# does the run's expiry file. history/<uid>/ stays, so the record can re-run
# the job while its inputs exist.

# teardown_run <uid> <note>: deletes run <uid>'s results, with the run's lock
# held, from run_lock or the followup, and adds <note>, if any, to the state in
# history. Holds history's lock as well while the run directory goes, so a
# command that waited on the run directory's lock takes history's next. Warns
# about anything it couldn't delete, and returns 1.
teardown_run() (
    local uid=$1 note=$2 dir=$DATA_DIR/runs/$1 history=$DATA_DIR/history/$1 gone errors left=0

    if [[ -d $dir ]]; then
        mkdir -p "$history" && { exec 7>> "$history/.lock"; } 2> /dev/null && flock -w 30 7 ||
            { warn "Can't lock $history, so run $uid's results weren't removed."; return 1; }
    fi

    # Phase 7: with Wrike, the run's task moves to Expired. With S3, the run's
    # results there go, leaving the expired page at their address. With
    # Globus, the run's archive goes.

    if [[ -d $dir ]]; then
        # Moved aside first, so a half-deleted run never looks like a run
        gone=$(mktemp -u "$DATA_DIR/runs/.tmp.remove.$uid.XXXXXX")
        mv -T "$dir" "$gone" 2> /dev/null ||
            { warn "Can't move $dir aside to delete it, so run $uid's results weren't removed."; return 1; }
        errors=$(rm -rf "$gone" 2>&1)
        if [[ -e $gone ]]; then
            warn "Couldn't delete everything in run $uid's directory. What's left is in $gone: $(head -3 <<< "$errors" | paste -sd ' ')"
            left=1
        fi
    fi
    rm -f "$DATA_DIR/expiry/$uid" 2> /dev/null || { warn "Couldn't delete $DATA_DIR/expiry/$uid."; left=1; }
    if [[ -n $note && -f $history/state.json ]]; then
        (cd "$history" && RUN_STATE_FILE=state.json state_append notes "$note") ||
            warn "Couldn't add to $history/state.json that the results were removed."
    fi
    return $left
)
