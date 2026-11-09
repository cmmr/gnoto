#!/bin/bash
#
# build_host_reference.sh - Builds a host reference for host depletion: one
# FASTA of NCBI genomes, its bowtie2 index and its minimap2 index.
#
# Several genomes become one reference because that's all taxprofiler takes: a
# single FASTA and a single index, so a host plus PhiX is one reference. Both
# indexes are built because instrument_platform, read from the data, decides
# which one a sample uses. Each is built in the image taxprofiler 2.0.1's
# BOWTIE2_BUILD and MINIMAP2_INDEX use, which pipelines/taxprofiler/lock.yaml
# pins, so an index suits the aligner that reads it. The minimap2 index is
# built with -x map-ont, as MINIMAP2_INDEX would build it: an .mmi is valid
# only for the preset it was built with.
#
# The genomes, and the md5 and size of each download, are the entry's sources
# in pipelines/databases.yaml, checked before anything is built from them.
#
# Usage:     build_host_reference.sh <db path> <out_dir>
#            <db path> is hostremoval/<name>/v<n>
# Called by: the database fetch job, as the entry's setup line, with <out_dir>
#            appended. <out_dir> is an empty directory the job made. On success
#            the job renames it into place and moves manifest.yaml beside it, as
#            <db path>.manifest.yaml. On failure it removes it.
# Requires:  curl, md5sum, sha256sum, gzip, yq and jq, from the gnoto image;
#            bowtie2 and minimap2, from the images taxprofiler's lock.yaml pins.
#            For a human reference, about 16 CPUs, 64 GB of memory and a few
#            hours.
# Reads:     the entry in pipelines/databases.yaml
# Writes:    into <out_dir>:
#              <name>.fa        the genomes, as hostremoval_reference names it
#              <name>/          the bowtie2 index, as shortread_hostremoval_index
#                               and kneaddata_db name it
#              <name>.mmi       the minimap2 index, as longread_hostremoval_index
#                               names it
#              manifest.yaml    what went in, from where, and how
# Env:       CODE_DIR, DATA_DIR and the log/fail helpers, from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
source "$CODE_DIR/steps/fetch_files.sh"

[[ $# -eq 2 ]] || fail "Usage: build_host_reference.sh <db path> <out_dir>"
readonly DB=$1
[[ $DB =~ ^hostremoval/([A-Za-z0-9._-]+)/v[0-9]+$ ]] || fail "$DB isn't a host reference's path, hostremoval/<name>/v<n>."
readonly NAME=${BASH_REMATCH[1]}
OUT=$(out_dir_path "$2") || exit 1
# Away from the caller's directory, where fail would write to a run's state.
# The builds run here, so the commands the manifest records name no site path.
cd "$OUT"

ENTRY=$(fetch_entry "$DB") || fail "pipelines/databases.yaml has no database $DB."
SOURCES=$(jq -c '[(.sources // [])[] | .file = (.url | tostring | split("/") | last)]' <<< "$ENTRY")
check_downloads "$SOURCES" "$DB"
BAD=$(jq -r 'first(.[] | select(.accession | tostring | test("^GC[AF]_[0-9]{9}[.][0-9]+$") | not) | .url)' <<< "$SOURCES")
[[ -z $BAD ]] || fail "pipelines/databases.yaml's $DB download $BAD doesn't name an NCBI assembly accession."

THREADS=${SLURM_CPUS_PER_TASK:-$(nproc)}

# Both images before any download, so one that can't be pulled fails in
# minutes rather than after the bowtie2 build
log "Pulling bowtie2 and minimap2..."
BOWTIE2_IMAGE=$(lock_image taxprofiler bowtie2) || exit 1
MINIMAP2_IMAGE=$(lock_image taxprofiler minimap2) || exit 1
container_sif "$BOWTIE2_IMAGE" > /dev/null
container_sif "$MINIMAP2_IMAGE" > /dev/null
BOWTIE2_VERSION=$(container_exec "$BOWTIE2_IMAGE" bowtie2-build --version 2>&1) ||
    fail "bowtie2-build didn't run from $BOWTIE2_IMAGE: $BOWTIE2_VERSION"
BOWTIE2_VERSION=${BOWTIE2_VERSION%%$'\n'*}
MINIMAP2_VERSION=$(container_exec "$MINIMAP2_IMAGE" minimap2 --version 2>&1) ||
    fail "minimap2 didn't run from $MINIMAP2_IMAGE: $MINIMAP2_VERSION"
MINIMAP2_VERSION=${MINIMAP2_VERSION%%$'\n'*}

DOWNLOADS=$OUT/.download
mkdir "$DOWNLOADS"

# 1. Each genome, checked, then appended to the reference
log "Building $DB from $(jq length <<< "$SOURCES") genomes..."
while IFS=$'\t' read -r label url md5 bytes file; do
    log "  $label, $(human_size "$bytes")"
    fetch_checked "$url" "$md5" "$bytes" "$DOWNLOADS/$file"
    gzip -dc "$DOWNLOADS/$file" >> "$NAME.fa" || fail "Couldn't decompress $file."
    rm -f "$DOWNLOADS/$file"
done < <(jq -r '.[] | [.label, .url, .md5, (.bytes | tostring), .file] | @tsv' <<< "$SOURCES")
rm -rf "$DOWNLOADS"

# 2. The bowtie2 index. BOWTIE2_ALIGN finds its name by globbing the directory
#    for *.rev.1.bt2, so the index only has to be alone in one.
mkdir "$NAME"
BOWTIE2_ARGS=(--threads "$THREADS" "$NAME.fa" "$NAME/$NAME")
log "Building the bowtie2 index with $THREADS threads..."
container_exec "$BOWTIE2_IMAGE" bowtie2-build "${BOWTIE2_ARGS[@]}" > bowtie2-build.log 2>&1 ||
    { tail -n 20 bowtie2-build.log >&2; fail "bowtie2-build failed for $DB."; }
rm -f bowtie2-build.log
compgen -G "$NAME/*.rev.1.bt2*" > /dev/null || fail "bowtie2-build wrote no .rev.1.bt2 file for $DB."

# 3. The minimap2 index, for the long-read path
MINIMAP2_ARGS=(-t "$THREADS" -x map-ont -d "$NAME.mmi" "$NAME.fa")
log "Building the minimap2 index..."
container_exec "$MINIMAP2_IMAGE" minimap2 "${MINIMAP2_ARGS[@]}" > minimap2.log 2>&1 ||
    { tail -n 20 minimap2.log >&2; fail "minimap2 failed for $DB."; }
rm -f minimap2.log
[[ -s $NAME.mmi ]] || fail "minimap2 wrote no $NAME.mmi for $DB."

# 4. Record what was built
ABOUT=$(jq -c --argjson sources "$SOURCES" \
    --arg reference_md5 "$(md5sum < "$NAME.fa" | cut -d' ' -f1)" \
    --arg bowtie2_image "$BOWTIE2_IMAGE" --arg bowtie2_version "$BOWTIE2_VERSION" \
    --arg bowtie2_command "bowtie2-build ${BOWTIE2_ARGS[*]}" \
    --arg minimap2_image "$MINIMAP2_IMAGE" --arg minimap2_version "$MINIMAP2_VERSION" \
    --arg minimap2_command "minimap2 ${MINIMAP2_ARGS[*]}" '{
        name, release, doi,
        built_with: "steps/build_host_reference.sh",
        sources: ($sources | map({label, accession, url, md5, bytes})),
        reference_md5: $reference_md5,
        bowtie2: {image: $bowtie2_image, version: $bowtie2_version, command: $bowtie2_command},
        minimap2: {image: $minimap2_image, version: $minimap2_version, command: $minimap2_command}
    }' <<< "$ENTRY")
write_manifest "$OUT" "$DB" "$ABOUT"
log "Built $DB in $OUT."
