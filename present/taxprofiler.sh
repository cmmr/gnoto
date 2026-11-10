#!/bin/bash
#
# taxprofiler.sh - Builds a taxprofiler run's dashboard and deliverables zip.
#
# Run by:    lib/job.sh, as the Present stage, from the run directory, and again
#            by gnoto publish
# Usage:     taxprofiler.sh results
# Requires:  zip, GNU find, awk and jq
# Reads:     present/templates/taxprofiler/{outputs,prune}.conf;
#            ./raw-sequences/, ./taxprofiler_database.csv and
#            ./composition_data.json; and title, retention, version, dev,
#            samples.count, statistics and stages.compute in ./run_state.json
# Writes:    the pages, listings, assets/, taxprofiler_database.csv and a final
#            progress.json in the results folder, and <title>_<uid>.zip in the
#            run directory
#
# The same steps as present/ampliseq.sh, with taxprofiler's statistics: read
# totals from fastp and bowtie2, the samples a tool left out, and a Feature
# Table tab each for MetaPhlAn, Kraken2 and Bracken, and HUMAnN. A shotgun run writes about ten times more
# bytes than anyone reads, so pruning is most of what keeps the zip a sensible
# size.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
source "$CODE_DIR/present/dashboard.sh"
source "$CODE_DIR/present/common.sh"

RESULTS_DIR=${1:-results}
RESULTS_DIR=${RESULTS_DIR%/}
FASTQ_DIR=raw-sequences
DB_SHEET=taxprofiler_database.csv
PLOT_DATA_FILE=composition_data.json
SUBTITLE="Shotgun metagenomic taxonomic profiling"
MULTIQC_REPORT=$RESULTS_DIR/multiqc/multiqc_report.html
MULTIQC_REPORT_HREF=multiqc/multiqc_report.html
OUTPUT_CATALOG=$CODE_DIR/present/templates/taxprofiler/outputs.conf
PRUNE_LIST=$CODE_DIR/present/templates/taxprofiler/prune.conf

RUN_ID=$(present_run_id) || fail "The results can't be presented: \"$PWD\" isn't a run directory."
[[ -d $RESULTS_DIR ]] || fail "The pipeline wrote no results directory ('$RESULTS_DIR') to present."
command -v zip > /dev/null || fail "The results can't be packaged for download: zip isn't installed."
[[ -d $FASTQ_DIR ]] || log "There's no $FASTQ_DIR directory, so the zip holds the results alone."

# 1. The database sheet the run read, with the Bracken read length it used, and
#    its paths as db: names
if [[ -r $DB_SHEET ]]; then
    present_redact < "$DB_SHEET" > "$RESULTS_DIR/$DB_SHEET" || warn "Couldn't publish $DB_SHEET."
fi

# 2. The Krona chart the bar offers. The run writes one per classifier and
#    database, and both of a Kraken2 database's charts draw Kraken2's clade
#    counts, not Bracken's: checked on a real run, where every wedge matched
#    Kraken2's report. So the one named for Bracken would mislead, and goes.
#    A listing from an earlier Present would sort ahead of the charts, so it's
#    passed over.
KRONA_CHART=""
KRONA_FALLBACK=""
for KRONA_PATH in "$RESULTS_DIR"/krona/*.html; do
    [[ -r $KRONA_PATH ]] || continue
    [[ ${KRONA_PATH##*/} == directory_listing.html ]] && continue
    if [[ $KRONA_PATH == *bracken* ]]; then
        : "${KRONA_FALLBACK:=${KRONA_PATH#"$RESULTS_DIR/"}}"
        continue
    fi
    KRONA_CHART=${KRONA_PATH#"$RESULTS_DIR/"}
    break
done
if [[ -n $KRONA_CHART && -n $KRONA_FALLBACK ]]; then
    rm -f "$RESULTS_DIR/$KRONA_FALLBACK" || warn "Couldn't delete the duplicate Krona chart $KRONA_FALLBACK."
fi
: "${KRONA_CHART:=$KRONA_FALLBACK}"

# 3. Delete what the run wrote for itself, and this site's paths from the rest
"$CODE_DIR/present/prune_results.sh" "$RESULTS_DIR" "$PRUNE_LIST" ||
    warn "The results couldn't be pruned, so the run publishes its working files too."
present_scrub "$RESULTS_DIR"
dashboard_assets "$RESULTS_DIR" || fail "Couldn't copy the pages' stylesheet and fonts into $RESULTS_DIR/assets."

# 4. What the pages offer, from what the run produced
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG"
dashboard_view krona "Taxonomy Explorer" "$KRONA_CHART"

declare -A STATS=()
while IFS=$'\t' read -r STAT_KEY STAT_VALUE; do
    STATS[$STAT_KEY]=$STAT_VALUE
done < <(state_get_tsv statistics)

# Reads as they reached the pipeline: quality filtering's total, or host
# removal's without it, or the classifiers' own
TOTAL_READS=${STATS[qc_total]:-${STATS[host_total]:-${STATS[reads_total]:-}}}

# What reached the classifiers, which a classification share is a share of,
# since filtering and depletion have taken their cut by then
RETAINED_READS=${STATS[reads_total]:-$TOTAL_READS}

if [[ $TOTAL_READS =~ ^[0-9]+$ ]] && (( TOTAL_READS > 0 )); then
    dashboard_stat_group "READ TOTALS" "${STATS[platform]:-}"
    dashboard_stat_bar "Total reads" "$(human_count "$TOTAL_READS")" 100

    # Host depletion counts what bowtie2 was given, not what filtering passed,
    # so what's left comes from its own two numbers
    HOST_KEPT=""
    if [[ ${STATS[host_total]:-} =~ ^[0-9]+$ && ${STATS[host_removed]:-} =~ ^[0-9]+$ ]]; then
        HOST_KEPT=$(( STATS[host_total] - STATS[host_removed] ))
    fi

    # fastp buckets each read by the first test it failed, quality, then N
    # content, then length, then complexity, so taking those off the total in
    # that order is what was left after each
    FASTP_SECTION=$(dashboard_report_section "$MULTIQC_REPORT" "$MULTIQC_REPORT_HREF" \
        "fastp-filtered-reads-chart fastp general_stats")
    QC_LEFT=$TOTAL_READS
    qc_step() {
        local label=$1 removed=${STATS[$2]:-}
        [[ $removed =~ ^[0-9]+$ ]] || return 0
        QC_LEFT=$((QC_LEFT - removed))
        dashboard_stat_share_detail reads "$label" "$QC_LEFT" "$TOTAL_READS" "$FASTP_SECTION"
    }
    qc_step "After quality filter" qc_cut_quality
    qc_step "After N filter" qc_cut_ncontent
    qc_step "After length filter" qc_cut_length
    qc_step "After complexity filter" qc_cut_complexity

    dashboard_stat_share_detail reads "After host depletion" "$HOST_KEPT" "$TOTAL_READS" \
        "$(dashboard_report_section "$MULTIQC_REPORT" "$MULTIQC_REPORT_HREF" "bowtie2 general_stats")"
    dashboard_stat_share "Retained reads" "$RETAINED_READS" "$TOTAL_READS" growth reads

    # The samples the plotted profiler had no report on, under a bar of those
    # that remain, and those another tool left out
    if [[ -n ${STATS[samples_dropped]:-}${STATS[metaphlan_missing]:-}${STATS[motus_missing]:-}${STATS[nonpareil_missing]:-}${STATS[humann_missing]:-} ]]; then
        dashboard_stat_group "SAMPLES"
        if [[ -n ${STATS[samples_dropped]:-} ]]; then
            read -ra DROPPED <<< "${STATS[samples_dropped]}"
            GIVEN_SAMPLES=$(present_sample_count)
            if [[ ! $GIVEN_SAMPLES =~ ^[0-9]+$ ]] || (( GIVEN_SAMPLES < ${#DROPPED[@]} )); then
                GIVEN_SAMPLES=$(( ${STATS[samples]:-0} + ${#DROPPED[@]} ))
            fi
            KEPT_SAMPLES=$((GIVEN_SAMPLES - ${#DROPPED[@]}))
            KEPT_PCT=$((KEPT_SAMPLES * 100 / GIVEN_SAMPLES))
            DROPPED_LIST=$(printf '%s, ' "${DROPPED[@]}")
            DROPPED_INFO="Samples left with no reads by quality filtering and host removal"
            if [[ ${STATS[profiler]:-} == Bracken ]]; then
                DROPPED_INFO+=", or with too few for any species to reach Bracken's threshold"
            fi
            DROPPED_INFO+=", as a blank can be, and so in none of the plots or feature tables"
            dashboard_stat_bar "Samples analysed" "$KEPT_SAMPLES of $GIVEN_SAMPLES" \
                "$KEPT_PCT" growth "" "Dropped: ${DROPPED_LIST%, }" "$DROPPED_INFO"
        fi
        for GAP in "No MetaPhlAn profile|metaphlan_missing" "No mOTUs profile|motus_missing" \
                   "No Nonpareil estimate|nonpareil_missing" "No HUMAnN profile|humann_missing"; do
            GAP_SAMPLES=${STATS[${GAP##*|}]:-}
            [[ -n $GAP_SAMPLES ]] || continue
            dashboard_stat_row "${GAP%%|*}" "${GAP_SAMPLES// /, }"
        done
    fi

    dashboard_stat_group "READS PER SAMPLE"
    dashboard_stat_chips "$(human_count "${STATS[reads_min]:-0}")|Min" \
        "$(human_count "${STATS[reads_median]:-0}")|Median" \
        "$(human_count "${STATS[reads_max]:-0}")|Max"
fi

# A tab per tool: the tables a reader most likely wants, its folder, and how
# much of the run it classified, each share of the reads that reached it
dashboard_tab metaphlan "MetaPhlAn"
dashboard_button "metaphlan/metaphlan_*_combined_reports.txt" "Relative abundance table" || :
dashboard_button "count_tables/metaphlan-reads.tsv" "Read count table" || :
dashboard_button "feature_table/metaphlan-table.hdf5.biom" "Feature table with phylogeny" || :
dashboard_folder "metaphlan/" "All MetaPhlAn outputs" || :
if [[ -n ${STATS[metaphlan_total]:-} ]]; then
    dashboard_stat_group "CLASSIFICATION" "${STATS[metaphlan_database]:-}"
    dashboard_stat_share "Mapped reads" "${STATS[metaphlan_mapped]:-}" "${STATS[metaphlan_total]}"
fi

dashboard_tab kraken "Kraken/Bracken"
# taxpasta's merged Bracken profile, or Kraken2's for a run without Bracken
if ! dashboard_button "taxpasta/bracken_*.tsv" "Species abundance table"; then
    dashboard_button "taxpasta/kraken2_*.tsv" "Taxonomic profile table" || :
fi
dashboard_formats "Feature table" \
    "Plain text|feature_table/feature-table.tsv" \
    "JSON|feature_table/feature-table.json.biom" \
    "HDF5|feature_table/feature-table.hdf5.biom" || :
dashboard_folder "kraken2/" "All Kraken2 outputs" || :
dashboard_folder "bracken/" "All Bracken outputs" || :

# How far down the taxonomy Kraken2 placed reads. Each rank counts the reads in
# some clade of it, so the three bars are one funnel.
if [[ $RETAINED_READS =~ ^[0-9]+$ ]] && (( RETAINED_READS > 0 )) &&
    [[ -n ${STATS[phylum_reads]:-}${STATS[genus_reads]:-}${STATS[species_reads]:-} ]]; then
    dashboard_stat_group "CLASSIFICATION" "${STATS[database]:-}"
    dashboard_stat_share "Phylum level" "${STATS[phylum_reads]:-}" "$RETAINED_READS"
    dashboard_stat_share "Genus level" "${STATS[genus_reads]:-}" "$RETAINED_READS"
    dashboard_stat_share "Species level" "${STATS[species_reads]:-}" "$RETAINED_READS"
fi

dashboard_tab humann "HUMAnN"
dashboard_button "humann/pathway-abundance-relab.tsv" "Pathway abundances" || :
dashboard_button "humann/gene-families-relab.tsv" "Gene family abundances" || :
dashboard_button "humann/ec-relab.tsv" "Enzyme (EC) abundances" || :
dashboard_folder "humann/" "All HUMAnN outputs" || :
if [[ -n ${STATS[humann_total]:-} ]]; then
    dashboard_stat_group "CLASSIFICATION"
    dashboard_stat_share "Mapped reads" "${STATS[humann_mapped]:-}" "${STATS[humann_total]}"
fi
dashboard_tab_end

TITLE=$(present_title)
SAMPLE_COUNT=$(present_sample_count)
EXPIRES=$(present_expires "$RUN_ID")
present_retire_progress "$RESULTS_DIR"

# 5. The reads and the results, as the one download
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
dashboard_bundle "$(bundle_href "$BUNDLE_NAME")" "$(stat -c %s "$BUNDLE_NAME.tmp")" "${BUNDLE_FOLDERS[@]}"

# 6. The pages, a listing in every folder, and those into the zip
if ! RENDER_OUTPUT=$(render_dashboard "$RUN_ID" "$TITLE" "$SUBTITLE" "$(present_version)" \
        "$(present_completed)" "$SAMPLE_COUNT" "$EXPIRES" "$PLOT_DATA_FILE"); then
    fail "The pages that present these results couldn't be built:"$'\n'"$RENDER_OUTPUT"
fi
"$CODE_DIR/present/index_directories.sh" "$RESULTS_DIR" "$FASTQ_DIR" ||
    warn "The results folders couldn't be indexed, so their listings are missing."
mapfile -t BUNDLE_LATE < <(dashboard_late_files)
if ! ZIP_OUTPUT=$(bundle_add "$BUNDLE_NAME" "${BUNDLE_LATE[@]}"); then
    warn "The zip doesn't carry the dashboard's pages and listings:"$'\n'"$ZIP_OUTPUT"
fi
mv -f "$BUNDLE_NAME.tmp" "$BUNDLE_NAME" || fail "Couldn't name the zip $BUNDLE_NAME."

present_check_published "$RESULTS_DIR" || :
log "The dashboard is $PWD/$RESULTS_DIR/index.html, and the download $PWD/$BUNDLE_NAME."
