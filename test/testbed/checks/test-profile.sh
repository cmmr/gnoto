#!/bin/bash
#
# test-profile.sh - Runs an nf-core pipeline's own test profile under Slurm,
# with Nextflow in the image, and waits for it.
#
# Run by:  a developer, in the test bed or on the cluster:
#          gnoto exec bash <install>/test/testbed/checks/test-profile.sh \
#              <pipeline> <version> [extra.config [sbatch option ...]]
#          e.g. ... test-profile.sh taxprofiler 2.0.1
#
# Runs inside the image. custom_config_base is empty, as it always is in gnoto.

set -euo pipefail

CHECKS=$(cd "$(dirname "$0")" && pwd)
PIPELINE=$1
VERSION=$2
EXTRA_CONFIG=${3:-}
SBATCH_EXTRA=("${@:4}")

if [[ -n $EXTRA_CONFIG && ! -r $EXTRA_CONFIG ]]; then
    echo "Can't read $EXTRA_CONFIG. Leave it out where Slurm's defaults will do." >&2
    exit 1
fi
RUN=$GNOTO_DATA_DIR/test/$USER/$PIPELINE-test

rm -rf "$RUN"
mkdir -p "$RUN"
cd "$RUN"

cat > params.yaml << EOF
outdir: "$RUN/results"
custom_config_base: ""
EOF

CONFIGS=(-c "$CHECKS/../nextflow/slurm.config")
if [[ -n $EXTRA_CONFIG ]]; then
    CONFIGS+=(-c "$EXTRA_CONFIG")
fi

printf -v NEXTFLOW '%q ' nextflow -log "$RUN/nextflow.log" run "nf-core/$PIPELINE" -r "$VERSION" \
    -profile test,apptainer -ansi-log false "${CONFIGS[@]}" -params-file "$RUN/params.yaml" \
    -work-dir "$RUN/work"
JOB=$(sbatch --parsable --job-name="$PIPELINE-test" --no-requeue --signal=B:TERM@300 \
    --time=4:00:00 --cpus-per-task=1 --mem=4G --output="$RUN/head.log" "${SBATCH_EXTRA[@]}" \
    --wrap "exec $GNOTO_CODE_DIR/gnoto exec $NEXTFLOW")
echo "Head job $JOB, run directory $RUN"

while squeue -h -j "$JOB" 2> /dev/null | grep -q .; do
    sleep 30
done

grep -E 'Pipeline completed|Duration|Succeeded|Failed|Ignored|ERROR' head.log || tail -20 head.log | cat -v
grep -q 'Pipeline completed successfully' head.log
