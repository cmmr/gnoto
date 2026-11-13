#!/bin/bash
#
# ampliseq.sh - Builds an ampliseq run's dashboard and deliverables zip.
#
# Run by:    lib/job.sh, as the Present stage, from the run directory, and again
#            by gnoto publish
# Usage:     ampliseq.sh results
# Requires:  zip, GNU find, awk and jq
# Reads:     present/templates/ampliseq/{outputs,prune}.conf; ./raw-sequences/,
#            ./region_detection.txt and ./composition_data.json; and title,
#            retention, version, dev, region, answers.dada_ref_taxonomy,
#            params.sequencing_type, samples.count, statistics and
#            stages.compute in ./run_state.json
# Writes:    the pages, listings, assets/ and a final progress.json in the
#            results folder, and <title>_<uid>.zip in the run directory
#
# Prunes what the run wrote for itself, takes this site's paths out of what's
# left, declares what the pages offer from what the run produced, zips the reads
# and the results, renders the pages, writes a listing into every folder, and
# adds those to the zip. The composition step ran in Compute and left
# composition_data.json and the statistics; when it didn't, the Overview shows
# its empty state and the sidebar fewer numbers. No network.
#
# The zip holds raw-sequences/ beside results/, inside one folder named after
# it, so an unpacked copy browses like the run directory. It's built before the
# pages, which state its size, and the pages and listings go in after.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
source "$CODE_DIR/present/dashboard.sh"
source "$CODE_DIR/present/common.sh"

RESULTS_DIR=${1:-results}
RESULTS_DIR=${RESULTS_DIR%/}
FASTQ_DIR=raw-sequences
PLOT_DATA_FILE=composition_data.json
SUBTITLE="16S rRNA amplicon sequencing analysis"
SUMMARY_REPORT=$RESULTS_DIR/summary_report/summary_report.html
SUMMARY_REPORT_HREF=summary_report/summary_report.html
OUTPUT_CATALOG=$CODE_DIR/present/templates/ampliseq/outputs.conf
PRUNE_LIST=$CODE_DIR/present/templates/ampliseq/prune.conf

RUN_ID=$(present_run_id) || fail "The results can't be presented: \"$PWD\" isn't a run directory."
[[ -d $RESULTS_DIR ]] || fail "The pipeline wrote no results directory ('$RESULTS_DIR') to present."
command -v zip > /dev/null || fail "The results can't be packaged for download: zip isn't installed."
[[ -d $FASTQ_DIR ]] || log "There's no $FASTQ_DIR directory, so the zip holds the results alone."

# 1. Delete what the run wrote for itself, before anything describes it
"$CODE_DIR/present/prune_results.sh" "$RESULTS_DIR" "$PRUNE_LIST" ||
    warn "The results couldn't be pruned, so the run publishes its working files too."

# 2. The report's link to the results folder is "../", which would open a second
#    dashboard inside the first. Point it at the folder's listing.
if [[ -w $SUMMARY_REPORT ]]; then
    sed -i 's|href="\.\./"|href="../directory_listing.html"|g' "$SUMMARY_REPORT" ||
        warn "The report's link to the results folder couldn't be redirected."
fi

# 3. How the region and platform were measured, published with the results
if [[ -r region_detection.txt ]]; then
    cp region_detection.txt "$RESULTS_DIR/" || warn "Couldn't publish region_detection.txt."
fi

# 4. No published file names a path on this site
present_scrub "$RESULTS_DIR"
dashboard_assets "$RESULTS_DIR" || fail "Couldn't copy the pages' stylesheet and fonts into $RESULTS_DIR/assets."

# 5. What the pages offer, from what the run produced
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG"
dashboard_view report "Analysis Report" "$SUMMARY_REPORT_HREF"

REGION=$(state_get region)
REF_TAXONOMY=$(form_answer dada_ref_taxonomy)
REF_TAXONOMY=${REF_TAXONOMY:-silva=138.2}
SEQUENCING_TYPE=$(state_get params.sequencing_type)

case $SEQUENCING_TYPE in
    illumina_pe | illumina_se) PLATFORM=Illumina ;;
    nanopore) PLATFORM="Oxford Nanopore" ;;
    pacbio) PLATFORM="PacBio HiFi" ;;
    *) PLATFORM=$SEQUENCING_TYPE ;;
esac

# The region the primers amplified, which is what the classifier was given to
# name, so it heads the classification: "16SV4" reads as "16S V4"
REFERENCE=""
[[ -n $REGION ]] && REFERENCE=${REGION/#16S/16S }

# ampliseq names a database as "silva=138.2", which reads as "SILVA 138.2"
REFERENCE_NAME=${REF_TAXONOMY%%=*}
REFERENCE_VERSION=${REF_TAXONOMY#*=}
if (( ${#REFERENCE_NAME} <= 5 )); then
    REFERENCE_NAME=${REFERENCE_NAME^^}
else
    REFERENCE_NAME=${REFERENCE_NAME^}
fi
[[ $REFERENCE_VERSION != "$REF_TAXONOMY" ]] && REFERENCE_NAME+=" $REFERENCE_VERSION"
REFERENCE+="${REFERENCE:+ · }$REFERENCE_NAME"

# What one stage of the read totals is called, and where ampliseq's report
# accounts for it, as "<label>|<anchors>": the subsection, then the section
# holding it, because a report has only the subsections for the steps its run
# took
read_stage_reading() {
    case $1 in
        chopper_output) printf 'After read filtering|read-filtering-with-chopper preprocessing' ;;
        cutadapt_passing_filters) printf 'After primer removal|primer-removal-with-cutadapt preprocessing' ;;
        filtered) printf 'After quality filter|quality-filtering-using-dada2 preprocessing' ;;
        merged) printf 'After pair merging|read-counts-per-sample asv-inference-using-dada2' ;;
        nonchim) printf 'After chimera removal|read-counts-per-sample asv-inference-using-dada2' ;;
        savont_output) printf 'After ASV calling|asv-inference-using-savont read-counts-per-sample' ;;
        ssufilter_output) printf 'After rRNA filter|rrna-detection post-processing-of-asvs' ;;
        lenfilter_output) printf 'After length filter|sequence-length post-processing-of-asvs' ;;
        *) printf '%s|' "$1" ;;
    esac
}

# The statistics the composition step counted. read_stages orders the read
# totals, since the two sequencing paths don't run their steps in one order.
declare -A STATS=()
READ_STAGES=""
CHEMISTRY=""
DROPPED_SAMPLES=""
while IFS=$'\t' read -r STAT_KEY STAT_VALUE; do
    case $STAT_KEY in
        read_stages) READ_STAGES=$STAT_VALUE ;;
        read_chemistry) CHEMISTRY=$STAT_VALUE ;;
        samples_dropped) DROPPED_SAMPLES=$STAT_VALUE ;;
        *) [[ $STAT_VALUE =~ ^[0-9]+(\.[0-9]+)?$ ]] && STATS[$STAT_KEY]=$STAT_VALUE ;;
    esac
done < <(state_get_tsv statistics)

# "Illumina, 2 × 250 bp"
SEQUENCED=$PLATFORM
[[ -n $CHEMISTRY ]] && SEQUENCED+="${SEQUENCED:+, }$CHEMISTRY"

if [[ -n ${STATS[reads_retained]:-} ]]; then
    RETAINED=${STATS[reads_retained]}
    TOTAL_READS=${STATS[reads_total]:-$RETAINED}
    RETAINED_PCT=100
    if (( TOTAL_READS > 0 )); then
        RETAINED_PCT=$(( (RETAINED * 100 + TOTAL_READS / 2) / TOTAL_READS ))
    fi

    dashboard_stat_group "READ TOTALS" "$SEQUENCED"
    dashboard_stat_bar "Total reads" "$(human_count "$TOTAL_READS")" 100

    # Every stage between the two, on the same scale, so the step that thinned
    # the run is the bar that drops
    for STAGE in $READ_STAGES; do
        STAGE_READS=${STATS[reads_$STAGE]:-}
        [[ -n $STAGE_READS ]] || continue
        STAGE_PCT=0
        if (( TOTAL_READS > 0 )); then
            STAGE_PCT=$(( (STAGE_READS * 100 + TOTAL_READS / 2) / TOTAL_READS ))
        fi
        STAGE_READING=$(read_stage_reading "$STAGE")
        STAGE_LINK=$(dashboard_report_section "$SUMMARY_REPORT" "$SUMMARY_REPORT_HREF" "${STAGE_READING#*|}")
        dashboard_stat_detail reads "${STAGE_READING%%|*}" \
            "$STAGE_PCT% · $(human_count "$STAGE_READS")" "$STAGE_PCT" "$STAGE_LINK"
    done
    dashboard_stat_bar "Retained reads" "$RETAINED_PCT% · $(human_count "$RETAINED")" "$RETAINED_PCT" growth reads

    # Samples the filters left with no reads, under a bar of those that
    # remain, rounded down so a run that lost any is never full
    if [[ -n $DROPPED_SAMPLES ]]; then
        read -ra DROPPED <<< "$DROPPED_SAMPLES"
        GIVEN_SAMPLES=$(present_sample_count)
        if [[ ! $GIVEN_SAMPLES =~ ^[0-9]+$ ]] || (( GIVEN_SAMPLES < ${#DROPPED[@]} )); then
            GIVEN_SAMPLES=$(( ${STATS[samples]:-0} + ${#DROPPED[@]} ))
        fi
        KEPT_SAMPLES=$((GIVEN_SAMPLES - ${#DROPPED[@]}))
        KEPT_PCT=$((KEPT_SAMPLES * 100 / GIVEN_SAMPLES))
        DROPPED_LIST=$(printf '%s, ' "${DROPPED[@]}")
        dashboard_stat_group "SAMPLES"
        dashboard_stat_bar "Samples analysed" "$KEPT_SAMPLES of $GIVEN_SAMPLES" \
            "$KEPT_PCT" growth "" "Dropped: ${DROPPED_LIST%, }" \
            "Samples with no reads left after the run's filters"
    fi

    dashboard_stat_group "READS PER SAMPLE"
    dashboard_stat_chips "$(human_count "${STATS[reads_min]:-0}")|Min" \
        "$(human_count "${STATS[reads_median]:-0}")|Median" \
        "$(human_count "${STATS[reads_max]:-0}")|Max"
fi

# The feature table in its three formats, under a tab named for what called the
# ASVs, and how far down the classifier named them: each rank a count of the
# ASVs that reached it, against the ASV total
ASV_TOOL=DADA2
[[ -d $RESULTS_DIR/savont && ! -d $RESULTS_DIR/dada2 ]] && ASV_TOOL=Savont

dashboard_tab asvs "$ASV_TOOL"
dashboard_formats "" \
    "Plain text|feature_table/feature-table.tsv" \
    "JSON|feature_table/feature-table.json.biom" \
    "HDF5|feature_table/feature-table.hdf5.biom" || :

if [[ -n ${STATS[asvs]:-}${STATS[phylum_asvs]:-}${STATS[genus_asvs]:-}${STATS[species_asvs]:-} ]]; then
    dashboard_stat_group "CLASSIFICATION" "$REFERENCE"
    TOTAL_ASVS=${STATS[asvs]:-0}
    [[ -n ${STATS[asvs]:-} ]] && dashboard_stat_bar "Total ASVs" "$(human_count "${STATS[asvs]}")" 100
    for RANK_STAT in "Phylum level|phylum_asvs" "Genus level|genus_asvs" "Species level|species_asvs"; do
        RANK_COUNT=${STATS[${RANK_STAT##*|}]:-}
        [[ -n $RANK_COUNT ]] || continue
        RANK_PCT=0
        if (( TOTAL_ASVS > 0 )); then
            RANK_PCT=$(( (RANK_COUNT * 100 + TOTAL_ASVS / 2) / TOTAL_ASVS ))
        fi
        dashboard_stat_bar "${RANK_STAT%%|*}" "$RANK_PCT% · $(human_count "$RANK_COUNT")" "$RANK_PCT" growth
    done
fi
dashboard_tab_end

TITLE=$(present_title)
SAMPLE_COUNT=$(present_sample_count)
EXPIRES=$(present_expires "$RUN_ID")
present_retire_progress "$RESULTS_DIR"

# 6. The reads and the results, as the one download
BUNDLE_NAME=$(bundle_name "$RUN_ID" "$TITLE")
BUNDLE_FOLDERS=()
BUNDLE_PARTS=()
if [[ -d $FASTQ_DIR ]]; then
    BUNDLE_FOLDERS+=("$FASTQ_DIR")
    BUNDLE_PARTS+=("$FASTQ_DIR|-0")
fi
BUNDLE_FOLDERS+=("$RESULTS_DIR")
BUNDLE_PARTS+=("$RESULTS_DIR|-9")

log "Packaging $BUNDLE_NAME..."
if ! ZIP_OUTPUT=$(bundle_build "$BUNDLE_NAME" "$RUN_ID" "${BUNDLE_PARTS[@]}"); then
    fail "This run couldn't be packaged for download:"$'\n'"$ZIP_OUTPUT"
fi
dashboard_bundle "$(bundle_href "$BUNDLE_NAME" "$RUN_ID")" "$(stat -c %s "$BUNDLE_NAME.tmp")" "${BUNDLE_FOLDERS[@]}"

# 7. The pages
if ! RENDER_OUTPUT=$(render_dashboard "$RUN_ID" "$TITLE" "$SUBTITLE" "$(present_version)" \
        "$(present_completed)" "$SAMPLE_COUNT" "$EXPIRES" "$PLOT_DATA_FILE"); then
    fail "The pages that present these results couldn't be built:"$'\n'"$RENDER_OUTPUT"
fi

# 8. A listing in every folder, and one for the reads, now that every file is in
#    place
"$CODE_DIR/present/index_directories.sh" "$RESULTS_DIR" "$FASTQ_DIR" ||
    warn "The results folders couldn't be indexed, so their listings are missing."

# 9. Those into the zip, which was built without them
mapfile -t BUNDLE_LATE < <(dashboard_late_files)
if ! ZIP_OUTPUT=$(bundle_add "$BUNDLE_NAME" "${BUNDLE_LATE[@]}"); then
    warn "The zip doesn't carry the dashboard's pages and listings:"$'\n'"$ZIP_OUTPUT"
fi
mv -f "$BUNDLE_NAME.tmp" "$BUNDLE_NAME" || fail "Couldn't name the zip $BUNDLE_NAME."

present_check_published "$RESULTS_DIR" || :
log "The dashboard is $PWD/$RESULTS_DIR/index.html, and the download $PWD/$BUNDLE_NAME."
