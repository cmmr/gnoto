#!/bin/bash
#
# ampliseq-16s-v4.sh - Runs nf-core/ampliseq 3.1.0 on the 16s-v4 fixture, with
# Nextflow in the image and every task under Slurm, through the helper.
#
# Run by:  a developer, in the test bed or on the cluster:
#          gnoto exec bash <install>/test/testbed/checks/ampliseq-16s-v4.sh \
#              [extra.config [sbatch option ...]]
#
# Runs inside the image, so every tool but Slurm and Apptainer is the image's.
# Fetches the fixture and SILVA 138.2 into the database directory, checking
# md5s, submits the head job through the sbatch stand-in, and waits for it. An
# extra config, such as a site's queue, is passed to Nextflow with -c, and any
# sbatch options, such as -p and -A, go to the head job.

set -euo pipefail

CHECKS=$(cd "$(dirname "$0")" && pwd)
EXTRA_CONFIG=${1:-}
SBATCH_EXTRA=("${@:2}")

if [[ -n $EXTRA_CONFIG && ! -r $EXTRA_CONFIG ]]; then
    echo "Can't read $EXTRA_CONFIG. Leave it out where Slurm's defaults will do." >&2
    exit 1
fi
DB=$GNOTO_DB_DIR
RUN=$GNOTO_DATA_DIR/test/$USER/ampliseq-16s-v4
FIXTURE=$DB/fixtures/16s-v4/v1
SILVA=$DB/dada2/silva-138.2

# Downloads to a temporary name, checks the md5, then renames
fetch() {
    local url=$1 md5=$2 dest=$3
    [[ -f $dest ]] && return
    mkdir -p "${dest%/*}"
    curl -fsSL --retry 3 -o "$dest.tmp" "$url" || { echo "Can't download $url" >&2; exit 1; }
    echo "$md5  $dest.tmp" | md5sum -c --quiet || { echo "md5 mismatch for $url" >&2; exit 1; }
    mv "$dest.tmp" "$dest"
}

EBI=https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR173/042/SRR17380142
fetch "$EBI/SRR17380142_1.fastq.gz" f73c4461d0e1674ccb357f55e985e120 "$FIXTURE/SRR17380142_1.fastq.gz"
fetch "$EBI/SRR17380142_2.fastq.gz" f63251aa1deb2aa16433ccb301ff6761 "$FIXTURE/SRR17380142_2.fastq.gz"
ZENODO=https://zenodo.org/records/14169026/files
fetch "$ZENODO/silva_nr99_v138.2_toSpecies_trainset.fa.gz" e0455a1a7de820039d684aad2053e937 \
    "$SILVA/silva_nr99_v138.2_toSpecies_trainset.fa.gz"
fetch "$ZENODO/silva_v138.2_assignSpecies.fa.gz" 62fd939bd1aa9832d2089847f9f0b87d \
    "$SILVA/silva_v138.2_assignSpecies.fa.gz"

rm -rf "$RUN"
mkdir -p "$RUN"
cd "$RUN"

printf 'sample\tfastq_1\tfastq_2\nSRR17380142\t%s\t%s\n' \
    "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" > samplesheet.tsv

cat > params.yaml << EOF
input: "$RUN/samplesheet.tsv"
outdir: "$RUN/results"
primer_fwd: "GTGYCAGCMGCCGCGGTAA"
primer_rev: "GGACTACNVGGGTWTCTAAT"
dada_ref_tax_custom: "$SILVA/silva_nr99_v138.2_toSpecies_trainset.fa.gz"
dada_ref_tax_custom_sp: "$SILVA/silva_v138.2_assignSpecies.fa.gz"
dada_assign_taxlevels: "Domain,Phylum,Class,Order,Family,Genus,Species"
skip_qiime_downstream: true
custom_config_base: ""
EOF

CONFIGS=(-c "$CHECKS/../nextflow/slurm.config")
if [[ -n $EXTRA_CONFIG ]]; then
    CONFIGS+=(-c "$EXTRA_CONFIG")
fi

# The head job runs the launcher again on the compute node
printf -v NEXTFLOW '%q ' nextflow -log "$RUN/nextflow.log" run nf-core/ampliseq -r 3.1.0 \
    -profile apptainer -ansi-log false "${CONFIGS[@]}" -params-file "$RUN/params.yaml" \
    -work-dir "$RUN/work"
JOB=$(sbatch --parsable --job-name=ampliseq-16s-v4 --no-requeue --signal=B:TERM@300 \
    --time=4:00:00 --cpus-per-task=1 --mem=4G --output="$RUN/head.log" "${SBATCH_EXTRA[@]}" \
    --wrap "exec $GNOTO_CODE_DIR/gnoto exec $NEXTFLOW")
echo "Head job $JOB, run directory $RUN"

while squeue -h -j "$JOB" 2> /dev/null | grep -q .; do
    sleep 30
done

tail -25 head.log | cat -v
for FILE in results/dada2/ASV_table.tsv results/dada2/ASV_tax.user.tsv; do
    if [[ -s $FILE ]]; then
        echo "ok    $FILE ($(( $(wc -l < "$FILE") - 1 )) ASVs)"
    else
        echo "FAIL  $FILE is missing"
        exit 1
    fi
done
