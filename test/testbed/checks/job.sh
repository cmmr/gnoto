#!/bin/bash
#
# job.sh - Runs an ampliseq job on the 16s-v4 fixture from start to finish
# through gnoto start, then checks what it leaves: the dashboard, the record,
# the zip, history, expiry and cleanup. With --cancel, it runs the job file
# gnoto new printed through gnoto run instead, cancels it, and checks that it
# stops and leaves no task running.
#
# Run by:  a developer, as any user, in the test bed or on the cluster:
#          bash <install>/test/testbed/checks/job.sh [--cancel] [--small]
# Requires:  the install's gnoto, and the 16s-v4 fixture in its database
#            directory, which test/testbed/checks/ampliseq-16s-v4.sh fetches.
#            Through gnoto lint --yes, it fetches the other databases the job
#            needs: SILVA 138.2, and the pplace and 16S references
#
# Runs on the host and drives gnoto as a user would. Whether jobs go to Slurm or
# run on this machine is the install's config.yaml. --small uses
# db:test/pplace-small, a 2,000-tip cut of the placement reference, for a node
# that can't hold EPA-NG on the full one. Writes its job files in
# <data_dir>/test/$USER/job. Takes about 15 minutes on an idle queue.

set -u

CODE_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
GNOTO=$CODE_DIR/gnoto
CANCEL=false
SMALL=false
for ARG in "$@"; do
    case $ARG in
        --cancel) CANCEL=true ;;
        --small) SMALL=true ;;
        *) echo "Usage: job.sh [--cancel] [--small]" >&2; exit 1 ;;
    esac
done
DATA_DIR=$($GNOTO exec printenv GNOTO_DATA_DIR)
DB_DIR=$($GNOTO exec printenv GNOTO_DB_DIR)
FIXTURE=$DB_DIR/fixtures/16s-v4/v1
WORK=$DATA_DIR/test/$USER/job
FAILED=0

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

mkdir -p "$WORK"
cd "$WORK" || exit 1
printf '%s\t%s\t%s\n' mock1 "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" > v4.tsv
JOB=(ampliseq --title="16S V4 mock" --samplesheet=v4.tsv --retention="1 Month" --ampliseq.mergepairs_strategy=merge)
if [[ $SMALL == true ]]; then
    JOB+=(--ampliseq.pplace_tree=db:test/pplace-small/bac16s.newick)
    JOB+=(--ampliseq.pplace_aln=db:test/pplace-small/bac16s.alnfna)
fi
if ! $GNOTO new "${JOB[@]}" > job.yaml 2> new.log; then
    echo "FAIL  gnoto new:"
    sed 's/^/      /' new.log
    exit 1
fi

# Missing databases are fetched as jobs, which the job then waits for
if ! $GNOTO lint --yes job.yaml > lint.log 2>&1 && ! grep -q '^Fetching db:' lint.log; then
    echo "FAIL  gnoto lint job.yaml:"
    sed 's/^/      /' lint.log
    exit 1
fi
grep '^Fetching db:' lint.log | sed 's/^/      /'

if [[ $CANCEL == true ]]; then
    echo "gnoto cancel on a running job"
    UID_=$($GNOTO run job.yaml | sed -n 's/^Started \([a-z2-7]\{8\}\),.*/\1/p')
    check "run prints the uid" "yes" "$([[ -n $UID_ ]] && echo yes)"
    [[ -n $UID_ ]] || exit 1
    for (( i = 0; i < 360; i++ )); do
        [[ $(run_status "$UID_") == Running ]] && break
        sleep 5
    done
    sleep 30
    $GNOTO cancel "$UID_" > /dev/null
    check "it ends as Cancelled" "Cancelled" "$(wait_for "$UID_" 10)"
    if command -v squeue > /dev/null && [[ -d $DATA_DIR/runs/$UID_ ]]; then
        check "no task of it is left in Slurm" "0" \
            "$(squeue -h -o %Z 2> /dev/null | grep -c "^$DATA_DIR/runs/$UID_/")"
    fi
    check "history keeps an error summary" "yes" "$([[ -s $DATA_DIR/history/$UID_/error.txt ]] && echo yes)"
    check "its task outputs went at once" "no" \
        "$(find "$DATA_DIR/runs/$UID_/work" -type f ! -name '.command.*' ! -name .exitcode 2> /dev/null | grep -q . && echo yes || echo no)"
    exit $FAILED
fi

echo "gnoto start, to the end"
UID_=$($GNOTO start "${JOB[@]}" | sed -n 's/^Started \([a-z2-7]\{8\}\),.*/\1/p')
check "start prints the uid" "yes" "$([[ -n $UID_ ]] && echo yes)"
[[ -n $UID_ ]] || exit 1
RUN=$DATA_DIR/runs/$UID_
check "it ends as Completed" "Completed" "$(wait_for "$UID_" 120)"

check "a dashboard in results/" "yes" "$([[ -s $RUN/results/index.html ]] && echo yes)"
# MultiQC's report and Nextflow's execution report and timeline, which gnoto
# doesn't write, load a favicon and an emoji image from the network
check "gnoto's pages load nothing from the network" "" \
    "$(grep -rhoE '<(script|link|img)[^>]*(src|href)="(https?:)?//[^"]*' "$RUN/results" \
        --include='*.html' --exclude-dir=multiqc --exclude-dir=pipeline_info 2> /dev/null | sort -u | head -3)"
check "the Overview's data" "yes" "$([[ -s $RUN/composition_data.json || -n $(ls "$RUN"/results/*.json 2> /dev/null) ]] && echo yes)"
check "the feature table" "yes" "$(ls "$RUN"/results/feature_table/*.biom > /dev/null 2>&1 && echo yes)"
check "a zip in the run directory" "1" "$(ls "$RUN"/*.zip 2> /dev/null | wc -l)"
check "the published job file names no path" "v4.tsv" "$(sed -n 's/^samplesheet: *"*\([^"]*\)"*$/\1/p' "$RUN/results/job.yaml")"
check "the record holds each input's checksum" "$(sha256sum < "$FIXTURE/SRR17380142_1.fastq.gz" | cut -d' ' -f1)" \
    "$(sed -n 's/^ *sha256_1: *"*\([0-9a-f]*\)"*$/\1/p' "$RUN/results/record.yaml" | head -1)"
check "and its batch" "yes" "$(grep -q '^ *run: *"*run_' "$RUN/results/record.yaml" && echo yes)"
check "and the measured primer" "yes" "$(grep -q '^  primer_fwd:' "$RUN/results/record.yaml" && echo yes)"
check "and no site path" "no" "$(grep -qE "$DATA_DIR|$DB_DIR|$CODE_DIR" "$RUN/results/record.yaml" && echo yes || echo no)"
check "the work directory went" "no" "$([[ -e $RUN/work ]] && echo yes || echo no)"
check "the staged inputs went" "no" "$([[ -e $RUN/raw-sequences ]] && echo yes || echo no)"
check "history has the job, record and state" "job.yaml record.yaml state.json" \
    "$(cd "$DATA_DIR/history/$UID_" 2> /dev/null && ls job.yaml record.yaml state.json | paste -sd ' ')"
check "and the job start made, with the samplesheet in full" "$WORK/v4.tsv" \
    "$(sed -n 's/^samplesheet: *"*\([^"]*\)"*$/\1/p' "$DATA_DIR/history/$UID_/job.yaml" 2> /dev/null)"
check "expiry about a month away" "yes" "$(grep -q "remove_utc: \"$(date -u -d '+1 month' +%Y-%m)" \
    "$DATA_DIR/expiry/$UID_" 2> /dev/null && echo yes)"
check "everything left is group-writable" "" "$(find "$RUN" ! -perm -g+w 2> /dev/null | head -3)"
check "status lists it as finished" "yes" "$($GNOTO status | grep -q "^  $UID_ .*Completed" && echo yes)"

exit $FAILED
