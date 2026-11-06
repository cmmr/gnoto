#!/bin/bash
#
# biobakery_disk_check.sh - Refuse a biobakery run the disk cannot hold.
#
# Estimates the disk a biobakery run will take from the read files its
# samplesheet names, and fails before anything is staged unless both
# filesystems it writes to have that much free, or their sum when they are one:
#
#   the run directory  reads recompressed into raw-sequences/, the reads host
#                      depletion keeps, KneadData's working space for every
#                      sample at once, and the cleaned reads KneadData leaves
#                      for the steps after it. HUMAnN works on those cleaned
#                      reads and needs less room per read than KneadData, so
#                      the same room covers it.
#   GLOBUS_DIR         the download, which holds each read set the
#                      delivered_reads answer names
#
# The host-depleted and cleaned reads are each taken at the reads' gzipped
# size, which is what they come to when little is removed.
#
# A file's uncompressed size is estimated from how far its first 16 MB
# decompress. Files the samplesheet step will refuse are left to it to report.
#
# Usage:     biobakery_disk_check.sh [input_samplesheet]
#            defaults to ./original_samplesheet.tsv, the run's copy of the
#            requester's samplesheet
# Called by: steps/biobakery_samplesheet.sh, from the run directory, before it
#            stages anything
# Requires:  gzip, awk, df and stat, and lbzip2 for .bz2 inputs
# Writes:    an explanation of a failure in ./run_state.json
# Env:       GLOBUS_DIR, the log/warn/fail helpers and form_answer_includes,
#            from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

INPUT_SAMPLESHEET="${1:-original_samplesheet.tsv}"

# KneadData's peak disk per byte of a sample's uncompressed reads: 4.9 measured
# on reads it barely trims, with a margin
KNEADDATA_FACTOR=5.5

# How many times over gzip shrinks FASTQ, at the least. Sizes the reads that
# are recompressed into raw-sequences/ and KneadData's cleaned reads.
GZIP_RATIO=3

# Compressed bytes read from the start of each file to estimate its size
SAMPLE_BYTES=16777216

# How many read sets the download carries, each about the size of the reads
DELIVERED_SETS=0

for READ_SET in "Raw" "Host Depleted" "Cleaned"; do
    if form_answer_includes delivered_reads "$READ_SET"; then
        DELIVERED_SETS=$((DELIVERED_SETS + 1))
    fi
done

[[ -r "$INPUT_SAMPLESHEET" ]] || exit 0

# The read files, by the rules taxprofiler_samplesheet.sh reads the sheet with
FILES=()
line_number=0

while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))

    line=${line//$'\r'/}
    line=${line//$'\xc2\xa0'/ }

    read -r sample fq1 fq2 _ <<< "$line"

    [[ -z "$sample" || "$sample" == \#* ]] && continue
    [[ $line_number -eq 1 && "${sample,,}" == "sample" ]] && continue

    for file in "$fq1" "$fq2"; do
        [[ -n "$file" && -r "$file" ]] && FILES+=("$file")
    done
done < "$INPUT_SAMPLESHEET"

[[ ${#FILES[@]} -gt 0 ]] || exit 0

# One line per file: "gz", "bz2" or "fastq", its size, and its uncompressed
# size, both in bytes. A file that decompresses to nothing is taken at 4 to 1.
measure() {
    local file="$1" kind size part out

    size=$(stat -L -c %s "$file")

    case "$file" in
        *.gz)  kind=gz ;;
        *.bz2) kind=bz2 ;;
        *)     printf 'fastq %s %s\n' "$size" "$size"; return ;;
    esac

    part=$(( size < SAMPLE_BYTES ? size : SAMPLE_BYTES ))

    if [[ $kind == gz ]]; then
        out=$({ head -c "$part" "$file" || true; } | { gzip -dc 2> /dev/null || true; } | wc -c)
    else
        out=$({ head -c "$part" "$file" || true; } | { lbzip2 -dc 2> /dev/null || true; } | wc -c)
    fi

    awk -v kind=$kind -v size="$size" -v part="$part" -v out="$out" \
        'BEGIN { printf "%s %s %.0f\n", kind, size, (out > 0 ? size * out / part : size * 4) }'
}

# KB of reads uncompressed, needed in the run directory, and needed for the download
read -r READS_KB RUN_KB DOWNLOAD_KB < <(
    for file in "${FILES[@]}"; do
        measure "$file"
    done | awk -v factor=$KNEADDATA_FACTOR -v ratio=$GZIP_RATIO -v sets=$DELIVERED_SETS '
        {
            gz = $1 == "gz" ? $2 : $3 / ratio

            reads += $3
            work += $3 * factor + 2 * gz
            if ($1 != "gz") staged += gz
            download += gz * sets
        }
        END { printf "%.0f %.0f %.0f\n", reads / 1024, (work + staged) / 1024, download / 1024 }'
)

size_text() {
    awk -v kb="$1" 'BEGIN {
        if (kb >= 1073741824) printf "%.2f TB", kb / 1073741824
        else if (kb >= 1048576) printf "%.1f GB", kb / 1048576
        else printf "%.0f MB", kb / 1024
    }'
}

# A filesystem's mount point and its free KB, as "mount free"
filesystem() {
    df -Pk "$1" | awk 'NR == 2 { print $6, $4 }'
}

read -r RUN_MOUNT RUN_FREE_KB < <(filesystem "$PWD")

DOWNLOAD_MOUNT=""
DOWNLOAD_FREE_KB=0

if [[ -n "${GLOBUS_DIR:-}" ]] && ! read -r DOWNLOAD_MOUNT DOWNLOAD_FREE_KB < <(filesystem "$GLOBUS_DIR" 2> /dev/null); then
    warn "Could not read the free space under $GLOBUS_DIR; the download is not counted."
    DOWNLOAD_MOUNT=""
fi

SUMMARY="${#FILES[@]} read files come to about $(size_text "$READS_KB") uncompressed."
SUMMARY+=" The run needs about $(size_text "$RUN_KB") in $RUN_MOUNT, which has $(size_text "$RUN_FREE_KB") free"

if [[ -n "$DOWNLOAD_MOUNT" ]]; then
    SUMMARY+=", and $(size_text "$DOWNLOAD_KB") for the download in $DOWNLOAD_MOUNT,"
    SUMMARY+=" which has $(size_text "$DOWNLOAD_FREE_KB") free"
fi

log "$SUMMARY."

SHORT=()

if [[ "$DOWNLOAD_MOUNT" == "$RUN_MOUNT" ]]; then
    NEEDED_KB=$(( RUN_KB + DOWNLOAD_KB ))

    if (( RUN_FREE_KB < NEEDED_KB )); then
        SHORT+=("about $(size_text "$NEEDED_KB") in $RUN_MOUNT for the run and its download, which has $(size_text "$RUN_FREE_KB") free")
    fi
else
    if (( RUN_FREE_KB < RUN_KB )); then
        SHORT+=("about $(size_text "$RUN_KB") in $RUN_MOUNT, which has $(size_text "$RUN_FREE_KB") free")
    fi

    if [[ -n "$DOWNLOAD_MOUNT" ]] && (( DOWNLOAD_FREE_KB < DOWNLOAD_KB )); then
        SHORT+=("about $(size_text "$DOWNLOAD_KB") for the download in $DOWNLOAD_MOUNT, which has $(size_text "$DOWNLOAD_FREE_KB") free")
    fi
fi

if [[ ${#SHORT[@]} -gt 0 ]]; then
    REASON="The cluster does not have the disk space for this run: it needs ${SHORT[0]}"
    [[ ${#SHORT[@]} -gt 1 ]] && REASON+=", and ${SHORT[1]}"
    REASON+=". Nothing has been staged, and the run can be resubmitted once space is freed."

    fail "$REASON"
fi
