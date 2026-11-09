#!/bin/bash
#
# digests.sh - Phase 5's finish test: a job, and then an exact re-run of its
# record, each pull every image by digest. Runs ampliseq on the 16s-v4 fixture
# with --debug, so its tasks' scripts stay, then removes the images its tasks
# ran in and re-runs the record with --inputs, so the re-run pulls them again.
# After each, every image a task ran in was pulled during that run, by digest,
# and no task names an image by tag, nor an https:// file but one its address
# names by SHA-256, as pipelines/lock.sh allows. Also checks the databases:
# lint --deep, the record's entries, and the re-run's core tables.
#
# Run by:  a developer, in the test bed or on the cluster, as any user:
#          bash <install>/test/testbed/checks/digests.sh [--small]
#          It removes ampliseq's task images, so it mustn't run beside another
#          ampliseq job on the same data directory. Other pipelines' images
#          are left alone.
# Requires:  the install's gnoto, whose IMAGE and lock files name images by
#            digest; the 16s-v4 fixture and the job's databases in its database
#            directory, which gnoto lint --yes fetches; with --small,
#            db:test/pplace-small there too
#
# Takes about an hour on an idle test bed, most of it Apptainer building each
# image twice.

set -u

CODE_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
GNOTO=$CODE_DIR/gnoto
SMALL=false
for ARG in "$@"; do
    case $ARG in
        --small) SMALL=true ;;
        *) echo "Usage: digests.sh [--small]" >&2; exit 1 ;;
    esac
done
DATA_DIR=$($GNOTO exec printenv GNOTO_DATA_DIR)
DB_DIR=$($GNOTO exec printenv GNOTO_DB_DIR)
FIXTURE=$DB_DIR/fixtures/16s-v4/v1
IMAGES=$DATA_DIR/images
WORK=$DATA_DIR/test/$USER/digests
FAILED=0

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

run_status() {
    $GNOTO status "$1" 2> /dev/null | sed -n 's/^  Status     \([^:]*\).*/\1/p'
}

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

# The image files pulled since a marker file was touched
pulled_since() {
    find "$IMAGES" -maxdepth 1 -type f \( -name '*.sif' -o -name '*.img' \) -newer "$1" -printf '%f\n'
}

# Nextflow's name for an image it pulled by digest, <address>@sha256-<digest>.img,
# or for a file for Apptainer it fetched from a path naming its SHA-256,
# <url>-blobs-sha256-<xx>-<digest>-data.img
NEXTFLOW_BY_DIGEST='([a-z0-9.-]+(-[a-z0-9._-]+)+@sha256-[0-9a-f]{64}|[a-z0-9.-]+-blobs-sha256-[0-9a-f]{2}-[0-9a-f]{64}-data)\.img'

# The image files a run's tasks ran in, by name, as their scripts name them
task_images() {
    grep -ho 'apptainer exec [^|;&]*' "$1"/work/*/*/.command.run 2> /dev/null |
        grep -o "$IMAGES/[^ ]*" | sed "s|^$IMAGES/||" | sort -u
}

# Those of a list of image names not named by digest
not_by_digest() {
    grep -vE "^$NEXTFLOW_BY_DIGEST\$" "$1" | head -3
}

# Those of a list of image names not pulled since a marker file was touched
not_pulled_since() {
    comm -23 "$1" <(pulled_since "$2" | sort) | head -3
}

core_tables() {
    (cd "$1/results" && sha256sum dada2/ASV_table.tsv dada2/DADA2_table.tsv dada2/ASV_seqs.fasta 2> /dev/null)
}

mkdir -p "$WORK"
cd "$WORK" || exit 1
printf '%s\t%s\t%s\n' mock1 "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" > v4.tsv
JOB=(ampliseq --title="16S V4 digests" --samplesheet=v4.tsv --retention="1 Month")
if [[ $SMALL == true ]]; then
    JOB+=(--ampliseq.pplace_tree=db:test/pplace-small/bac16s.newick --ampliseq.pplace_aln=db:test/pplace-small/bac16s.alnfna)
fi
$GNOTO new "${JOB[@]}" > job.yaml 2> new.log || { echo "FAIL  gnoto new:"; sed 's/^/      /' new.log; exit 1; }

echo "the gnoto image"
IMAGE=$(cat "$CODE_DIR/IMAGE")
check "IMAGE names it by digest" "yes" "$([[ $IMAGE =~ ^docker://[^@]+@sha256:[0-9a-f]{64}$ ]] && echo yes)"
check "and the launcher pulled it by digest" "yes" "$([[ -f $IMAGES/gnoto-${IMAGE##*@sha256:}.sif ]] && echo yes)"

echo "lint"
$GNOTO lint --deep job.yaml > lint.log 2>&1
check "lint --deep passes" "0" "$?"
check "checking each pinned database by its tree digest" "yes" \
    "$(grep -q 'databases: all .* present, .* as lock.yaml pins them, by tree digest' lint.log && echo yes || tail -3 lint.log)"

echo "a job"
# Without any of ampliseq's task images, named as Nextflow names them, so the
# job pulls each one it runs
grep -oE "container = '[^']+'" "$CODE_DIR/pipelines/ampliseq/containers.config" | cut -d"'" -f2 | sort -u |
    while IFS= read -r ADDRESS; do
        ADDRESS=${ADDRESS#https://}
        ADDRESS=${ADDRESS//\//-}
        rm -f "$IMAGES/${ADDRESS//:/-}.img" "$IMAGES/${ADDRESS//:/-}.img.lock"
    done
touch before-job
sleep 1
UID_=$($GNOTO run --debug job.yaml | sed -n 's/^Started \([a-z2-7]\{8\}\),.*/\1/p')
[[ -n $UID_ ]] || { echo "FAIL  gnoto run printed no uid"; exit 1; }
RUN=$DATA_DIR/runs/$UID_
STATUS=$(wait_for "$UID_" 120)
check "it ends as Completed" "Completed" "$STATUS"
[[ $STATUS == Completed ]] || { echo "Stopping: the job didn't complete. Its run directory is $RUN."; exit 1; }
task_images "$RUN" > first-images
check "its tasks ran in images" "yes" "$([[ -s first-images ]] && echo yes)"
check "every one named by digest" "" "$(not_by_digest first-images)"
check "and pulled during the job" "" "$(not_pulled_since first-images before-job)"
check "every https:// file it fetched is one named by its SHA-256" "" \
    "$(grep -ho 'Pulling Apptainer image https://[^ ]*' "$RUN/nextflow.log" 2> /dev/null | cut -d' ' -f4 |
        grep -vE '^https://[a-z0-9.-]+/.*/blobs/sha256/[0-9a-f]{2}/[0-9a-f]{64}/data$' | head -2)"
check "the record holds the databases it read" "yes" \
    "$($GNOTO exec yq -e '.databases | length > 0' "$RUN/results/record.yaml" > /dev/null 2>&1 && echo yes)"
LOCKED_16S=$($GNOTO exec yq '.databases."db:16s/v1".tree_sha256' "$CODE_DIR/pipelines/ampliseq/lock.yaml")
check "a pinned one by its lock entry" "yes $LOCKED_16S" \
    "$([[ $LOCKED_16S =~ ^[0-9a-f]{64}$ ]] && echo yes) $($GNOTO exec yq '.databases."db:16s/v1".tree_sha256' "$RUN/results/record.yaml")"
FIRST_TABLES=$(core_tables "$RUN")

echo "an exact re-run, without the images the job's tasks ran in"
while IFS= read -r FILE; do
    rm -f "$IMAGES/$FILE" "$IMAGES/$FILE.lock"
done < first-images
touch before-rerun
sleep 1
mkdir -p inputs
ln -sf "$FIXTURE/SRR17380142_1.fastq.gz" inputs/a_1.fq.gz
ln -sf "$FIXTURE/SRR17380142_2.fastq.gz" inputs/a_2.fq.gz
cp "$RUN/results/record.yaml" record.yaml
$GNOTO lint --deep --inputs=inputs record.yaml > relint.log 2>&1
check "lint --deep passes on the record" "0" "$?"
RERUN_UID=$($GNOTO run --debug --inputs=inputs record.yaml | sed -n 's/^Started \([a-z2-7]\{8\}\),.*/\1/p')
[[ -n $RERUN_UID ]] || { echo "FAIL  gnoto run record.yaml printed no uid"; exit 1; }
RERUN=$DATA_DIR/runs/$RERUN_UID
check "it ends as Completed" "Completed" "$(wait_for "$RERUN_UID" 120)"
# An exact re-run skips what the record measured, such as the 16S region, so
# it may read fewer databases and images than the job did
PINNED=$($GNOTO exec yq '.databases | to_entries | .[] | select(.value.tree_sha256) | .key' "$RERUN/results/record.yaml" |
    sort | paste -sd ' ')
check "its head job checked each pinned database it read by its tree digest" "yes $PINNED" \
    "$([[ -n $PINNED ]] && echo yes) $(sed -n 's/.*\(db:[^ ]*\) matches its tree digest\.$/\1/p' "$RERUN/job.out" | sort | paste -sd ' ')"
task_images "$RERUN" > rerun-images
check "its tasks ran in images" "yes" "$([[ -s rerun-images ]] && echo yes)"
check "every one named by digest" "" "$(not_by_digest rerun-images)"
check "and pulled again during the re-run" "" "$(not_pulled_since rerun-images before-rerun)"
check "each one the job ran in" "" "$(comm -13 first-images rerun-images | head -3)"
check "its core tables match the first run's" "$FIRST_TABLES" "$(core_tables "$RERUN")"

exit $FAILED
