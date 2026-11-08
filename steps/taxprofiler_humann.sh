#!/bin/bash
#
# taxprofiler_humann.sh - Functional profiling for a finished taxprofiler run.
#
# nf-core/taxprofiler answers what was in each sample and not what it could do,
# so the functional half of a shotgun deliverable is a second workflow run over
# what the first one produced. This pairs each sample with the reads that
# reached the classifiers and with its MetaPhlAn profile, then runs
# workflows/humann, which publishes <results_dir>/humann/.
#
# Two preparations happen here rather than in the workflow.
#
# The reads. taxprofiler publishes the analysis-ready set (trimmed,
# complexity-filtered, host-depleted and run-merged) under one directory, but
# names each file after the step that last touched it, so a sample's files are
# identifiable only by the sample name they start with. Each is matched to the
# longest sample name it begins with, since one sample name can be a prefix of
# another.
#
# The profile. taxprofiler runs MetaPhlAn with -t rel_ab_w_read_stats, and
# HUMAnN reads the abundance from the second-to-last column of whatever it is
# given, which in that layout is coverage, not the percentage. Given the profile
# unchanged, HUMAnN silently reads a species at 12% as being at 0.05% and drops
# nearly everything below its prescreen threshold. So each profile is rewritten
# here into the column layout -t rel_ab writes, with the comment lines kept:
# HUMAnN 3.9 exits unless one of them names the vJun23 database.
#
# Only Illumina samples are profiled. HUMAnN's nucleotide tier is bowtie2 and
# its translated tier is DIAMOND blastx, both short-read aligners.
#
# Nothing here is fatal. A run whose functional profiling could not be done
# still publishes everything the taxonomic half produced, and the dashboard
# leaves out the outputs whose paths match nothing, so it simply carries no
# functional section. What went wrong is appended to the run state's .notes,
# which the job reports to the requester.
#
# Usage:     taxprofiler_humann.sh [results_dir]
#            defaults to ./results, the outdir set in the taxprofiler params file
# Called by: the job, from the run directory, as a post-process step of the
#            taxprofiler pipeline. It must run before the results are pruned and
#            published, because pruning deletes the reads this reads.
# Requires:  nextflow and awk
# Reads:     ./taxprofiler_samplesheet.csv, <results_dir>/analysis_ready_fastqs/,
#            <results_dir>/metaphlan/, and $DB_DIR/humann/v201901b/
# Writes:    ./humann_samplesheet.csv, ./humann_profiles/, ./humann_command.sh,
#            ./humann.out and ./humann.log (the console output the progress
#            page reads and the workflow's own log), and <results_dir>/humann/:
#            the tables, the per-sample logs, and a copy of that command record
#            naming no site paths
# Env:       CODE_DIR, DB_DIR, NEXTFLOW_CONFIG, the log/warn helpers,
#            nextflow_session and the run state helpers, from lib/env.sh;
#            site.config, which the job wrote; GNOTO_RESUME, true when the job
#            resumes a run

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

RESULTS_DIR="${1:-results}"
RESULTS_DIR="${RESULTS_DIR%/}"

# Nextflow resolves what it is handed against its own launch directory, so every
# path written into the samplesheet below is absolute
RESULTS_PATH="$RESULTS_DIR"
[[ "$RESULTS_PATH" == /* ]] || RESULTS_PATH="$PWD/$RESULTS_DIR"

# Written by taxprofiler_samplesheet.sh, and the only record of this run's
# sample names and their platforms
SAMPLESHEET="taxprofiler_samplesheet.csv"

# The reads that reached the classifiers, published by
# save_analysis_ready_fastqs, and the per-sample profiles beside them
READS_DIR="$RESULTS_PATH/analysis_ready_fastqs"
METAPHLAN_DIR="$RESULTS_PATH/metaphlan"

# Rewritten profiles and the sheet naming them, in the run directory rather than
# in the results: both are derived from files the run publishes
PROFILE_DIR="humann_profiles"
HUMANN_SHEET="humann_samplesheet.csv"

# The three databases HUMAnN 3.9 reads, as fetch_taxprofiler_db.sh humann
# installs them
HUMANN_DB="$DB_DIR/humann/v201901b"
CHOCOPHLAN="$HUMANN_DB/chocophlan"
UNIREF="$HUMANN_DB/uniref90"
UTILITY_MAPPING="$HUMANN_DB/utility_mapping"

WORKFLOW="$CODE_DIR/workflows/humann"

# The MetaPhlAn database HUMAnN 3.9 is built against, as it appears in the
# comment line at the top of a profile. A run given a second, newer MetaPhlAn
# database publishes profiles this will not match, and those are passed over.
readonly HUMANN_MPA_VERSION="vJun23"

# The platform taxprofiler_samplesheet.sh records for short reads
readonly SHORT_READ_PLATFORM="ILLUMINA"

# What a failure here leaves on the run, for the job to report
NOTE_PREFIX="Functional profiling (HUMAnN) was not done"

# Says so on the run and on this job's log, and exits 0: everything the
# taxonomic half produced is still worth publishing.
skip() {
    warn "$NOTE_PREFIX: $*"
    state_append notes "$NOTE_PREFIX: $*" || true
    exit 0
}

if [[ ! -d "$RESULTS_DIR" ]]; then
    skip "there is no '$RESULTS_DIR' directory."
fi

if [[ ! -r "$SAMPLESHEET" ]]; then
    skip "this run wrote no $SAMPLESHEET, so its samples cannot be named."
fi

if [[ ! -d "$READS_DIR" ]]; then
    skip "this run published no analysis-ready reads under ${READS_DIR#"$RESULTS_PATH/"}/."
fi

if [[ ! -d "$METAPHLAN_DIR" ]]; then
    skip "this run produced no MetaPhlAn profiles for HUMAnN to be given."
fi

for path in "$CHOCOPHLAN" "$UNIREF" "$UTILITY_MAPPING"; do
    [[ -d "$path" ]] && continue
    skip "there is no HUMAnN database at $path. gnoto lint <job file> offers to fetch it."
done

command -v nextflow > /dev/null || skip "nextflow is not on PATH."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Every short-read sample this run was given, one per line, longest name first,
# which is the order the reads below are matched in
SAMPLES="$WORK/samples.txt"

LC_ALL=C awk -F, -v platform="$SHORT_READ_PLATFORM" '
    NR == 1 { next }
    toupper($3) == platform && !seen[$1]++ { print length($1), $1 }
' "$SAMPLESHEET" | LC_ALL=C sort -k1,1nr -k2,2 | cut -d" " -f2- > "$SAMPLES"

if [[ ! -s "$SAMPLES" ]]; then
    skip "this run carried no $SHORT_READ_PLATFORM samples, and HUMAnN reads short reads only."
fi

# Every analysis-ready FASTQ against the sample whose name it starts with, as
# "sample <TAB> path". The separator after the name is required: without it
# PT10_D7 would take the files of PT10_D7_STOOL. The sort above offers the
# longer name each file first.
READS="$WORK/reads.tsv"
: > "$READS"

for path in "$READS_DIR"/*.f*q.gz; do
    [[ -r "$path" ]] || continue

    name=${path##*/}

    while read -r sample; do
        rest=${name#"$sample"}

        [[ "$rest" == "$name" ]] && continue
        [[ "$rest" == [._]* ]] || continue

        printf '%s\t%s\n' "$sample" "$path" >> "$READS"
        break
    done < "$SAMPLES"
done

if [[ ! -s "$READS" ]]; then
    skip "none of the files in ${READS_DIR#"$RESULTS_PATH/"}/ could be matched to a sample."
fi

# One sample's MetaPhlAn profile, rewritten into the layout -t rel_ab writes:
# clade, taxon id, relative abundance, and the empty additional-species column
# HUMAnN reads the abundance from the left of. Comment lines are carried
# through, since the first of them tells HUMAnN which database this is.
#
# MetaPhlAn 4 names the taxon id column "clade_taxid" under -t
# rel_ab_w_read_stats and "NCBI_tax_id" under -t rel_ab, so either is taken.
#
# Prints nothing and returns non-zero when the profile carries no
# relative_abundance or taxon id column, which is what a file that is not a
# MetaPhlAn profile looks like from here.
rewrite_profile() {
    local source="$1" destination="$2"

    LC_ALL=C awk -v OFS='\t' -F'\t' '
        /^#clade_name/ {
            for (i = 1; i <= NF; i++) {
                field = $i
                sub(/^#/, "", field)
                column[field] = i
            }

            abundance = column["relative_abundance"]
            taxid = column["clade_taxid"] ? column["clade_taxid"] : column["NCBI_tax_id"]

            if (!abundance || !taxid) exit 1

            print "#clade_name", "NCBI_tax_id", "relative_abundance", "additional_species"
            next
        }

        /^#/ { print; next }

        abundance {
            print $1, $taxid, $abundance, ""
            rows++
        }

        END { if (!rows) exit 1 }
    ' "$source" > "$destination"
}

# The profile a sample was given, under the database folder it was written into.
# taxprofiler names it "<sample>_<database>.metaphlan_profile.txt" when run
# merging is on, which the pipeline sets. Only a profile naming the database
# HUMAnN 3.9 was built against is offered. A run classified against two
# MetaPhlAn databases has one of each.
sample_profile() {
    local sample="$1"
    local database path

    for database in "$METAPHLAN_DIR"/*/; do
        database=${database%/}
        path="$database/${sample}_${database##*/}.metaphlan_profile.txt"

        [[ -r "$path" ]] || continue
        grep -qm1 "^#.*$HUMANN_MPA_VERSION" "$path" || continue

        printf '%s' "$path"
        return 0
    done

    return 1
}

rm -rf "$PROFILE_DIR"
mkdir -p "$PROFILE_DIR"

printf 'sample,reads,taxonomic_profile\n' > "$HUMANN_SHEET"

PROFILED=0
SKIPPED=()

while read -r sample; do
    READ_LIST=$(LC_ALL=C awk -F'\t' -v sample="$sample" \
        '$1 == sample { printf "%s%s", separator, $2; separator = ";" }' "$READS")

    if [[ -z "$READ_LIST" ]]; then
        SKIPPED+=("$sample (no analysis-ready reads)")
        continue
    fi

    if ! PROFILE=$(sample_profile "$sample"); then
        SKIPPED+=("$sample (no $HUMANN_MPA_VERSION MetaPhlAn profile)")
        continue
    fi

    if ! rewrite_profile "$PROFILE" "$PROFILE_DIR/$sample.tsv"; then
        rm -f "$PROFILE_DIR/$sample.tsv"
        SKIPPED+=("$sample (its MetaPhlAn profile could not be read)")
        continue
    fi

    printf '%s,%s,%s\n' "$sample" "$READ_LIST" "$PWD/$PROFILE_DIR/$sample.tsv" >> "$HUMANN_SHEET"
    PROFILED=$((PROFILED + 1))
done < "$SAMPLES"

if (( ${#SKIPPED[@]} > 0 )); then
    warn "${#SKIPPED[@]} sample(s) will have no functional profile:" \
         "$(printf '%s; ' "${SKIPPED[@]}")"
    state_append notes "No functional profile for: $(printf '%s; ' "${SKIPPED[@]}")" || true
fi

if (( PROFILED == 0 )); then
    skip "no sample had both analysis-ready reads and a $HUMANN_MPA_VERSION MetaPhlAn profile."
fi

# What the progress page says under the run's name, since this takes hours per
# sample
set_run_stage "Profiling what the community can do (HUMAnN)." || true

log "Running HUMAnN over $PROFILED sample(s)..."

# Written and then executed, so the record published with the tables can't
# drift from what produced them
HUMANN_ARGS=(
    -log humann.log
    run "$WORKFLOW"
    -profile apptainer
    -ansi-log false
    --input "$PWD/$HUMANN_SHEET"
    --outdir "$RESULTS_PATH"
    --chocophlan "$CHOCOPHLAN"
    --uniref "$UNIREF"
    --utility_mapping "$UTILITY_MAPPING"
)

# The site's settings, as the job's own Nextflow run has them: the executor and
# each task's limits from site.config, which the job wrote, then
# core.nextflow_config
[[ ! -f site.config ]] || HUMANN_ARGS+=(-c "$PWD/site.config")
[[ -z "${NEXTFLOW_CONFIG:-}" ]] || HUMANN_ARGS+=(-c "$NEXTFLOW_CONFIG")

# A resumed run resumes this workflow's own session, which shares the run
# directory with the job's main Nextflow run
if [[ "${GNOTO_RESUME:-false}" == true ]]; then
    SESSION=$(nextflow_session "$WORKFLOW")
    [[ -z "$SESSION" ]] || HUMANN_ARGS+=(-resume "$SESSION")
fi

{
    printf '#!/bin/bash\n'
    printf '# HUMAnN over %s sample(s), recorded %s\n' "$PROFILED" "$(date)"
    printf 'exec nextflow'
    printf ' %q' "${HUMANN_ARGS[@]}"
    printf '\n'
} > humann_command.sh
chmod +x humann_command.sh

# Teed to humann.out, where the progress page reads the processes it lists under
# this step
if ! ./humann_command.sh 2>&1 | tee humann.out; then
    skip "the HUMAnN workflow failed; see humann.out."
fi

set_run_stage "Packaging and publishing your results." || true

# Beside the tables it produced, since the taxprofiler command published in the
# results is not the command that produced them. The published copy names no
# site paths: databases as db: names, gnoto's code as <gnoto>, and the run
# directory not at all.
PUBLISHED_PATHS=(-e "s#$DB_DIR/#db:#g" -e "s#$CODE_DIR/#<gnoto>/#g" -e "s#$PWD/##g")
[[ -z "${NEXTFLOW_CONFIG:-}" ]] ||
    PUBLISHED_PATHS=(-e "s#$NEXTFLOW_CONFIG#<core.nextflow_config>#g" "${PUBLISHED_PATHS[@]}")
sed "${PUBLISHED_PATHS[@]}" humann_command.sh > "$RESULTS_DIR/humann/humann_command.sh" 2> /dev/null ||
    warn "Could not publish the HUMAnN command record with its tables."

log "HUMAnN finished; its tables are in $RESULTS_DIR/humann."
