#!/bin/bash
#
# versions.sh - Phase 4's finish test: jobs run from the version cache. Adds
# two test commits to the install's repository, one naming another gnoto
# image, then one moving main on, and checks that:
#
#   - a job at the commit with the other image runs in that image, and its
#     record re-runs exactly at that commit, in that image, after main has moved
#     on, with the same core tables
#   - gnoto upgrade while a job runs leaves the job on its own code, and gnoto
#     prune keeps the running job's version and the current one
#   - a run that failed, its head job cancelled in Slurm partway through
#     Nextflow, resumes at its own commit after an upgrade, with the tasks that
#     finished taken from its cache
#
# With --resume, it checks only the last, at the current version and with no
# upgrade, so it needs no test commits and runs on the cluster too.
#
# Run by:    alice or bob, in the test bed, on an install that testbed.sh
#            install made, a clone of the test bed's repository:
#            bash <install>/test/testbed/checks/versions.sh --small
#            or anyone, anywhere, with --resume
# Requires:  git; Slurm, on in the install's config.yaml; the 16s-v4 fixture,
#            SILVA 138.2, the 16S and pplace references in its database
#            directory, and with --small, db:test/pplace-small, a 2,000-tip cut
#            of the pplace reference for a node that can't hold EPA-NG on the
#            full one; without --resume, write access to the repository,
#            which testbed.sh repo gives gnoto's group
#
# Runs on the host and drives gnoto as a user would. Each ampliseq run takes
# about 8 minutes in the test bed, so the whole check takes about 45. Its files
# go in <data_dir>/test/$USER/versions.

set -u
umask 002

CODE_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
GNOTO=$CODE_DIR/gnoto
DATA_DIR=$($GNOTO exec printenv GNOTO_DATA_DIR)
DB_DIR=$($GNOTO exec printenv GNOTO_DB_DIR)
FIXTURE=$DB_DIR/fixtures/16s-v4/v1
WORK=$DATA_DIR/test/$USER/versions
REPOSITORY=$(git -C "$CODE_DIR" remote get-url origin)
FAILED=0
RESUME_ONLY=false
SMALL=false
for ARG in "$@"; do
    case $ARG in
        --resume) RESUME_ONLY=true ;;
        --small) SMALL=true ;;
        *) echo "Usage: versions.sh [--resume] [--small]" >&2; exit 1 ;;
    esac
done

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# A run's status from its state, wherever the run is
run_status() {
    $GNOTO status "$1" 2> /dev/null | sed -n 's/^  Status     \([^:]*\).*/\1/p'
}

# A value from a run's state, read with the image's jq, since a host may have none
run_state() {
    $GNOTO exec jq -r "$2 // \"\" | tostring" "$DATA_DIR/runs/$1/run_state.json" 2> /dev/null
}

# Waits up to $2 minutes for a run to end, printing its stage as it changes
wait_for() {
    local uid=$1 status stage last=""
    for (( i = 0; i < $2 * 6; i++ )); do
        status=$(run_status "$uid")
        case $status in
            Completed | Failed | Cancelled | "Publish failed" | Lost) printf '%s' "$status"; return ;;
        esac
        stage=$($GNOTO status "$uid" 2> /dev/null | sed -n 's/^  Status     //p')
        [[ $stage == "$last" ]] || echo "      $stage" >&2
        last=$stage
        sleep 10
    done
    printf 'still %s' "$status"
}

# The uid gnoto run, start or resume printed
started() {
    sed -n 's/^\(Started\|Resumed\) \([a-z2-7]\{8\}\),.*/\2/p'
}

current() {
    sed -n 1p "$DATA_DIR/current"
}

# The SHA-256 of a run's core DADA2 tables
core_tables() {
    (cd "$DATA_DIR/runs/$1/results/dada2" 2> /dev/null && sha256sum ASV_table.tsv DADA2_table.tsv ASV_seqs.fasta)
}

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK" || exit 1
printf '%s\t%s\t%s\n' mock1 "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" > v4.tsv
JOB=(--title="16S V4 mock" --samplesheet=v4.tsv --retention="1 Month" --ampliseq.mergepairs_strategy=merge)
if [[ $SMALL == true ]]; then
    JOB+=(--ampliseq.pplace_tree=db:test/pplace-small/bac16s.newick)
    JOB+=(--ampliseq.pplace_aln=db:test/pplace-small/bac16s.alnfna)
fi

A=$(current)
J1=""
J2=""
if [[ $RESUME_ONLY == false ]]; then
    echo "Test commits: another image, then main moves on"
    git clone -q "$REPOSITORY" repo || exit 1
    IMAGE=$(cat repo/IMAGE)
    ALT=${IMAGE%.sif}-alt.sif
    ln -f "$DATA_DIR/images/$IMAGE" "$DATA_DIR/images/$ALT" || exit 1
    (
        cd repo &&
            git checkout -q "$A" &&
            echo "$ALT" > IMAGE &&
            git -c user.name=test -c user.email=test@localhost commit -q -am "Test: another gnoto image" &&
            echo "$IMAGE" > IMAGE &&
            echo "main moved on $(date -u)" > TESTMARK &&
            git add TESTMARK &&
            git -c user.name=test -c user.email=test@localhost commit -q -am "Test: main moves on" &&
            git push -q -f origin HEAD:main
    ) || exit 1
    C=$(git -C repo rev-parse HEAD~1)
    B=$(git -C repo rev-parse HEAD)
    echo "      A $A, the install's; C $C, another image; B $B, main"

    echo "gnoto upgrade to a commit"
    $GNOTO upgrade --yes "$C" > upgrade-c.log 2>&1
    check "it makes C current" "$C" "$(current)"
    check "it lists the commit it adds" "yes" "$(grep -q 'Test: another gnoto image' upgrade-c.log && echo yes)"
    check "it runs C's lint" "yes" "$(grep -q "version: $C, the current one" upgrade-c.log && echo yes)"

    echo "A job at C, in C's image"
    $GNOTO new ampliseq "${JOB[@]}" > c.yaml 2> new.log
    check "new pins the current version" "pipeline: ampliseq@$C" "$(grep '^pipeline:' c.yaml)"
    J1=$($GNOTO run c.yaml 2>&1 | tee run-c.log | started)
    check "run prints the uid" "yes" "$([[ -n $J1 ]] && echo yes)"
    [[ -n $J1 ]] || { sed 's/^/      /' run-c.log; exit 1; }
    check "it ends as Completed" "Completed" "$(wait_for "$J1" 30)"
    check "at C" "$C" "$(run_state "$J1" .commit)"
    check "in C's image" "$ALT" "$(run_state "$J1" .image)"
    check "its head job ran C's code" "$DATA_DIR/versions/$C" "$(run_state "$J1" .code_dir.job)"
    check "and so did its followup" "$DATA_DIR/versions/$C" "$(run_state "$J1" .code_dir.followup)"

    echo "main moves on: gnoto upgrade with no version"
    $GNOTO upgrade --yes > upgrade-b.log 2>&1
    check "with no release, it goes to main" "$B" "$(current)"
    check "new now pins B" "pipeline: ampliseq@$B" "$($GNOTO new ampliseq 2> /dev/null | grep '^pipeline:')"
    check "lint hands C's job file to C" "yes" \
        "$($GNOTO lint c.yaml 2>&1 | grep -q "OK    pipeline: ampliseq@$C, commit $C" && echo yes)"
    check "new ampliseq@<commit> hands over too" "pipeline: ampliseq@$A" \
        "$($GNOTO new "ampliseq@$A" 2> /dev/null | grep '^pipeline:')"
    check "a commit from before the version cache is refused" "yes" \
        "$($GNOTO new ampliseq@554d810e826d07295b6477ba93e977b0e30d4b9d 2>&1 | grep -q "older than gnoto's version cache" && echo yes)"
    check "and a short commit" "yes" \
        "$($GNOTO new "ampliseq@${A:0:7}" 2>&1 | grep -q 'needs the full 40-character commit' && echo yes)"

    echo "C's record re-runs exactly, at C"
    cp "$DATA_DIR/runs/$J1/results/record.yaml" c-record.yaml
    mkdir -p inputs/elsewhere
    ln -s "$FIXTURE/SRR17380142_1.fastq.gz" inputs/elsewhere/R1.fq.gz
    ln -s "$FIXTURE/SRR17380142_2.fastq.gz" inputs/R2.fastq.gz
    check "a record without --inputs is refused" "yes" \
        "$($GNOTO run c-record.yaml 2>&1 | grep -q 'a record re-runs with --inputs' && echo yes)"
    R1=$($GNOTO run c-record.yaml --inputs="$WORK/inputs" 2>&1 | tee rerun.log | started)
    check "run record.yaml prints the uid" "yes" "$([[ -n $R1 ]] && echo yes)"
    [[ -n $R1 ]] || { sed 's/^/      /' rerun.log; exit 1; }
    check "it found the inputs by size" "yes" "$(grep -q 'found under .* by size' rerun.log && echo yes)"
    check "it ends as Completed" "Completed" "$(wait_for "$R1" 30)"
    check "at C, while B is current" "$C $B" "$(run_state "$R1" .commit) $(current)"
    check "in C's image" "$ALT" "$(run_state "$R1" .image)"
    check "from C's code" "$DATA_DIR/versions/$C" "$(run_state "$R1" .code_dir.job)"
    check "with the record's parameters" "$($GNOTO exec yq -o=json -I=0 .ampliseq c-record.yaml)" \
        "$($GNOTO exec yq -o=json -I=0 .ampliseq "$DATA_DIR/runs/$R1/results/record.yaml")"
    check "and its batch, from other paths" "$($GNOTO exec yq '.inputs[0].run' c-record.yaml)" \
        "$($GNOTO exec yq '.inputs[0].run' "$DATA_DIR/runs/$R1/results/record.yaml")"
    check "the core tables are identical" "$(core_tables "$J1")" "$(core_tables "$R1")"
    check "and are there" "3" "$(core_tables "$R1" | wc -l)"

    echo "An upgrade while a job runs"
    J2=$($GNOTO start ampliseq "${JOB[@]}" 2>&1 | tee start-b.log | started)
    check "start prints the uid" "yes" "$([[ -n $J2 ]] && echo yes)"
    [[ -n $J2 ]] || { sed 's/^/      /' start-b.log; exit 1; }
    for (( i = 0; i < 120; i++ )); do
        [[ $(run_status "$J2") == Running ]] && break
        sleep 5
    done
    check "it's running" "Running" "$(run_status "$J2")"
    $GNOTO upgrade --yes "$A" > upgrade-a.log 2>&1
    check "going back is a pointer move" "$A" "$(current)"
    touch -d '2 hours ago' "$DATA_DIR"/versions/*/
    $GNOTO prune --yes > prune.log 2>&1
    check "prune keeps the running job's version" "yes" "$([[ -x $DATA_DIR/versions/$B/gnoto ]] && echo yes)"
    check "and the current one" "yes" "$([[ -x $DATA_DIR/versions/$A/gnoto ]] && echo yes)"
    check "and removes one nothing uses" "no" "$([[ -e $DATA_DIR/versions/$C ]] && echo yes || echo no)"
    check "but keeps its image, which can't be pulled again" "yes" "$([[ -f $DATA_DIR/images/$ALT ]] && echo yes)"
    check "the job ends as Completed" "Completed" "$(wait_for "$J2" 30)"
    check "at B" "$B" "$(run_state "$J2" .commit)"
    check "its head job ran B's code" "$DATA_DIR/versions/$B" "$(run_state "$J2" .code_dir.job)"
    check "and so did its followup, after the upgrade" "$DATA_DIR/versions/$B" "$(run_state "$J2" .code_dir.followup)"
    check "a pruned version is fetched again when named" "pipeline: ampliseq@$C" \
        "$($GNOTO new "ampliseq@$C" 2> /dev/null | grep '^pipeline:')"
fi

echo "A run that fails partway, then resumed"
J3=$($GNOTO start ampliseq "${JOB[@]}" 2>&1 | tee start-a.log | started)
check "start prints the uid" "yes" "$([[ -n $J3 ]] && echo yes)"
[[ -n $J3 ]] || { sed 's/^/      /' start-a.log; exit 1; }
RUN3=$DATA_DIR/runs/$J3
for (( i = 0; i < 180; i++ )); do
    DONE=$(cat "$RUN3"/results/pipeline_info/execution_trace_*.txt 2> /dev/null | grep -c $'\tCOMPLETED\t')
    (( DONE >= 8 )) && break
    sleep 5
done
check "8 of its tasks finish" "yes" "$( (( DONE >= 8 )) && echo yes)"
scancel "$(run_state "$J3" .scheduler.job_id)"
check "cancelled in Slurm, it ends as Failed" "Failed" "$(wait_for "$J3" 10)"
check "it keeps Nextflow's work directory" "yes" "$([[ -d $RUN3/work && -d $RUN3/.nextflow ]] && echo yes)"
check "and the task outputs in it" "yes" \
    "$(find "$RUN3/work" -type f ! -name '.command.*' ! -name .exitcode | grep -q . && echo yes)"
check "and its staged inputs" "yes" "$([[ -d $RUN3/raw-sequences ]] && echo yes)"
check "until cleanup_utc" "yes" "$(grep -q '^cleanup_utc:' "$DATA_DIR/expiry/$J3" 2> /dev/null && echo yes)"
check "gnoto resume lists it" "yes" "$($GNOTO resume | grep -q "^  $J3 " && echo yes)"
if [[ -n $J2 ]]; then
    check "a completed run can't be resumed" "yes" \
        "$($GNOTO resume "$J2" 2>&1 | grep -q "can't be resumed: it completed" && echo yes)"
fi
if [[ $RESUME_ONLY == false ]]; then
    $GNOTO upgrade --yes "$B" > upgrade-b2.log 2>&1
    check "B is current again" "$B" "$(current)"
fi
$GNOTO resume "$J3" > resume.log 2>&1
check "resume restarts it" "yes" "$(grep -q "^Resumed $J3" resume.log && echo yes)"
check "it ends as Completed" "Completed" "$(wait_for "$J3" 30)"
check "at its own commit, A" "$A" "$(run_state "$J3" .commit)"
if [[ $RESUME_ONLY == false ]]; then
    check "from A's code, with B current" "$DATA_DIR/versions/$A $B" "$(run_state "$J3" .code_dir.job) $(current)"
else
    check "from its own code" "$DATA_DIR/versions/$A" "$(run_state "$J3" .code_dir.job)"
fi
check "its first attempt is recorded" "1 Failed" \
    "$($GNOTO exec jq -r '"\(.attempts | length) \(.attempts[0].status)"' "$RUN3/run_state.json" 2> /dev/null)"
check "Nextflow resumed its session" "yes" "$(grep -q '^exec nextflow .* -resume [0-9a-f-]*$' "$RUN3/nextflow_command.sh" && echo yes)"
CACHED=$(grep -c 'Cached process >' "$RUN3/nextflow.out")
check "and took the tasks that finished from the cache" "yes" "$( (( CACHED > 0 && CACHED >= DONE - 2 )) && echo yes)"
echo "      $CACHED tasks cached, of $DONE that finished before"
check "its samplesheet step didn't run again" "yes" \
    "$(grep -q 'The samplesheet step finished in an earlier attempt' "$RUN3/job.out" && echo yes)"
check "the core tables are complete" "3" "$(core_tables "$J3" | wc -l)"
[[ -z $J1 ]] ||
    check "and identical to the first job's" "$(core_tables "$J1")" "$(core_tables "$J3")"
check "a dashboard in results/" "yes" "$([[ -s $RUN3/results/index.html ]] && echo yes)"
check "status shows the attempt" "yes" "$($GNOTO status "$J3" | grep -q '^  Attempt    2, resumed' && echo yes)"

exit $FAILED
