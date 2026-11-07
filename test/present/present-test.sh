#!/bin/bash
#
# present-test.sh - Runs each Present script on a copy of real or synthetic
# results, and checks the pages, the zip, and that nothing published loads from
# the network or names a path on this site.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec bash <install>/test/present/present-test.sh
# Requires:  in the test bed, phase 1's results in
#            <data_dir>/test/alice/ampliseq-16s-v4/results and
#            <data_dir>/test/bob/taxprofiler-test/results, and the 16s-v4
#            fixture in <db_dir>/fixtures/16s-v4/v1. Without them, those two
#            runs are skipped.
# Env:       KEEP, set to keep the runs in <data_dir>/test/<user>/present for a
#            look at the pages. The launcher passes no environment, so set it
#            inside: gnoto exec env KEEP=1 bash ...
#
# biobakery runs on synthetic results, since the test bed has no real ones. The
# runs never touch the originals: each is a copy.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
source "$CODE/present/dashboard.sh"
source "$CODE/present/common.sh"

WORK=$DATA_DIR/test/$(id -un)/present
AMPLISEQ_SOURCE=$DATA_DIR/test/alice/ampliseq-16s-v4/results
TAXPROFILER_SOURCE=$DATA_DIR/test/bob/taxprofiler-test/results
FIXTURE=$DB_DIR/fixtures/16s-v4/v1
FAILED=0

rm -rf "$WORK"
mkdir -p "$WORK"
[[ -n ${KEEP:-} ]] || trap 'rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Passes when the command prints nothing, and shows what it printed otherwise
check_none() {
    local label=$1 output
    shift
    output=$("$@" 2>&1)
    if [[ -z $output ]]; then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n%s\n' "$label" "$(head -n 20 <<< "$output" | sed 's/^/      /')"
        FAILED=1
    fi
}

# --- Library functions, with fixtures -----------------------------------------

echo "Library functions"
cd "$WORK" || exit 1

TEMPLATE=$WORK/template.html
printf '<p>__ONE__ and __TWO__ and __LEFT__</p>\n' > "$TEMPLATE"
check "a value isn't searched for another placeholder" \
    "<p>__TWO__ & x and 2 and __LEFT__</p>" "$(render_template "$TEMPLATE" ONE "__TWO__ & x" TWO 2)"
printf '{"a": "</script><!--"}' > "$WORK/data.json"
check "JSON for a script has every < escaped" '{"a":"\u003c/script>\u003c!--"}' "$(dashboard_script_json "$WORK/data.json")"
printf 'not json' > "$WORK/bad.json"
check "JSON that isn't is null" "null" "$(dashboard_script_json "$WORK/bad.json")"
check "a missing file is null" "null" "$(dashboard_script_json "$WORK/none.json")"

check "a title becomes a file name" "Mock-b-16S-co-s-b_abcdefgh.zip" "$(bundle_name abcdefgh 'Mock <b>"16S" & co'"'"'s</b>')"
check "a title of nothing leaves the uid" "abcdefgh.zip" "$(bundle_name abcdefgh '<&>')"
check "a group heading as a fragment" "how-this-run-was-set-up" "$(dashboard_slug "How this run was set up!")"
check "a share near the top keeps a decimal" "99.5" "$(dashboard_share_reading 995 1000 | cut -d' ' -f2)"
check "a share near nothing keeps a decimal" "<0.1" "$(dashboard_share_reading 1 100000 | cut -d' ' -f2)"
check "a share of a non-count fails" "1" "$(dashboard_share_reading x 10 > /dev/null; echo $?)"

mkdir -p "$WORK/abcdefgh"
cd "$WORK/abcdefgh" || exit 1
state_init abcdefgh
RUN=$PWD
REDACTED=$(printf '%s\n' "$RUN/work/ab/cd x" "$DB_DIR/kraken2/x,$DB_DIR" "$DATA_DIR/nextflow/assets y" \
    "${DATA_DIR}base/z" "/mnt$DATA_DIR/q" "$CODE_DIR/conf/a.config" "$HOME/site.config" \
    "$(realpath "$RUN")/results" | present_redact)
check "site paths become names, and only whole ones" \
    "$(printf '%s\n' "./work/ab/cd x" "db:kraken2/x,db:" "data:nextflow/assets y" \
        "${DATA_DIR}base/z" "/mnt$DATA_DIR/q" "gnoto:conf/a.config" "~/site.config" "./results")" \
    "$REDACTED"

state_set retention "3 Months" > /dev/null
check "three months from today" "$(date -u -d '+3 months' +%F)" "$(present_expires abcdefgh)"
state_set retention "1 Month" > /dev/null
check "never sooner than the notice" "$(date -u -d '+45 days' +%F)" \
    "$(EXPIRATION_NOTICE_DAYS=45 present_expires abcdefgh)"
state_set retention "Unlimited" > /dev/null
check "unlimited has no date" "" "$(present_expires abcdefgh)"
state_set version "ampliseq@0123456789abcdef0123456789abcdef01234567" > /dev/null
state_set_json dev true > /dev/null
check "a commit is cut short, and a working tree said" "ampliseq@0123456789ab (working tree)" "$(present_version)"
state_set title $'Line one\nline two' > /dev/null
check "a title is one line" "Line one" "$(present_title)"

# --- Runs ---------------------------------------------------------------------

# A run directory with a state as the job leaves it after Compute: new_run <uid>
# <pipeline> <title>, from the run's directory
new_run() {
    mkdir -p "$WORK/$1"
    cd "$WORK/$1" || exit 1
    state_init "$1"
    state_update '. + $add' --argjson add "$(jq -n --arg pipeline "$2" --arg title "$3" \
        --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{
            pipeline: $pipeline, version: ($pipeline + "@1.2.0"),
            commit: "0123456789abcdef0123456789abcdef01234567",
            repository: "https://github.com/cmmr/gnoto", dev: false,
            title: $title, retention: "3 Months", answers: {}, params: {},
            owner: "alice", scheduler: {kind: "slurm"}, status: "Presenting",
            started_utc: $now, stages: {compute: $now},
            samples: {count: 3, platform: "ILLUMINA"}}')" || exit 1
    mkdir -p results
    printf 'pipeline: %s@1.2.0\ntitle: "%s"\nsamplesheet: "samples.tsv"\n' "$2" "$3" > results/job.yaml
    printf 'schema: 1\npipeline: "%s@1.2.0"\n' "$2" > results/record.yaml
    # The progress page the watcher left, which Present replaces
    printf '<!DOCTYPE html><title>progress</title>\n' > results/index.html
    printf '{"state":"live"}\n' > results/progress.json
}

# Checks every run shares: the pages, the zip, and nothing published that loads
# from the network or names this site. check_run <zip name> <read folder>...
check_run() {
    local zip=$1 top=${1%.zip} page files
    shift

    for page in index overview deliverables; do
        check "$page.html written" "yes" "$([[ -s results/$page.html ]] && echo yes)"
    done
    check "index.html is the dashboard" "1" "$(grep -c 'id="views"' results/index.html)"
    check "progress.json says final" '{"state":"final"}' "$(< results/progress.json)"
    check "the stylesheet is in assets" "yes" "$([[ -s results/assets/gnoto.css && -s results/assets/fonts/InterVariable.woff2 ]] && echo yes)"
    check "the results folder has a listing" "yes" "$([[ -s results/directory_listing.html ]] && echo yes)"
    check "the zip is named for the title" "$zip" "$(ls ./*.zip 2> /dev/null | sed 's|^\./||')"
    check "no half-built zip is left" "" "$(ls ./*.tmp 2> /dev/null)"

    files=$(unzip -Z1 "$zip")
    check "the zip holds the dashboard" "yes" "$(grep -qx "$top/results/index.html" <<< "$files" && echo yes)"
    check "the zip holds the assets" "yes" "$(grep -qx "$top/results/assets/fonts/MaterialSymbolsOutlined.woff2" <<< "$files" && echo yes)"
    check "the zip holds the listings" "yes" "$(grep -qx "$top/results/directory_listing.html" <<< "$files" && echo yes)"
    check "the zip's index.html is the dashboard, not the progress page" \
        "$(sha256sum < results/index.html)" "$(unzip -p "$zip" "$top/results/index.html" | sha256sum)"
    check "the zip's progress.json says final" '{"state":"final"}' "$(unzip -p "$zip" "$top/results/progress.json")"
    for folder in "$@"; do
        check "the zip holds $folder/ as data" "yes" \
            "$(unzip -Z -l "$zip" "$top/$folder/*" 2> /dev/null | awk '$4 > 0 && /^-/ { found = 1 } END { if (found) print "yes" }')"
        check "the zip holds the listing for $folder/" "yes" \
            "$(grep -qx "$top/results/$folder/directory_listing.html" <<< "$files" && echo yes)"
    done

    # Nothing gnoto wrote loads from the network, and the stylesheet fetches
    # nothing. Links that open a page elsewhere are fine.
    mapfile -t pages < <(ls results/*.html; find results -mindepth 2 -name directory_listing.html)
    check_none "no page gnoto wrote loads from the network" network_loads "${pages[@]}"
    check_none "the stylesheet loads nothing" network_loads results/assets/gnoto.css
    check "every stylesheet a page links is there" "" "$(grep -ohE '<link[^>]*href="[^"]*"' results/*.html |
        sed -E 's/.*href="([^"]*)"/\1/' | sort -u | while read -r href; do [[ -e results/$href ]] || echo "$href"; done)"
    check_none "nothing published names this site's paths" present_site_path_files results
    check_none "the zip names none of them" bash -c "unzip -p '$zip' '$top/results/*' 2> /dev/null |
        LC_ALL=C grep -aoF -e '$DATA_DIR' -e '$CODE_DIR' -e '$PWD' | sort -u"

    # Every class in a page gnoto wrote has a rule in the stylesheet, or in the
    # page's own styles
    check_none "every class on the pages has a style" check_classes \
        results/index.html results/overview.html results/deliverables.html \
        ${methods:+results/methods.html}
    check_none "every icon is in the font" check_icons results/*.html

    # The pipeline's own reports are as it wrote them, so this only reports
    mapfile -t pages < <(find results -mindepth 2 -name "*.html" ! -name directory_listing.html)
    if (( ${#pages[@]} > 0 )) && network_loads "${pages[@]}" | grep -q .; then
        echo "note  the pipeline's own reports load from the network:"
        network_loads "${pages[@]}" | sed -E 's/^([^:]*): .*(https?:)?\/\/([^/"]*).*/\1 \3/' |
            sort -u | head -n 10 | sed 's/^/      /'
    fi
}

# Each script, stylesheet, image, frame, url() or @import in the files given
# that names another site or is protocol-relative
network_loads() {
    local file
    for file in "$@"; do
        grep -oiE '<(script|link|img|iframe|source|embed|object|video|audio)[^>]*>' "$file" |
            grep -oiE '(src|href|data)="(https?:)?//[^"]*"' | sed "s|^|$file: |"
        grep -oiE 'url\(["'"'"']?(https?:)?//[^)]*\)|@import' "$file" | sed "s|^|$file: |"
    done
}

# Classes that come from a page's own style block or common.css, or are hooks
# for its script, not Tailwind's
PAGE_CLASSES=" group groups about tree name size desc tag held held-note menu empty light local docked full-width label date countdown dir note methods-text methods-refs methods-bibtex plot-table num taxon swatch rank-path legend-name tip row here unnamed stripe dial tasks material-symbols-outlined "

# Each class token in the pages, outside their scripts, that has no rule in
# gnoto.css
check_classes() {
    local css token selector
    css=$(< results/assets/gnoto.css)
    awk '/<script/ { skip = 1 } !skip { print } /<\/script>/ { skip = 0 }' "$@" |
        grep -oE 'class="[^"]*"' | sed -E 's/^class="//; s/"$//' |
        tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u |
        while IFS= read -r token; do
            [[ $PAGE_CLASSES == *" $token "* || $token == *__* ]] && continue
            selector=$(printf '%s' "$token" | sed -E 's/([^A-Za-z0-9_-])/\\\1/g')
            [[ $css == *".$selector"[^A-Za-z0-9_-]* ]] || printf '%s\n' "$token"
        done
}

# Each icon the pages name that build-assets.sh didn't put in the font
check_icons() {
    local icons
    icons=" $(sed -n '/^ICONS=(/,/)/p' "$CODE/present/build-assets.sh" | tr -d '()\n' | sed 's/ICONS=//') "
    cat "$@" | grep -oE 'material-symbols-outlined[^>]*>[[:space:]]*[a-z0-9_]+' | sed -E 's/.*>[[:space:]]*//' |
        LC_ALL=C sort -u | while read -r icon; do
            [[ $icons == *" $icon "* ]] || printf 'no %s\n' "$icon"
        done
}

echo
echo "ampliseq, from phase 1's 16s-v4 run"
if [[ -d $AMPLISEQ_SOURCE && -r $FIXTURE/SRR17380142_1.fastq.gz ]]; then
    TITLE='Mock <b>"16S" & co'"'"'s</b>'
    new_run ampliseq ampliseq "$TITLE"
    cp -R "$AMPLISEQ_SOURCE/." results/
    mkdir raw-sequences
    ln -s "$FIXTURE/SRR17380142_1.fastq.gz" raw-sequences/SRR17380142_reads_1.fq.gz
    ln -s "$FIXTURE/SRR17380142_2.fastq.gz" raw-sequences/SRR17380142_reads_2.fq.gz
    printf 'Region: 16S V4 (515F/806R)\nPlatform: Illumina, from reads of 250 bp\n' > region_detection.txt
    state_set region 16SV4 > /dev/null
    state_set params.sequencing_type illumina_pe > /dev/null
    state_set_json statistics '{"samples": 1, "asvs": 120, "phylum_asvs": 118, "genus_asvs": 90,
        "species_asvs": 12, "reads_total": 40000, "reads_retained": 31000, "reads_min": 31000,
        "reads_median": 31000, "reads_max": 31000, "read_chemistry": "2 × 250 bp",
        "read_stages": "cutadapt_passing_filters filtered merged nonchim",
        "reads_cutadapt_passing_filters": 39000, "reads_filtered": 36000, "reads_merged": 33000,
        "reads_nonchim": 31500}' > /dev/null
    # An Overview with plots, and a taxon that would close the script element
    jq -n '{samples: ["SRR17380142", "S2"], reads: [31000, 1200],
        alpha: {shannon: [2.5, 1.1], observed: [120, 40]},
        metrics: [{key: "shannon", title: "Shannon index", note: "richness and evenness", places: 2},
                  {key: "observed", title: "Observed ASVs", note: "distinct ASVs", integer: true},
                  {key: "reads", title: "Read depth", note: "reads", integer: true, scale: "sqrt"}],
        levels: [{rank: 2, name: "Phylum",
                  taxa: [{label: "Bacillota</script><script>alert(1)</script>", lineage: "Bacteria", mean: 6000, prevalence: 100},
                         {label: "Other", lineage: "", mean: 3000, prevalence: 100}],
                  values: [[7000, 5000], [2500, 3500]]}]}' > composition_data.json

    "$CODE/present/ampliseq.sh" results > present.out 2>&1
    check "ampliseq.sh exits 0" "0" "$?"
    methods=""
    check_run "Mock-b-16S-co-s-b_ampliseq.zip" raw-sequences
    check "the title is escaped" "1" "$(grep -c '<title>Mock &lt;b&gt;&quot;16S&quot; &amp; co&#39;s&lt;/b&gt;</title>' results/index.html)"
    check "no raw markup from the title" "0" "$(grep -c '<b>"16S"' results/overview.html)"
    check "the plot data can't close its script" "0" "$(grep -c 'Bacillota</script>' results/overview.html)"
    check "the plot data is there, escaped" "1" "$(grep -c 'Bacillota\\u003c/script>' results/overview.html)"
    check "the bar offers the analysis report" "1" "$(grep -c 'data-view="report"' results/index.html)"
    check "the QC report is in the bar, hidden" "1" "$(grep -c 'data-view="quality" href="multiqc/multiqc_report.html" target="view" hidden' results/index.html)"
    check "the report's link up goes to the listing" "0" "$(grep -c 'href="\.\./"' results/summary_report/summary_report.html)"
    check "the read totals name the platform and chemistry" "1" "$(grep -c 'Illumina, 2 × 250 bp' results/overview.html)"
    check "the classification names region and reference" "1" "$(grep -c '16S V4 · SILVA 138.2' results/overview.html)"
    check "the button offers the zip, relative" "1" "$(grep -c 'id="download-all" href="\.\./Mock-b-16S-co-s-b_ampliseq.zip"' results/overview.html)"
    check "the index lists the zip with its size" "1" "$(grep -c '<a href="../Mock-b-16S-co-s-b_ampliseq.zip" download target="_top">Everything from this run</a>' results/deliverables.html)"
    check "the index lists the reads, held" "1" "$(grep -c '<tr class="held"><td class="name"><a href="raw-sequences/directory_listing.html"' results/deliverables.html)"
    check "the index draws the zip's tree" "1" "$(grep -c '<pre class="tree">Mock-b-16S-co-s-b_ampliseq/' results/deliverables.html)"
    check "the index lists record.yaml" "1" "$(grep -c 'href="record.yaml"' results/deliverables.html)"
    check "the index lists region_detection.txt" "1" "$(grep -c 'href="region_detection.txt"' results/deliverables.html)"
    check "the index doesn't list run_state.json" "0" "$(grep -c 'run_state.json' results/deliverables.html)"
    check "the reads' listing reaches them two levels up" "1" "$(grep -c 'href="../../raw-sequences/SRR17380142_reads_1.fq.gz"' results/raw-sequences/directory_listing.html)"
    check "the expiry date is in the bar" "1" "$(grep -c "data-expires=\"$(date -u -d '+3 months' +%F)\"" results/index.html)"
    check "the footer names the version and uid" "1" "$(grep -c 'ampliseq@1.2.0 · ampliseq' results/overview.html)"
    check "the dashboard names no site" "0" \
        "$(cat results/*.html | sed 's|github.com/cmmr/gnoto||g' | grep -ci 'CMMR\|Alkek\|Baylor')"

    # gnoto publish runs Present again, here under a new title
    state_set title "Second title" > /dev/null
    "$CODE/present/ampliseq.sh" results > present2.out 2>&1
    check "a second Present exits 0" "0" "$?"
    check "it leaves one zip, under the new title" "Second-title_ampliseq.zip" "$(ls ./*.zip | sed 's|^\./||')"
else
    echo "skip  no 16s-v4 results or fixture in this test bed"
fi

echo
echo "taxprofiler, from phase 1's test-profile run"
if [[ -d $TAXPROFILER_SOURCE ]]; then
    new_run taxprofi taxprofiler "Taxprofiler test"
    cp -R "$TAXPROFILER_SOURCE/." results/
    mkdir raw-sequences
    printf '@r1\nACGT\n+\nIIII\n' | gzip > raw-sequences/2611_1.fastq.gz
    printf 'tool,db_name,db_params,db_type,db_path\nkraken2,pluspf,--confidence 0.1,short,%s/kraken2/pluspf\nbracken,pluspf_bracken,;-r 150,short,%s/kraken2/pluspf\n' \
        "$DB_DIR" "$DB_DIR" > taxprofiler_database.csv
    state_set_json statistics '{"platform": "Illumina", "qc_total": 1000000, "qc_cut_quality": 20000,
        "qc_cut_ncontent": 100, "qc_cut_length": 5000, "qc_cut_complexity": 1000, "host_total": 973900,
        "host_removed": 3900, "reads_total": 970000, "reads_min": 300000, "reads_median": 320000,
        "reads_max": 350000, "phylum_reads": 800000, "genus_reads": 600000, "species_reads": 400000,
        "database": "Kraken2 PlusPF", "metaphlan_total": 970000, "metaphlan_mapped": 50000}' > /dev/null

    "$CODE/present/taxprofiler.sh" results > present.out 2>&1
    check "taxprofiler.sh exits 0" "0" "$?"
    methods=""
    check_run "Taxprofiler-test_taxprofi.zip" raw-sequences
    check "the database sheet is published with db: names" \
        "$(printf '%s\n' 'tool,db_name,db_params,db_type,db_path' 'kraken2,pluspf,--confidence 0.1,short,db:kraken2/pluspf' 'bracken,pluspf_bracken,;-r 150,short,db:kraken2/pluspf')" \
        "$(< results/taxprofiler_database.csv)"
    check "the bar offers a Krona chart" "1" "$(grep -c 'data-view="krona" href="krona/' results/index.html)"
    check "the sidebar shows the read totals" "1" "$(grep -c 'READ TOTALS' results/overview.html)"
    check "no plots without composition data" "1" "$(grep -c 'var DATA = null;' results/overview.html)"
    check "multiqc_data's copies were pruned" "no" "$([[ -e results/multiqc/multiqc_data/multiqc_data.json ]] && echo yes || echo no)"
    check "the execution report names no site path" "0" "$(cat results/pipeline_info/execution_report*.html | grep -c "$DATA_DIR")"
else
    echo "skip  no taxprofiler results in this test bed"
fi

echo
echo "biobakery, from synthetic results"
new_run biobaker biobakery "Synthetic biobakery"
state_set_json answers '{"delivered_reads": "Raw,Cleaned"}' > /dev/null
state_set_json params "$(jq -n --arg db "$DB_DIR" '{input: "biobakery_samplesheet.csv",
    kneaddata_db: "db:hostremoval/chm13v2phix", host_prefilter_bowtie2_options: "--fast",
    host_bowtie2_options: "--very-sensitive-local", kneaddata_sequencer_source: "NexteraPE",
    metaphlan_db: "db:metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403", run_humann: true,
    run_motus: true, run_nonpareil: true, run_esviritu: true, run_markermagu: true,
    humann_chocophlan: "db:humann/v201901b/chocophlan", humann_uniref: "db:humann/v201901b/uniref90",
    esviritu_db: "db:esviritu/v3.2.4", markermagu_db: "db:markermagu/v1.1",
    markermagu_detection: "default"}')" > /dev/null
state_set_json statistics '{"platform": "Illumina", "layout": "paired-end", "raw_total": 2000000,
    "host_kept": 1900000, "trimmed_total": 1800000, "retained_total": 1750000, "reads_min": 500000,
    "reads_median": 600000, "reads_max": 650000, "samples": 2, "samples_dropped": "S3",
    "humann_missing": "S2", "metaphlan_mapped": 40000, "metaphlan_database": "mpa_vJun23",
    "humann_mapped": 900000, "markermagu_mapped": 3000}' > /dev/null
printf ' N E X T F L O W   ~  version 26.10.5\n' > nextflow.out
printf 'sample,run_accession,instrument_platform,fastq_1,fastq_2\nS1,r1,ILLUMINA,a,b\nS1,r2,ILLUMINA,c,d\nS2,r1,ILLUMINA,e,f\n' > biobakery_samplesheet.csv
mkdir -p raw-sequences cleaned-sequences results/kneaddata/logs results/metaphlan \
    results/humann results/esviritu results/markermagu results/multiqc results/pipeline_info
printf '@r1\nACGT\n+\nIIII\n' | gzip > raw-sequences/S1_1.fastq.gz
printf '@r1\nACGT\n+\nIIII\n' | gzip > "$WORK/S1_clean.fastq.gz"
ln -s "$WORK/S1_clean.fastq.gz" cleaned-sequences/S1_1.fastq.gz
for SAMPLE in S1 S2; do
    {
        printf 'match = 2\nmismatch = 7\ndelta = 7\npm = 80\npi = 10\nminscore = 50\nmaxperiod = 500\n'
        printf 'bypass_trim = False\nbypass_trf = False\ntrimmomatic_options = None\n'
        printf 'Execute command: java -jar trimmomatic.jar PE in1 in2 out MINLEN:60 ILLUMINACLIP:%s/kneaddata/adapters/NexteraPE-PE.fa:2:30:10:8:TRUE SLIDINGWINDOW:4:20 MINLEN:%s\n' \
            "$DB_DIR" "$([[ $SAMPLE == S1 ]] && echo 75 || echo 50)"
    } > "results/kneaddata/logs/$SAMPLE.log"
done
printf '#taxon\tS1\tS2\nk__Bacteria\t10\t20\n' > results/metaphlan/taxa-counts.tsv
mkdir -p results/motus/profiles
printf '# mOTUs\n#taxonomy\tid\tS1\tS2\ntaxon A\t1\t0\t5\ntaxon B\t2\t0\t0.000\ntaxon C\t3\t1.5\t0\n' > results/motus/motus-counts.tsv
printf 'x\n' > results/motus/profiles/S1.motus
printf '#pathway\tS1\nPWY-1\t5\n' > results/humann/pathway-abundance-rpk.tsv
printf 'sample\treads\nS1\t100\nS2\t100\n' > results/esviritu/read-counts.tsv
printf 'sample\ttaxon\nS1\tvirus\n' > results/esviritu/virus-taxa.tsv
printf '#sgb\tS1\nvSGB1\t3\n' > results/markermagu/virome-counts.tsv
printf '<html><body><div id="kneaddata"></div>based on data in %s/work</body></html>\n' "$PWD" > results/multiqc/multiqc_report.html
printf 'task_id\thash\tname\n1\tab/cdef12\tKNEADDATA (S1)\n' > results/pipeline_info/trace.txt

"$CODE/present/biobakery.sh" results > present.out 2>&1
check "biobakery.sh exits 0" "0" "$?"
methods=1
check_run "Synthetic-biobakery_biobaker.zip" raw-sequences cleaned-sequences
check "host-depleted reads weren't asked for, so aren't zipped" "0" \
    "$(unzip -Z1 Synthetic-biobakery_biobaker.zip | grep -c '^Synthetic-biobakery_biobaker/host-depleted-sequences/')"
check "the Methods page is in the bar" "1" "$(grep -c 'data-view="methods" href="methods.html"' results/index.html)"
check "the methods name Nextflow's version" "1" "$(grep -c 'Nextflow v26.10.5 (Di Tommaso et al., 2017)' results/methods.html)"
check "the methods give MINLEN's range" "1" "$(grep -c 'MINLEN:50–75' results/methods.html)"
check "the methods name the host genomes" "1" "$(grep -c 'human T2T-CHM13v2.0 (GCF_009914755.1)' results/methods.html)"
check "the methods cite in BibTeX" "1" "$(grep -c '@article{beghini2021,' results/methods.html)"
check "the methods name no site path" "0" "$(grep -c "$DB_DIR" methods_data.json results/methods.html | awk -F: '{ t += $2 } END { print t }')"
check "the KneadData logs were pruned after" "no" "$([[ -d results/kneaddata/logs ]] && echo yes || echo no)"
check "the dropped sample is named" "1" "$(grep -c 'Dropped: S3' results/overview.html)"
check "pruning drops a table's empty rows, keeping its headers" \
    "$(printf '# mOTUs\n#taxonomy\tid\tS1\tS2\ntaxon A\t1\t0\t5\ntaxon C\t3\t1.5\t0')" "$(< results/motus/motus-counts.tsv)"
check "and removes a folder it names" "no" "$([[ -e results/motus/profiles ]] && echo yes || echo no)"
check "the multiqc report's run path is redacted" "1" "$(grep -c 'based on data in ./work' results/multiqc/multiqc_report.html)"

# A read set whose files are gone stops the zip rather than leaving them out
new_run brokenrd biobakery "Broken reads"
state_set_json answers '{"delivered_reads": "Cleaned"}' > /dev/null
state_set_json params '{"metaphlan_db": "db:metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403"}' > /dev/null
mkdir cleaned-sequences
ln -s "$WORK/gone.fastq.gz" cleaned-sequences/S1_1.fastq.gz
"$CODE/present/biobakery.sh" results > present.out 2>&1
check "a read set with missing files fails Present" "1" "$?"
check "and says why" "This run couldn't be packaged for download: 1 of the files in cleaned-sequences/ are missing." \
    "$(state_get message)"

echo
if (( FAILED )); then
    echo "Some checks failed."
    exit 1
fi
echo "All checks passed."
