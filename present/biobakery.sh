#!/bin/bash
#
# biobakery.sh - Builds a biobakery run's dashboard and deliverables zip.
#
# Run by:    lib/job.sh, as the Present stage, from the run directory, and again
#            by gnoto publish
# Usage:     biobakery.sh results
# Requires:  zip, GNU find, awk, jq and yq
# Reads:     present/templates/biobakery/{outputs,prune}.conf; the read sets
#            beside the results; ./composition_data.json; and title, retention,
#            version, dev, answers.delivered_reads, params, samples.count,
#            statistics and stages.compute in ./run_state.json
# Writes:    the pages, listings, assets/ and a final progress.json in the
#            results folder, ./methods_data.json, and <title>_<uid>.zip in the
#            run directory
#
# The same steps as present/ampliseq.sh, with the Methods page's text written
# first, by present/biobakery_methods.sh, while the KneadData logs it reads are
# still there. The sidebar carries KneadData's read totals and a Feature Table
# tab each for MetaPhlAn, HUMAnN, EsViritu and Marker-MAGu, and a tool the run
# didn't enable leaves its tab off.
#
# The zip carries the read sets the job's delivered_reads asked for: the reads
# as staged, and those the workflow published beside the results when asked.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
source "$CODE_DIR/present/dashboard.sh"
source "$CODE_DIR/present/common.sh"

RESULTS_DIR=${1:-results}
RESULTS_DIR=${RESULTS_DIR%/}
PLOT_DATA_FILE=composition_data.json
METHODS_DATA_FILE=methods_data.json
SUBTITLE="Shotgun metagenomic taxonomic and functional profiling"
MULTIQC_REPORT=$RESULTS_DIR/multiqc/multiqc_report.html
MULTIQC_REPORT_HREF=multiqc/multiqc_report.html
OUTPUT_CATALOG=$CODE_DIR/present/templates/biobakery/outputs.conf
PRUNE_LIST=$CODE_DIR/present/templates/biobakery/prune.conf

RUN_ID=$(present_run_id) || fail "The results can't be presented: \"$PWD\" isn't a run directory."
[[ -d $RESULTS_DIR ]] || fail "The pipeline wrote no results directory ('$RESULTS_DIR') to present."
command -v zip > /dev/null || fail "The results can't be packaged for download: zip isn't installed."

READ_DIRS=()
if form_answer_includes delivered_reads Raw && [[ -d raw-sequences ]]; then
    READ_DIRS+=(raw-sequences)
fi
for READ_DIR in host-depleted-sequences cleaned-sequences; do
    [[ -d $READ_DIR ]] && READ_DIRS+=("$READ_DIR")
done
if (( ${#READ_DIRS[@]} > 0 )); then
    log "The zip carries ${READ_DIRS[*]} beside the results."
else
    log "No reads were asked for, so the zip holds the results alone."
fi

# The read folders are links into work/ and the staged inputs, and zip leaves
# out a link whose file is gone without failing
for READ_DIR in ${READ_DIRS[@]+"${READ_DIRS[@]}"}; do
    BROKEN=$(find -L "$READ_DIR" -type l | wc -l)
    (( BROKEN == 0 )) ||
        fail "This run couldn't be packaged for download: $BROKEN of the files in $READ_DIR/ are missing."
done

# 1. The Methods page's text, before pruning takes the logs it reads
if ! "$CODE_DIR/present/biobakery_methods.sh" "$RESULTS_DIR"; then
    warn "The methods text couldn't be written, so the dashboard has no Methods page."
    rm -f "$METHODS_DATA_FILE"
fi

# 2. Delete what the run wrote for itself, and this site's paths from the rest
"$CODE_DIR/present/prune_results.sh" "$RESULTS_DIR" "$PRUNE_LIST" ||
    warn "The results couldn't be pruned, so the run publishes its working files too."
present_scrub "$RESULTS_DIR"
dashboard_assets "$RESULTS_DIR" || fail "Couldn't copy the pages' stylesheet and fonts into $RESULTS_DIR/assets."

# 3. What the pages offer, from what the run produced
dashboard_reset "$RESULTS_DIR" "$OUTPUT_CATALOG"
dashboard_methods_view "$METHODS_DATA_FILE" Methods

declare -A STATS=()
while IFS=$'\t' read -r STAT_KEY STAT_VALUE; do
    STATS[$STAT_KEY]=$STAT_VALUE
done < <(state_get_tsv statistics)

# Reads as sequenced, what host depletion and trimming each left, and what was
# kept, each step behind "details" linking to KneadData's table in the report
TOTAL_READS=${STATS[raw_total]:-}
if [[ $TOTAL_READS =~ ^[0-9]+$ ]] && (( TOTAL_READS > 0 )); then
    READS_NOTE=${STATS[platform]:-}
    [[ -n ${STATS[layout]:-} ]] && READS_NOTE+="${READS_NOTE:+, }${STATS[layout]}"
    KNEADDATA_SECTION=$(dashboard_report_section "$MULTIQC_REPORT" "$MULTIQC_REPORT_HREF" kneaddata)

    dashboard_stat_group "READ TOTALS" "$READS_NOTE"
    dashboard_stat_bar "Total reads" "$(human_count "$TOTAL_READS")" 100
    dashboard_stat_share_detail reads "After host depletion" "${STATS[host_kept]:-}" \
        "$TOTAL_READS" "$KNEADDATA_SECTION"
    dashboard_stat_share_detail reads "After trimming" "${STATS[trimmed_total]:-}" \
        "$TOTAL_READS" "$KNEADDATA_SECTION"
    dashboard_stat_share "Retained reads" "${STATS[retained_total]:-}" "$TOTAL_READS" growth reads

    # The samples KneadData left with no reads, or no pairs, under a bar of
    # those that remain, and those HUMAnN or Nonpareil couldn't finish
    if [[ -n ${STATS[samples_dropped]:-}${STATS[humann_missing]:-}${STATS[nonpareil_missing]:-} ]]; then
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
            dashboard_stat_bar "Samples analysed" "$KEPT_SAMPLES of $GIVEN_SAMPLES" \
                "$KEPT_PCT" growth "" "Dropped: ${DROPPED_LIST%, }" \
                "Samples with no reads left after trimming and host depletion, or paired samples with no pairs left, and so in none of the run's tables"
        fi
        for GAP in "No HUMAnN profile|humann_missing" "No Nonpareil estimate|nonpareil_missing"; do
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

# A tab per tool: the SGB counts in three BIOM formats, HUMAnN's RPK tables
dashboard_tab metaphlan "MetaPhlAn"
dashboard_formats "" \
    "Taxa|BIOM (tsv)|metaphlan/taxa-counts.tsv" \
    "Taxa|BIOM (json)|metaphlan/taxa-counts.json.biom" \
    "Taxa|BIOM (hdf5)|metaphlan/taxa-counts.hdf5.biom" || :

# The reads each tool placed on a marker gene, out of those KneadData kept, the
# database named under the bar. What aligned, not what was inferred from it, so
# both read low.
if [[ -n ${STATS[metaphlan_mapped]:-} ]]; then
    dashboard_stat_group
    dashboard_stat_share_of "Marker gene reads" "${STATS[metaphlan_mapped]}" \
        "${STATS[retained_total]:-${STATS[metaphlan_total]:-}}" "${STATS[metaphlan_database]:-}" \
        "Reads bowtie2 placed on one of MetaPhlAn's clade-specific marker genes, out of the reads KneadData retained. Expect a low share: the markers are a small part of each genome, so most reads from an organism MetaPhlAn identified confidently will not touch one. This is what was recognised rather than what was inferred from it - the abundances in the tables scale each clade's marker coverage up by its genome size, and metaphlan-counts.tsv reports many times this number."
fi

dashboard_tab humann "HUMAnN"
dashboard_formats "" \
    "Pathways|BIOM (tsv)|humann/pathway-abundance-rpk.tsv" \
    "Genes|BIOM (tsv)|humann/gene-families-rpk.tsv" \
    "Enzymes|BIOM (tsv)|humann/ec-rpk.tsv" || :
if [[ -n ${STATS[humann_mapped]:-} ]]; then
    dashboard_stat_group
    dashboard_stat_share_of "Mapped reads" "${STATS[humann_mapped]}" \
        "${STATS[retained_total]:-${STATS[humann_total]:-}}" "${STATS[humann_database]:-}" \
        "Reads HUMAnN aligned to a gene family: first as DNA to the ChocoPhlAn pangenomes of the species MetaPhlAn found, then, for reads left over, as translated protein against UniRef90. Reads that matched neither are unmapped. A sample HUMAnN could not finish is counted as unmapped."
fi

# EsViritu's tables and report, and the samples it found a virus in
dashboard_tab esviritu "EsViritu"
dashboard_formats "" \
    "Taxa|TSV|esviritu/virus-taxa.tsv" \
    "Genomes|TSV|esviritu/virus-assemblies.tsv" \
    "Report|HTML|esviritu/virus-report.html" || :
ESVIRITU_READ_COUNTS=$RESULTS_DIR/esviritu/read-counts.tsv
ESVIRITU_TAXA=$RESULTS_DIR/esviritu/virus-taxa.tsv
if [[ -r $ESVIRITU_READ_COUNTS ]]; then
    ESVIRITU_SAMPLES=$(tail -n +2 "$ESVIRITU_READ_COUNTS" | cut -f1 | LC_ALL=C sort -u | wc -l)
    ESVIRITU_DETECTED=0
    if [[ -r $ESVIRITU_TAXA ]]; then
        ESVIRITU_DETECTED=$(tail -n +2 "$ESVIRITU_TAXA" | cut -f1 | LC_ALL=C sort -u | wc -l)
    fi
    ESVIRITU_DB=$(state_get params.esviritu_db)
    ESVIRITU_DB=${ESVIRITU_DB%/}
    dashboard_stat_group
    dashboard_stat_share_of "Samples with a virus" "$ESVIRITU_DETECTED" "$ESVIRITU_SAMPLES" \
        "${ESVIRITU_DB:+EsViritu database ${ESVIRITU_DB##*/}}" \
        "Samples in which EsViritu aligned reads to at least one of the human, animal and plant virus genomes in its database, keeping only reads that align over at least 100 bases and 90% of their length at 80% identity or better. A sample absent from the taxa table had no such read."
fi

# Marker-MAGu's viral SGB counts in three BIOM formats, and the reads it placed
# on a viral marker gene
dashboard_tab markermagu "Marker-MAGu"
dashboard_formats "" \
    "Virome|BIOM (tsv)|markermagu/virome-counts.tsv" \
    "Virome|BIOM (json)|markermagu/virome-counts.json.biom" \
    "Virome|BIOM (hdf5)|markermagu/virome-counts.hdf5.biom" || :
if [[ -n ${STATS[markermagu_mapped]:-} ]]; then
    dashboard_stat_group
    dashboard_stat_share_of "Marker gene reads" "${STATS[markermagu_mapped]}" \
        "${STATS[retained_total]:-${STATS[markermagu_total]:-}}" "${STATS[markermagu_database]:-}" \
        "Reads minimap2 placed on a marker gene of one of the viruses Marker-MAGu reported, out of the reads KneadData retained. Read the same way as the MetaPhlAn bar: what was recognised, not what was inferred from it. Reads on the markers of its bacterial calls, which are left to MetaPhlAn, are not counted here, and nor are reads on the markers of a virus that missed the detection threshold."
fi
dashboard_tab_end

TITLE=$(present_title)
SAMPLE_COUNT=$(present_sample_count)
EXPIRES=$(present_expires "$RUN_ID")
present_retire_progress "$RESULTS_DIR"

# 4. The read sets asked for and the results, as the one download
BUNDLE_NAME=$(bundle_name "$RUN_ID" "$TITLE")
BUNDLE_PARTS=()
for READ_DIR in ${READ_DIRS[@]+"${READ_DIRS[@]}"}; do
    BUNDLE_PARTS+=("$READ_DIR|-0")
done
BUNDLE_PARTS+=("$RESULTS_DIR|-9")

log "Packaging $BUNDLE_NAME..."
if ! ZIP_OUTPUT=$(bundle_build "$BUNDLE_NAME" "$RUN_ID" "${BUNDLE_PARTS[@]}"); then
    fail "This run couldn't be packaged for download:"$'\n'"$ZIP_OUTPUT"
fi
dashboard_bundle "$(bundle_href "$BUNDLE_NAME" "$RUN_ID" "$(stat -c %s "$BUNDLE_NAME.tmp")")" "$(stat -c %s "$BUNDLE_NAME.tmp")" "${BUNDLE_PARTS[@]%%|*}"

# 5. The pages, a listing in every folder and each read set, and those into
#    the zip
if ! RENDER_OUTPUT=$(render_dashboard "$RUN_ID" "$TITLE" "$SUBTITLE" "$(present_version)" \
        "$(present_completed)" "$SAMPLE_COUNT" "$EXPIRES" "$PLOT_DATA_FILE"); then
    fail "The pages that present these results couldn't be built:"$'\n'"$RENDER_OUTPUT"
fi
"$CODE_DIR/present/index_directories.sh" "$RESULTS_DIR" ${READ_DIRS[@]+"${READ_DIRS[@]}"} ||
    warn "The results folders couldn't be indexed, so their listings are missing."
mapfile -t BUNDLE_LATE < <(dashboard_late_files)
if ! ZIP_OUTPUT=$(bundle_add "$BUNDLE_NAME" "${BUNDLE_LATE[@]}"); then
    warn "The zip doesn't carry the dashboard's pages and listings:"$'\n'"$ZIP_OUTPUT"
fi
mv -f "$BUNDLE_NAME.tmp" "$BUNDLE_NAME" || fail "Couldn't name the zip $BUNDLE_NAME."

present_check_published "$RESULTS_DIR" || :
log "The dashboard is $PWD/$RESULTS_DIR/index.html, and the download $PWD/$BUNDLE_NAME."
