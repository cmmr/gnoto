#!/bin/bash
#
# progress-test.sh - Runs present/progress.sh against real Nextflow runs: one
# with retried, ignored and failed tasks, one cancelled through the cancel file,
# and, with Slurm on, one whose tasks run on Slurm, cancelled the same way.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec bash <install>/test/present/progress-test.sh
# Requires:  nextflow, from the image; with slurm.enabled, Slurm and
#            Apptainer, as in the test bed
# Env:       KEEP, set to keep the runs in <data_dir>/test/<user>/progress. The
#            launcher passes no environment, so set it inside:
#            gnoto exec env KEEP=1 bash ...
#
# A stand-in for the job runs Nextflow in the background and, like lib/job.sh,
# passes a SIGTERM on to it. Takes about 3 minutes, most of it the Slurm part.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1

WORK=$DATA_DIR/test/$(id -un)/progress
FAILED=0

rm -rf "$WORK"
mkdir -p "$WORK"
[[ -n ${KEEP:-} ]] || trap 'rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# A run directory with a state as the job keeps it: new_run <uid> <kind>
new_run() {
    mkdir -p "$WORK/$1"
    cd "$WORK/$1" || exit 1
    state_init "$1"
    state_update '. + $add' --argjson add "$(jq -n --arg kind "$2" \
        --arg started "$(date -u -d '-1 hour -2 minutes' '+%Y-%m-%dT%H:%M:%SZ')" '{
            pipeline: "ampliseq", version: "ampliseq@1.2.0", title: "Progress <check>",
            status: "Running", stage: "Running the analysis.", started_utc: $started,
            scheduler: {kind: $kind},
            steps: [{name: "samplesheet", log: "samplesheet.out", state: "done"},
                    {name: "tasks", log: "nextflow.out", state: "active"},
                    {name: "composition", log: "composition.out", state: "waiting"},
                    {name: "dashboard", log: "present.out", state: "waiting"}]}')" || exit 1
    printf 'Staged 3 samples from %s/inputs.\n' "$PWD" > samplesheet.out
}

# A field of results/progress.json
field() {
    jq -r ".$1" results/progress.json
}

# The row a process has, as "<label> <percent>% <count>", from the page's state
row_of() {
    field rows | grep -o "title=\"$1\".*" | head -n 1 |
        sed -E 's/^title="([^"]*)".*>([0-9]+)%<\/span>.*sm:block">([^<]*)<.*/\1 \2% \3/'
}

# Waits up to $1 seconds for a command to succeed
wait_for() {
    local seconds=$1 i
    shift
    for (( i = 0; i < seconds; i++ )); do
        "$@" && return 0
        sleep 1
    done
    return 1
}

# True once a process has ended, which a zombie counts as
gone() {
    local stat
    stat=$(ps -o stat= -p "$1" 2> /dev/null) || return 0
    [[ -z $stat || $stat == Z* ]]
}

# Each class on the page and in its state that has no rule in gnoto.css, but
# those its own style block defines
missing_classes() {
    local css token selector
    css=$(< results/assets/gnoto.css)
    {
        awk '/<script/ { skip = 1 } !skip { print } /<\/script>/ { skip = 0 }' results/index.html
        jq -r '.status_pill, .cluster, .timers, .rows, .failure' results/progress.json
    } | grep -oE 'class="[^"]*"' | sed -E 's/^class="//; s/"$//' | tr ' ' '\n' | grep -v '^$' |
        LC_ALL=C sort -u | while IFS= read -r token; do
            [[ " light stripe dial tasks " == *" $token "* ]] && continue
            selector=$(printf '%s' "$token" | sed -E 's/([^A-Za-z0-9_-])/\\\1/g')
            [[ $css == *".$selector"[^A-Za-z0-9_-]* ]] || printf '%s\n' "$token"
        done
}

sleeps_in_flight() {
    [[ $(field rows 2> /dev/null) == *"0 of 3"* ]]
}

# This run's tasks still sleeping, by their working directory
leftover_sleeps() {
    local pid
    for pid in $(pgrep -u "$(id -un)" -x sleep); do
        [[ $(readlink "/proc/$pid/cwd" 2> /dev/null) == "$PWD"/work/* ]] && echo "$pid"
    done
    return 0
}

# True once the page counts three tasks running or queued on Slurm
three_on_slurm() {
    (( $(field cluster 2> /dev/null | grep -oE '>[0-9]+</span>' | grep -oE '[0-9]+' |
        awk '{ t += $1 } END { print t + 0 }') == 3 ))
}

no_slurm_tasks() {
    ! squeue -h -u "$(id -un)" -o %Z | grep -q "^$PWD/"
}

# The stand-in for the job: runs Nextflow and passes SIGTERM on, as lib/job.sh
# does. Its pid is what the watcher watches. start_job <log> <nextflow args>...
start_job() {
    local log=$1
    shift
    bash -c 'trap "kill -TERM \$NF 2> /dev/null" TERM
        nextflow -log nextflow.log run "$@" -ansi-log false > "'"$log"'" 2>&1 &
        NF=$!
        wait $NF
        wait $NF' job "$@" &
    JOB=$!
}

echo "A run with retried, ignored and failed tasks"
new_run failrun2 local
nextflow -log nextflow.log run "$CODE/test/present/tasks.nf" -ansi-log false > nextflow.out 2>&1
check "the workflow fails, as it's meant to" "1" "$?"
state_update '.steps[1].state = "failed" | .status = "Failed"
    | .message = "The Nextflow pipeline failed. Its output is in \($dir)/nextflow.out."
    | .clocks = {elapsed_seconds: 3725, cpu_seconds: 7300}' --arg dir "$PWD"
bash "$CODE/present/progress.sh"
check "progress.sh exits 0" "0" "$?"
check "the page is ended" "ended" "$(field state)"
check "quick tasks all done" "QUICK 100% 3 of 3" "$(row_of QUICK)"
check "a retried task counts once" "FLAKY 100% 2 of 2" "$(row_of FLAKY)"
check "an ignored task has ended" "IGNORED 100% 1 of 1" "$(row_of IGNORED)"
check "a failed task is a failed row" "FAILS 100% 0 of 1, 1 failed" "$(row_of FAILS)"
check "the failed row is red" "1" "$(field rows | grep -c 'bg-error-red rounded-full" style="width:100%"')"
check "the dial counts steps and tasks, a failed one as ended" "8 of 10 tasks" "$(field tasks)"
check "the steps are listed" "4" "$(field rows | grep -c 'font-semibold truncate')"
check "an ended run keeps its clocks" "1" "$(field timers | grep -c '1h 02m.*2h 01m')"
check "the failure panel has Nextflow's error" "1" "$(field failure | grep -c "ERROR ~ Error executing process &gt; &#39;FAILS")"
check "the failure panel has the task's stderr, path redacted" "1" "$(field failure | grep -q 'Reads in ./raw-sequences ran out' && echo 1)"
check "nothing on the page names the run directory" "0" "$(cat results/progress.json results/index.html | grep -c "$PWD")"
check "nothing names the data directory" "0" "$(cat results/progress.json results/index.html | grep -c "$DATA_DIR")"
check "the title is escaped" "2" "$(grep -c 'Progress &lt;check&gt;' results/index.html)"
check "the page carries its state" "1" "$(grep -c 'var INITIAL = {' results/index.html)"
check "and nothing in it closes the script" "0" "$(sed -n '/var INITIAL/p' results/index.html | grep -c '</')"
check "the pill says Failed" "1" "$(field status_pill | grep -c 'text-error-red.*>Failed</span>')"
check "the page links its stylesheet" "1" "$(grep -c '<link rel="stylesheet" href="assets/gnoto.css">' results/index.html)"
check "and it's there" "yes" "$([[ -s results/assets/gnoto.css ]] && echo yes)"
check "every class on a failed page has a style" "" "$(missing_classes)"

# Without Nextflow's log, the console still names what was submitted
mv nextflow.log nextflow.log.bak
bash "$CODE/present/progress.sh"
check "from the console alone, what was submitted" "QUICK 0% 0 of 3" "$(row_of QUICK)"
mv nextflow.log.bak nextflow.log

# The dashboard is never written over
state_set stages.present "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > /dev/null
printf 'dashboard\n' > results/index.html
bash "$CODE/present/progress.sh"
check "a presented run keeps its dashboard" "dashboard" "$(< results/index.html)"

echo
echo "A local run, cancelled through the cancel file"
new_run cancelrn local
start_job nextflow.out "$CODE/test/testbed/nextflow/sleep.nf" --seconds 300
bash "$CODE/present/progress.sh" --watch "$JOB" --interval 2 > progress.out 2>&1 &
WATCHER=$!
if wait_for 120 sleeps_in_flight; then
    check "the page is live" "live" "$(field state)"
    check "three sleeps in flight" "SLEEP 0% 0 of 3" "$(row_of SLEEP)"
    check "three running" "1" "$(field cluster | grep -c '>3</span>.*>Running<')"
    check "the clock runs from the job's start" "1" "$(field timers | grep -c '1h 0[23]m')"
    check "the pill pulses" "1" "$(field status_pill | grep -c animate-ping)"
    check "every class on a live page has a style" "" "$(missing_classes)"
    START=$SECONDS
    touch cancel
    wait_for 60 gone "$JOB"
    check "the job stops when the cancel file appears" "yes" "$(gone "$JOB" && echo yes)"
    echo "      took $((SECONDS - START)) s"
    wait "$JOB" 2> /dev/null
    check "no sleep is left running" "" "$(leftover_sleeps)"
    wait_for 10 gone "$WATCHER"
    check "the watcher ends with the job" "yes" "$(gone "$WATCHER" && echo yes)"
    check "the job was signalled once" "1" "$(grep -c 'Found the cancel file' progress.out)"
    check "the stage says it's cancelling" "Cancelling the run." "$(state_get stage)"
    state_set status Cancelled > /dev/null
    bash "$CODE/present/progress.sh"
    check "a cancelled run's page is ended" "ended" "$(field state)"
    check "the pill says Cancelled" "1" "$(field status_pill | grep -c 'text-warning-amber.*>Cancelled</span>')"
    check "a cancelled run shows nothing in flight" "0 1" "$(field rows | grep -c stripe) $(field rows | grep -c 'bg-outline rounded-full" style')"
    check "every class on a cancelled page has a style" "" "$(missing_classes)"
else
    echo "FAIL  the sleeps weren't in flight within 2 minutes"
    tail -n 5 nextflow.out progress.out | sed 's/^/      /'
    FAILED=1
fi
kill "$JOB" "$WATCHER" 2> /dev/null
wait 2> /dev/null

# The watcher ends when it's sent SIGTERM, as the job stops it before Present
new_run sigterms local
sleep 300 &
SLEEPER=$!
bash "$CODE/present/progress.sh" --watch "$SLEEPER" > /dev/null 2>&1 &
WATCHER=$!
sleep 3
check "the watcher is watching" "yes" "$(gone "$WATCHER" || echo yes)"
START=$SECONDS
kill -TERM "$WATCHER"
wait "$WATCHER"
check "a SIGTERM ends the watcher at once" "0 0" "$? $(( (SECONDS - START) / 2 ))"
check "and leaves what it watched alone" "yes" "$(gone "$SLEEPER" || echo yes)"
kill "$SLEEPER"
wait 2> /dev/null

echo
if [[ ${SLURM_ENABLED:-false} == true ]] && command -v squeue > /dev/null; then
    echo "A Slurm run, cancelled through the cancel file"
    new_run slurmrun slurm
    start_job nextflow.out "$CODE/test/testbed/nextflow/sleep.nf" --seconds 300 \
        -c "$CODE/test/testbed/nextflow/slurm.config"
    bash "$CODE/present/progress.sh" --watch "$JOB" --interval 2 > progress.out 2>&1 &
    WATCHER=$!
    if wait_for 240 three_on_slurm; then
        check "three tasks running or queued on Slurm" "Running Queued" \
            "$(field cluster | grep -oE 'Running|Queued' | tr '\n' ' ' | sed 's/ $//')"
        check "the page is live" "live" "$(field state)"
        touch cancel
        wait_for 120 gone "$JOB"
        check "the job stops when the cancel file appears" "yes" "$(gone "$JOB" && echo yes)"
        wait "$JOB" 2> /dev/null
        wait_for 90 no_slurm_tasks
        check "no task is left on Slurm" "0" "$(squeue -h -u "$(id -un)" -o %Z | grep -c "^$PWD/")"
        wait_for 10 gone "$WATCHER"
        check "the watcher ends with the job" "yes" "$(gone "$WATCHER" && echo yes)"
    else
        echo "FAIL  the tasks weren't on Slurm within 4 minutes"
        tail -n 5 nextflow.out progress.out | sed 's/^/      /'
        FAILED=1
    fi
    kill "$JOB" "$WATCHER" 2> /dev/null
    wait 2> /dev/null
    squeue -h -u "$(id -un)" -o '%i %Z' | awk -v here="$PWD/" 'index($2, here) == 1 { print $1 }' |
        xargs -r scancel
else
    echo "skip  Slurm isn't on here"
fi

echo
if (( FAILED )); then
    echo "Some checks failed."
    exit 1
fi
echo "All checks passed."
