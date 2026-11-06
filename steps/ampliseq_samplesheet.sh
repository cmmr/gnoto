#!/bin/bash
#
# ampliseq_samplesheet.sh - Convert the lab samplesheet into nf-core/ampliseq format.
#
# Reads the lab's standard whitespace-delimited samplesheet (sample, fastq_1 and
# optionally fastq_2 per line, no header) and writes ./ampliseq_samplesheet.tsv,
# doing the four things ampliseq won't do for itself:
#
#  - Recompresses .bz2 and uncompressed FASTQ files to .gz, which is all ampliseq reads.
#  - Merges FASTQ files that share a sample name into one file, or one pair of
#    files, since ampliseq requires sample names to be unique.
#  - Renames samples that ampliseq would reject: names must be alphanumeric or
#    underscore, and must not start with a digit.
#  - Names the staged files so that ampliseq accepts them: it refuses an entry
#    whose fastq_1 has the same simple name as the sample plus "_1", which is
#    what naming a file after its sample alone produces.
#
# A line with no fastq_2 is single-end, from a MinION run or single-end Illumina,
# and the fastq_2 column is left off the sheet entirely. ampliseq derives one read
# layout for the whole pipeline, so a run that mixes the two is refused here.
#
# Every sample ends up as exactly one file, or one pair, in ./raw-sequences/,
# named <sample>_reads_1.fq.gz and <sample>_reads_2.fq.gz, and the samplesheet
# points there. The sample name itself is left alone: it's what the requester
# sees throughout the results. Already-gzipped inputs are symlinked, and only
# merged and non-gzip inputs are written out. The deliverables archive includes
# this directory, and zip stores what a symlink points at, so the archive holds
# real data.
#
# Failures here are caused by the requester's samplesheet: fail records the
# explanation as .message in the run's state, and the job reports it to the
# requester.
#
# Usage:     ampliseq_samplesheet.sh [input_samplesheet]
#            defaults to ./original_samplesheet.tsv, the run's copy of the
#            requester's samplesheet
# Called by: the job, from the run directory, as a pre-process step of the
#            ampliseq pipeline
# Requires:  pigz and md5sum, and lbzip2 for .bz2 inputs, from the gnoto image
# Reads:     the samplesheet, and the FASTQ files it names
# Writes:    ./ampliseq_samplesheet.tsv, ./ampliseq_metadata.tsv, ./raw-sequences/,
#            and the sample count and any explanation of a failure in
#            ./run_state.json
# Env:       the log/fail helpers and the run state helpers, from lib/env.sh
#
# The samplesheet is whitespace-delimited, so FASTQ paths can't contain spaces.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

INPUT_SAMPLESHEET="${1:-original_samplesheet.tsv}"
OUT_TSV="ampliseq_samplesheet.tsv"
OUT_METADATA="ampliseq_metadata.tsv"

# The requester's archive directory, which is zipped under this name
FASTQ_DIR="raw-sequences"

# Sits between the sample name and the mate number in every staged file's name,
# so that fastq_1 is never the sample name plus "_1", which ampliseq refuses
FASTQ_INFIX="reads"

[[ -r "$INPUT_SAMPLESHEET" ]] || fail "Samplesheet '$INPUT_SAMPLESHEET' is not readable."

mkdir -p "$FASTQ_DIR"

# Every CPU Slurm gave us, or 1 outside Slurm
THREADS="${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-1}}"

# Decompresses any mix of .bz2, .gz and raw FASTQ inputs into one .gz file,
# streaming throughout so merging large runs never needs scratch space. The
# destination is removed first, because it may be a link to an input left by an
# earlier attempt, and writing through it would overwrite that input.
stream_to_gz() {
    local outfile="$1"
    local file
    shift

    rm -f "$outfile"
    for file in "$@"; do
        if [[ "$file" == *.bz2 ]]; then
            lbzip2 -n "$THREADS" -dc "$file"
        elif [[ "$file" == *.gz ]]; then
            pigz -p "$THREADS" -dc "$file"
        else
            cat "$file"
        fi
    done | pigz -p "$THREADS" -c > "$outfile"
}

# Places one input file at its destination in FASTQ_DIR: gzipped files are
# symlinked, anything else recompressed. The link target must be absolute, since
# the link resolves from inside FASTQ_DIR.
link_or_compress() {
    local src="$1"
    local dest="$2"

    if [[ "$src" == *.gz ]]; then
        ln -sfn "$(readlink -e "$src")" "$dest"
    else
        log "Compressing '$src'..."
        stream_to_gz "$dest" "$src"
    fi
}

# SAMPLE_ORDER keeps the samplesheet's order, which the associative arrays don't.
# The maps hold space-separated file lists per sanitized name.
declare -a SAMPLE_ORDER=()
declare -A SAMPLE_FQ1_MAP=()
declare -A SAMPLE_FQ2_MAP=()

# "paired" or "single", set by the first line that names files and required of
# every line after it. ampliseq_detect_region.sh reads it back from the sheet's
# header.
READ_LAYOUT=""

set_run_stage "Checking your samplesheet and staging the sequencing files."

# 1. Read and validate the samplesheet line by line.
# The || clause picks up a final line that is missing its trailing newline.
line=""
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))

    # Strip carriage returns from Windows-edited sheets and convert the
    # non-breaking spaces that come from pasting out of a spreadsheet
    line=${line//$'\r'/}
    line=${line//$'\xc2\xa0'/ }

    # read splits on whitespace and ignores leading and trailing padding
    read -r sample fq1 fq2 <<< "$line"
    [[ -z "$sample" ]] && continue

    # Skip comment lines and a header row, which a spreadsheet export often has
    [[ "$sample" == \#* ]] && continue
    [[ $line_number -eq 1 && "${sample,,}" == "sample" ]] && continue

    if [[ -z "$fq1" ]]; then
        fail "Invalid line format in samplesheet: '$line'"
    fi

    if [[ -z "$fq2" ]]; then
        line_layout="single"
    else
        line_layout="paired"
    fi

    if [[ -z "$READ_LAYOUT" ]]; then
        READ_LAYOUT="$line_layout"
    elif [[ "$READ_LAYOUT" != "$line_layout" ]]; then
        REASON="Samplesheet line $line_number is $line_layout-end,"
        REASON+=" but the lines before it are $READ_LAYOUT-end."
        REASON+=$'\n'"Every sample in one run has to have the same number of FASTQ files,"
        REASON+=" because ampliseq analyses the whole run one way or the other."
        fail "$REASON"
    fi

    [[ -r "$fq1" ]] || fail "Input FASTQ file '$fq1' does not exist or is not readable."

    if [[ "$READ_LAYOUT" == "paired" ]]; then
        [[ -r "$fq2" ]] || fail "Input FASTQ file '$fq2' does not exist or is not readable."
    fi

    # Sanitize the sample name into what ampliseq accepts
    clean_sample=${sample//[^a-zA-Z0-9_]/_}
    if [[ "$clean_sample" != [a-zA-Z]* ]]; then
        clean_sample="S_$clean_sample"
    fi

    # Group by sanitized name so duplicate samples accumulate for merging.
    # Sanitizing first means names that differ only in punctuation merge too.
    if [[ -z "${SAMPLE_FQ1_MAP[$clean_sample]+set}" ]]; then
        SAMPLE_ORDER+=("$clean_sample")
        SAMPLE_FQ1_MAP["$clean_sample"]="$fq1"
        SAMPLE_FQ2_MAP["$clean_sample"]="$fq2"
    else
        SAMPLE_FQ1_MAP["$clean_sample"]+=" $fq1"
        SAMPLE_FQ2_MAP["$clean_sample"]+=" $fq2"
    fi

done < "$INPUT_SAMPLESHEET"

[[ ${#SAMPLE_ORDER[@]} -gt 0 ]] || fail "No samples found in '$INPUT_SAMPLESHEET'."

# 2. Generate the ampliseq TSV. A single-end run has no fastq_2 column at all,
#    rather than an empty one.
if [[ "$READ_LAYOUT" == "paired" ]]; then
    printf "sample\tfastq_1\tfastq_2\trun\n" > "$OUT_TSV"
else
    printf "sample\tfastq_1\trun\n" > "$OUT_TSV"
fi

# ampliseq skips every QIIME2 diversity step, and the phylogeny with them, unless
# it's given a metadata sheet, and it analyses only the samples that sheet lists.
# The request collects no sample metadata, so the sheet carries the one variable
# this step knows: which sequencing run each sample came off. Two columns is also
# the least ampliseq's metadata_all.r can read: it loops from column 2, and an
# ID-only sheet makes that count backwards.
printf "ID\trun\n" > "$OUT_METADATA"

for clean_sample in "${SAMPLE_ORDER[@]}"; do
    read -ra fq1_list <<< "${SAMPLE_FQ1_MAP[$clean_sample]}"

    num_files=${#fq1_list[@]}

    # Every sample lands at the same predictable path, whether its files were
    # merged, recompressed or linked
    final_fq1="$FASTQ_DIR/${clean_sample}_${FASTQ_INFIX}_1.fq.gz"
    final_fq2="$FASTQ_DIR/${clean_sample}_${FASTQ_INFIX}_2.fq.gz"

    # 2a. Populate the archive directory
    if [[ "$num_files" -gt 1 ]]; then
        log "Merging $num_files duplicate entries for sample '$clean_sample'..."
        stream_to_gz "$final_fq1" "${fq1_list[@]}"
    else
        link_or_compress "${fq1_list[0]}" "$final_fq1"
    fi

    if [[ "$READ_LAYOUT" == "paired" ]]; then
        read -ra fq2_list <<< "${SAMPLE_FQ2_MAP[$clean_sample]}"

        if [[ "$num_files" -gt 1 ]]; then
            stream_to_gz "$final_fq2" "${fq2_list[@]}"
        else
            link_or_compress "${fq2_list[0]}" "$final_fq2"
        fi
    fi

    # 2b. Derive the 'run' ID ampliseq uses to batch samples for error-model
    # training. Samples sequenced together share a source directory, so hashing
    # that directory list groups them, and md5sum shortens it to a safe token.
    # Must read the original paths: every sample shares FASTQ_DIR, so hashing
    # the destinations would collapse every run into one batch.
    dir_concat=""
    for fq in "${fq1_list[@]}"; do
        dir_concat+="$(dirname "$fq");"
    done
    run_hash=$(echo -n "$dir_concat" | md5sum | cut -c1-8)

    if [[ "$READ_LAYOUT" == "paired" ]]; then
        printf "%s\t%s\t%s\t%s\n" "$clean_sample" "$final_fq1" "$final_fq2" "run_$run_hash" >> "$OUT_TSV"
    else
        printf "%s\t%s\t%s\n" "$clean_sample" "$final_fq1" "run_$run_hash" >> "$OUT_TSV"
    fi

    printf "%s\t%s\n" "$clean_sample" "run_$run_hash" >> "$OUT_METADATA"
done

# The count after merging, which is the number of samples the run analyses. The
# results page shows it in its header, and leaves it out when it wasn't recorded.
state_set_number samples.count "${#SAMPLE_ORDER[@]}"

log "Successfully generated ampliseq samplesheet: $OUT_TSV and $OUT_METADATA (${#SAMPLE_ORDER[@]} $READ_LAYOUT-end samples)"
