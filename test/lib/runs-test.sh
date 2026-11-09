#!/bin/bash
#
# runs-test.sh - Tests gnoto remove, and the run lock and stop request it
# shares with gnoto cancel, in the real image: several runs at once, the prompt
# and --yes, a job still running, locally and on Slurm, which its followup
# removes once it ends, a lost run, unknown uids, results already gone, an
# expiry file left behind, and what history keeps. Slurm is stubbed where it's
# asked.
#
# Run by:    a developer, as any user but root, through the launcher:
#            gnoto exec --dev bash <install>/test/lib/runs-test.sh
# Requires:  the gnoto image
#
# Its data directory is a scratch directory. Finished runs are ended by the
# real followup, run by the local scheduler, as a job without Slurm is.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "$GNOTO_DATA_DIR/test-runs.XXXXXX")
FAILED=0
SLEEPER=""
trap 'kill $SLEEPER 2> /dev/null; chmod -R u+rwX "$WORK" 2> /dev/null; rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# True when a check's output holds a line
has() {
    grep -qF -- "$2" <<< "$1" && echo yes || echo no
}

exists() {
    [[ -e $1 ]] && echo yes || echo no
}

mkdir -p "$WORK/install" "$WORK/data"
printf 'core:\n  data_dir: "%s"\n' "$WORK/data" > "$WORK/install/config.yaml"
export GNOTO_INSTALL_DIR=$WORK/install
export GNOTO_LAUNCHER=$WORK/install/gnoto
source "$CODE/lib/env.sh" || exit 1
source "$CODE/lib/args.sh"
source "$CODE/lib/runs.sh"
source "$CODE/lib/followup.sh"
source "$CODE/lib/start.sh"
source "$CODE/service/expire.sh"
RUNS=$WORK/data/runs
HISTORY=$WORK/data/history
EXPIRY=$WORK/data/expiry
ME=$(id -un)
( exit 0 ) &
wait $!
DEAD_PID=$!

# A run as gnoto start leaves it, on the local scheduler with its process
# gone: make_run <uid> [owner]
make_run() {
    local dir=$RUNS/$1
    mkdir -p "$dir/results" "$dir/work"
    (
        cd "$dir" || exit 1
        state_init "$1" > /dev/null
        state_update '. + $f' --argjson f "$(jq -n --arg owner "${2:-$ME}" --arg host "$(uname -n)" \
            --arg pid "$DEAD_PID" '{pipeline: "ampliseq", version: "ampliseq@1.1.0", title: "Mock run",
            retention: "1 Month", owner: $owner, scheduler: {kind: "local", host: $host, pid: $pid}}')"
        set_run_status Running
        printf 'pipeline: ampliseq\n' > job.yaml
        printf 'schema: 1\n' > record.yaml
        echo '<html></html>' > results/index.html
        echo zip > "gnoto-$1.zip"
    )
}

# Ends a run as its followup does, as Completed, or otherwise as Failed:
# end_run <uid> <Completed|Failed>
end_run() {
    (
        cd "$RUNS/$1" || exit 1
        [[ $2 != Completed ]] || set_run_status Completed
        followup_main "$RUNS/$1"
    ) > /dev/null 2>&1
}

# gnoto remove through the entry point, with $1 typed at its prompt in a
# terminal: remove_typed <answer> <uid>...
remove_typed() {
    local answer=$1
    shift
    printf '%s\n' "$answer" | script -qec "bash $CODE/lib/main.sh remove $*" /dev/null 2>&1 | tr -d '\r'
}

echo "the arguments"
OUT=$( (remove_main) 2>&1)
check "needs a uid" "yes" "$(has "$OUT" "Usage: gnoto remove [--yes] <uid>...")"
OUT=$( (remove_main --force abcdefgh) 2>&1)
check "takes only --yes" "yes" "$(has "$OUT" "gnoto remove takes --yes, not --force.")"
OUT=$( (remove_main --yes nope) 2>&1)
check "refuses what isn't a uid" "yes" "$(has "$OUT" "\"nope\" isn't a run's uid")"

echo "several at once, with --yes"
make_run aaaaaaaa
make_run bbbbbbbb someone
make_run cccccccc
end_run aaaaaaaa Completed
end_run bbbbbbbb Completed
end_run cccccccc Failed
check "the runs ended, as their followups leave them" "Completed Completed Failed yes yes yes" \
    "$(jq -r .status "$HISTORY"/{aaaaaaaa,bbbbbbbb,cccccccc}/state.json | paste -sd ' ') $(exists "$EXPIRY/aaaaaaaa") $(exists "$EXPIRY/bbbbbbbb") $(exists "$EXPIRY/cccccccc")"
OUT=$(cd "$WORK" && remove_main --yes aaaaaaaa BBBBBBBB cccccccc aaaaaaaa 2>&1)
check "lists them once each, uids in any case" "Deleting these 3 runs' results. Their records stay in $HISTORY." \
    "$(head -n 1 <<< "$OUT")"
check "with each one's version, status, owner and title" \
    "  bbbbbbbb  ampliseq@1.1.0     Completed       someone    Mock run" "$(sed -n 3p <<< "$OUT")"
check "and a failed one" "yes" "$(has "$OUT" "  cccccccc  ampliseq@1.1.0     Failed          $ME")"
check "says nothing about stopping, as none is going" "no" "$(has "$OUT" "stopped first")"
check "removes each, another member's included" "3" "$(grep -c "^Removed run [abc]\{8\}'s results. Its record stays in $HISTORY/" <<< "$OUT")"
check "the run directories go" "no no no" "$(exists "$RUNS/aaaaaaaa") $(exists "$RUNS/bbbbbbbb") $(exists "$RUNS/cccccccc")"
check "with nothing left aside" "" "$(ls -A "$RUNS")"
check "and the expiry files" "no no no" "$(exists "$EXPIRY/aaaaaaaa") $(exists "$EXPIRY/bbbbbbbb") $(exists "$EXPIRY/cccccccc")"
check "history keeps the job, record and state" "job.yaml record.yaml state.json" \
    "$(cd "$HISTORY/aaaaaaaa" && ls job.yaml record.yaml state.json | paste -sd ' ')"
check "and a failed run's error summary" "yes" "$(exists "$HISTORY/cccccccc/error.txt")"
check "and the state says who removed the results, and when" "yes" \
    "$(jq -r '.notes[]' "$HISTORY/aaaaaaaa/state.json" | grep -qE "^Results removed by $ME at 20[0-9-]+T[0-9:]+Z\.$" && echo yes || echo no)"
OUT=$(status_one aaaaaaaa 2>&1)
check "which status shows, from history" "yes yes" \
    "$(has "$OUT" "History    $HISTORY/aaaaaaaa") $(has "$OUT" "Note       Results removed by $ME")"
check "and its list says the results went" "yes" "$(status_all | grep -q '^  aaaaaaaa .*results removed$' && echo yes || echo no)"

echo "results already gone"
OUT=$(remove_main aaaaaaaa 2>&1; echo "exit $?")
check "says so, asks nothing, and succeeds" \
    "Run aaaaaaaa's results have already gone. Its record is in $HISTORY/aaaaaaaa.|exit 0" "$(paste -sd '|' <<< "$OUT")"

echo "an expiry file left behind"
printf 'remove_utc: "2026-12-01T00:00:00Z"\n' > "$EXPIRY/aaaaaaaa"
OUT=$( (remove_main --yes aaaaaaaa) 2>&1)
check "is listed" "yes" "$(has "$OUT" "  aaaaaaaa  results already gone, and its leftover expiry file goes")"
check "and removed" "yes no" "$(has "$OUT" "Removed run aaaaaaaa's leftover expiry file.") $(exists "$EXPIRY/aaaaaaaa")"
check "under history's lock, with history kept" "yes yes" "$(exists "$HISTORY/aaaaaaaa/.lock") $(exists "$HISTORY/aaaaaaaa/state.json")"
printf 'remove_utc: "2026-12-01T00:00:00Z"\n' > "$EXPIRY/dddddddd"
OUT=$( (remove_main --yes dddddddd) 2>&1)
check "even with no history" "yes no" "$(has "$OUT" "Removed run dddddddd's leftover expiry file.") $(exists "$EXPIRY/dddddddd")"

echo "unknown uids"
make_run eeeeeeee
end_run eeeeeeee Completed
OUT=$( (remove_main --yes eeeeeeee zzzzzzzz) 2>&1; echo "exit $?")
check "one is refused" "yes" "$(has "$OUT" "There's no run zzzzzzzz, so nothing was removed.")"
check "and nothing is removed" "exit 1 yes yes" "$(tail -n 1 <<< "$OUT") $(exists "$RUNS/eeeeeeee") $(exists "$EXPIRY/eeeeeeee")"
OUT=$( (remove_main --yes zzzzzzzz eeeeeeee yyyyyyyy) 2>&1)
check "several are named together" "yes" "$(has "$OUT" "There are no runs zzzzzzzz yyyyyyyy, so nothing was removed.")"
mkdir -p "$RUNS/ffffffff"
OUT=$( (remove_main --yes ffffffff eeeeeeee) 2>&1)
check "a run directory with no state isn't touched, nor anything else" "yes yes yes" \
    "$(has "$OUT" "$RUNS/ffffffff has no run_state.json") $(exists "$RUNS/ffffffff") $(exists "$RUNS/eeeeeeee")"
rmdir "$RUNS/ffffffff"

echo "the prompt"
OUT=$( (remove_main eeeeeeee) < /dev/null 2>&1)
check "needs a terminal without --yes" "yes yes" "$(has "$OUT" "No terminal to confirm on. Add --yes to remove.") $(exists "$RUNS/eeeeeeee")"
OUT=$(remove_typed n eeeeeeee)
check "lists the run" "yes yes" "$(has "$OUT" "Deleting this run's results. Its record stays in $HISTORY.") $(has "$OUT" "  eeeeeeee  ampliseq@1.1.0     Completed")"
check "asks once" "1" "$(grep -c 'Remove it? \[y/N\]' <<< "$OUT")"
check "and no keeps it" "yes yes yes" "$(has "$OUT" "Nothing removed.") $(exists "$RUNS/eeeeeeee") $(exists "$EXPIRY/eeeeeeee")"
make_run gggggggg
end_run gggggggg Failed
OUT=$(remove_typed y eeeeeeee gggggggg)
check "asks once for several" "1 1" "$(grep -c 'Remove them? \[y/N\]' <<< "$OUT") $(grep -c '\[y/N\]' <<< "$OUT")"
check "and yes removes them all" "no no no no" \
    "$(exists "$RUNS/eeeeeeee") $(exists "$RUNS/gggggggg") $(exists "$EXPIRY/eeeeeeee") $(exists "$EXPIRY/gggggggg")"

echo "a run still going, on this machine"
make_run hhhhhhhh
sleep 600 &
SLEEPER=$!
(cd "$RUNS/hhhhhhhh" && state_set scheduler.pid "$SLEEPER")
OUT=$(remove_main --yes hhhhhhhh 2>&1)
check "is listed as running, to be stopped first" "yes yes" \
    "$(has "$OUT" "  hhhhhhhh  ampliseq@1.1.0     Running") $(has "$OUT" "A run still going is stopped first, and its results go once it has.")"
check "is asked to stop" "yes" \
    "$(has "$OUT" "Asked run hhhhhhhh to stop. Its results go once it has, and $WORK/install/gnoto status hhhhhhhh shows when.")"
check "with the cancel file and the remove marker, and its results kept for now" "yes yes yes" \
    "$(exists "$RUNS/hhhhhhhh/cancel") $(exists "$RUNS/hhhhhhhh/remove") $(exists "$RUNS/hhhhhhhh/results/index.html")"
check "and a note on the run" "yes" "$(has "$(cd "$RUNS/hhhhhhhh" && state_get notes)" "Removal asked by $ME at ")"
check "which gnoto resume refuses" "gnoto remove was asked to remove it" "$(cd "$RUNS/hhhhhhhh" && resume_refusal)"
OUT=$(remove_main --yes hhhhhhhh 2>&1)
check "asking again changes nothing" "yes yes" "$(has "$OUT" "Asked run hhhhhhhh to stop.") $(exists "$RUNS/hhhhhhhh")"
kill $SLEEPER
wait $SLEEPER 2> /dev/null
SLEEPER=""
OUT=$( (followup_main "$RUNS/hhhhhhhh") 2>&1)
check "its followup removes the results once it has stopped" "yes no no" \
    "$(has "$OUT" "Run hhhhhhhh: Cancelled. Its results were removed, as asked.") $(exists "$RUNS/hhhhhhhh") $(exists "$EXPIRY/hhhhhhhh")"
check "after recording it in history, cancelled, with its error summary" "Cancelled yes yes" \
    "$(jq -r .status "$HISTORY/hhhhhhhh/state.json") $(exists "$HISTORY/hhhhhhhh/error.txt") $(exists "$HISTORY/hhhhhhhh/record.yaml")"
check "and who asked" "yes" \
    "$(jq -r '.notes[]' "$HISTORY/hhhhhhhh/state.json" | grep -q "^Results removed once the run ended, as $ME asked at " && echo yes || echo no)"
check "with nothing left aside" "" "$(ls -A "$RUNS")"

# Slurm as the stand-ins would answer, from each job's state in STUB_STATE
declare -A STUB_STATE=()
stub_id() {
    while [[ $# -gt 0 && $1 != -j ]]; do shift; done
    printf '%s' "${2:-}"
}
squeue() {
    local id
    id=$(stub_id "$@")
    [[ -z $id || -z ${STUB_STATE[$id]:-} ]] || echo "${STUB_STATE[$id]}"
}
sacct() { :; }
scancel() { echo "$*" >> "$WORK/cancelled"; }
on_slurm() {
    (cd "$RUNS/$1" && state_update '.scheduler = {kind: "slurm", job_id: $head, followup_id: $followup}' \
        --arg head "$2" --arg followup "$3")
}

echo "a run still going, on Slurm"
make_run iiiiiiii
on_slurm iiiiiiii 11 12
STUB_STATE=([11]=PENDING [12]=PENDING)
OUT=$(remove_main --yes iiiiiiii 2>&1)
check "a queued one is listed as queued" "yes" "$(has "$OUT" "  iiiiiiii  ampliseq@1.1.0     Queued")"
check "is taken out of the queue, as cancel does" "11" "$(cat "$WORK/cancelled" 2> /dev/null)"
check "and gets the cancel file and the marker" "yes yes yes" \
    "$(has "$OUT" "Asked run iiiiiiii to stop.") $(exists "$RUNS/iiiiiiii/cancel") $(exists "$RUNS/iiiiiiii/remove")"
STUB_STATE=([11]=CANCELLED)
(followup_main "$RUNS/iiiiiiii") > /dev/null 2>&1
check "and its followup removes it" "no Cancelled" "$(exists "$RUNS/iiiiiiii") $(jq -r .status "$HISTORY/iiiiiiii/state.json")"
rm -f "$WORK/cancelled"

echo "a run whose followup is still to run"
make_run jjjjjjjj
on_slurm jjjjjjjj 21 22
(cd "$RUNS/jjjjjjjj" && set_run_status Failed && state_set message "The job reached its time limit.")
STUB_STATE=([21]=TIMEOUT [22]=PENDING)
OUT=$(remove_main --yes jjjjjjjj 2>&1)
check "is listed as finishing" "yes" "$(has "$OUT" "  jjjjjjjj  ampliseq@1.1.0     Finishing")"
check "waits for its followup" "yes yes" \
    "$(has "$OUT" "Run jjjjjjjj has ended, and its results go once its followup has finished") $(exists "$RUNS/jjjjjjjj/remove")"
check "without a cancel file, which would change how it ended" "no" "$(exists "$RUNS/jjjjjjjj/cancel")"
check "and cancels no job" "no" "$(exists "$WORK/cancelled")"
(followup_main "$RUNS/jjjjjjjj") > /dev/null 2>&1
check "which removes it, as it ended" "no Failed The job reached its time limit." \
    "$(exists "$RUNS/jjjjjjjj") $(jq -r '"\(.status) \(.message)"' "$HISTORY/jjjjjjjj/state.json")"

echo "a lost run"
make_run kkkkkkkk
on_slurm kkkkkkkk 31 32
STUB_STATE=([31]=FAILED [32]=FAILED)
OUT=$(remove_main --yes kkkkkkkk 2>&1)
check "is listed as lost, and isn't waited for" "yes no" \
    "$(has "$OUT" "  kkkkkkkk  ampliseq@1.1.0     Lost") $(has "$OUT" "stopped first")"
check "is removed at once" "yes no" "$(has "$OUT" "Removed run kkkkkkkk's results.") $(exists "$RUNS/kkkkkkkk")"
check "after recording it in history, as its followup would have" "Lost|Nothing was running for the run when it was removed.|yes yes" \
    "$(jq -r '"\(.status)|\(.message)"' "$HISTORY/kkkkkkkk/state.json")|$(exists "$HISTORY/kkkkkkkk/job.yaml") $(exists "$HISTORY/kkkkkkkk/error.txt")"
check "and leaves the nodes gnoto avoids alone" "no" "$(exists "$WORK/data/excluded-nodes")"
make_run llllllll
on_slurm llllllll 41 42
(cd "$RUNS/llllllll" && set_run_status Failed && state_unset scheduler.job_id)
OUT=$(remove_main --yes llllllll 2>&1)
check "and one Slurm refused, which never had a job" "yes Failed" \
    "$(has "$OUT" "Removed run llllllll's results.") $(jq -r .status "$HISTORY/llllllll/state.json")"
unset -f squeue sacct scancel stub_id

echo "the run lock"
make_run mmmmmmmm
end_run mmmmmmmm Completed
check "is in the run directory while there is one" "$RUNS/mmmmmmmm/.lock" \
    "$( (run_lock mmmmmmmm && readlink /proc/self/fd/9) )"
# A teardown that holds both locks for 2 seconds, after moving the run aside
(
    run_lock mmmmmmmm || exit 1
    exec 7>> "$HISTORY/mmmmmmmm/.lock" && flock 7
    : > "$WORK/held"
    mv "$RUNS/mmmmmmmm" "$WORK/aside"
    sleep 2
) &
HOLDER=$!
while [[ ! -e $WORK/held ]]; do sleep 0.1; done
START=$SECONDS
OUT=$( (run_lock mmmmmmmm && readlink /proc/self/fd/9) )
check "and in history once the run directory goes, after the teardown" "$HISTORY/mmmmmmmm/.lock yes" \
    "$OUT $( (( SECONDS - START >= 1 )) && echo yes || echo no)"
wait $HOLDER
rm -rf "$WORK/aside" "$WORK/held"
make_run nnnnnnnn
sleep 600 &
SLEEPER=$!
(cd "$RUNS/nnnnnnnn" && state_set scheduler.pid "$SLEEPER")
OUT=$( (cancel_main nnnnnnnn) 2>&1)
check "cancel still writes the cancel file under it" "yes yes no" \
    "$(has "$OUT" "Asked run nnnnnnnn to stop.") $(exists "$RUNS/nnnnnnnn/cancel") $(exists "$RUNS/nnnnnnnn/remove")"
kill $SLEEPER
wait $SLEEPER 2> /dev/null
SLEEPER=""
(followup_main "$RUNS/nnnnnnnn") > /dev/null 2>&1
check "and cancel alone keeps the results" "Cancelled yes" \
    "$(jq -r .status "$HISTORY/nnnnnnnn/state.json") $(exists "$RUNS/nnnnnnnn")"

echo "what can't be deleted"
if (( $(id -u) == 0 )); then
    echo "skipped: root deletes anything"
else
    mkdir -p "$RUNS/nnnnnnnn/results/locked"
    : > "$RUNS/nnnnnnnn/results/locked/table.tsv"
    chmod 555 "$RUNS/nnnnnnnn/results/locked"
    OUT=$( (remove_main --yes nnnnnnnn) 2>&1; echo "exit $?")
    check "is reported, where it's left" "yes" \
        "$(has "$OUT" "Couldn't delete everything in run nnnnnnnn's directory. What's left is in $RUNS/.tmp.remove.nnnnnnnn.")"
    check "and fails the command" "yes exit 1" \
        "$(has "$OUT" "1 of the 1 runs couldn't be removed") $(tail -n 1 <<< "$OUT")"
    check "though the run has gone from gnoto's view" "no no" "$(exists "$RUNS/nnnnnnnn") $(exists "$EXPIRY/nnnnnnnn")"
fi

exit $FAILED
