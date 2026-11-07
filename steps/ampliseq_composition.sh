#!/bin/bash
#
# ampliseq_composition.sh - Work out what a 16S run found, for the dashboard to plot.
#
# What a requester wants out of a 16S run is usually two things: what was in each
# sample, and how varied each sample was. Both are worked out from the run's own
# feature table, which is assembled here rather than taken from the pipeline.
#
# steps/R/ampliseq_tables.R does that work, in the gnoto-rbiom image. It reads
# what DADA2 published (counts, taxonomy and sequences) and the phylogeny EPA-NG
# placed those ASVs on, assembles them into one object, and writes:
#
#   feature_table/         the same table as classic TSV, BIOM 1.0 and BIOM 2.1
#   abundance_tables/      counts and sample shares collapsed to each rank
#   alpha_diversity.tsv    per-sample diversity, unrarefied
#   composition_data.json  what the Overview's two charts draw
#
# so the file a requester downloads and the numbers on the page are the same
# object read twice.
#
# What's left here is what doesn't come out of the feature table. The read
# totals are counted off overall_summary.tsv, the only place the reads that went
# in are written down, and the chemistry off what FastQC measured. Both go into
# the "statistics" of ./run_state.json beside the counts the R script returns.
#
# Nothing is rarefied, and no group is compared against another: these runs
# carry no experimental metadata to compare by. The read depth every index was
# computed at is published beside it.
#
# A feature table that can't be assembled fails the run, because it's a core
# result, as does a missing rbiom image. A missing summary or plot data only
# leaves the Overview with less to show.
#
# Usage:     ampliseq_composition.sh [results_dir]
#            defaults to ./results, the outdir in the ampliseq params file
# Called by: the job's Compute stage, from the run directory, after Nextflow and
#            the post-process steps
# Requires:  GNU awk, and the rbiom image pipelines/ampliseq/lock.yaml pins
# Reads:     <results_dir>/, ./ampliseq_samplesheet.tsv, and params.exclude_taxa
#            and params.sequencing_type in ./run_state.json
# Writes:    <results_dir>/feature_table/, <results_dir>/abundance_tables/,
#            <results_dir>/alpha_diversity.tsv, ./composition_data.json, and the
#            "statistics" of ./run_state.json
# Env:       the log, warn and fail helpers, the run state helpers, lock_image
#            and container_exec, from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

RESULTS_DIR=${1:-results}
[[ -d "$RESULTS_DIR" ]] || fail "There's no $RESULTS_DIR directory to summarise."

# Absolute, because the R script reads it inside a container
RESULTS_DIR=$(cd "$RESULTS_DIR" && pwd)

readonly R_DIR="$CODE_DIR/steps/R"
readonly TABLES_SCRIPT="$R_DIR/ampliseq_tables.R"

# Reads surviving each stage of the pipeline, one row per sample
readonly OVERALL_SUMMARY="$RESULTS_DIR/overall_summary.tsv"

# What FastQC measured off each raw FASTQ, as MultiQC tabulated it. The zips
# FastQC wrote are pruned from the results, and this table isn't.
readonly FASTQC_TABLE="$RESULTS_DIR/multiqc/multiqc_data/multiqc_fastqc.txt"

readonly SAMPLESHEET="ampliseq_samplesheet.tsv"
readonly ALPHA_TABLE="$RESULTS_DIR/alpha_diversity.tsv"

# The Overview's own data, in the run directory rather than the results. Every
# number in it comes from a table that is published.
readonly PLOT_DATA="$PWD/composition_data.json"

readonly STATS_KEY="statistics"

# The columns of the summary the sidebar breaks the read total down by. Which of
# them a run wrote depends on its path: chopper and savont are the nanopore
# route, DADA2's four the Illumina one, cutadapt either. They're reported in the
# order the summary's header lists them, which is the order they ran, because
# the two paths don't run their steps in the same order, and a funnel whose bars
# rise partway down isn't a funnel.
readonly READ_STAGE_COLUMNS=(
    chopper_output
    cutadapt_passing_filters
    filtered
    merged
    nonchim
    savont_output
    ssufilter_output
    lenfilter_output
)

# Inside the run directory, so the container sees it under the data directory
WORK=$(mktemp -d "$PWD/.composition.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

readonly TABLE_STATS="$WORK/statistics.tsv"

# The stages this run's summary carries, in the order its header lists them
summary_stages() {
    LC_ALL=C awk -F'\t' -v known="${READ_STAGE_COLUMNS[*]}" '
        BEGIN { split(known, list, " "); for (i in list) wanted[list[i]] = 1 }

        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i in wanted) printf "%s%s", (found++ ? " " : ""), $i
            }

            printf "\n"
            exit
        }
    ' "$OVERALL_SUMMARY"
}

# Reads at one stage of the run, summed over every sample. The stage is named as
# the columns that could carry it, earliest first, and the first the summary has
# is taken. Prints nothing when the summary has none of them.
#
# cutadapt writes its counts with thousands separators, so everything that isn't
# part of the number is stripped first.
summary_reads() {
    LC_ALL=C awk -F'\t' -v candidates="$1" '
        NR == 1 {
            for (i = 1; i <= NF; i++) at[$i] = i

            split(candidates, want, " ")

            for (i = 1; i in want; i++) {
                if (want[i] in at) { pick = at[want[i]]; break }
            }
            next
        }

        pick {
            reads = $pick
            gsub(/[^0-9.]/, "", reads)
            total += reads + 0
        }

        END { if (pick) print total + 0 }
    ' "$OVERALL_SUMMARY"
}

total_input_reads() {
    summary_reads "chopper_input cutadapt_total_processed DADA2_input input_reads input"
}

# The chemistry FastQC read off the raw files, as a reader says it: "2 × 250 bp"
# for a paired run, "250 bp" for a single-ended one, and "250 + 150 bp" where the
# mates were read to different lengths.
#
# FastQC states a length as one number or a range, such as "35-251" for files
# already trimmed, and the chemistry is the longest read, so the top of the range
# is taken. A mate is read off the trailing _1 or _2 MultiQC names the file by,
# and the commonest length of each mate is the run's. Ties go to the longer, or
# the page would come out differently on two runs of the same data.
#
# A nanopore run has no chemistry to report: its read lengths are a wide
# distribution, so it's named by its instrument alone.
read_chemistry() {
    local chemistry

    [[ "$(state_get params.sequencing_type)" == "nanopore" ]] && return 1
    [[ -r "$FASTQC_TABLE" ]] || return 1

    chemistry=$(LC_ALL=C awk -F'\t' '
        function longest(s,   n, top) {
            while (match(s, /[0-9]+/)) {
                n = substr(s, RSTART, RLENGTH) + 0
                if (n > top) top = n
                s = substr(s, RSTART + RLENGTH)
            }

            return top
        }

        NR == 1 {
            for (i = 1; i <= NF; i++) at[$i] = i

            if (!("Sample" in at) || !("Sequence length" in at)) exit

            named = 1
            next
        }

        named {
            mate = ($(at["Sample"]) ~ /_2$/) ? 2 : 1
            seen[mate, longest($(at["Sequence length"]))]++
        }

        END {
            for (key in seen) {
                split(key, part, SUBSEP)
                mate = part[1] + 0
                bp   = part[2] + 0

                if (seen[key] < most[mate]) continue
                if (seen[key] == most[mate] && bp <= len[mate]) continue

                most[mate] = seen[key]
                len[mate]  = bp
            }

            if (!len[1])                  exit
            else if (!len[2])             printf "%d bp", len[1]
            else if (len[1] == len[2])    printf "2 × %d bp", len[1]
            else                          printf "%d + %d bp", len[1], len[2]
        }
    ' "$FASTQC_TABLE")

    [[ -n "$chemistry" ]] || return 1

    printf '%s' "$chemistry"
}

# The samplesheet's samples with no reads in the feature table, space-separated
# in samplesheet order. The second column of the alpha diversity table is the
# sample's reads.
dropped_samples() {
    [[ -s "$ALPHA_TABLE" && -r "$SAMPLESHEET" ]] || return 0

    LC_ALL=C awk -F'\t' '
        FNR == 1         { next }
        FILENAME == kept { if ($2 > 0) have[$1] = 1; next }
        !($1 in have)    { printf "%s%s", (n++ ? " " : ""), $1 }
        END              { if (n) printf "\n" }
    ' kept="$ALPHA_TABLE" "$ALPHA_TABLE" "$SAMPLESHEET"
}

# Everything the sidebar reports: what the R script counted off the feature
# table, the chemistry, the samples the table is missing, and the read totals
write_run_statistics() {
    local chemistry dropped stages stage

    {
        cat "$TABLE_STATS"

        if chemistry=$(read_chemistry); then
            printf 'read_chemistry\t%s\n' "$chemistry"
        fi

        dropped=$(dropped_samples)
        [[ -z "$dropped" ]] || printf 'samples_dropped\t%s\n' "$dropped"

        if [[ -r "$OVERALL_SUMMARY" ]]; then
            printf 'reads_total\t%s\n' "$(total_input_reads)"

            # Recorded beside the counts, because only this script has read the
            # header their order comes from
            stages=$(summary_stages)

            if [[ -n "$stages" ]]; then
                printf 'read_stages\t%s\n' "$stages"

                for stage in $stages; do
                    printf 'reads_%s\t%s\n' "$stage" "$(summary_reads "$stage")"
                done
            fi
        fi
    } | state_set_tsv "$STATS_KEY"
}


log "Summarising composition and diversity under $RESULTS_DIR..."

# Pulled first, so a missing image fails the step rather than reading as a
# table that couldn't be assembled
RBIOM_IMAGE=$(lock_image ampliseq rbiom) || exit 1
container_sif "$RBIOM_IMAGE" > /dev/null || exit 1

EXCLUDE_TAXA=$(state_get params.exclude_taxa)
EXCLUDE_TAXA=${EXCLUDE_TAXA:-none}

# 1. The feature table, and everything read off it
if ! R_OUTPUT=$(container_exec "$RBIOM_IMAGE" -B "$R_DIR:$R_DIR:ro" \
        Rscript --vanilla "$TABLES_SCRIPT" \
            "$RESULTS_DIR" "$PLOT_DATA" "$TABLE_STATS" "$EXCLUDE_TAXA" 2>&1); then
    # The feature table is a core result, so a run without one has failed
    rm -f "$PLOT_DATA"
    fail "The feature table couldn't be assembled:"$'\n'"$(tail -n 5 <<< "$R_OUTPUT")"
fi

[[ -z "$R_OUTPUT" ]] || log "$R_OUTPUT"

if [[ ! -s "$PLOT_DATA" ]]; then
    warn "No plot data was written; the Overview will show no plots."
    rm -f "$PLOT_DATA"
    exit 0
fi

# 2. The counts the sidebar reports, from the R script and from the summary
if [[ -s "$TABLE_STATS" ]] && ! write_run_statistics; then
    warn "The run statistics could not be counted; the dashboard will show fewer numbers."
    state_unset "$STATS_KEY" || true
fi

DROPPED=$(dropped_samples)
[[ -z "$DROPPED" ]] || warn "Samples missing from the feature table: $DROPPED"

log "Wrote ${PLOT_DATA##*/} and the feature table under $RESULTS_DIR."
