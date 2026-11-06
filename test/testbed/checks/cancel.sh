#!/bin/bash
#
# cancel.sh - Checks that a Nextflow run cancels its Slurm tasks through the
# scancel stand-in when its head job is cancelled, when the head job reaches its
# time limit, and when an interactive run gets SIGTERM.
#
# Run by:  a developer, as any user, in the test bed or on a cluster:
#          docker exec gnoto-testbed runuser -l alice -c 'bash /opt/gnoto/test/testbed/checks/cancel.sh'
# Env:     TEST_SBATCH_ARGS, optional sbatch options for the head jobs, such as
#          "-p short -A lab", and TEST_NF_CONFIG, an optional Nextflow config
#          that sets the same for the tasks. Neither is needed where Slurm's
#          defaults do.
#
# The host side, like launcher.sh, and it watches jobs with the host's squeue.
# Takes about 6 minutes on an idle queue. Cancels only its own jobs: the head
# jobs, named gnoto-cancel-test, and their nf-SLEEP tasks.

set -u
umask 002

CODE_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
GNOTO=$CODE_DIR/gnoto
NEXTFLOW_DIR=$CODE_DIR/test/testbed/nextflow
BASE=$($GNOTO exec printenv GNOTO_DATA_DIR)/test/$USER/cancel
SBATCH_ARGS=${TEST_SBATCH_ARGS:-}
NF_CONFIGS="-c $NEXTFLOW_DIR/slurm.config${TEST_NF_CONFIG:+ -c $TEST_NF_CONFIG}"
FAILED=0

for COMMAND in squeue scancel; do
    if ! command -v "$COMMAND" > /dev/null; then
        echo "FAIL  $COMMAND isn't on PATH here, and this check needs it"
        exit 1
    fi
done
if [[ -n ${TEST_NF_CONFIG:-} && ! -r $TEST_NF_CONFIG ]]; then
    echo "FAIL  TEST_NF_CONFIG names $TEST_NF_CONFIG, which can't be read"
    exit 1
fi

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Counts this check's tasks in the queue, or with $1, those in that state
tasks_in() {
    squeue -h -u "$USER" ${1:+-t "$1"} -o %j | grep -c '^nf-SLEEP'
}

# True while the head job is queued or running, or for an interactive run
# (pid:<launcher>), while the launcher is
still_running() {
    if [[ $1 == pid:* ]]; then
        kill -0 "${1#pid:}" 2> /dev/null
    else
        squeue -h -j "$1" 2> /dev/null | grep -q .
    fi
}

# Waits for the three tasks to be submitted, then up to a minute more for them
# to run: running tasks are the better test, but a busy queue may hold them, and
# cancelling takes the same path either way. Fails if Nextflow ($1, as for
# still_running) ends first, showing the end of its log ($2).
wait_for_tasks() {
    # Long, for a head job waiting in a busy queue. A failed run ends it at once.
    for (( i = 0; i < 1800; i++ )); do
        if [[ $(tasks_in) -ge 3 ]]; then
            for (( j = 0; j < 30; j++ )); do
                [[ $(tasks_in RUNNING) -ge 3 || $(tasks_in) -lt 3 ]] && break
                sleep 2
            done
            echo "      $(tasks_in RUNNING) of 3 tasks running"
            return 0
        fi
        if ! still_running "$1"; then
            echo "FAIL  Nextflow ended before submitting its tasks. The end of $2:"
            tail -5 "$2" 2> /dev/null | cat -v | sed 's/^/      /'
            FAILED=1
            return 1
        fi
        sleep 2
    done
    echo "FAIL  the tasks weren't submitted within an hour"
    FAILED=1
    return 1
}

# Waits up to $1 seconds for every task to leave the queue
wait_for_no_tasks() {
    for (( i = 0; i < $1; i++ )); do
        [[ $(tasks_in) -eq 0 ]] && return 0
        sleep 1
    done
}

submit_head() {
    local dir=$1
    shift
    rm -rf "$dir"
    mkdir -p "$dir"
    cd "$dir"
    $GNOTO exec sbatch --parsable --no-requeue --job-name=gnoto-cancel-test --mem=4G \
        --output="$dir/head.log" $SBATCH_ARGS "$@" \
        --wrap "exec $GNOTO exec nextflow run $NEXTFLOW_DIR/sleep.nf -ansi-log false $NF_CONFIGS"
}

cancel_own_jobs() {
    squeue -h -u "$USER" -o '%i %j' | awk '$2 ~ /^(nf-SLEEP|gnoto-cancel-test)/ { print $1 }' |
        xargs -r scancel
}

cancel_own_jobs

echo "scancel on the head job"
HEAD=$(submit_head "$BASE/scancel" --time=30 --signal=B:TERM@300)
if wait_for_tasks "$HEAD" "$BASE/scancel/head.log"; then
    START=$SECONDS
    scancel "$HEAD"
    wait_for_no_tasks 90
    check "no task left after scancel on the head job" 0 "$(tasks_in)"
    echo "      took $(( SECONDS - START )) s"
    grep -h -E 'Killing|Session aborted' "$BASE/scancel/.nextflow.log" | head -3 | cut -c1-160
fi
cancel_own_jobs

echo "head job reaching its time limit"
# The warning comes 2 minutes after the head job starts, once its tasks are in
HEAD=$(submit_head "$BASE/timeout" --time=4 --signal=B:TERM@120)
if wait_for_tasks "$HEAD" "$BASE/timeout/head.log"; then
    while still_running "$HEAD"; do sleep 2; done
    wait_for_no_tasks 90
    check "no task left after the head job's time limit" 0 "$(tasks_in)"
    grep -h -E 'Killing|Session aborted' "$BASE/timeout/.nextflow.log" | head -3 | cut -c1-160
fi
cancel_own_jobs

echo "SIGTERM to an interactive run"
rm -rf "$BASE/interactive"
mkdir -p "$BASE/interactive"
cd "$BASE/interactive"
$GNOTO exec nextflow run "$NEXTFLOW_DIR/sleep.nf" -ansi-log false $NF_CONFIGS > run.log 2>&1 &
LAUNCHER=$!
if wait_for_tasks "pid:$LAUNCHER" "$BASE/interactive/run.log"; then
    START=$SECONDS
    kill -TERM "$LAUNCHER"
    wait "$LAUNCHER"
    wait_for_no_tasks 90
    check "no task left after SIGTERM to the launcher" 0 "$(tasks_in)"
    echo "      took $(( SECONDS - START )) s"
fi
kill -TERM "$LAUNCHER" 2> /dev/null
wait "$LAUNCHER" 2> /dev/null

cancel_own_jobs
exit $FAILED
