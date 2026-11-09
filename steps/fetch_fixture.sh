#!/bin/bash
#
# fetch_fixture.sh - Fetches a test fixture that's made from its downloads
# rather than used as they are: a shotgun fixture, cut to its first 100,000
# reads, and 16s-v5v6, converted from NCBI's .sra file.
#
# Every download is checked against the md5 and size pipelines/databases.yaml
# records before anything reads it. Each of a shotgun fixture's files is cut to
# its first 100,000 reads, so both mates of a pair stay in step, and wgs-ont,
# which has fewer, is kept whole. 16s-v5v6 goes through fasterq-dump, in the
# sra-tools image ampliseq's lock.yaml pins. Every FASTQ is then recompressed
# with gzip -n, which leaves out the file's name and time, so a fixture is the
# same bytes, and has the same tree digest, wherever it's made.
#
# Usage:     fetch_fixture.sh <db path> <out_dir>
#            <db path> is fixtures/<name>/v1, for a wgs-* fixture or 16s-v5v6
# Called by: the database fetch job, as the setup lib/databases.sh gives these
#            fixtures, with <out_dir> appended. <out_dir> is an empty directory
#            the job made. On success the job renames it into place and moves
#            manifest.yaml beside it, as <db path>.manifest.yaml. On failure it
#            removes it.
# Requires:  curl, md5sum, gzip, head, yq and jq, from the gnoto image; for
#            16s-v5v6, fasterq-dump from the image ampliseq's lock.yaml pins
# Reads:     pipelines/databases.yaml
# Writes:    into <out_dir>, each FASTQ as <download's name>.fastq.gz, and
#            manifest.yaml
# Env:       CODE_DIR and the log/fail helpers, from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
source "$CODE_DIR/steps/fetch_files.sh"

FIXTURE_READS=100000

[[ $# -eq 2 ]] || fail "Usage: fetch_fixture.sh <db path> <out_dir>"
readonly DB=$1
[[ $DB =~ ^fixtures/(wgs-[a-z0-9-]+|16s-v5v6)/v1$ ]] || fail "$DB isn't a fixture fetch_fixture.sh makes."
readonly NAME=${BASH_REMATCH[1]}
OUT=$(out_dir_path "$2") || exit 1
# Away from the caller's directory, where fail would write to a run's state
cd "$OUT"

ENTRY=$(fetch_entry "$DB") || fail "pipelines/databases.yaml has no fixture $DB."
DOWNLOADS=$(jq -c '[.files[] | .file = (.file // (.url | tostring | sub("[?#].*$"; "") | split("/") | last))]' <<< "$ENTRY")
check_downloads "$DOWNLOADS" "$DB"

# 1. The downloads, each checked, into a directory of their own
mkdir .download
log "Fetching $DB: $(jq length <<< "$DOWNLOADS") files, $(human_size "$(jq 'map(.bytes) | add' <<< "$DOWNLOADS")")..."
while IFS=$'\t' read -r url md5 bytes file; do
    log "  $file"
    fetch_checked "$url" "$md5" "$bytes" ".download/$file"
done < <(jq -r '.[] | [.url, .md5, (.bytes | tostring), .file] | @tsv' <<< "$DOWNLOADS")

# 2. The FASTQ files
if [[ $NAME == wgs-* ]]; then
    HOW="each file cut to its first $((FIXTURE_READS * 4)) lines, $FIXTURE_READS reads, and recompressed with gzip -n"
    while IFS= read -r file; do
        log "Cutting $file to its first $FIXTURE_READS reads..."
        # awk reads to the end, so gzip never meets a closed pipe
        gzip -dc ".download/$file" | awk -v lines=$((FIXTURE_READS * 4)) 'NR <= lines' | gzip -n > "$file.part" ||
            fail "Couldn't cut $file from $DB."
        mv "$file.part" "$file"
    done < <(jq -r '.[].file' <<< "$DOWNLOADS")
    TOOL=null
else
    SRA_IMAGE=$(lock_image ampliseq sra_tools) || exit 1
    container_sif "$SRA_IMAGE" > /dev/null
    VERSION=$(container_exec "$SRA_IMAGE" fasterq-dump --version 2>&1) ||
        fail "fasterq-dump didn't run from $SRA_IMAGE: $VERSION"
    VERSION=$(grep -o '[0-9][0-9.]*[0-9]' <<< "$VERSION" | head -1)
    FILE=$(jq -r '.[0].file' <<< "$DOWNLOADS")
    ARGS=(--split-files --threads 1 --outdir .fastq ".download/$FILE")
    log "Converting $FILE with fasterq-dump $VERSION..."
    container_exec "$SRA_IMAGE" fasterq-dump "${ARGS[@]}" > fasterq-dump.log 2>&1 ||
        { tail -n 20 fasterq-dump.log >&2; fail "fasterq-dump failed for $DB."; }
    rm -f fasterq-dump.log
    for fastq in .fastq/*.fastq; do
        [[ -s $fastq ]] || fail "fasterq-dump wrote no FASTQ for $DB."
        gzip -n < "$fastq" > "${fastq##*/}.gz.part" || fail "Couldn't compress ${fastq##*/} for $DB."
        mv "${fastq##*/}.gz.part" "${fastq##*/}.gz"
    done
    rm -rf .fastq
    HOW="converted with fasterq-dump ${ARGS[*]}, and compressed with gzip -n"
    TOOL=$(jq -cn --arg image "$SRA_IMAGE" --arg version "$VERSION" '{image: $image, version: $version}')
fi
rm -rf .download

# 3. Each file holds whole FASTQ records, and a pair's mates the same number
COUNTS=""
for fastq in *.fastq.gz; do
    LINES=$(gzip -dc "$fastq" | wc -l)
    (( LINES > 0 && LINES % 4 == 0 )) || fail "$fastq, made for $DB, has $LINES lines, which isn't whole FASTQ records."
    COUNTS+="$fastq $((LINES / 4))"$'\n'
done
if [[ $(grep -c '_[12]\.fastq\.gz ' <<< "$COUNTS") -eq 2 ]]; then
    [[ $(grep '_[12]\.fastq\.gz ' <<< "$COUNTS" | cut -d' ' -f2 | sort -u | wc -l) -eq 1 ]] ||
        fail "The two mates made for $DB hold different numbers of reads: $(paste -sd ' ' <<< "$COUNTS")"
fi

ABOUT=$(jq -c --argjson sources "$DOWNLOADS" --arg how "$HOW" --argjson tool "$TOOL" \
    --argjson reads "$(awk 'NF == 2 { printf "%s{\"file\":\"%s\",\"reads\":%d}", (n++ ? "," : "["), $1, $2 } END { print (n ? "]" : "[]") }' <<< "$COUNTS")" '{
        built_with: "steps/fetch_fixture.sh",
        sources: ($sources | map({file, url, md5, bytes})),
        made: $how,
        fasterq_dump: $tool,
        reads: $reads
    }' <<< "$ENTRY")
write_manifest "$OUT" "$DB" "$ABOUT"
log "Made $DB in $OUT."
