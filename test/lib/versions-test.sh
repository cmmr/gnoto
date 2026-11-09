#!/bin/bash
#
# versions-test.sh - Tests the version cache's pieces that need no scheduler,
# in the real image: repository URLs, resolving a version, fetching a commit
# with its COMPAT floor, which main or a release reaches, the current version,
# handing a command over, gnoto upgrade and gnoto prune; and what phase 4 added
# to jobs: finding a record's inputs, its parameters as recorded, checking
# inputs against their checksums, Nextflow's session, the cleanup that keeps a
# failed run's cache, which runs can be resumed, and the install directory in
# a Slurm job's command.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/lib/versions-test.sh
# Requires:  the gnoto image
#
# Builds its own git repository, as file://, with a commit from before the
# version cache, an annotated release, a lightweight one, main, and a branch
# no release reaches, whose COMPAT is higher.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "$GNOTO_DATA_DIR/test-versions.XXXXXX")
FAILED=0
trap 'chmod -R u+w "$WORK" 2> /dev/null; rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

mkdir -p "$WORK/install" "$WORK/data" "$WORK/helper"
printf 'core:\n  data_dir: "%s"\n  db_dir: "%s"\n' "$WORK/data" "$WORK/data/db" > "$WORK/install/config.yaml"
export GNOTO_INSTALL_DIR=$WORK/install
source "$CODE/lib/env.sh" || exit 1
source "$CODE/lib/args.sh"
source "$CODE/lib/lint.sh"
source "$CODE/lib/jobfile.sh"
source "$CODE/lib/runs.sh"
source "$CODE/lib/start.sh"
source "$CODE/lib/job.sh"
source "$CODE/lib/followup.sh"

# The test repository
SRC=$WORK/src
REPO=file://$SRC
git init -q -b main "$SRC"
src_commit() {
    git -C "$SRC" add -A && git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m "$1" &&
        git -C "$SRC" rev-parse HEAD
}
echo old > "$SRC/README"
OLD=$(src_commit "before the version cache")
echo 1 > "$SRC/COMPAT"
echo gnoto-test.sif > "$SRC/IMAGE"
mkdir -p "$SRC/lib/sub"
printf '#!/bin/sh\necho launcher\n' > "$SRC/gnoto"
chmod +x "$SRC/gnoto"
echo x > "$SRC/lib/sub/file"
V12=$(src_commit "release 1.2.0")
git -C "$SRC" -c user.name=t -c user.email=t@t tag -a v1.2.0 -m "1.2.0"
echo more > "$SRC/lib/more"
V13=$(src_commit "release 1.3.0")
git -C "$SRC" tag v1.3.0
echo main > "$SRC/lib/main-only"
MAIN=$(src_commit "main moves on")
git -C "$SRC" checkout -q -b side "$V13"
echo 2 > "$SRC/COMPAT"
SIDE=$(src_commit "a side branch with COMPAT 2")
git -C "$SRC" checkout -q main

echo "repository URLs"
check "https, with credentials and .git taken off" "https://github.com/cmmr/gnoto" \
    "$(repository_url https://user:token@github.com/cmmr/gnoto.git)"
check "an ssh remote becomes https" "https://github.com/cmmr/gnoto" "$(repository_url git@github.com:cmmr/gnoto.git)"
check "a path becomes file://, keeping .git" "file:///srv/gnoto.git" "$(repository_url /srv/gnoto.git)"
check "anything else is nothing" "" "$(repository_url ssh://host/repo)"
check "a clone's commit" "$MAIN" "$(install_commit "$SRC")"
check "a directory that isn't a clone has none" "" "$(install_commit "$WORK/install")"
echo "commit: \"$V12\"" > "$WORK/install/VERSION"
check "but a release's VERSION does" "$V12" "$(install_commit "$WORK/install")"
rm "$WORK/install/VERSION"

echo "resolving a version"
check "a release, an annotated tag" "$V12" "$(version_resolve "$REPO" 1.2.0)"
check "a release, a lightweight tag" "$V13" "$(version_resolve "$REPO" 1.3.0)"
check "a branch" "$MAIN" "$(version_resolve "$REPO" main)"
check "another branch" "$SIDE" "$(version_resolve "$REPO" side)"
check "a tag by its name" "$V12" "$(version_resolve "$REPO" v1.2.0)"
check "a full commit, as it is" "$OLD" "$(version_resolve "$REPO" "$OLD")"
check "a short commit" "a version needs the full 40-character commit, not ${MAIN:0:7}" \
    "$(version_resolve "$REPO" "${MAIN:0:7}" 2>&1)"
check "no such release" "$REPO has no release, branch or tag 9.9.9" "$(version_resolve "$REPO" 9.9.9 2>&1)"
check "not a version" "1" "$(version_resolve "$REPO" 'a..b' > /dev/null 2>&1; echo $?)"
check "a repository that isn't there" "yes" \
    "$(version_resolve "file://$WORK/nothing" main 2>&1 | grep -q "^can't reach file://$WORK/nothing to look up main" && echo yes)"
check "the newest release" "v1.3.0" "$(latest_release "$REPO")"
check "none" "" "$(latest_release "file://$WORK/nothing")"
check "a commit's release" "v1.2.0" "$(release_of "$REPO" "$V12")"

echo "fetching a commit"
check "one from before the version cache is refused" \
    "commit $OLD is older than gnoto's version cache, so gnoto can't run it" \
    "$(version_fetch "$REPO" "$OLD" 2>&1 | tail -1)"
check "and leaves nothing" "no" "$([[ -e $DATA_DIR/versions/$OLD ]] && echo yes || echo no)"
version_fetch "$REPO" "$V12" 2> /dev/null
DIR=$DATA_DIR/versions/$V12
check "a release lands whole" "yes" "$([[ -f $DIR/lib/sub/file && -x $DIR/gnoto ]] && echo yes)"
check "with its VERSION" $'commit: "'"$V12"$'"\nrepository: "'"$REPO"'"' "$(cat "$DIR/VERSION")"
check "its files read-only" "" "$(find "$DIR" -type f -perm /222)"
check "its directories group-writable" "2775 2775" "$(stat -c %a "$DIR" "$DIR/lib/sub" | paste -sd ' ')"
check "and the bare repository shared by the group" "1" \
    "$(git -C "$DATA_DIR/repo.git" config core.sharedRepository)"
check "fetching it again does nothing" "" "$(version_fetch "$REPO" "$V12" 2>&1)"
check "a commit the repository doesn't have" "yes" \
    "$(version_fetch "$REPO" 0123456789abcdef0123456789abcdef01234567 2>&1 | grep -q "^can't fetch commit" && echo yes)"
mkdir -p "$WORK/code2"
echo 2 > "$WORK/code2/COMPAT"
check "a commit whose COMPAT is below this version's is refused" \
    "commit $V13 is from before a change this version of gnoto can't run across: its COMPAT is 1, and this version's is 2" \
    "$(CODE_DIR=$WORK/code2 version_fetch "$REPO" "$V13" 2>&1 | tail -1)"
check "one whose COMPAT is higher isn't" "0" "$(version_fetch "$REPO" "$SIDE" > /dev/null 2>&1; echo $?)"

echo "which main or a release reaches"
check "a release" "yes" "$(version_reachable "$REPO" "$V12")"
check "an older commit of main" "yes" "$(version_reachable "$REPO" "$V13")"
check "a branch neither reaches" "no" "$(version_reachable "$REPO" "$SIDE")"

echo "the code's own version"
(
    CODE_DIR=$DATA_DIR/versions/$V12
    code_version
    check "a cached copy has its commit and repository" "$V12 $REPO false" "$CODE_COMMIT $CODE_REPOSITORY $CODE_DEV"
)
(
    CODE_DIR=$SRC
    code_version
    check "an install's own files are dev, with its origin or gnoto's repository" " https://github.com/cmmr/gnoto true" \
        "$CODE_COMMIT $CODE_REPOSITORY $CODE_DEV"
)

echo "the current version"
check "none yet" "" "$(current_commit)"
current_write "$V12" "$REPO"
check "written" "$V12 $REPO 664" "$(current_commit) $(current_repository) $(stat -c %a "$DATA_DIR/current")"
check "a plain name is the current version" "$V12" "$(CODE_COMMIT=$V13 version_commit "")"
check "a resolved hand-over is taken as given" "$V13" "$(CODE_COMMIT=$V13 GNOTO_RESOLVED=$V13 version_commit main)"
check "a hand-over resolved to another commit isn't" "$MAIN" \
    "$(CODE_COMMIT=$V13 CODE_REPOSITORY=$REPO GNOTO_RESOLVED=$V12 version_commit main)"

echo "handing a command over"
check "to its own commit, nothing" "0 no" \
    "$(CODE_COMMIT=$V12 GNOTO_HELPER_DIR=$WORK/helper version_route "$REPO" "$V12"; echo "$? $([[ -e $WORK/helper/handover ]] && echo yes || echo no)")"
(CODE_COMMIT=$V12 GNOTO_HELPER_DIR=$WORK/helper version_route "$REPO" "$V13" 2> /dev/null)
echo "exit $?" > "$WORK/route.out"
check "to another, it fetches it and leaves the hand-over" $'exit 0' "$(cat "$WORK/route.out")"
check "naming the commit, resolved" $V13$'\nresolved' "$(cat "$WORK/helper/handover")"
check "which is fetched" "yes" "$([[ -x $DATA_DIR/versions/$V13/gnoto ]] && echo yes)"
rm -f "$WORK/helper/handover"
check "without the launcher's private directory, it fails" "1" \
    "$( (CODE_COMMIT=$V12 GNOTO_HELPER_DIR= version_route "$REPO" "$V13") > /dev/null 2>&1; echo $?)"

echo "gnoto upgrade"
upgrade() {
    (
        code_version() { CODE_COMMIT=""; CODE_REPOSITORY=$REPO; CODE_DEV=true; }
        GNOTO_HELPER_DIR=$WORK/helper upgrade_main "$@"
    ) < /dev/null 2>&1
}
OUT=$(upgrade --yes)
check "with no version, the newest release" "$V13" "$(current_commit)"
check "says what it adds" "yes" "$(grep -q 'release 1.3.0' <<< "$OUT" && echo yes)"
check "and hands over to its lint" $V13$'\nlint' "$(cat "$WORK/helper/handover")"
rm -f "$WORK/helper/handover"
check "the current one again" "gnoto 1.3.0 (commit $V13) is current already." "$(upgrade 1.3.0)"
OUT=$(upgrade 1.2.0)
check "without --yes or a terminal, nothing changes" "$V13" "$(current_commit)"
check "and it says why" "yes" "$(grep -q 'Add --yes to upgrade' <<< "$OUT" && echo yes)"
OUT=$(upgrade --yes 1.2.0)
check "going back" "$V12" "$(current_commit)"
check "says what it leaves out" "yes" "$(grep -A1 'Commits it leaves out' <<< "$OUT" | grep -q 'release 1.3.0' && echo yes)"
upgrade --yes main > /dev/null
check "a branch" "$MAIN" "$(current_commit)"
check "a commit from before the version cache" "$MAIN" "$(upgrade --yes "$OLD" > /dev/null; current_commit)"
rm -f "$WORK/helper/handover"

echo "gnoto prune"
version_fetch "$REPO" "$MAIN" 2> /dev/null
mkdir -p "$DATA_DIR/runs/aaaaaaaa" "$DATA_DIR/runs/bbbbbbbb" "$DATA_DIR/images"
printf '{"status": "Running", "commit": "%s"}\n' "$V13" > "$DATA_DIR/runs/aaaaaaaa/run_state.json"
printf '{"status": "Completed", "commit": "%s"}\n' "$SIDE" > "$DATA_DIR/runs/bbbbbbbb/run_state.json"
touch -d '2 hours ago' "$DATA_DIR"/versions/*/
OUT=$(prune_main 2>&1 < /dev/null)
check "without --yes or a terminal, nothing goes" "yes yes" \
    "$(grep -q 'Add --yes to prune' <<< "$OUT" && echo yes) $([[ -d $DATA_DIR/versions/$SIDE ]] && echo yes)"
check "it plans to remove what nothing uses" \
    "$(printf 'Removing version %s\n' "$SIDE" "$V12" | sort | paste -sd ' ')" \
    "$(grep '^Removing' <<< "$OUT" | sort | paste -sd ' ')"
OUT=$(prune_main --yes 2>&1)
check "it keeps the current version" "yes" "$([[ -d $DATA_DIR/versions/$MAIN ]] && echo yes)"
check "and a running job's" "yes" "$(grep -q "Keeping $V13: run aaaaaaaa" <<< "$OUT" && echo yes)"
check "and removes the rest" "no no" \
    "$([[ -e $DATA_DIR/versions/$SIDE ]] && echo yes || echo no) $([[ -e $DATA_DIR/versions/$V12 ]] && echo yes || echo no)"
check "leaving nothing half-removed" "" "$(ls -A "$DATA_DIR/versions" | grep '^\.tmp')"
check "and keeps a version used in the last hour" "Nothing to prune." \
    "$(version_fetch "$REPO" "$V12" 2> /dev/null; prune_main --yes 2>&1 | tail -1)"
mkdir -p "$DATA_DIR/versions/notacommit"
check "versions not named by 40 characters are left alone" "Nothing to prune." "$(prune_main --yes 2>&1 | tail -1)"

HEX=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
LOCKED=$WORK/locked
mkdir -p "$LOCKED/pipelines/a" "$LOCKED/modules"
echo "docker://ghcr.io/cmmr/gnoto@sha256:$HEX" > "$LOCKED/IMAGE"
printf 'step_images:\n  r: "ghcr.io/cmmr/gnoto-rbiom@sha256:%s"\n  v: "local-v.sif"\n' "$HEX" > "$LOCKED/pipelines/a/lock.yaml"
printf "    withName: 'X' { container = 'quay.io/biocontainers/x@sha256:%s' } // quay.io/biocontainers/x:1\n" "$HEX" \
    > "$LOCKED/pipelines/a/containers.config"
printf "    withName: 'Z' { container = 'https://c.example.org/docker/registry/v2/blobs/sha256/01/%s/data' } // c.example.org/z:3\n" "$HEX" \
    >> "$LOCKED/pipelines/a/containers.config"
printf "    container 'community.wave.seqera.io/library/y@sha256:%s' // community.wave.seqera.io/library/y:2\n" "$HEX" \
    > "$LOCKED/modules/m.nf"
check "the images a version names, as each puller names its file" \
    "gnoto-$HEX.sif yes|ghcr.io-cmmr-gnoto-rbiom@sha256-$HEX.sif yes|local-v.sif no|community.wave.seqera.io-library-y@sha256-$HEX.img yes|c.example.org-docker-registry-v2-blobs-sha256-01-$HEX-data.img yes|quay.io-biocontainers-x@sha256-$HEX.img yes" \
    "$(version_images "$LOCKED" | tr '\t' ' ' | paste -sd '|')"
touch "$DATA_DIR/images/gnoto-test.sif" "$DATA_DIR/images/quay.io-biocontainers-x@sha256-$HEX.img" \
    "$DATA_DIR/images/quay.io-biocontainers-old-1.0.img" "$DATA_DIR/images/quay.io-biocontainers-old-1.0.img.lock"
touch -d '2 hours ago' "$DATA_DIR"/images/*
touch "$DATA_DIR/images/fresh.img"
OUT=$(prune_main --yes 2>&1)
check "prune removes the images no version it keeps names" "yes yes" \
    "$(grep -q "Removing image $DATA_DIR/images/quay.io-biocontainers-x@sha256-$HEX.img" <<< "$OUT" && echo yes) $(grep -q 'and 2 images.' <<< "$OUT" && echo yes)"
check "and keeps a local .sif a kept version names, and one just pulled" \
    "fresh.img gnoto-test.sif" "$(ls "$DATA_DIR/images" | paste -sd ' ')"
rm -rf "$DATA_DIR/runs" "$DATA_DIR/images"/*

echo "a record's inputs"
mkdir -p "$WORK/inputs/a" "$WORK/inputs/b"
printf 'AAAA\n' > "$WORK/inputs/a/one.fq"
printf 'BBBB\n' > "$WORK/inputs/b/two.fq"
printf 'CCCCCC\n' > "$WORK/inputs/three.fq"
SUM1=$(sha256sum < "$WORK/inputs/a/one.fq" | cut -d' ' -f1)
SUM2=$(sha256sum < "$WORK/inputs/b/two.fq" | cut -d' ' -f1)
SUM3=$(sha256sum < "$WORK/inputs/three.fq" | cut -d' ' -f1)
RECORD=$(jq -n --arg s1 "$SUM1" --arg s2 "$SUM2" --arg s3 "$SUM3" '{inputs: [
    {sample: "S1", run: "run_1", fastq1: "S1_R1.fq", bytes_1: 5, sha256_1: $s2, fastq2: "S1_R2.fq", bytes_2: 7, sha256_2: $s3},
    {sample: "S2", run: "run_2", fastq1: "S2.fq", bytes_1: 5, sha256_1: $s1}]}')
LINT_FAILS=0
OUT=$(JOB_INPUTS_DIR=$WORK/inputs; job_check_inputs "$RECORD"; printf '%s' "$JOB_SAMPLES_TEXT" > "$WORK/samples")
check "found by size, and where sizes are shared, by checksum" \
    $'S1\t'"$WORK/inputs/b/two.fq"$'\t'"$WORK/inputs/three.fq"$'\nS2\t'"$WORK/inputs/a/one.fq" "$(cat "$WORK/samples")"
check "and reported" "yes" "$(grep -q 'OK    inputs: 2 samples, 3 FASTQ files' <<< "$OUT" && echo yes)"
rm "$WORK/inputs/three.fq"
OUT=$(JOB_INPUTS_DIR=$WORK/inputs; job_check_inputs "$RECORD")
check "a file that isn't there" "yes" \
    "$(grep -q "FAIL  inputs: nothing under $WORK/inputs is S1_R2.fq, sample S1's 7-byte file" <<< "$OUT" && echo yes)"
check "a record needs --inputs" "yes" \
    "$(JOB_INPUTS_DIR=; job_check_inputs "$RECORD" | grep -q 'a record re-runs with --inputs' && echo yes)"
check "each sample's batch" '{"S1":"run_1","S2":"run_2"}' \
    "$(JOB_INPUTS_DIR=$WORK/inputs; job_check_inputs "$RECORD" > /dev/null; printf '%s' "$JOB_RECORDED_RUNS")"

echo "a record, checked as a job file"
cat > "$WORK/record.yaml" << EOF
schema: 1
pipeline: "ampliseq@$V13"
repository: "$REPO"
commit: "$V13"
title: "Re-run"
retention: "1 Month"
ampliseq:
  input: "ampliseq_samplesheet.tsv"
  cut_dada_ref_taxonomy: true
  primer_fwd: "GTGCCAGCMGCCGCGGTAA"
outputs: []
inputs:
  - sample: "S2"
    run: "run_2"
    fastq1: "S2.fq"
    bytes_1: 5
    sha256_1: "$SUM1"
EOF
OUT=$(
    code_version() { CODE_COMMIT=$V13; CODE_REPOSITORY=$REPO; CODE_DEV=false; }
    JOB_INPUTS_DIR=$WORK/inputs
    LINT_FAILS=0
    job_check "$WORK/record.yaml" 2>&1
)
check "takes the record's own keys" "" "$(grep -E 'FAIL  (schema|repository|commit|outputs|inputs):' <<< "$OUT")"
check "runs at its commit" "yes" "$(grep -q "OK    pipeline: ampliseq@$V13, re-run from its record" <<< "$OUT" && echo yes)"
check "with its parameters as recorded, owned keys included" "yes" \
    "$(grep -q 'OK    ampliseq: 3 parameters, as recorded' <<< "$OUT" && echo yes)"
check "and its inputs" "yes" "$(grep -q 'OK    inputs: 1 sample, 1 FASTQ file' <<< "$OUT" && echo yes)"
OUT=$(
    code_version() { CODE_COMMIT=""; CODE_REPOSITORY=$REPO; CODE_DEV=true; }
    JOB_INPUTS_DIR=$WORK/inputs
    LINT_FAILS=0
    job_check "$WORK/record.yaml" 2>&1
)
check "--dev can't re-run a record" "yes" "$(grep -q 'FAIL  pipeline: a record re-runs at its own commit' <<< "$OUT" && echo yes)"
sed -i 's/^schema: 1$/schema: 1\ndev: true/' "$WORK/record.yaml"
OUT=$(LINT_FAILS=0; job_check "$WORK/record.yaml" 2>&1)
check "nor can anything re-run a --dev run's record" "yes" \
    "$(grep -q "is the record of a --dev run" <<< "$OUT" && echo yes)"

echo "a record's parameters, as recorded"
params_set exclude_taxa "x"
params_apply_exact '{"cut_dada_ref_taxonomy": true, "input": "ampliseq_samplesheet.tsv", "trunclenf": 230}'
check "replace the map, each as it is" '{"cut_dada_ref_taxonomy":true,"input":"ampliseq_samplesheet.tsv","trunclenf":230}' \
    "$(params_json | jq -c .)"

echo "inputs against their checksums"
mkdir -p "$WORK/run"
cd "$WORK/run" || exit 1
printf 'A\n' > in1.fq
printf 'S1\t%s\n' "$WORK/run/in1.fq" > original_samplesheet.tsv
state_init vvvvvvvv > /dev/null
state_set_json expected_inputs "[{\"sample\": \"S1\", \"sha256_1\": \"$(sha256sum < in1.fq | cut -d' ' -f1)\"}]"
check "a re-run whose inputs match" "0" "$( (stage_inputs) > /dev/null 2>&1; echo $?)"
state_set exact true
state_set_json expected_inputs '[{"sample": "S1", "sha256_1": "0000"}]'
check "one whose inputs don't" "1" "$( (stage_inputs) > /dev/null 2>&1; echo $?)"
check "says which" "S1's in1.fq doesn't match the checksum it had in the record." "$(state_get message)"
state_unset expected_inputs
state_unset exact
state_set_json attempts '[{"status": "Failed"}]'
state_set_json inputs '[{"sample": "S1", "fastq1": "in1.fq", "sha256_1": "1111"}]'
check "a resumed run checks against its first attempt" "1" "$( (stage_inputs) > /dev/null 2>&1; echo $?)"
check "and says so" "S1's in1.fq doesn't match the checksum it had in the run's first attempt." "$(state_get message)"

echo "Nextflow's session"
mkdir -p .nextflow
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "2026-11-08 10:00:00" 5m happy_name ERR abc 11111111-aaaa-bbbb-cccc-000000000001 "nextflow run nf-core/ampliseq -r x" \
    "2026-11-08 11:00:00" 5m other_name OK def 22222222-aaaa-bbbb-cccc-000000000002 "nextflow run /code/workflows/humann" \
    > .nextflow/history
check "the main run's" "11111111-aaaa-bbbb-cccc-000000000001" "$(nextflow_session nf-core/ampliseq)"
check "HUMAnN's, in the same directory" "22222222-aaaa-bbbb-cccc-000000000002" "$(nextflow_session /code/workflows/humann)"
check "none" "" "$(nextflow_session nothing)"

echo "what a failed run keeps"
mkdir -p work/ab/cdef raw-sequences results/pipeline_info results/dada2
touch work/ab/cdef/.command.sh work/ab/cdef/out.tsv raw-sequences/S1.fq.gz results/dada2/x .inputs.list
clean_run Failed
check "its work directory, Nextflow's history and its staged inputs" "yes yes yes" \
    "$([[ -f work/ab/cdef/out.tsv ]] && echo yes) $([[ -f .nextflow/history ]] && echo yes) $([[ -f raw-sequences/S1.fq.gz ]] && echo yes)"
check "but not the results Nextflow publishes again" "no yes" \
    "$([[ -e results/dada2 ]] && echo yes || echo no) $([[ -d results/pipeline_info ]] && echo yes)"
clean_run Completed
check "a completed run keeps none of them" "no no no" \
    "$([[ -e work ]] && echo yes || echo no) $([[ -e .nextflow ]] && echo yes || echo no) $([[ -e raw-sequences ]] && echo yes || echo no)"
state_set retention "1 Month"
write_expiry vvvvvvvv Failed 2026-11-08T00:00:00Z
check "a failed run's leftovers go when its record does" \
    $'# Written by gnoto when run vvvvvvvv ended. The daily timer acts on it.\nremove_utc: "2026-11-22T00:00:00Z"\ncleanup_utc: "2026-11-22T00:00:00Z"' \
    "$(cat "$DATA_DIR/expiry/vvvvvvvv")"

echo "which runs can be resumed"
live_status() { printf 'Lost'; }
state_set commit "$V13"
state_set dev false
for status in Completed "Publish failed" Failed Cancelled Running; do
    set_run_status "$status"
    printf '%s: %s\n' "$status" "$(resume_refusal)"
done > "$WORK/refusals"
check "not a completed one" "Completed: it completed" "$(sed -n 1p "$WORK/refusals")"
check "nor one that made its results" "Publish failed: its results were made, and only building or publishing their pages failed" \
    "$(sed -n 2p "$WORK/refusals")"
check "a failed, cancelled or lost one" "Failed: |Cancelled: |Running: " "$(sed -n '3,5p' "$WORK/refusals" | paste -sd '|')"
live_status() { printf 'Running'; }
check "not one still going" "it's still going, as Running" "$(resume_refusal)"
set_run_status Failed
state_set_json steps '[{"name": "ampliseq", "log": "nextflow.out", "state": "failed"}]'
check "not one whose cache has gone" "its cache, the work directory, is gone" "$(resume_refusal)"
state_set dev true
check "nor a --dev run" "it ran an install's own files, with --dev" "$(resume_refusal)"

echo "a Slurm job's command"
sbatch() { printf '%s\n' "$@" > "$WORK/sbatch.args"; echo 77; }
SLURM_ENABLED=true scheduler_submit --name x --dir "$WORK/run" --log "$WORK/run/job.out" -- _job "$WORK/run" > /dev/null
check "names the install directory and this version's launcher" \
    "--wrap GNOTO_INSTALL_DIR='$INSTALL_DIR'; export GNOTO_INSTALL_DIR; exec '$CODE_DIR/gnoto' '_job' '$WORK/run'" \
    "$(grep -A1 -- '^--wrap$' "$WORK/sbatch.args" | paste -sd ' ')"

exit $FAILED
