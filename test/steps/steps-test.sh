#!/bin/bash
#
# steps-test.sh - Runs the steps that need no large database on the 16s-v4
# fixture, with real containers, and checks what they write.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec bash <install>/test/steps/steps-test.sh
# Requires:  the 16s-v4 fixture in <db_dir>/fixtures/16s-v4/v1, as
#            test/testbed/checks/ampliseq-16s-v4.sh fetches it
#
# The steps run with a scratch install directory whose db_dir holds tiny
# placement trees, so pruning runs the real gotree image.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
FIXTURE=$DB_DIR/fixtures/16s-v4/v1
WORK=$(mktemp -d "$DATA_DIR/test-steps.XXXXXX")
FAILED=0
trap '[[ -n ${KEEP:-} ]] || rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

[[ -r $FIXTURE/SRR17380142_1.fastq.gz ]] || { echo "No 16s-v4 fixture in $FIXTURE"; exit 1; }

mkdir -p "$WORK/install" "$WORK/db/pplace"
printf 'core:\n  data_dir: "%s"\n  db_dir: "%s"\n' "$DATA_DIR" "$WORK/db" > "$WORK/install/config.yaml"
export GNOTO_INSTALL_DIR=$WORK/install
source "$CODE/lib/env.sh" || exit 1

# A second sample of the same reads, as bzip2, under a name ampliseq rejects
gzip -dc "$FIXTURE/SRR17380142_1.fastq.gz" | lbzip2 > "$WORK/second_1.fq.bz2"
gzip -dc "$FIXTURE/SRR17380142_2.fastq.gz" | lbzip2 > "$WORK/second_2.fq.bz2"
SHEET=$(printf '%s\t%s\t%s\n' \
    SRR17380142 "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" \
    2nd.sample "$WORK/second_1.fq.bz2" "$WORK/second_2.fq.bz2")

# Makes a run directory with a fresh state and the samplesheet
new_run() {
    mkdir -p "$WORK/$1"
    cd "$WORK/$1" || exit 1
    state_init abcdefgh
    printf '%s\n' "$SHEET" > original_samplesheet.tsv
}

echo "ampliseq"
new_run ampliseq
"$CODE/steps/ampliseq_samplesheet.sh" > samplesheet.log 2>&1
check "samplesheet step exits 0" "0" "$?"
check "two samples recorded" "2" "$(state_get samples.count)"
check "sheet has a header and two rows" "3" "$(wc -l < ampliseq_samplesheet.tsv)"
check "gzip input linked" "yes" "$([[ -L raw-sequences/SRR17380142_reads_1.fq.gz ]] && echo yes)"
check "bzip2 input recompressed to the same reads" \
    "$(lbzip2 -dc "$WORK/second_1.fq.bz2" | md5sum)" \
    "$(gzip -dc raw-sequences/*2nd*_reads_1.fq.gz 2> /dev/null | md5sum)"
echo "      sheet: $(cut -f1 ampliseq_samplesheet.tsv | tr '\n' ' ')"

"$CODE/steps/ampliseq_detect_region.sh" > detect.log 2>&1
check "region detection without its reference fails" "1" "$?"
check "and says which reference" "yes" "$(state_get message | grep -q '16s' && echo yes || state_get message)"

mkdir -p results/pplace
echo "(R1:0.1,R2:0.2,(R3:0.1,R4:0.1):0.3);" > "$WORK/db/pplace/bac16s.newick"
echo "(R1:0.1,R2:0.2,(R3:0.1,R4:0.1):0.3,((ASV_1:0.1,ASV_2:0.2):0.05,ASV_3:0.1):0.05);" > results/pplace/gtdb.graft.newick
"$CODE/steps/ampliseq_prune_tree.sh" > prune.log 2>&1
check "pruning, with the real gotree image" "0" "$?"
check "leaves only the ASVs" "ASV_1 ASV_2 ASV_3" \
    "$(grep -o -E 'ASV_[0-9]+' results/pplace/asv_tree.newick 2> /dev/null | sort | tr '\n' ' ' | sed 's/ $//')"

echo "taxprofiler"
new_run taxprofiler
"$CODE/steps/taxprofiler_samplesheet.sh" > samplesheet.log 2>&1
check "samplesheet step exits 0" "0" "$?"
check "two samples, measured as Illumina" "ILLUMINA ILLUMINA" \
    "$(awk -F, 'NR > 1 { print $3 }' taxprofiler_samplesheet.csv | tr '\n' ' ' | sed 's/ $//')"
check "read length near 250" "yes" "$([[ $(state_get samples.read_length) -gt 200 ]] && echo yes || state_get samples.read_length)"
check "database sheet holds paths, not db: names" "0 4" \
    "$(grep -c 'db:' taxprofiler_database.csv) $(grep -c "^[a-z0-9]*,.*,$WORK/db/" taxprofiler_database.csv)"

echo "biobakery"
new_run biobakery
"$CODE/steps/biobakery_samplesheet.sh" > samplesheet.log 2>&1
STATUS=$?
check "samplesheet and disk check exit 0" "0" "$STATUS"
[[ $STATUS -eq 0 ]] || tail -5 samplesheet.log | sed 's/^/      /'
check "biobakery samplesheet written" "yes" "$([[ -s biobakery_samplesheet.csv ]] && echo yes)"

exit $FAILED
