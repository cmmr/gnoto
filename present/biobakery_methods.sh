#!/bin/bash
#
# biobakery_methods.sh - Writes the methods text a biobakery run's Methods page
# shows.
#
# Run by:    present/biobakery.sh, before it prunes the KneadData logs
# Usage:     biobakery_methods.sh [results_dir]
#            results_dir defaults to ./results
# Requires:  jq and yq
# Reads:     <results_dir>/kneaddata/logs/*.log, the samplesheet, params and
#            statistics.layout in ./run_state.json, nextflow.out,
#            pipelines/databases.yaml, pipelines/references.yaml and
#            modules/*.nf
# Writes:    ./methods_data.json: {paragraphs: [...], references: {id: {...}}}
#
# One paragraph for a manuscript's methods section, saying how this run's
# profiles were made from its reads: the steps, the tools, and the databases.
#
# Versions are the BioContainers tags the modules pin, and the tools inside
# those images, such as Trimmomatic and Bowtie2, are named by the image. While
# the modules name gnoto-kneaddata, KneadData is the version its code reports,
# at the commit images/gnoto-kneaddata/Dockerfile names. Host depletion is
# described by the Bowtie2 options in the run's params, and KneadData's steps
# as each sample's log recorded them. A run whose logs are gone is described by
# KneadData's defaults, without the read length.
#
# Databases are the run's db: names, described by their entry in
# pipelines/databases.yaml: a release, the genomes a host reference was built
# from, a dataset DOI, and what to cite. A name with no entry is named by its
# folder.
#
# Citations are written [@id], for ids of pipelines/references.yaml, and
# present/dashboard.sh renders them author-year. A tool named again, or a
# database whose citation is its tool's, isn't cited twice.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

RESULTS_DIR=${1:-results}
RESULTS_DIR=${RESULTS_DIR%/}
METHODS_DATA=methods_data.json

state_has params || fail "This run recorded no parameters, so its methods can't be described."

DATABASES=$(yq -o=json '.' "$CODE_DIR/pipelines/databases.yaml") ||
    fail "Can't read $CODE_DIR/pipelines/databases.yaml."
REFERENCES=$(yq -o=json '.' "$CODE_DIR/pipelines/references.yaml") ||
    fail "Can't read $CODE_DIR/pipelines/references.yaml."

# The image a module pins for a tool, by the tag in the comment after its
# digest, such as quay.io/biocontainers/humann:3.9--py312hdfd78af_0, or nothing
container_image() {
    { grep -ho "container '[^']*' // [^ ,]*/$1:[^ ,]*" "$CODE_DIR"/modules/*.nf || :; } |
        head -n 1 | sed 's#.* // ##'
}

# The tool's version in that image's tag, such as 3.9
tool_version() {
    local image
    image=$(container_image "$1")
    image=${image##*:}
    printf '%s' "${image%%--*}"
}

# A tool as the text names it: "HUMAnN v3.9", or "HUMAnN" with no version
named() {
    printf '%s%s' "$1" "${2:+ v$2}"
}

# Words as a sentence lists them: "a", "a and b", "a, b, and c"
and_list() {
    case $# in
        0) ;;
        1) printf '%s' "$1" ;;
        2) printf '%s and %s' "$1" "$2" ;;
        *)
            printf '%s, ' "${@:1:$#-1}"
            printf 'and %s' "${!#}"
            ;;
    esac
}

# " [@a; @b]" for the ids given, into CITATION, marking them cited. cite_new
# leaves out ids already cited.
declare -A CITED=()
CITATION=""

cite() {
    local id
    CITATION=""
    for id in "$@"; do
        [[ -n $id ]] || continue
        CITED[$id]=1
        CITATION+="${CITATION:+; }@$id"
    done
    [[ -z $CITATION ]] || CITATION=" [$CITATION]"
}

cite_new() {
    local id ids=()
    for id in "$@"; do
        [[ -n $id && -z ${CITED[$id]:-} ]] && ids+=("$id")
    done
    cite ${ids[@]+"${ids[@]}"}
}

# The pipelines/databases.yaml entry for a db: name, as compact JSON, into
# ENTRY: the component it names inside an entry, or else the entry it's in.
# Empty for a name the file doesn't describe.
database_entry() {
    local name=${1#db:}
    name=${name%/}
    ENTRY=""
    [[ -n $name && $1 == db:* ]] || return 0
    ENTRY=$(jq -c --arg path "$name" '
        [.databases[] as $db
         | if $db.path == $path then $db
           elif ($path | startswith($db.path + "/"))
           then ($db.components // {})[$path[($db.path | length) + 1:]] // $db
           else empty end][0] // empty' <<< "$DATABASES")
    [[ -n $ENTRY ]] ||
        warn "pipelines/databases.yaml doesn't describe $1, so the methods name it by its folder."
}

entry_get() {
    jq -r "$1 // empty" <<< "$ENTRY"
}

# A database as the text names it, into PHRASE, "the UniRef90 database
# (v201901b)", with the dataset DOI beside the release, and its citations into
# CITATION
database_phrase() {
    local path=$1 name release doi details="" ids=()
    database_entry "$path"
    if [[ -z $ENTRY ]]; then
        path=${path%/}
        PHRASE="the ${path##*/} database"
        CITATION=""
        return 0
    fi
    name=$(entry_get .name)
    release=$(entry_get .release)
    doi=$(entry_get .doi)
    mapfile -t ids < <(entry_get '.cite[]?')
    if [[ -n $release && $name == *"$release"* ]]; then
        name=$release
    elif [[ -n $release ]]; then
        details=$release
    fi
    [[ -n $doi ]] && details+="${details:+, }doi:$doi"
    PHRASE="the $name database${details:+ ($details)}"
    cite_new ${ids[@]+"${ids[@]}"}
}

# The genomes a host reference was built from, into PHRASE, "the human
# T2T-CHM13v2.0 (GCF_009914755.1) and bacteriophage phiX174 (GCF_000819615.1)
# genomes", each with its citations, and the reference's own into CITATION
host_phrase() {
    local path=$1 count i label accession ids=() parts=()
    database_entry "$path"
    if [[ -z $ENTRY ]]; then
        path=${path%/}
        PHRASE="the ${path##*/} reference"
        CITATION=""
        return 0
    fi
    count=$(entry_get '.sources | length')
    for (( i = 0; i < ${count:-0}; i++ )); do
        label=$(entry_get ".sources[$i].label")
        accession=$(entry_get ".sources[$i].accession")
        mapfile -t ids < <(entry_get ".sources[$i].cite[]?")
        cite_new ${ids[@]+"${ids[@]}"}
        parts+=("$label${accession:+ ($accession)}$CITATION")
    done
    PHRASE="the $(and_list ${parts[@]+"${parts[@]}"}) genome"
    (( ${count:-0} > 1 )) && PHRASE+="s"
    mapfile -t ids < <(entry_get '.cite[]?')
    cite_new ${ids[@]+"${ids[@]}"}
}

# The options a run added to a tool, as a clause
extra_options() {
    [[ -z $1 ]] || printf ', with the additional options %s' "$1"
}

# Every distinct value KneadData logged for one of its arguments, a line each
kneaddata_setting() {
    if (( ${#KNEADDATA_LOGS[@]} == 0 )); then
        printf '%s\n' "${KNEADDATA_DEFAULTS[$1]:-}"
        return 0
    fi
    sed -n "s/^$1 = //p" "${KNEADDATA_LOGS[@]}" | LC_ALL=C sort -u
}

# What KneadData logs for these when nothing overrides them
declare -A KNEADDATA_DEFAULTS=(
    [bypass_trim]=False [bypass_trf]=False [trimmomatic_options]=None
    [match]=2 [mismatch]=7 [delta]=7 [pm]=80 [pi]=10 [minscore]=50 [maxperiod]=500
)

# Each sample's Trimmomatic steps as KneadData ran them, one distinct set a
# line, the adapter file named without its folder:
# "MINLEN:60 ILLUMINACLIP:NexteraPE-PE.fa:2:30:10:8:TRUE SLIDINGWINDOW:4:20 MINLEN:75"
trimmomatic_runs() {
    local log
    if (( ${#KNEADDATA_LOGS[@]} == 0 )); then
        if [[ ${SEQUENCER_SOURCE,,} == none ]]; then
            printf 'SLIDINGWINDOW:4:20 MINLEN:half\n'
        else
            printf 'MINLEN:60 ILLUMINACLIP:%s-PE.fa:2:30:10%s SLIDINGWINDOW:4:20 MINLEN:half\n' \
                "$SEQUENCER_SOURCE" "$([[ $LAYOUT == single-end ]] || printf ':8:TRUE')"
        fi
        return 0
    fi
    for log in "${KNEADDATA_LOGS[@]}"; do
        { grep -m 1 "Execute command: .*trimmomatic" "$log" || :; } |
            grep -oE ' [A-Z]+:[^ ]+' |
            sed 's#^ ##; s#^ILLUMINACLIP:.*/#ILLUMINACLIP:#' |
            paste -sd ' ' -
    done | sed '/^$/d' | LC_ALL=C sort -u
}

# What one Trimmomatic step did, given its name, every value it took over the
# samples (a line each), and whether it's the first. A value that differed,
# such as the final MINLEN, which KneadData sets to half each sample's read
# length, is given as its range.
trimmomatic_step() {
    local name=$1 values=$2 first=$3 low high value setting
    low=$(sort -n <<< "$values" | head -n 1)
    high=$(sort -n <<< "$values" | tail -n 1)
    value=$low
    [[ $low == "$high" ]] || value="$low–$high"
    setting="$name:$value"
    [[ $name == ILLUMINACLIP ]] && setting="$name:$(paste -sd '|' - <<< "$values" | sed 's/|/ or /g')"

    case $name in
        MINLEN)
            if [[ $value == half ]]; then
                printf 'discarded reads left shorter than half of the input read length'
            elif [[ -n $first ]]; then
                printf 'discarded reads shorter than %s bp (%s)' "$value" "$setting"
            elif [[ $low != "$high" && $DEFAULT_TRIMMING == true ]]; then
                printf "discarded reads left shorter than half of each sample's read length (%s)" "$setting"
            elif [[ $low != "$high" ]]; then
                printf 'discarded reads left shorter than %s bp, depending on the sample (%s)' "$value" "$setting"
            elif [[ $DEFAULT_TRIMMING == true ]]; then
                printf 'discarded reads left shorter than %s bp, half of the input read length (%s)' "$value" "$setting"
            else
                printf 'discarded reads left shorter than %s bp (%s)' "$value" "$setting"
            fi
            ;;
        ILLUMINACLIP) printf 'clipped adapter sequences (%s)' "$setting" ;;
        SLIDINGWINDOW)
            printf 'cut each read at the first %s-base window whose mean quality fell below %s (%s)' \
                "${value%%:*}" "${value#*:}" "$setting"
            ;;
        LEADING) printf 'removed leading bases of quality below %s (%s)' "$value" "$setting" ;;
        TRAILING) printf 'removed trailing bases of quality below %s (%s)' "$value" "$setting" ;;
        HEADCROP) printf 'removed the first %s bases of each read (%s)' "$value" "$setting" ;;
        CROP) printf 'cut each read to %s bases (%s)' "$value" "$setting" ;;
        AVGQUAL) printf 'discarded reads of mean quality below %s (%s)' "$value" "$setting" ;;
        *) printf 'applied %s' "$setting" ;;
    esac
}

# The Trimmomatic steps as a clause, in the order they ran
trimmomatic_clause() {
    local runs=() first=() steps=() fields=() i run name values position
    mapfile -t runs < <(trimmomatic_runs)
    (( ${#runs[@]} > 0 )) || return 0
    read -ra first <<< "${runs[0]}"
    for (( i = 0; i < ${#first[@]}; i++ )); do
        name=${first[i]%%:*}
        values=""
        position=""
        (( i > 0 )) || position=first
        for run in "${runs[@]}"; do
            read -ra fields <<< "$run"
            [[ ${fields[i]:-} == "$name":* ]] && values+="${fields[i]#*:}"$'\n'
        done
        values=$(LC_ALL=C sort -u <<< "${values%$'\n'}")
        steps+=("$(trimmomatic_step "$name" "$values" "$position")")
    done
    and_list "${steps[@]}"
}

# 1. What the run was given
NEXTFLOW_VERSION=$(sed -n 's/^ *N E X T F L O W *~ *version \([0-9][0-9.]*\).*/\1/p' nextflow.out 2> /dev/null | head -n 1)
HOST_DB=$(state_get params.kneaddata_db)
HOST_PREFILTER_OPTIONS=$(state_get params.host_prefilter_bowtie2_options)
HOST_OPTIONS=$(state_get params.host_bowtie2_options)
SEQUENCER_SOURCE=$(state_get params.kneaddata_sequencer_source)
KNEADDATA_ARGS=$(state_get params.kneaddata_args)
METAPHLAN_DB=$(state_get params.metaphlan_db)
METAPHLAN_ARGS=$(state_get params.metaphlan_args)
RUN_HUMANN=$(state_get params.run_humann)
RUN_MOTUS=$(state_get params.run_motus)
RUN_NONPAREIL=$(state_get params.run_nonpareil)
RUN_ESVIRITU=$(state_get params.run_esviritu)
RUN_MARKERMAGU=$(state_get params.run_markermagu)
HUMANN_CHOCOPHLAN=$(state_get params.humann_chocophlan)
HUMANN_UNIREF=$(state_get params.humann_uniref)
ESVIRITU_DB=$(state_get params.esviritu_db)
ESVIRITU_ARGS=$(state_get params.esviritu_args)
MARKERMAGU_DB=$(state_get params.markermagu_db)
MARKERMAGU_DETECTION=$(state_get params.markermagu_detection)
MARKERMAGU_ARGS=$(state_get params.markermagu_args)
LAYOUT=$(state_get statistics.layout)
SAMPLESHEET=$(state_get params.input)

: "${SEQUENCER_SOURCE:=NexteraPE}"
: "${HOST_PREFILTER_OPTIONS:=--fast}"
: "${HOST_OPTIONS:=--very-sensitive-local}"

KNEADDATA_LOGS=()
for log in "$RESULTS_DIR"/kneaddata/logs/*.log; do
    [[ -r $log ]] && KNEADDATA_LOGS+=("$log")
done

# The samples the samplesheet lists more than one sequencing run for
SAMPLE_RUNS=()
if [[ -n $SAMPLESHEET && -r $SAMPLESHEET ]]; then
    mapfile -t SAMPLE_RUNS < <(tail -n +2 "$SAMPLESHEET" | cut -d, -f1 | LC_ALL=C sort | uniq -d)
fi

[[ -n $METAPHLAN_DB ]] || fail "This run recorded no MetaPhlAn database, so its methods can't be described."

TOOLS=(kneaddata metaphlan)
[[ $RUN_HUMANN == true ]] && TOOLS+=(humann)
[[ $RUN_MOTUS == true ]] && TOOLS+=(motus)
[[ $RUN_NONPAREIL == true ]] && TOOLS+=(nonpareil)
[[ $RUN_ESVIRITU == true ]] && TOOLS+=(esviritu)
[[ $RUN_MARKERMAGU == true ]] && TOOLS+=(marker-magu)
TOOLS+=(multiqc)

IMAGES=()
for tool in "${TOOLS[@]}"; do
    image=$(container_image "$tool")
    [[ -n $image ]] && IMAGES+=("$image")
done

# KneadData as the text names it, and gnoto-kneaddata's base image and commit
# when the modules name that image
KNEADDATA_IMAGE=$(container_image gnoto-kneaddata)
KNEADDATA_BASE=""
KNEADDATA_COMMIT=""
if [[ -n $KNEADDATA_IMAGE ]]; then
    RECIPE=$CODE_DIR/images/gnoto-kneaddata/Dockerfile
    KNEADDATA_BASE=$(sed -n 's/^FROM \([^@ ]*\).*/\1/p' "$RECIPE" 2> /dev/null | head -n 1)
    KNEADDATA_COMMIT=$(sed -n 's#.*/archive/\([0-9a-f]\{7\}\)[0-9a-f]*\.tar\.gz.*#\1#p' "$RECIPE" 2> /dev/null | head -n 1)
    KNEADDATA_NAME=$(named KneadData "$(sed -n "s/.*'kneaddata v\([0-9.]*\)'.*/\1/p" "$RECIPE" 2> /dev/null | head -n 1)")
    KNEADDATA_NAME+=${KNEADDATA_COMMIT:+ (commit $KNEADDATA_COMMIT)}
else
    KNEADDATA_NAME=$(named KneadData "$(tool_version kneaddata)")
fi

# 2. The workflow, and the images the tools ran from
cite ditommaso2017
TEXT="Sequencing reads were processed with a $(named Nextflow "$NEXTFLOW_VERSION")$CITATION workflow"
cite daveigaleprevost2017
TEXT+=" that ran each tool from a BioContainers image$CITATION"
(( ${#IMAGES[@]} == 0 )) || TEXT+=" ($(and_list "${IMAGES[@]}"))"
HOST_IMAGE=$(container_image bowtie2_htslib_samtools_pigz)
if [[ -n $HOST_DB && -n $HOST_IMAGE ]]; then
    TEXT+=", and Bowtie2 for host depletion from the Seqera Containers image $HOST_IMAGE"
fi
TEXT+="."
if [[ -n $KNEADDATA_IMAGE ]]; then
    TEXT+=" KneadData ran from $KNEADDATA_IMAGE"
    [[ -n $KNEADDATA_BASE ]] && TEXT+=", which is $KNEADDATA_BASE"
    [[ -n $KNEADDATA_COMMIT ]] && TEXT+=" with KneadData's code from commit $KNEADDATA_COMMIT of its repository"
    TEXT+="."
fi

# 3. Host depletion, KneadData as its logs recorded it, and the quality reports
if (( ${#KNEADDATA_LOGS[@]} == 0 )); then
    warn "There are no KneadData logs in $RESULTS_DIR/kneaddata/logs, so the methods describe KneadData's defaults."
fi

if [[ -n $HOST_DB ]]; then
    host_phrase "$HOST_DB"
    TEXT+=" Reads aligning to $PHRASE"
    [[ -n $ENTRY ]] && TEXT+=" from NCBI RefSeq"
    TEXT+="$CITATION"
    cite langmead2012
    TEXT+=" were removed from each sequencing run with Bowtie2$CITATION"
    TEXT+=", each read aligned on its own"
    [[ $LAYOUT == *paired* ]] && TEXT+=" and a pair removed when either mate aligned"
    TEXT+=": first end to end ($HOST_PREFILTER_OPTIONS) over every read,"
    TEXT+=" then with $HOST_OPTIONS over the reads the first pass left."
fi

if (( ${#SAMPLE_RUNS[@]} > 0 )); then
    TEXT+=" Where a sample was sequenced in more than one run, the reads of its runs were then concatenated."
fi

cite beghini2021
TEXT+=" Reads were quality controlled with $KNEADDATA_NAME$CITATION"
TEXT+="$(extra_options "$KNEADDATA_ARGS")."

TRIMMED=""
REPEATS=""
if [[ $(kneaddata_setting bypass_trim) != True ]]; then
    DEFAULT_TRIMMING=false
    [[ $(kneaddata_setting trimmomatic_options) == None ]] && DEFAULT_TRIMMING=true
    TRIMMING=$(trimmomatic_clause)
    if [[ -n $TRIMMING ]]; then
        cite bolger2014
        TEXT+=" Trimmomatic$CITATION $TRIMMING."
        TRIMMED=1
    fi
fi

if [[ $(kneaddata_setting bypass_trf) != True ]]; then
    cite benson1999
    TEXT+=" Reads in which Tandem Repeats Finder$CITATION detected a tandem repeat were removed"
    TEXT+=" (match $(kneaddata_setting match), mismatch $(kneaddata_setting mismatch),"
    TEXT+=" indel $(kneaddata_setting delta), PM $(kneaddata_setting pm), PI $(kneaddata_setting pi),"
    TEXT+=" minimum score $(kneaddata_setting minscore), maximum period $(kneaddata_setting maxperiod))."
    REPEATS=1
fi

if [[ $LAYOUT == *paired* && -n $TRIMMED$REPEATS ]]; then
    DISCARDED=${TRIMMED:+Trimmomatic}
    [[ -n $REPEATS ]] && DISCARDED+="${DISCARDED:+ or }Tandem Repeats Finder"
    TEXT+=" A read whose mate was discarded by $DISCARDED was kept as an unpaired read."
fi

[[ -n $HOST_DB ]] || TEXT+=" Host sequences were not removed."

cite andrews2010
TEXT+=" Read quality before and after processing was assessed with FastQC$CITATION"
cite ewels2016
TEXT+=" and summarized with $(named MultiQC "$(tool_version multiqc)")$CITATION."

# 4. MetaPhlAn
READS="the quality-controlled reads"
[[ $LAYOUT == *paired* ]] && READS="the quality-controlled paired and unpaired reads"

cite blancomiguez2023
TEXT+=" Taxonomic profiles were generated from $READS with"
TEXT+=" $(named MetaPhlAn "$(tool_version metaphlan)")$CITATION"
database_phrase "$METAPHLAN_DB"
TEXT+=" and $PHRASE$CITATION"
cite_new langmead2012
TEXT+=", mapping reads with Bowtie2$CITATION"
TEXT+=" and estimating the unclassified fraction (--unclassified_estimation)$(extra_options "$METAPHLAN_ARGS")."
cite mcdonald2012
TEXT+=" Estimated read counts per species-level genome bin (SGB) were written as BIOM tables with"
TEXT+=" biom-format$CITATION, together with the MetaPhlAn SGB phylogeny pruned to the SGBs detected;"
TEXT+=" eukaryotic bins, which that phylogeny does not include, were left out of these tables."

# 5. HUMAnN
if [[ $RUN_HUMANN == true ]]; then
    cite beghini2021
    TEXT+=" Functional profiles were generated from the same reads with"
    TEXT+=" $(named HUMAnN "$(tool_version humann)")$CITATION."
    cite_new langmead2012
    TEXT+=" Guided by each sample's MetaPhlAn profile, reads were mapped with Bowtie2$CITATION"
    database_phrase "$HUMANN_CHOCOPHLAN"
    TEXT+=" to pangenomes of the detected species from $PHRASE$CITATION,"
    cite buchfink2021
    TEXT+=" and reads that did not map were aligned in a translated search with DIAMOND$CITATION"
    database_phrase "$HUMANN_UNIREF"
    TEXT+=" against $PHRASE$CITATION."
    cite caspi2020
    TEXT+=" Gene family abundances, in reads per kilobase, were summarized as MetaCyc pathways$CITATION"
    cite ye2009
    TEXT+=" with MinPath$CITATION, regrouped to Enzyme Commission numbers and KEGG Orthology groups"
    cite kanehisa2000
    TEXT+="$CITATION, normalized to relative abundance, and split by contributing species with"
    TEXT+=" the HUMAnN utility scripts."
fi

# 6. Diversity
DIVERSITY=()
if [[ $RUN_MOTUS == true ]]; then
    cite ruscheweyh2022
    DIVERSITY+=("$(named mOTUs "$(tool_version motus)")$CITATION")
fi
if [[ $RUN_NONPAREIL == true ]]; then
    cite rodriguezr2018
    DIVERSITY+=("$(named Nonpareil "$(tool_version nonpareil)")$CITATION")
fi
if (( ${#DIVERSITY[@]} > 0 )); then
    TEXT+=" $(and_list "${DIVERSITY[@]}")"
    if (( ${#DIVERSITY[@]} > 1 )); then
        TEXT+=" were"
    else
        TEXT+=" was"
    fi
    TEXT+=" run with default settings to quantify community diversity."
fi

# 7. EsViritu, which reads one layout per sample, so a paired sample's unpaired
#    reads are left out
if [[ $RUN_ESVIRITU == true ]]; then
    ESVIRITU_READS="the quality-controlled reads"
    if [[ $LAYOUT == *paired*single* || $LAYOUT == *single*paired* ]]; then
        ESVIRITU_READS="the quality-controlled reads, a paired sample's mates alone,"
    elif [[ $LAYOUT == *paired* ]]; then
        ESVIRITU_READS="the quality-controlled read pairs, without unpaired reads,"
    fi
    cite tisza2023
    TEXT+=" Human, animal and plant viruses were detected in $ESVIRITU_READS with"
    TEXT+=" $(named EsViritu "$(tool_version esviritu)")$CITATION"
    database_phrase "$ESVIRITU_DB"
    TEXT+=" and $PHRASE$CITATION"
    cite li2018
    TEXT+=", aligning reads with minimap2$CITATION and keeping alignments of at least 100 nucleotides"
    TEXT+=" that covered at least 90% of the read at 80% identity or more$(extra_options "$ESVIRITU_ARGS")."
    TEXT+=" Reference genomes sharing reads were dereplicated, and each detected virus was quantified"
    TEXT+=" as reads per kilobase of genome per million reads and assigned to species and subspecies"
    TEXT+=" at 90% and 95% nucleotide identity to the reference."
fi

# 8. Marker-MAGu. A marker counts as detected once one read aligns to it: the
#    default asks for 75% of an SGB's markers, relaxed for 33.3% and three.
if [[ $RUN_MARKERMAGU == true ]]; then
    MARKERMAGU_DETECTED="at least 75% of its marker genes carried a read"
    if [[ $MARKERMAGU_DETECTION == relaxed ]]; then
        MARKERMAGU_DETECTED="at least 33.3% of its marker genes carried a read, at least three of them did,"
    fi
    cite tisza2025
    TEXT+=" Bacteriophages and other viruses were profiled in the quality-controlled reads with"
    TEXT+=" $(named Marker-MAGu "$(tool_version marker-magu)")$CITATION"
    database_phrase "$MARKERMAGU_DB"
    TEXT+=" and $PHRASE$CITATION, which holds viral marker genes alongside those of bacteria,"
    TEXT+=" archaea and microeukaryotes."
    cite_new li2018
    TEXT+=" Reads were aligned to its marker genes with minimap2$CITATION, and only reads aligning"
    TEXT+=" to a single marker over at least 50% of their length at 90% identity or more were"
    TEXT+=" counted$(extra_options "$MARKERMAGU_ARGS")."
    TEXT+=" A species-level genome bin was reported when $MARKERMAGU_DETECTED and at least ten"
    TEXT+=" reads aligned to it in total, and its abundance was taken as reads per kilobase of"
    TEXT+=" marker gene per million reads. Only viral detections were reported, as read"
    TEXT+=" counts per species-level genome bin and as relative abundances renormalised over"
    TEXT+=" the viral bins of each sample; bacterial, archaeal and eukaryotic taxa were taken"
    TEXT+=" from the MetaPhlAn profiles."
fi

# 9. The paragraph and the references it cites
if ! jq -n --arg text "$TEXT" --argjson refs "$REFERENCES" '
        [$text | scan("\\[@[^\\]]*\\]") | scan("@([A-Za-z0-9_]+)") | .[0]] | unique as $ids
        | ($ids - ($refs.references | keys)) as $missing
        | if ($missing | length) > 0
          then error("pipelines/references.yaml has no " + ($missing | join(", ")))
          else {paragraphs: [$text],
                references: ($refs.references
                             | with_entries(select(.key as $k | $ids | any(.[]; . == $k))))}
          end' > "$METHODS_DATA.tmp"; then
    rm -f "$METHODS_DATA.tmp"
    fail "The methods text couldn't be written."
fi
mv "$METHODS_DATA.tmp" "$METHODS_DATA"
log "Wrote the methods text to $METHODS_DATA."
