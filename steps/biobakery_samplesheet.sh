#!/bin/bash
#
# biobakery_samplesheet.sh - Stage the reads and write the biobakery samplesheet.
#
# Runs biobakery_disk_check.sh, which refuses a run the disk cannot hold, then
# taxprofiler_samplesheet.sh, which validates the lab samplesheet, stages every
# read into ./raw-sequences/ and records the sample count and platform, and
# keeps the CSV it writes as ./biobakery_samplesheet.csv. The Bracken database
# sheet it also writes is deleted. A run whose reads are not Illumina short
# reads is refused.
#
# Usage:     biobakery_samplesheet.sh [input_samplesheet]
#            defaults to ./original_samplesheet.tsv, the run's copy of the
#            requester's samplesheet
# Called by: the job, from the run directory, as the biobakery pipeline's
#            pre-process step
# Runs:      steps/biobakery_disk_check.sh, then steps/taxprofiler_samplesheet.sh
# Writes:    ./biobakery_samplesheet.csv, ./raw-sequences/, and the samples
#            section of ./run_state.json
# Env:       CODE_DIR, the fail helper and the run state helpers, from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

"$CODE_DIR/steps/biobakery_disk_check.sh" "$@"

"$CODE_DIR/steps/taxprofiler_samplesheet.sh" "$@"

mv taxprofiler_samplesheet.csv biobakery_samplesheet.csv
rm -f taxprofiler_database.csv

PLATFORM=$(state_get samples.platform)

if [[ "$PLATFORM" != "ILLUMINA" ]]; then
    fail "These reads look like $PLATFORM reads. KneadData, MetaPhlAn and HUMAnN take Illumina short reads only."
fi
