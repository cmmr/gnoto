#!/bin/bash
#
# taxprofiler_samplesheet.sh - Convert the lab samplesheet into nf-core/taxprofiler format.
#
# Reads the lab's standard whitespace-delimited samplesheet and writes
# ./taxprofiler_samplesheet.csv with the six columns taxprofiler requires:
# sample, run_accession, instrument_platform, fastq_1, fastq_2, fasta.
#
# Input lines are "sample fastq_1 fastq_2" for paired reads or "sample fastq_1"
# for single-end. A sample's runs must all be one or the other, as taxprofiler's
# own cross-row check requires.
#
# Lines sharing a sample name become separate rows, numbered run_1, run_2 and so
# on. The pipeline sets perform_runmerging, so taxprofiler concatenates a
# sample's runs itself after per-run QC and host removal. Without it, each run
# would be profiled separately.
#
# taxprofiler reads gzipped FASTQ only, so every read ends up in ./raw-sequences/
# as <sample>_<run>_{1,2}.fq.gz: gzipped inputs are symlinked, and .bz2 and plain
# FASTQ recompressed. The deliverables archive includes that directory, and zip
# stores what a symlink points at, so the archive holds real data.
#
# instrument_platform is measured from read length, because taxprofiler uses it
# only to choose between the short-read and long-read paths. Reads longer than
# LONG_READ_THRESHOLD are called OXFORD_NANOPORE and everything else ILLUMINA.
# Setting INSTRUMENT_PLATFORM in the environment overrides the measurement, e.g.
# for PACBIO_SMRT.
#
# It also writes ./taxprofiler_database.csv, the run's copy of the database
# sheet, with its db: names resolved to paths, because taxprofiler reads it, and
# with Bracken's read length set from the data. Bracken's -r must name a
# databaseNNNmers.kmer_distrib the Kraken2 database carries, and the right one
# depends on the reads.
#
# Failures here are caused by the requester's samplesheet: fail records the
# explanation as .message in the run's state, and the job reports it to the
# requester.
#
# Usage:     taxprofiler_samplesheet.sh [input_samplesheet]
#            defaults to ./original_samplesheet.tsv, the run's copy of the
#            requester's samplesheet
# Called by: the job, from the run directory, as the taxprofiler pipeline's
#            pre-process step; and steps/biobakery_samplesheet.sh
# Requires:  pigz, awk, sort and uniq, and lbzip2 for .bz2 inputs
# Reads:     pipelines/taxprofiler/database.csv, the database sheet it specializes
# Writes:    ./taxprofiler_samplesheet.csv, ./taxprofiler_database.csv,
#            ./raw-sequences/, and the sample count, the measured read length,
#            the platform and any explanation of a failure in ./run_state.json
# Env:       CODE_DIR, DB_DIR, the log/warn/fail helpers, the run state helpers
#            and db_path, from lib/env.sh; INSTRUMENT_PLATFORM, optionally, to
#            override the measurement
#
# The samplesheet is whitespace-delimited, so FASTQ paths can't contain spaces.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

INPUT_SAMPLESHEET="${1:-original_samplesheet.tsv}"
OUT_CSV="taxprofiler_samplesheet.csv"

# The database sheet the pipeline names, written per run, and the one it is
# derived from
OUT_DB_SHEET="taxprofiler_database.csv"
STATIC_DB_SHEET="$CODE_DIR/pipelines/taxprofiler/database.csv"

# Reads per file to sample when measuring read length
READ_LENGTH_SAMPLE=10000

# Median read length above which a run is treated as long-read. No Illumina
# instrument reaches 1000bp, and nanopore and PacBio runs are far above it.
LONG_READ_THRESHOLD=1000

# How far the nearest Bracken distribution may sit from the measured read length
# before it's worth a warning, as a percentage of that length: 15bp off matters
# at 35bp and not at 250bp.
READ_LENGTH_TOLERANCE_PCT=15

# Client-facing archive directory. The deliverables archive takes it by this name.
FASTQ_DIR="raw-sequences"

for tool in pigz awk sort uniq; do
    command -v "$tool" > /dev/null || fail "Required tool '$tool' is not installed."
done

[[ -r "$INPUT_SAMPLESHEET" ]] || fail "Samplesheet '$INPUT_SAMPLESHEET' is not readable."

mkdir -p "$FASTQ_DIR"

THREADS="${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-1}}"

# Decompress one .bz2 or plain FASTQ into a .gz, streaming throughout
to_gz() {
    local src="$1"
    local outfile="$2"

    log "Compressing '$src'..."
    if [[ "$src" == *.bz2 ]]; then
        lbzip2 -n "$THREADS" -dc "$src"
    else
        cat "$src"
    fi | pigz -p "$THREADS" -c > "$outfile"
}

# Place one input file at its destination in FASTQ_DIR and set STAGED_PATH to it:
# gzipped files are symlinked, anything else recompressed. The link target must
# be absolute, since the link resolves from inside FASTQ_DIR.
#
# Sets STAGED_PATH rather than printing it. set -e does not reach a function
# called inside a command substitution, so a failed recompression there would
# leave an empty file and carry on.
stage_read() {
    local src="$1"
    local dest="$FASTQ_DIR/$2"

    if [[ "$src" == *.gz ]]; then
        ln -sfn "$(readlink -e "$src")" "$dest"
    else
        to_gz "$src" "$dest"
    fi

    STAGED_PATH="$PWD/$dest"
}

# Modal and median read length across the staged R1 files, as "mode median".
# The mode picks Bracken's distribution, which suits the fixed-length reads that
# use it. The median decides the platform, being the more stable of the two
# across the long tail of a nanopore run.
#
# awk exits once it has seen enough of a file, which closes the pipe on pigz, so
# its status is discarded.
read_length_stats() {
    local file

    for file in "$@"; do
        { pigz -dc "$file" 2> /dev/null || true; } \
            | awk -v n="$READ_LENGTH_SAMPLE" 'NR % 4 == 2 { print length; if (++seen >= n) exit }'
    done | sort -n | uniq -c | awk '
        {
            count[NR] = $1
            value[NR] = $2
            total += $1
            if ($1 > best) {
                best = $1
                mode = $2
            }
        }
        END {
            if (NR == 0) exit
            for (i = 1; i <= NR; i++) {
                seen += count[i]
                if (seen >= total / 2) {
                    median = value[i]
                    break
                }
            }
            print mode, median
        }'
}

# The read length of the closest databaseNNNmers.kmer_distrib in a Kraken2
# database directory
nearest_distrib() {
    local db_path="$1"
    local target="$2"
    local file base len gap best="" best_gap=""

    for file in "$db_path"/database*mers.kmer_distrib; do
        [[ -r "$file" ]] || continue

        base=${file##*/}
        len=${base#database}
        len=${len%mers.kmer_distrib}
        [[ "$len" =~ ^[0-9]+$ ]] || continue

        gap=$(( len > target ? len - target : target - len ))
        if [[ -z "$best_gap" || "$gap" -lt "$best_gap" ]]; then
            best_gap="$gap"
            best="$len"
        fi
    done

    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

# Prints one column of the static database sheet, located by its header name:
# every row, or with a tool name, only that tool's first row
database_column() {
    local column="$1" tool="${2:-}"

    awk -F, -v column="$column" -v tool="$tool" '
        NR == 1 { for (i = 1; i <= NF; i++) idx[$i] = i; next }
        NF < 2 || !idx[column] { next }
        tool == "" { print $idx[column]; next }
        idx["tool"] && $idx["tool"] == tool { print $idx[column]; exit }
    ' "$STATIC_DB_SHEET"
}

# Copy the static database sheet with each db: name in its db_path column
# resolved, and, given a read length, the bracken row's -r set to it. Columns are
# located by header name. Anything before the semicolon in db_params is
# kraken2's and is left alone.
write_database_sheet() {
    local length="${1:-}" name path resolved=""

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        path=$(db_path "$name") || exit 1
        resolved+="$name"$'\t'"$path"$'\n'
    done < <(database_column db_path)

    # Through the environment, so awk -v does not read backslashes as escapes
    DB_PATHS="$resolved" awk -F, -v OFS=, -v len="$length" '
        BEGIN {
            n = split(ENVIRON["DB_PATHS"], pairs, "\n")
            for (i = 1; i <= n; i++) {
                tab = index(pairs[i], "\t")
                if (tab) resolved[substr(pairs[i], 1, tab - 1)] = substr(pairs[i], tab + 1)
            }
        }
        NR == 1 {
            for (i = 1; i <= NF; i++) idx[$i] = i
            print
            next
        }
        NF < 2 { next }
        {
            if (idx["db_path"] && ($idx["db_path"] in resolved)) {
                $idx["db_path"] = resolved[$idx["db_path"]]
            }

            if (len != "" && idx["tool"] && $idx["tool"] == "bracken") {
                params = $idx["db_params"]
                semi = index(params, ";")
                kraken = semi ? substr(params, 1, semi - 1) : params
                bracken = semi ? substr(params, semi + 1) : ""

                gsub(/(^| )-r +[0-9]+/, "", bracken)
                gsub(/^ +| +$/, "", bracken)

                $idx["db_params"] = kraken ";-r " len (bracken == "" ? "" : " " bracken)
            }
            print
        }
    ' "$STATIC_DB_SHEET"
}

# Rows in samplesheet order. RUN_COUNT numbers the runs within each sample, and
# SAMPLE_LAYOUT records whether a sample is paired, so its runs can be checked
# against each other.
declare -a ROW_SAMPLE=() ROW_FQ1=() ROW_FQ2=()
declare -A RUN_COUNT=() SAMPLE_LAYOUT=()

# Staged files, in row order. STAGED_R2 holds an empty string for single-end rows.
declare -a STAGED_R1=() STAGED_R2=()

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

    # A fourth field would silently vanish into fq2, so catch it
    read -r sample fq1 fq2 extra <<< "$line"
    [[ -z "$sample" ]] && continue

    [[ "$sample" == \#* ]] && continue
    [[ $line_number -eq 1 && "${sample,,}" == "sample" ]] && continue

    if [[ -z "$fq1" ]]; then
        fail "Samplesheet line $line_number names no FASTQ file: '$line'"
    fi

    if [[ -n "$extra" ]]; then
        fail "Samplesheet line $line_number has more than three columns: '$line'"
    fi

    if [[ "$fq1" == *.bz2 || "$fq2" == *.bz2 ]]; then
        command -v lbzip2 > /dev/null \
            || fail "Samplesheet line $line_number has bzip2 inputs, but lbzip2 is not installed."
    fi

    [[ -r "$fq1" ]] || fail "Input FASTQ file '$fq1' does not exist or is not readable."
    if [[ -n "$fq2" ]]; then
        [[ -r "$fq2" ]] || fail "Input FASTQ file '$fq2' does not exist or is not readable."
    fi

    # The samplesheet is a CSV, so an unquoted comma in a path would split a field
    if [[ "$fq1" == *,* || "$fq2" == *,* ]]; then
        fail "Input FASTQ paths may not contain commas: '$line'"
    fi

    # The name becomes part of file names that reach unquoted shell code in the
    # nf-core modules, so it keeps only characters that are safe there
    clean_sample=${sample//[^A-Za-z0-9._-]/_}

    # A leading dash reads as an option to whatever the name is handed to
    [[ "$clean_sample" == -* ]] && clean_sample="_$clean_sample"

    if [[ "$clean_sample" != "$sample" ]]; then
        log "Renamed sample '$sample' to '$clean_sample'."
    fi

    # taxprofiler rejects a sample whose runs disagree, so say so here instead
    layout="single"
    [[ -n "$fq2" ]] && layout="paired"

    if [[ -n "${SAMPLE_LAYOUT[$clean_sample]:-}" && "${SAMPLE_LAYOUT[$clean_sample]}" != "$layout" ]]; then
        fail "Sample '$clean_sample' mixes paired and single-end runs; taxprofiler needs one or the other."
    fi
    SAMPLE_LAYOUT["$clean_sample"]="$layout"

    ROW_SAMPLE+=("$clean_sample")
    ROW_FQ1+=("$fq1")
    ROW_FQ2+=("$fq2")

done < "$INPUT_SAMPLESHEET"

[[ ${#ROW_SAMPLE[@]} -gt 0 ]] || fail "No samples found in '$INPUT_SAMPLESHEET'."

# 2. Stage every read into FASTQ_DIR. Done before the CSV is written because the
#    platform column is measured from the staged files.
declare -a ROW_RUN=()

for i in "${!ROW_SAMPLE[@]}"; do
    sample=${ROW_SAMPLE[$i]}

    RUN_COUNT[$sample]=$(( ${RUN_COUNT[$sample]:-0} + 1 ))
    run="run_${RUN_COUNT[$sample]}"
    ROW_RUN+=("$run")

    stage_read "${ROW_FQ1[$i]}" "${sample}_${run}_1.fq.gz"
    STAGED_R1+=("$STAGED_PATH")

    if [[ -n "${ROW_FQ2[$i]}" ]]; then
        stage_read "${ROW_FQ2[$i]}" "${sample}_${run}_2.fq.gz"
        STAGED_R2+=("$STAGED_PATH")
    else
        STAGED_R2+=("")
    fi
done

# 3. Measure the reads, which decides both the platform and Bracken's -r.
READ_STATS=$(read_length_stats "${STAGED_R1[@]}") || READ_STATS=""
read -r READ_MODE READ_MEDIAN <<< "$READ_STATS"

if [[ -z "${READ_MEDIAN:-}" ]]; then
    warn "Could not measure a read length; assuming ILLUMINA."
    READ_MODE=""
    READ_MEDIAN=0
else
    state_set_number samples.read_length "$READ_MODE"
fi

if [[ -n "${INSTRUMENT_PLATFORM:-}" ]]; then
    log "instrument_platform pinned to $INSTRUMENT_PLATFORM; skipping detection."
elif [[ "$READ_MEDIAN" -gt "$LONG_READ_THRESHOLD" ]]; then
    INSTRUMENT_PLATFORM="OXFORD_NANOPORE"
    log "Median read length is ${READ_MEDIAN}bp; treating this run as $INSTRUMENT_PLATFORM."
else
    INSTRUMENT_PLATFORM="ILLUMINA"
    log "Median read length is ${READ_MEDIAN}bp; treating this run as $INSTRUMENT_PLATFORM."
fi

# Recorded as well as written into the CSV, because the dashboard heads the read
# totals with it and the samplesheet isn't published
state_set samples.platform "$INSTRUMENT_PLATFORM"

# taxprofiler rejects a long-read row that names a second FASTQ, and paired long
# reads don't exist, so this is a mislabelled or mis-built samplesheet
if [[ "$INSTRUMENT_PLATFORM" == "OXFORD_NANOPORE" || "$INSTRUMENT_PLATFORM" == "PACBIO_SMRT" ]]; then
    for i in "${!ROW_SAMPLE[@]}"; do
        if [[ -n "${ROW_FQ2[$i]}" ]]; then
            REASON="These reads are long (median ${READ_MEDIAN}bp), but sample"
            REASON+=" '${ROW_SAMPLE[$i]}' names two FASTQ files."
            REASON+=" Long-read samples take one file per line."
            fail "$REASON"
        fi
    done
fi

# 4. Generate the taxprofiler CSV. fastq_2 is empty for single-end rows and the
#    fasta column is always empty.
printf 'sample,run_accession,instrument_platform,fastq_1,fastq_2,fasta\n' > "$OUT_CSV"

for i in "${!ROW_SAMPLE[@]}"; do
    printf '%s,%s,%s,%s,%s,\n' \
        "${ROW_SAMPLE[$i]}" "${ROW_RUN[$i]}" "$INSTRUMENT_PLATFORM" \
        "${STAGED_R1[$i]}" "${STAGED_R2[$i]}" >> "$OUT_CSV"
done

# Distinct samples, not rows: a sample sequenced over several runs is one sample
SAMPLE_COUNT=${#RUN_COUNT[@]}
state_set_number samples.count "$SAMPLE_COUNT"

log "Successfully generated taxprofiler samplesheet: $OUT_CSV ($SAMPLE_COUNT samples, ${#ROW_SAMPLE[@]} runs)"

# 5. Specialize the database sheet to these reads. Bracken's -r must name a
#    distribution the Kraken2 database ships, and a mismatch silently biases its
#    abundance estimates.
#
#    Every failure to measure or match falls back to the sheet as written: a run
#    is still worth doing with Bracken's recorded default.
[[ -r "$STATIC_DB_SHEET" ]] || fail "The database sheet '$STATIC_DB_SHEET' is not readable."

if [[ -z "$READ_MODE" ]]; then
    warn "No read length measured; using the database sheet as written."
    write_database_sheet > "$OUT_DB_SHEET"
elif [[ "$INSTRUMENT_PLATFORM" != "ILLUMINA" ]]; then
    # taxprofiler skips Bracken on long reads, so there is nothing to tune
    log "Long-read run; Bracken does not apply and the database sheet is used as written."
    write_database_sheet > "$OUT_DB_SHEET"
else
    # The bracken row names the Kraken2 database it reads its distributions from
    BRACKEN_DB=$(database_column db_path bracken)
    if [[ -n "$BRACKEN_DB" ]]; then
        BRACKEN_DB=$(db_path "$BRACKEN_DB") || exit 1
    fi

    if [[ -z "$BRACKEN_DB" ]]; then
        log "No bracken row in the database sheet; using it as written."
        write_database_sheet > "$OUT_DB_SHEET"
    elif ! DISTRIB=$(nearest_distrib "$BRACKEN_DB" "$READ_MODE"); then
        warn "No databaseNNNmers.kmer_distrib in '$BRACKEN_DB'; using the database sheet as written."
        write_database_sheet > "$OUT_DB_SHEET"
    else
        GAP=$(( DISTRIB > READ_MODE ? DISTRIB - READ_MODE : READ_MODE - DISTRIB ))
        if (( GAP * 100 > READ_LENGTH_TOLERANCE_PCT * READ_MODE )); then
            warn "Reads are ${READ_MODE}bp but the closest Bracken distribution is ${DISTRIB}bp;"
            warn "abundance estimates may be biased. Build a ${READ_MODE}mer distribution to fix this."
        fi

        write_database_sheet "$DISTRIB" > "$OUT_DB_SHEET"
        log "Reads are ${READ_MODE}bp; Bracken set to -r $DISTRIB in $OUT_DB_SHEET"
    fi
fi
