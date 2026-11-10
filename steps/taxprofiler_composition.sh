#!/bin/bash
#
# taxprofiler_composition.sh - Work out what a shotgun run found, for the dashboard to plot.
#
# The counterpart of ampliseq_composition.sh, writing the same two files in the
# same shapes, so both pipelines are read through the same Overview: what was in
# each sample, and how varied each sample was. taxprofiler answers the first only
# as Krona sunbursts, one page per classifier, and the second not at all.
#
# Composition is read off the kraken2-style reports the run publishes:
#
#   bracken/<db>/<sample>_<db>.bracken.kraken2.report_bracken.txt   preferred
#   kraken2/<db>/<sample>_<db>.kraken2.kraken2.report.txt           fallback
#
# Either carries a clade count at every rank, so a rank is read straight off the
# report. Bracken's is preferred because it redistributes the reads kraken2
# stranded at internal nodes down to the species they came from.
#
# The kraken2 reports are read either way. They're the only place unclassified
# reads are counted, and the only honest account of how far the classifier got,
# since bracken renormalises over what it placed. So every share here is a share
# of every read that reached the classifier. The unclassified reads are written
# out as a taxon of their own, which the Overview doesn't draw: on a shotgun run
# it's routinely the largest share, and drawn, it buried the taxa under it.
#
# The rest of the sidebar's read funnel comes from the reports each step wrote
# about itself: fastp's (reads given to quality filtering, reads through it, and
# the chemistry), bowtie2's (what the host took), and the kraken2 reports (what
# reached the classifier). So does the share of those reads MetaPhlAn and HUMAnN
# each mapped, off every MetaPhlAn profile's header and HUMAnN's
# alignment-summary.tsv.
#
# A sample left with no reads by quality filtering and host removal, as a blank
# can be, is skipped by every profiler, and one left with too few for Bracken
# or MetaPhlAn is left out by that tool, rather than failing the run
# (pipelines/taxprofiler/resources.config). The sidebar names it: as dropped
# when the plotted profiler has no report on it, which leaves it out of the
# plots and feature tables, and otherwise under each tool that left it out.
#
# Diversity isn't computed from those reports. Half the reads of a shotgun sample
# routinely reach no taxon, and an index over the half a database names
# describes the database as much as the sample. Two tools that don't depend on
# one answer instead:
#
#   nonpareil/nonpareil_all_samples.tsv   how much of the community was covered
#   motus/<db>/<sample>_<db>.out          how many species-level clusters there were
#
# Nonpareil's curves are fitted per run of a sample, so a sample sequenced twice
# keeps its deepest run rather than an average.
#
# The feature tables a requester loads are built here too, by
# steps/R/taxprofiler_tables.R in the gnoto-rbiom image: the merged profile as a
# BIOM with a tree in it, so UniFrac and Faith's PD can be computed as they can
# from a 16S run. Two trees carry that: the NCBI taxonomy over the taxa the run
# saw, built by taxprofiler_taxonomy_tree.sh, and the phylogeny MetaPhlAn
# publishes with its database. Faith's PD comes back from both into the
# diversity table, with the share of the run's reads each covers beside it.
#
# Each part is optional and fails on its own: a run missing a report, a
# taxonomy dump or a phylogeny publishes what it can. A missing rbiom image
# fails the step.
#
# Usage:     taxprofiler_composition.sh [results_dir]
#            defaults to ./results, the outdir in the taxprofiler params file
# Called by: the job's Compute stage, from the run directory, after Nextflow and
#            the post-process steps
# Requires:  GNU awk; jq, for the fastp reports; the rbiom image
#            pipelines/taxprofiler/lock.yaml pins, for the feature tables
# Runs:      steps/taxprofiler_taxonomy_tree.sh and steps/R/taxprofiler_tables.R
# Reads:     <results_dir>/, ./taxprofiler_database.csv,
#            ./taxprofiler_samplesheet.csv, and samples.platform in
#            ./run_state.json
# Writes:    <results_dir>/alpha_diversity.tsv, <results_dir>/feature_table/,
#            <results_dir>/count_tables/, ./composition_data.json, and the
#            "statistics" of ./run_state.json
# Env:       the log, warn and fail helpers, the run state helpers, db_path,
#            lock_image and container_exec, from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

RESULTS_DIR=${1:-results}
[[ -d "$RESULTS_DIR" ]] || fail "There's no $RESULTS_DIR directory to summarise."

# Absolute, because the R script reads paths under it inside a container
RESULTS_DIR=$(cd "$RESULTS_DIR" && pwd)

# One folder per database, holding one report per sample
readonly BRACKEN_DIR="$RESULTS_DIR/bracken"
readonly KRAKEN2_DIR="$RESULTS_DIR/kraken2"

# Host removal's own accounting, one log per sample, on a run that depleted one
readonly BOWTIE2_DIR="$RESULTS_DIR/bowtie2/align"

# Quality filtering's own accounting, one report per run of a sample, on the
# short-read path
readonly FASTP_DIR="$RESULTS_DIR/fastp"

readonly NONPAREIL_DIR="$RESULTS_DIR/nonpareil"
readonly NONPAREIL_SUMMARY="nonpareil_all_samples.tsv"
readonly MOTUS_DIR="$RESULTS_DIR/motus"
readonly MOTUS_SUFFIX=".out"

readonly ALPHA_TABLE="$RESULTS_DIR/alpha_diversity.tsv"

readonly TAXPASTA_DIR="$RESULTS_DIR/taxpasta"
readonly METAPHLAN_DIR="$RESULTS_DIR/metaphlan"

# The run's own database sheet first, which its Nextflow read, then any copy in
# the results
readonly DB_SHEET="taxprofiler_database.csv"

# The samples the run was given, written by taxprofiler_samplesheet.sh
readonly SAMPLESHEET="taxprofiler_samplesheet.csv"

readonly R_DIR="$CODE_DIR/steps/R"
readonly TABLES_SCRIPT="$R_DIR/taxprofiler_tables.R"
readonly TREE_SCRIPT="$CODE_DIR/steps/taxprofiler_taxonomy_tree.sh"

# The Overview's own data, in the run directory rather than the results. Every
# number in it comes from a report that is published.
readonly PLOT_DATA="composition_data.json"

readonly STATS_KEY="statistics"

# Named taxa of each rank drawn in their own colour before the tail is summed
# into "Other"; the palette carries eleven. A rank is written out as these, the
# unclassified share, and "Other".
readonly TOP_TAXA=11

# The ranks a stacked bar is offered at, as the letter a kraken2-style report
# codes each with, and the numbers the Overview knows them by. A code with a
# digit, such as S1 or G2, is between two of these and is left out: its reads
# are counted in the clade above it.
readonly RANK_CODES=(P C O F G S)
readonly RANK_NUMBERS=(2 3 4 5 6 7)
readonly RANK_NAMES=(Phylum Class Order Family Genus Species)

# The suffix each kind of report is named with, after the sample and database
readonly BRACKEN_SUFFIX=".bracken.kraken2.report_bracken.txt"
readonly KRAKEN2_SUFFIX=".kraken2.kraken2.report.txt"
readonly METAPHLAN_SUFFIX=".metaphlan_profile.txt"

readonly HUMANN_SUMMARY="$RESULTS_DIR/humann/alignment-summary.tsv"

# Inside the run directory, so the container sees it under the data directory
WORK=$(mktemp -d "$PWD/.composition.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# sample <TAB> report, one line per sample, for each set of reports. The plotted
# set decides the sample order everything else is built in.
PROFILE_SET="$WORK/profiles.tsv"
KRAKEN2_SET="$WORK/kraken2.tsv"

# Every read that reached the classifier, as sample, unclassified and classified
READ_TOTALS="$WORK/reads.tsv"

# Reads a sample lost to the host, or empty for a run that depleted nothing
HOST_TABLE="$WORK/host.tsv"

# What nonpareil measured and how many clusters mOTUs found, one line per sample
NONPAREIL_TABLE="$WORK/nonpareil.tsv"
MOTUS_TABLE="$WORK/motus.tsv"

# mOTUs and MetaPhlAn profiles as "sample <TAB> path"
MOTUS_SET="$WORK/motus_reports.tsv"
METAPHLAN_SET="$WORK/metaphlan_reports.tsv"

# Faith's PD off each tree, as taxprofiler_tables.R returns it
FAITH_TABLE="$WORK/faith.tsv"

# Opened by name inside awk, by passes already reading other files
export PROFILE_SET READ_TOTALS NONPAREIL_TABLE MOTUS_TABLE FAITH_TABLE

# Which tool and database the plots are drawn from, as the sidebar names them
PROFILE_TOOL=""
PROFILE_DB=""

# A report is named "<sample>_<db><suffix>" under a folder named "<db>", which is
# the only place the sample's own name survives
report_sample_name() {
    local path="$1" suffix="$2"
    local name database

    name=${path##*/}
    database=${path%/*}
    database=${database##*/}

    name=${name%"$suffix"}

    printf '%s' "${name%"_$database"}"
}

# Every report of one kind as "sample <TAB> path", in sample order, written where
# the caller says. Fails for a run that produced none.
#
# One database's worth. A run given two databases for one tool profiles every
# sample against each, and the two aren't one measurement to average or stack,
# so the first by name is summarised, and named beside its numbers.
collect_reports() {
    local root="$1" suffix="$2" out="$3"
    local path

    for path in "$root"/*/*"$suffix"; do
        [[ -r "$path" ]] || continue

        printf '%s\t%s\n' "$(report_sample_name "$path" "$suffix")" "$path"
    done | LC_ALL=C sort -k1,1 > "$out"

    [[ -s "$out" ]] || return 1

    LC_ALL=C awk -F'\t' '
        function database(path) {
            sub(/\/[^\/]*$/, "", path)
            sub(/.*\//, "", path)
            return path
        }

        NR == FNR {
            name = database($2)
            if (first == "" || name < first) first = name
            next
        }

        database($2) == first
    ' "$out" "$out" > "$out.one" && mv "$out.one" "$out"

    [[ -s "$out" ]]
}

# The database a set of reports was found under, off the first one's folder
reports_database() {
    local path

    path=$(head -n 1 "$1" | cut -f2)
    path=${path%/*}

    printf '%s' "${path##*/}"
}

# Reads that never reached a taxon, and reads that did, per sample. Only the
# kraken2 report carries the first: bracken drops the unclassified line and
# renormalises over what it placed. The two together are the depth everything
# else here is a share of.
read_totals() {
    local -a reports=("$@")

    LC_ALL=C awk -F'\t' '
        NR == FNR { sample[$2] = $1; next }

        FNR == 1 { name = sample[FILENAME]; seen[name] = 1 }

        # The rank code and taxon id sit at the end of the row, because a report
        # with minimizer counts carries two more columns than one without
        $(NF - 2) == "U"                   { unclassified[name] += $2 }
        $(NF - 2) == "R" && $(NF - 1) == 1 { classified[name] += $2 }

        # Every sample with a report, a blank Kraken2 classified nothing in too
        END {
            for (name in seen)
                printf "%s\t%d\t%d\n", name, unclassified[name] + 0, classified[name] + 0
        }
    ' "$KRAKEN2_SET" "${reports[@]}" | LC_ALL=C sort -k1,1
}

# Reads a sample lost to the host, off bowtie2's summary. The first line counts
# what went in, pairs for a paired run, as the classifier counts them, and the
# rate at the end is the share of them that was host.
host_removal() {
    local path name

    for path in "$BOWTIE2_DIR"/*.bowtie2.log; do
        [[ -r "$path" ]] || continue

        name=${path##*/}
        name=${name%.bowtie2.log}

        LC_ALL=C awk -v name="$name" '
            /reads; of these:/ && !total     { total = $1 + 0 }
            /overall alignment rate/         { rate = $1 + 0 }

            END {
                if (total > 0)
                    printf "%s\t%d\t%d\n", name, total, int(total * rate / 100 + 0.5)
            }
        ' "$path"
    done
}

fastp_reports() {
    local path

    for path in "$FASTP_DIR"/*.fastp.json; do
        [[ -r "$path" ]] || continue

        printf '%s\n' "$path"
    done
}

# Reads that reached quality filtering and reads that came through each of its
# tests, summed over every report, in pairs where the reads are paired, because
# that's what host removal and the classifier count.
#
# fastp makes one pass and buckets a read by the first test it failed: quality,
# then N content, then length, then complexity. So the buckets are disjoint, and
# taking them off the total in that order is what survived each. Its length
# filter covers both ends, so too_long is counted with too_short.
fastp_totals() {
    jq -s -r '
        map({
            mates:      (if (.summary.sequencing // "") | startswith("paired end")
                         then 2 else 1 end),
            before:     (.summary.before_filtering.total_reads // 0),
            passed:     (.filtering_result.passed_filter_reads // 0),
            quality:    (.filtering_result.low_quality_reads // 0),
            ncontent:   (.filtering_result.too_many_N_reads // 0),
            length:     ((.filtering_result.too_short_reads // 0)
                         + (.filtering_result.too_long_reads // 0)),
            complexity: (.filtering_result.low_complexity_reads // 0)
        })
        | "qc_total\t\(map(.before / .mates) | add | floor)\n"
          + "qc_passed\t\(map(.passed / .mates) | add | floor)\n"
          + "qc_cut_quality\t\(map(.quality / .mates) | add | floor)\n"
          + "qc_cut_ncontent\t\(map(.ncontent / .mates) | add | floor)\n"
          + "qc_cut_length\t\(map(.length / .mates) | add | floor)\n"
          + "qc_cut_complexity\t\(map(.complexity / .mates) | add | floor)"
    ' "$@"
}

# The chemistry fastp read off the files, as a reader says it: "2 × 151 bp" for
# a paired run, "151 bp" for a single-ended one. fastp states it as "paired end
# (151 cycles + 151 cycles)". The commonest reading across the run's files is
# taken, and ties go to the one that sorts first, or the page would come out
# differently on two runs of the same data.
read_chemistry() {
    jq -r '.summary.sequencing // empty' "$@" | LC_ALL=C awk '
        { seen[$0]++ }

        END {
            for (line in seen) {
                if (seen[line] < best || (seen[line] == best && line >= text)) continue

                best = seen[line]
                text = line
            }

            while (match(text, /[0-9]+/)) {
                cycles[++n] = substr(text, RSTART, RLENGTH) + 0
                text = substr(text, RSTART + RLENGTH)
            }

            if (n == 1)                                printf "%d bp", cycles[1]
            else if (n >= 2 && cycles[1] == cycles[2]) printf "2 × %d bp", cycles[1]
            else if (n >= 2)                           printf "%d + %d bp", cycles[1], cycles[2]
        }'
}

# The note the read totals are headed with: the platform the samplesheet step
# measured, and the chemistry fastp read. Without a recorded platform, a run
# with fastp reports took the short-read path, and the long-read path has only
# ever been nanopore.
sequencing_summary() {
    local platform chemistry=""

    platform=$(state_get samples.platform)

    if [[ -z "$platform" ]]; then
        if (( ${#FASTP_REPORTS[@]} > 0 )); then
            platform="ILLUMINA"
        else
            platform="OXFORD_NANOPORE"
        fi
    fi

    case "$platform" in
        ILLUMINA)        platform="Illumina" ;;
        OXFORD_NANOPORE) platform="Nanopore" ;;
        PACBIO_SMRT)     platform="PacBio" ;;
    esac

    if (( ${#FASTP_REPORTS[@]} > 0 )); then
        chemistry=$(read_chemistry "${FASTP_REPORTS[@]}")
    fi

    printf '%s%s' "$platform" "${chemistry:+, $chemistry}"
}

# What nonpareil measured, one line per sample, or nothing for a run without it.
#
# NonpareilCurves.R writes one row per curve, labelled with the run it was fitted
# to, and R leaves the header one field short, with no column for the row
# names, so the header is matched to the data rather than assumed. A label is
# matched back to the longest sample name it starts with, since a sample name
# may hold an underscore of its own.
#
# A sample sequenced over several runs keeps its deepest run: every reading here
# saturates with sequencing effort, so the run that saw the most reads is the
# best supported estimate of the same community.
#
# Coverage and redundancy are written as percentages and the efforts in Gbp. A
# reading nonpareil couldn't fit is NA rather than zero.
nonpareil_table() {
    local summary="" path

    for path in "$NONPAREIL_DIR/$NONPAREIL_SUMMARY" "$NONPAREIL_DIR"/*.tsv; do
        [[ -r "$path" ]] || continue

        summary="$path"
        break
    done

    [[ -n "$summary" ]] || return 0

    LC_ALL=C awk -F'\t' '
        function numeric(v) {
            return v ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/
        }

        function reading(v, scale) {
            return numeric(v) ? sprintf("%.4f", v * scale) : "NA"
        }

        function sample_of(label,   name, best) {
            if (label in known) return label

            best = ""
            for (name in known)
                if (index(label, name "_") == 1 && length(name) > length(best))
                    best = name

            return best
        }

        BEGIN {
            while ((getline line < ENVIRON["PROFILE_SET"]) > 0) {
                split(line, field, "\t")
                known[field[1]] = 1
            }
        }

        FNR == 1 {
            for (i = 1; i <= NF; i++) head[i] = $i
            columns = NF
            next
        }

        # Where the header is a field short, every column named in it sits one
        # field to the right
        FNR == 2 {
            shift = (NF == columns + 1) ? 1 : 0
            for (i = 1; i <= columns; i++) column[head[i]] = i + shift
        }

        {
            name = sample_of($1)
            if (name == "") next

            effort = numeric($(column["LR"])) ? $(column["LR"]) + 0 : 0
            if (name in depth && depth[name] >= effort) next

            depth[name]      = effort
            diversity[name]  = reading($(column["diversity"]), 1)
            coverage[name]   = reading($(column["C"]), 100)
            redundancy[name] = reading($(column["kappa"]), 100)
            fit[name]        = reading($(column["modelR"]), 1)
            spent[name]      = reading($(column["LR"]), 1 / 1000000000)
            needed[name]     = reading($(column["LRstar"]), 1 / 1000000000)
        }

        END {
            for (name in diversity)
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", name, diversity[name], \
                    coverage[name], redundancy[name], fit[name], spent[name], needed[name]
        }
    ' "$summary" | LC_ALL=C sort -k1,1
}

# How many mOTUs each sample carried: the rows of its profile that weren't zero,
# less the unassigned row, which isn't a cluster. The count is the last field
# whichever flags mOTUs was given.
motus_table() {
    local -a reports=("$@")

    LC_ALL=C awk -F'\t' '
        NR == FNR { sample[$2] = $1; observed[$1] = 0; next }

        FNR == 1 { name = sample[FILENAME] }

        /^#/               { next }
        $1 == "unassigned" { next }

        $NF + 0 > 0 { observed[name]++ }

        END {
            for (name in observed) printf "%s\t%d\n", name, observed[name]
        }
    ' "$MOTUS_SET" "${reports[@]}" | LC_ALL=C sort -k1,1
}

# -- The feature tables, and the phylogenetic diversity read off them ---------

# The first readable file of those named, or nothing
first_match() {
    local path

    for path in "$@"; do
        [[ -r "$path" ]] || continue

        printf '%s' "$path"
        return 0
    done

    return 1
}

# One column of one tool's row in the database sheet, with a db: name resolved
database_field() {
    local tool="$1" want="$2"
    local sheet value

    sheet=$(first_match "$DB_SHEET" "$RESULTS_DIR/$DB_SHEET") || return 1

    value=$(LC_ALL=C awk -F, -v tool="$tool" -v want="$want" '
        NR == 1 { for (i = 1; i <= NF; i++) idx[$i] = i; next }
        idx["tool"] && idx[want] && $idx["tool"] == tool { print $idx[want]; exit }
    ' "$sheet")

    if [[ "$value" == db:* ]]; then
        value=$(db_path "$value") || return 1
    fi

    printf '%s' "$value"
}

# The taxon ids of a merged taxpasta table, one per line. A kraken2 table has a
# row at every rank, and a clade count plus the counts inside it is the same
# read twice, so only its species rows are taken.
profile_taxon_ids() {
    local path="$1" species_only="$2"

    LC_ALL=C awk -F'\t' -v species_only="$species_only" '
        NR == 1 {
            for (i = 1; i <= NF; i++) idx[$i] = i
            if (!idx["taxonomy_id"]) exit 1
            next
        }

        species_only == 1 && idx["rank"] && $idx["rank"] != "species" { next }

        $idx["taxonomy_id"] ~ /^[0-9]+$/ && $idx["taxonomy_id"] != "0" \
            && $idx["taxonomy_id"] != "1" { print $idx["taxonomy_id"] }
    ' "$path"
}

# The BIOM files a requester loads, and Faith's PD off each tree into
# $FAITH_TABLE. A run missing a profile, a taxonomy dump or the MetaPhlAn
# phylogeny publishes the tables it can and leaves those columns empty.
build_feature_tables() {
    local profile species_only=0
    local taxonomy_dir metaphlan_db metaphlan_name metaphlan_tree=""
    local metaphlan_profile="" tree="" lineage=""
    local metaphlan_dir="" motus_profile="" image output
    local ids="$WORK/taxon_ids.txt"

    if profile=$(first_match "$TAXPASTA_DIR"/bracken_*.tsv); then
        :
    elif profile=$(first_match "$TAXPASTA_DIR"/kraken2_*.tsv); then
        species_only=1
    else
        profile=""
        log "No merged taxpasta profile under $TAXPASTA_DIR; no feature table will be built."
    fi

    # The taxonomy dump the profile's taxon ids come from. The Kraken2 database
    # carries nodes.dmp and names.dmp, which is why taxpasta is pointed at it too.
    taxonomy_dir=$(database_field kraken2 db_path) || taxonomy_dir=""

    if [[ -n "$profile" && -r "$taxonomy_dir/nodes.dmp" ]]; then
        if ! profile_taxon_ids "$profile" "$species_only" > "$ids"; then
            warn "The taxon ids could not be read from ${profile##*/}."
            : > "$ids"
        fi

        if [[ -s "$ids" ]]; then
            tree="$WORK/taxonomy.newick"
            lineage="$WORK/lineage.tsv"

            log "Building the taxonomy tree for $(wc -l < "$ids") taxa..."

            if ! "$TREE_SCRIPT" "$taxonomy_dir" "$ids" "$lineage" > "$tree"; then
                warn "The taxonomy tree could not be built; the feature table will carry none."
                tree=""
                lineage=""
            fi
        fi
    elif [[ -n "$profile" ]]; then
        warn "No nodes.dmp under \"$taxonomy_dir\"; the feature table will carry no tree."
    fi

    # MetaPhlAn's own phylogeny, fetched into its database directory and named
    # after the release
    metaphlan_db=$(database_field metaphlan db_path) || metaphlan_db=""
    metaphlan_name=$(database_field metaphlan db_name) || metaphlan_name=""

    if [[ -n "$metaphlan_db" && -n "$metaphlan_name" \
          && -r "$metaphlan_db/$metaphlan_name.nwk" ]]; then
        metaphlan_tree="$metaphlan_db/$metaphlan_name.nwk"
        metaphlan_profile=$(first_match "$METAPHLAN_DIR"/metaphlan_*_combined_reports.txt) \
            || metaphlan_profile=""
    else
        log "No MetaPhlAn phylogeny beside its database; no SGB table will be built."
    fi

    # What the count tables are read from, none of which needs a tree. The
    # per-sample MetaPhlAn profiles are the only place its read and coverage
    # estimates survive, so this has to run before Present prunes them.
    if [[ -d "$METAPHLAN_DIR" ]] && \
       compgen -G "$METAPHLAN_DIR/*/*_profile.txt" > /dev/null; then
        metaphlan_dir="$METAPHLAN_DIR"
    fi

    motus_profile=$(first_match "$MOTUS_DIR"/motus_*_combined_reports.txt) \
        || motus_profile=""

    if [[ -z "$profile" && -z "$metaphlan_profile" && -z "$metaphlan_dir" \
          && -z "$motus_profile" ]]; then
        return 1
    fi

    # Pulled first, so a missing image fails the step rather than reading as a
    # table that couldn't be assembled
    image=$(lock_image taxprofiler rbiom) || exit 1
    container_sif "$image" > /dev/null || exit 1

    if ! output=$(container_exec "$image" -B "$R_DIR:$R_DIR:ro" \
            Rscript --vanilla "$TABLES_SCRIPT" \
                "$RESULTS_DIR" "$FAITH_TABLE" "$profile" "$species_only" \
                "$tree" "$lineage" "$metaphlan_profile" "$metaphlan_tree" \
                "$metaphlan_dir" "$motus_profile" 2>&1); then
        # The feature tables are core results, so a run without them has failed
        fail "The feature tables couldn't be assembled:"$'\n'"$(tail -n 5 <<< "$output")"
    fi

    [[ -z "$output" ]] || log "$output"

    return 0
}

# Per-sample diversity, as the table published with the results, in the sample
# order everything else on the page follows. The read depth each reading was
# measured at is part of it, and so is nonpareil's model fit, which says whether
# its estimate for that sample is worth reading. Nothing is rarefied.
write_alpha_table() {
    LC_ALL=C awk -F'\t' '
        function reading(v) {
            return v == "" ? "NA" : v
        }

        BEGIN {
            while ((getline line < ENVIRON["READ_TOTALS"]) > 0) {
                split(line, field, "\t")
                depth[field[1]] = field[2] + field[3]
            }

            while ((getline line < ENVIRON["NONPAREIL_TABLE"]) > 0) {
                split(line, field, "\t")
                diversity[field[1]]  = field[2]
                coverage[field[1]]   = field[3]
                redundancy[field[1]] = field[4]
                fit[field[1]]        = field[5]
                spent[field[1]]      = field[6]
                needed[field[1]]     = field[7]
            }

            while ((getline line < ENVIRON["MOTUS_TABLE"]) > 0) {
                split(line, field, "\t")
                motus[field[1]] = field[2]
            }

            # sample, the phylogenetic diversity on the taxonomy, the reads it
            # covered, then the same on the MetaPhlAn phylogeny
            while ((getline line < ENVIRON["FAITH_TABLE"]) > 0) {
                split(line, field, "\t")
                if (field[1] == "sample") continue

                faith[field[1]]     = field[2]
                placed[field[1]]    = field[3]
                faith_sgb[field[1]] = field[4]
                sgb_pct[field[1]]   = field[5]
            }

            print "sample\treads\tnonpareil_diversity\tcoverage_pct\tredundancy_pct" \
                  "\tmodel_fit\teffort_gbp\teffort_95_gbp\tobserved_motus" \
                  "\tfaith_pd\tfaith_pd_basis_pct\tfaith_pd_sgb\tfaith_pd_sgb_basis_pct"
        }

        # The share of the reads that reached the classifier that ended up on
        # the tree the index was computed over, so a reader can tell a reading
        # over half a sample from one over all of it
        function basis(name,   total) {
            total = depth[name] + 0

            if (!(name in placed) || placed[name] == "NA" || total <= 0) return "NA"

            return sprintf("%.2f", placed[name] * 100 / total)
        }

        {
            name = $1

            printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                name, depth[name] + 0, \
                reading(diversity[name]), reading(coverage[name]), \
                reading(redundancy[name]), reading(fit[name]), reading(spent[name]), \
                reading(needed[name]), reading(motus[name]), \
                reading(faith[name]), basis(name), \
                reading(faith_sgb[name]), reading(sgb_pct[name])
        }
    ' "$PROFILE_SET"
}

# Whether a column of the table has a reading for at least one sample
alpha_has_column() {
    LC_ALL=C awk -F'\t' -v want="$1" '
        NR == 1 {
            for (i = 1; i <= NF; i++) if ($i == want) column = i
            next
        }

        column && $column ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/ {
            found = 1
            exit
        }

        END { exit !found }
    ' "$ALPHA_TABLE"
}

# The readings the Overview's diversity chart offers, and how to write each.
# Only this script knows which the run produced. The first is the one the chart
# opens on: estimated coverage, because it says whether the rest is worth
# reading at all, and it's the one a requester asks about first. Each names the
# tool it came from, which the page prints under the chart.
#
# A coverage is a share of a whole, so its axis tops out at 100. A read depth is
# drawn on a square root, or a run with one sample a hundred times deeper than
# the rest draws every other column as a hairline.
#
# Fails for a run that measured no diversity, which leaves the page to hide that
# half rather than chart read depth alone.
composition_metrics() {
    local -a metrics=()

    if alpha_has_column coverage_pct; then
        metrics+=('{"key":"coverage","title":"Estimated coverage","note":"how much of the community the reads reached","places":1,"unit":"%","max":100,"source":"Nonpareil"}')
    fi

    if alpha_has_column nonpareil_diversity; then
        metrics+=('{"key":"diversity","title":"Nonpareil diversity","note":"how varied the community is, read off how often the same sequence recurs rather than off a database","places":2,"source":"Nonpareil"}')
    fi

    if alpha_has_column observed_motus; then
        metrics+=('{"key":"motus","title":"Observed mOTUs","note":"species-level clusters found in universal marker genes","integer":true,"source":"mOTUs"}')
    fi

    if alpha_has_column effort_95_gbp; then
        metrics+=('{"key":"effort95","title":"Effort for 95% coverage","note":"the sequencing this sample would take to reach 95% coverage","places":1,"unit":" Gbp","source":"Nonpareil"}')
    fi

    # It describes only the part of the sample MetaPhlAn detected, and
    # alpha_diversity.tsv carries that share beside it.
    #
    # Its counterpart over the NCBI taxonomy is published in that table but not
    # offered here. On a taxonomy, Faith's PD counts the lineages a classifier
    # named, which rises with how much of the sample the database covers. On
    # one run it correlated +0.57 with the classified fraction and -0.46 with
    # the mOTUs count, while this one correlated +0.99 with that count. The
    # taxonomy tree is shipped in the BIOM for UniFrac, which compares
    # renormalised profiles and doesn't inherit that.
    if alpha_has_column faith_pd_sgb; then
        metrics+=('{"key":"faithsgb","title":"Faith'"'"'s PD","note":"branch length of the published species phylogeny this sample covers, over the species MetaPhlAn detected","places":2,"source":"MetaPhlAn"}')
    fi

    (( ${#metrics[@]} > 0 )) || return 1

    metrics+=('{"key":"reads","title":"Read depth","note":"reads that reached the classifier","integer":true,"scale":"sqrt","source":"the Kraken2 reports"}')

    local IFS=,
    printf '%s' "${metrics[*]}"
}

# The sample names alone, for a run whose diversity table couldn't be built. The
# page defaults every other array, so composition still draws.
samples_json() {
    LC_ALL=C awk -F'\t' '
        function json_string(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return "\"" s "\""
        }

        { out = out (NR > 1 ? "," : "") json_string($1) }

        END { printf "\"samples\":[%s]", out }
    ' "$PROFILE_SET"
}

# The diversity table as the arrays the plots read, plus the sample names every
# other array is ordered by
alpha_json() {
    LC_ALL=C awk -F'\t' '
        function json_string(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return "\"" s "\""
        }

        # A reading nothing produced is null rather than zero: a sample nonpareil
        # could not fit has no diversity to report, which is not none
        function number(v) {
            return v ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/ \
                ? v + 0 : "null"
        }

        function series(name, column,   i, out) {
            out = "\"" name "\":["

            for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") value[i, column]

            return out "]"
        }

        FNR == 1 { next }

        {
            n++
            name[n] = $1
            for (i = 2; i <= NF; i++) value[n, i] = number($i)
        }

        END {
            out = "\"samples\":["

            for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") json_string(name[i])

            printf "%s],%s,\"alpha\":{%s,%s,%s,%s,%s}", out, series("reads", 2), \
                series("diversity", 3), series("coverage", 4), \
                series("effort95", 8), series("motus", 9), \
                series("faithsgb", 12)
        }
    ' "$ALPHA_TABLE"
}

# Every rank as the array of objects the page stacks its bars from.
#
# Two passes over the reports, which is why they're given twice, with every rank
# worked out in each: a shotgun report is megabytes per sample. The first pass
# sums each taxon across every sample, which decides the eleven drawn; the second
# emits only those, in the canonical sample order, with the rest left to
# "Other". So only twelve rows of data are held per rank, however many taxa it
# has.
#
# A report is indented two spaces per step down the taxonomy, its only record of
# what sits above a taxon, so the ancestors are carried in a stack as the file is
# read. A taxon is keyed by that lineage as well as its name, so two genera of the
# same name in different families stay apart.
#
# Shares are ten-thousandths, and "Other" is what's left of ten thousand, so a
# stack always closes exactly.
levels_json() {
    local -a reports=("$@")

    LC_ALL=C awk -F'\t' -v codes="${RANK_CODES[*]}" -v numbers="${RANK_NUMBERS[*]}" \
            -v names="${RANK_NAMES[*]}" -v top="$TOP_TAXA" -v nfiles="$#" '
        function json_string(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return "\"" s "\""
        }

        function trim(s) {
            sub(/^ +/, "", s)
            return s
        }

        # What sits above a taxon, at the ranks a lineage is read at
        function ancestry(depth,   i, out) {
            out = ""

            for (i = 0; i < depth; i++) {
                if (code[i] !~ /^[DKPCOFG]$/ && !(id[i] in DOMAIN)) continue

                out = out (out == "" ? "" : " > ") path[i]
            }

            return out
        }

        # Mean share of a sample, in ten-thousandths
        function mean(rank, key) {
            return int(total[rank, key] / samples * 10000 + 0.5)
        }

        # The head of the taxa of one rank, ranked by that mean and kept by
        # insertion, so the tail is never sorted. Ties go to the key that sorts
        # first, or the page would come out differently on two runs of the same
        # data.
        #
        # The unclassified share never competes for a place. The page does not
        # draw it, so a rank where it ranked high, which on a shotgun run is
        # every rank, came out a taxon short. It goes after them instead, which
        # keeps it out of the colours and leaves "Other" as what is left.
        function choose(rank,   combined, part, key, place) {
            for (combined in total) {
                split(combined, part, SUBSEP)

                if (part[1] != rank) continue

                key = part[2]

                if (key == UNCLASSIFIED) continue

                place = drawn[rank] < top ? drawn[rank] + 1 : top + 1

                while (place > 1 && \
                       (total[rank, taxon[rank, place - 1]] < total[rank, key] || \
                        (total[rank, taxon[rank, place - 1]] == total[rank, key] && \
                         taxon[rank, place - 1] > key))) {
                    taxon[rank, place] = taxon[rank, place - 1]
                    place--
                }

                if (place > top) continue

                taxon[rank, place] = key
                if (drawn[rank] < top) drawn[rank]++
            }

            if ((rank, UNCLASSIFIED) in total) {
                taxon[rank, ++drawn[rank]] = UNCLASSIFIED
            }

            for (place = 1; place <= drawn[rank]; place++)
                chosen[rank, taxon[rank, place]] = place
        }

        # The reads no taxon was found for, entered at every rank as a taxon of
        # their own once each sample is totalled
        function rank_unclassified(   r, rank, name, place, share) {
            for (r = 1; r <= ranks; r++) {
                rank = code_of[r]

                for (name in position) {
                    if (depth[name] > 0 && missed[name] > 0)
                        total[rank, UNCLASSIFIED] += missed[name] / depth[name]
                }

                choose(rank)

                place = chosen[rank, UNCLASSIFIED]
                if (!place) continue

                for (name in position) {
                    if (depth[name] <= 0) continue

                    share = int(missed[name] / depth[name] * 10000 + 0.5)

                    value[rank, place, position[name]] = share
                    if (share > 0) present[rank, place]++
                }
            }
        }

        BEGIN {
            ranks = split(codes, code_of, " ")
            split(numbers, number_of, " ")
            split(names, name_of, " ")

            for (i = 1; i <= ranks; i++) plotted[code_of[i]] = 1

            # The top of a taxonomy, which a kraken2 database codes as a rank of
            # its own rather than one a lineage is read at
            split("2 2157 2759 10239 12884", domains, " ")
            for (i in domains) DOMAIN[domains[i]] = 1

            UNCLASSIFIED = "\tUnclassified"

            while ((getline line < ENVIRON["READ_TOTALS"]) > 0) {
                split(line, field, "\t")
                depth[field[1]] = field[2] + field[3]
                missed[field[1]] = field[2] + 0
            }

            while ((getline line < ENVIRON["PROFILE_SET"]) > 0) {
                split(line, field, "\t")
                position[field[1]] = ++samples
                sample[field[2]] = field[1]
            }
        }

        FNR == 1 {
            if (++seen == nfiles + 1) rank_unclassified()

            name = sample[FILENAME]
            column = position[name]

            delete path
            delete code
            delete id
        }

        {
            label = $NF
            here = int((length(label) - length(trim(label))) / 2)
            label = trim(label)

            rank = $(NF - 2)

            path[here] = label
            code[here] = rank
            id[here] = $(NF - 1)

            if (!(rank in plotted) || depth[name] <= 0) next

            key = ancestry(here) "\t" label

            if (seen <= nfiles) {
                total[rank, key] += $2 / depth[name]
                next
            }

            place = chosen[rank, key]
            if (!place) next

            share = int($2 / depth[name] * 10000 + 0.5)

            value[rank, place, column] = share
            if (share > 0) present[rank, place]++
        }

        END {
            for (r = 1; r <= ranks; r++) {
                rank = code_of[r]

                printf "%s{\"rank\":%d,\"name\":%s,\"taxa\":[", (r > 1 ? "," : ""), \
                    number_of[r], json_string(name_of[r])

                for (t = 1; t <= drawn[rank]; t++) {
                    key = taxon[rank, t]
                    split(key, field, "\t")

                    printf "%s{\"label\":%s,\"lineage\":%s,\"mean\":%d,\"prevalence\":%d}", \
                        (t > 1 ? "," : ""), json_string(field[2]), json_string(field[1]), \
                        mean(rank, key), int((present[rank, t] + 0) / samples * 100 + 0.5)
                }

                rest = 10000
                for (t = 1; t <= drawn[rank]; t++) rest -= mean(rank, taxon[rank, t])

                printf "%s{\"label\":\"Other\",\"lineage\":\"\",\"mean\":%d,\"prevalence\":0}],", \
                    (drawn[rank] > 0 ? "," : ""), (rest > 0 ? rest : 0)

                printf "\"values\":["

                for (t = 1; t <= drawn[rank]; t++) {
                    printf "%s[", (t > 1 ? "," : "")
                    for (s = 1; s <= samples; s++)
                        printf "%s%d", (s > 1 ? "," : ""), value[rank, t, s] + 0
                    printf "]"
                }

                printf "%s[", (drawn[rank] > 0 ? "," : "")

                for (s = 1; s <= samples; s++) {
                    rest = 10000
                    for (t = 1; t <= drawn[rank]; t++) rest -= value[rank, t, s] + 0
                    printf "%s%d", (s > 1 ? "," : ""), (rest > 0 ? rest : 0)
                }

                printf "]]}"
            }
        }
    ' "${reports[@]}" "${reports[@]}"
}

# Reads the classifier placed inside some clade of one rank, summed over the
# run. Read off the kraken2 reports whichever set is plotted, because bracken
# pushes every read it can down to a species.
rank_resolved_reads() {
    local rank="$1"
    shift

    LC_ALL=C awk -F'\t' -v rank="$rank" '
        $(NF - 2) == rank { total += $2 }
        END { print total + 0 }
    ' "$@"
}

# Read depth across the samples, off what the classifier was given. The median
# rather than the mean, which one deep sample drags away from the rest.
read_depth_stats() {
    LC_ALL=C awk -F'\t' '
        {
            reads = $2 + $3
            sum += reads
            classified += $3 + 0
            depth[++n] = reads
        }

        END {
            if (n) {
                asort(depth)
                median = n % 2 ? depth[(n + 1) / 2] \
                               : (depth[n / 2] + depth[n / 2 + 1]) / 2
            }

            printf "reads_total\t%d\nreads_classified\t%d\n", sum + 0, classified + 0
            printf "reads_median\t%d\nreads_min\t%d\nreads_max\t%d\n", \
                median + 0.5, depth[1] + 0, depth[n] + 0
        }
    ' "$READ_TOTALS"
}

# The reads that reached the classifier on the samples MetaPhlAn profiled, and
# how many of them it mapped to a known clade. Each profile's header gives the
# reads it processed and mapped, and that share is weighed by the sample's depth
# here, since MetaPhlAn counts each mate of a pair on its own.
metaphlan_mapping() {
    local -a profiles=()

    mapfile -t profiles < <(cut -f2 "$METAPHLAN_SET")

    LC_ALL=C awk -F'\t' '
        function settle() {
            if (name in depth && reads > 0 && known != "") {
                total += depth[name]
                mapped += depth[name] * known / reads
            }
            reads = known = ""
        }

        ARGIND == 1 { depth[$1] = $2 + $3; next }
        ARGIND == 2 { sample[$2] = $1; next }

        FNR == 1 { settle(); name = sample[FILENAME] }

        /^#[0-9]+ reads processed/                  { reads = substr($1, 2) + 0 }
        /^#estimated_reads_mapped_to_known_clades:/ { known = substr($0, index($0, ":") + 1) + 0 }

        END {
            settle()

            if (total > 0)
                printf "metaphlan_total\t%d\nmetaphlan_mapped\t%d\n", total, mapped + 0.5
        }
    ' "$READ_TOTALS" "$METAPHLAN_SET" "${profiles[@]}"
}

# The same for HUMAnN, off its alignment summary: a sample is mapped as far as
# its translated search got, or its nucleotide search where no translated search
# ran
humann_mapping() {
    LC_ALL=C awk -F'\t' '
        NR == FNR { depth[$1] = $2 + $3; next }

        FNR == 1 { next }

        {
            unaligned = $4 != "" ? $4 : $3

            if (unaligned == "" || !($1 in depth)) next

            total += depth[$1]
            mapped += depth[$1] * (100 - unaligned) / 100
        }

        END {
            if (total > 0)
                printf "humann_total\t%d\nhumann_mapped\t%d\n", total, mapped + 0.5
        }
    ' "$READ_TOTALS" "$HUMANN_SUMMARY"
}

# The samples the run was given, one per line in samplesheet order. A sample
# sequenced in more than one run has a row for each.
given_samples() {
    LC_ALL=C awk -F',' 'NR > 1 && !seen[$1]++ { print $1 }' "$SAMPLESHEET"
}

# Of the samples on stdin, those that aren't the first column of any row of a
# table after its header lines, space-separated
not_in_table() {
    local table="$1" header="$2"

    LC_ALL=C awk -F'\t' -v header="$header" '
        NR == FNR     { if (FNR > header) have[$1] = 1; next }
        !($1 in have) { printf "%s%s", (n++ ? " " : ""), $1 }
        END           { if (n) printf "\n" }
    ' "$table" -
}

# The samples missing from the run's outputs, as statistics: those the plotted
# profiler has no report on, which are in none of the plots or feature tables,
# and of the rest, those MetaPhlAn, mOTUs, Nonpareil or HUMAnN left out. A tool
# that profiled no sample, such as MetaPhlAn on a long-read run, names none.
sample_gaps() {
    local dropped gap entry key table header

    if [[ -r "$SAMPLESHEET" ]]; then
        dropped=$(given_samples | not_in_table "$PROFILE_SET" 0)
        [[ -z "$dropped" ]] || printf 'samples_dropped\t%s\n' "$dropped"
    fi

    for entry in "metaphlan_missing|$METAPHLAN_SET|0" "motus_missing|$MOTUS_SET|0" \
                 "nonpareil_missing|$NONPAREIL_TABLE|0" "humann_missing|$HUMANN_SUMMARY|1"; do
        IFS='|' read -r key table header <<< "$entry"
        [[ -s "$table" ]] || continue

        gap=$(cut -f1 "$PROFILE_SET" | not_in_table "$table" "$header")
        [[ -z "$gap" ]] || printf '%s\t%s\n' "$key" "$gap"
    done

    return 0
}

# The run's headline numbers, keyed for the sidebar. Each is left out rather
# than guessed when the reports behind it are missing.
write_run_statistics() {
    local -a kraken2=()

    mapfile -t kraken2 < <(cut -f2 "$KRAKEN2_SET")

    {
        printf 'profiler\t%s\n' "$PROFILE_TOOL"
        printf 'database\t%s\n' "$PROFILE_DB"
        printf 'samples\t%s\n'  "$(wc -l < "$PROFILE_SET")"
        printf 'platform\t%s\n' "$(sequencing_summary)"

        read_depth_stats

        if (( ${#FASTP_REPORTS[@]} > 0 )); then
            fastp_totals "${FASTP_REPORTS[@]}"
        fi

        printf 'phylum_reads\t%s\n'  "$(rank_resolved_reads P "${kraken2[@]}")"
        printf 'genus_reads\t%s\n'   "$(rank_resolved_reads G "${kraken2[@]}")"
        printf 'species_reads\t%s\n' "$(rank_resolved_reads S "${kraken2[@]}")"

        if [[ -s "$HOST_TABLE" ]]; then
            LC_ALL=C awk -F'\t' '
                { total += $2; removed += $3 }
                END { printf "host_total\t%d\nhost_removed\t%d\n", total, removed }
            ' "$HOST_TABLE"
        fi

        if [[ -s "$METAPHLAN_SET" ]]; then
            printf 'metaphlan_database\t%s\n' "$(reports_database "$METAPHLAN_SET")"
            metaphlan_mapping
        fi

        if [[ -s "$HUMANN_SUMMARY" ]]; then
            humann_mapping
        fi

        sample_gaps
    } | state_set_tsv "$STATS_KEY"
}

log "Summarising composition and diversity under $RESULTS_DIR..."

# 1. The reports the run published, and which of them the plots are drawn from
if ! collect_reports "$KRAKEN2_DIR" "$KRAKEN2_SUFFIX" "$KRAKEN2_SET"; then
    log "No kraken2 reports under $KRAKEN2_DIR; the Overview will show no plots."
    exit 0
fi

if collect_reports "$BRACKEN_DIR" "$BRACKEN_SUFFIX" "$PROFILE_SET"; then
    PROFILE_TOOL="Bracken"
    PROFILE_DB=$(reports_database "$PROFILE_SET")

    # taxprofiler names a bracken database after the kraken2 one it was built
    # from, which the tool beside it already says
    PROFILE_DB=${PROFILE_DB%_bracken}
else
    cp "$KRAKEN2_SET" "$PROFILE_SET"

    PROFILE_TOOL="Kraken2"
    PROFILE_DB=$(reports_database "$PROFILE_SET")

    log "No bracken reports under $BRACKEN_DIR; plotting kraken2's own counts."
fi

mapfile -t PROFILES < <(cut -f2 "$PROFILE_SET")
mapfile -t KRAKEN2_REPORTS < <(cut -f2 "$KRAKEN2_SET")

read_totals "${KRAKEN2_REPORTS[@]}" > "$READ_TOTALS"
host_removal > "$HOST_TABLE"

declare -a FASTP_REPORTS=()
mapfile -t FASTP_REPORTS < <(fastp_reports)

collect_reports "$METAPHLAN_DIR" "$METAPHLAN_SUFFIX" "$METAPHLAN_SET" \
    || log "No MetaPhlAn profiles under $METAPHLAN_DIR; its mapping rate will be missing."

# 2. Diversity, as nonpareil and mOTUs measured it. Neither is required.
if ! nonpareil_table > "$NONPAREIL_TABLE"; then
    warn "The nonpareil summary could not be read; coverage and Nd will be missing."
    : > "$NONPAREIL_TABLE"
elif [[ ! -s "$NONPAREIL_TABLE" ]]; then
    log "No nonpareil summary under $NONPAREIL_DIR; coverage and Nd will be missing."
fi

: > "$MOTUS_TABLE"

if collect_reports "$MOTUS_DIR" "$MOTUS_SUFFIX" "$MOTUS_SET"; then
    mapfile -t MOTUS_REPORTS < <(cut -f2 "$MOTUS_SET")

    if ! motus_table "${MOTUS_REPORTS[@]}" > "$MOTUS_TABLE"; then
        warn "The mOTUs profiles could not be counted; the cluster counts will be missing."
        : > "$MOTUS_TABLE"
    fi
else
    log "No mOTUs profiles under $MOTUS_DIR; the cluster counts will be missing."
fi

# 3. The feature tables, and the phylogenetic diversity read off their trees,
#    ahead of the diversity table, whose last four columns come from them
: > "$FAITH_TABLE"

build_feature_tables \
    || log "No feature table was built; the diversity table keeps its other columns."

[[ -s "$FAITH_TABLE" ]] || log "This run measured no phylogenetic diversity."

# The diversity half fails on its own: composition and the sidebar owe this
# table nothing
if ! write_alpha_table > "$ALPHA_TABLE"; then
    warn "The diversity table could not be built; the Overview will plot composition only."
    rm -f "$ALPHA_TABLE"
fi

if [[ -s "$ALPHA_TABLE" ]]; then
    DATA=$(alpha_json)

    # A run that measured nothing leaves metrics off, which hides that half of
    # the panel
    if METRICS=$(composition_metrics); then
        DATA="\"metrics\":[$METRICS],$DATA"
    else
        log "This run measured no diversity; the Overview will plot composition only."
    fi
else
    DATA=$(samples_json)
fi

# What the reader is shown a count of, so the page says species where the 16S
# page says ASV
DATA="\"feature\":{\"one\":\"species\",\"many\":\"species\",\"depth\":\"reads that reached the classifier\"},$DATA"

# 4. Composition, every rank in the order a reader reads them
LEVELS=""

if ! LEVELS=$(levels_json "${PROFILES[@]}"); then
    warn "The abundance counts could not be summarised; composition is left unplotted."
    LEVELS=""
fi

DATA+=",\"levels\":[$LEVELS]"

# 5. The run's headline numbers
if ! write_run_statistics; then
    warn "The run statistics could not be counted; the dashboard will show fewer numbers."
    state_unset "$STATS_KEY" || true
fi

if ! printf '{%s}\n' "$DATA" > "$PLOT_DATA"; then
    rm -f "$PLOT_DATA"
    fail "The composition and diversity data could not be written."
fi

log "Wrote $PLOT_DATA for $(wc -l < "$PROFILE_SET") samples."
