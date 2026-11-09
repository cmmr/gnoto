#!/bin/bash
#
# repeat.sh - The determinism test that chooses a pipeline's stable-files: runs
# each fixture job its selftest.yaml lists twice on this install, and once more
# on another install whose slurm.max_cpus differs, then sorts every file the
# three runs of each job made with classify-outputs.sh.
#
# Run by:    a developer, as any user, on the cluster, from the install whose
#            pipelines/<pipeline>/selftest.yaml it reads:
#            bash <install>/test/testbed/checks/repeat.sh <pipeline> <other install> [<job> ...]
#            With jobs named, only those run.
# Requires:  both installs at the same version, with the same database
#            directory; Slurm, since every run starts at once, which a
#            single node with room for one run at a time can't hold.
#            gnoto start --yes fetches the fixtures and databases the jobs need.
#
# The three runs of a job share a title, so the files that name it compare too.
# Each job's classes go in <data_dir>/test/$USER/repeat/<pipeline>-<job>.tsv,
# and every file that isn't stable is printed. The runs are left in place, to
# be looked at, and gnoto remove clears them. Takes as long as the slowest job.

set -u

CODE_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
GNOTO=$CODE_DIR/gnoto
[[ $# -ge 2 ]] || { sed -n '9,11p' "$0" >&2; exit 1; }
PIPELINE=$1
OTHER=$(cd "$2" && pwd)/gnoto
shift 2
[[ -x $OTHER ]] || { echo "There's no gnoto in $2." >&2; exit 1; }
DATA_DIR=$($GNOTO exec printenv GNOTO_DATA_DIR)
DB_DIR=$($GNOTO exec printenv GNOTO_DB_DIR)
OTHER_DATA=$($OTHER exec printenv GNOTO_DATA_DIR)
WORK=$DATA_DIR/test/$USER/repeat
SPEC=$CODE_DIR/pipelines/$PIPELINE/selftest.yaml
[[ -r $SPEC ]] || { echo "There's no $SPEC." >&2; exit 1; }
mkdir -p "$WORK"
cd "$WORK" || exit 1

# jq on selftest.yaml, in the image: spec_jq <jq's arguments and filter>
spec_jq() {
    $GNOTO exec bash -c 'spec=$1; shift; yq -o=json . "$spec" | jq "$@"' _ "$SPEC" "$@"
}

# The jobs, as "<name>\t<their args, as a JSON list>"
JOBS=$(spec_jq -r '.jobs[] | [.name, ((.args // []) | tojson)] | @tsv')
[[ $# -eq 0 ]] || JOBS=$(grep -E "^($(IFS='|'; echo "$*"))"$'\t' <<< "$JOBS")
[[ -n $JOBS ]] || { echo "No job of $SPEC matches." >&2; exit 1; }

started() {
    local out uid
    out=$("$@" 2>&1)
    uid=$(sed -n 's/^Started \([a-z2-7]\{8\}\),.*/\1/p' <<< "$out")
    [[ -n $uid ]] || { printf 'gnoto start failed:\n%s\n' "$out" >&2; return 1; }
    printf '%s' "$uid"
}

declare -A RUNS=()
while IFS=$'\t' read -r NAME ARGS; do
    spec_jq -r --arg name "$NAME" --arg db "$DB_DIR" \
        '.jobs[] | select(.name == $name) | .samples[] | [.[0]] + (.[1:] | map($db + "/" + .)) | @tsv' \
        > "$PIPELINE-$NAME.samples.tsv"
    mapfile -t EXTRA < <($GNOTO exec jq -r '.[]' <<< "$ARGS")
    JOB=("$PIPELINE" --title="repeat $PIPELINE $NAME" --samplesheet="$WORK/$PIPELINE-$NAME.samples.tsv"
        --retention="1 Month" --yes ${EXTRA[@]+"${EXTRA[@]}"})
    A=$(started $GNOTO start "${JOB[@]}") || exit 1
    B=$(started $GNOTO start "${JOB[@]}") || exit 1
    C=$(started $OTHER start "${JOB[@]}") || exit 1
    RUNS[$NAME]="$A $B $C"
    echo "$PIPELINE $NAME: runs $A and $B here, $C on the other install"
done <<< "$JOBS"

# Until every run has a final status in history
for NAME in "${!RUNS[@]}"; do
    read -r A B C <<< "${RUNS[$NAME]}"
    for (( i = 0; i < 2880; i++ )); do
        [[ -f $DATA_DIR/history/$A/state.json && -f $DATA_DIR/history/$B/state.json &&
            -f $OTHER_DATA/history/$C/state.json ]] && break
        sleep 30
    done
done

for NAME in "${!RUNS[@]}"; do
    read -r A B C <<< "${RUNS[$NAME]}"
    STATUS="$($GNOTO status "$A" | sed -n 's/^  Status     //p') / $($GNOTO status "$B" | sed -n 's/^  Status     //p') / $($OTHER status "$C" | sed -n 's/^  Status     //p')"
    echo
    echo "$PIPELINE $NAME, runs $A $B $C: $STATUS"
    bash "$CODE_DIR/test/testbed/checks/classify-outputs.sh" "$DATA_DIR/runs/$A/results" \
        "$DATA_DIR/runs/$B/results" "$OTHER_DATA/runs/$C/results" > "$PIPELINE-$NAME.tsv"
    printf '  %s stable, %s not:\n' "$(grep -c '^stable' "$PIPELINE-$NAME.tsv")" "$(grep -vc '^stable' "$PIPELINE-$NAME.tsv")"
    grep -v '^stable' "$PIPELINE-$NAME.tsv" | grep -v 'pipeline_info/execution_\|pipeline_info/pipeline_dag_\|pipeline_info/params_' |
        sed 's/^/    /'
done
