#!/bin/bash
#
# composition-test.sh - Runs the three composition steps with the real rbiom
# image, on real pipeline outputs and on synthetic additions where those fall
# short, and checks what they write.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec bash <install>/test/steps/composition-test.sh \
#                [ampliseq_results] [taxprofiler_results]
#            The defaults are the test bed's phase 1 runs: ampliseq 3.1.0 on the
#            16s-v4 fixture, and taxprofiler's test profile.
# Requires:  the rbiom image the lock files name, in <data_dir>/images, as
#            "test/testbed/testbed.sh image gnoto-rbiom" builds it
#
# The results are copied, so the originals are never changed. Synthetic
# additions cover what those runs lack: a second and an empty sample and a
# placement tree for ampliseq; a taxonomy dump, a MetaPhlAn phylogeny, lineage
# columns, read statistics and mOTUs for taxprofiler. biobakery has no real
# outputs here, so its step runs on synthetic ones shaped like the module stubs.
# "gnoto exec env KEEP=1 bash ..." keeps the scratch directory.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
AMPLISEQ_RESULTS=${1:-/data/gnoto/test/alice/ampliseq-16s-v4/results}
TAXPROFILER_RESULTS=${2:-/data/gnoto/test/bob/taxprofiler-test/results}
WORK=$(mktemp -d "$DATA_DIR/test-composition.XXXXXX")
FAILED=0
trap '[[ -n ${KEEP:-} ]] || rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Shows a step's log when a check on its exit fails
check_step() {
    check "$1" 0 "$2"
    [[ $2 -eq 0 ]] || tail -20 "$3" | sed 's/^/      /'
}

for dir in "$AMPLISEQ_RESULTS" "$TAXPROFILER_RESULTS"; do
    [[ -d $dir ]] || { echo "No results in $dir"; exit 1; }
done

# A scratch install whose db_dir holds the synthetic databases
mkdir -p "$WORK/install" "$WORK/db"
printf 'core:\n  data_dir: "%s"\n  db_dir: "%s"\n' "$DATA_DIR" "$WORK/db" > "$WORK/install/config.yaml"
export GNOTO_INSTALL_DIR=$WORK/install
source "$CODE/lib/env.sh" || exit 1

RBIOM=$(lock_image ampliseq rbiom) || exit 1
check "taxprofiler pins the same rbiom image" "$RBIOM" "$(lock_image taxprofiler rbiom)"

new_run() {
    mkdir -p "$WORK/$1"
    cd "$WORK/$1" || exit 1
    state_init abcdefgh
}

json() {
    jq -r "$1" composition_data.json 2> /dev/null
}

stat_of() {
    state_get "statistics.$1"
}

# Runs an R expression on a file in the rbiom image, printing what it cats
r_eval() {
    printf '%s\n' "$1" > "$WORK/eval.R"
    container_exec "$RBIOM" Rscript --vanilla "$WORK/eval.R" 2> /dev/null
}

# Every sample column of every rank sums to exactly 10000 with "exact", or
# otherwise to at most 10000 plus what rounding each row can add
levels_close() {
    jq -r --arg exact "${1:-}" '
        [.levels[] | (.values | length) as $rows | .values | transpose[] | add
         | if $exact == "exact" then . == 10000 else . <= 10000 + $rows / 2 end]
        | all' composition_data.json 2> /dev/null
}

echo "container_sif"
cd "$WORK" || exit 1
OUT=$( (container_sif no-such-image.sif) 2>&1 )
check "a missing bare .sif fails" "1" "$?"
check "and names where it looked" "yes" "$([[ $OUT == *"$DATA_DIR/images/no-such-image.sif"* ]] && echo yes || echo "$OUT")"
check "a bare .sif is found in the images directory" "$DATA_DIR/images/$RBIOM" "$(container_sif "$RBIOM")"
OUT=$( (container_sif quay.io/biocontainers/gotree:0.5.2) 2>&1 )
check "an address by tag is still refused" "1" "$?"

echo "ampliseq, the 16s-v4 run"
new_run ampliseq
cp -r "$AMPLISEQ_RESULTS" results
SAMPLES=$(head -n 1 results/dada2/ASV_table.tsv | cut -f2- | tr '\t' ' ')
{
    printf 'sample\tfastq_1\tfastq_2\n'
    for sample in $SAMPLES; do printf '%s\tr1.fq.gz\tr2.fq.gz\n' "$sample"; done
} > ampliseq_samplesheet.tsv
state_set_json params '{"exclude_taxa": "mitochondria,chloroplast,Francisella"}'

"$CODE/steps/ampliseq_composition.sh" > composition.log 2>&1
check_step "composition step exits 0" "$?" composition.log
check "plot data names the samples" "$SAMPLES" "$(json '.samples | join(" ")')"
check "ranks Phylum to Species are charted" "Phylum Class Order Family Genus Species" \
    "$(json '[.levels[].name] | join(" ")')"
check "no column exceeds the whole sample, beyond rounding" "true" "$(levels_close)"
check "diversity offers Shannon first, and no Faith's PD without a tree" "shannon no" \
    "$(json '.metrics[0].key + " " + (if any(.metrics[]; .key == "faith") then "yes" else "no" end)')"
for file in feature-table.tsv feature-table.json.biom feature-table.hdf5.biom feature-sequences.fasta; do
    check "feature_table/$file written" "yes" "$([[ -s results/feature_table/$file ]] && echo yes)"
done
check "abundance tables at seven ranks, two ways" "14" "$(ls results/abundance_tables | wc -l)"
ASVS=$(grep -vc '^#' results/feature_table/feature-table.tsv)
TOTAL_ASVS=$(($(wc -l < results/dada2/ASV_table.tsv) - 1))
check "statistics count the table's ASVs" "$ASVS" "$(stat_of asvs)"
check "the JSON BIOM agrees" "$ASVS $(wc -w <<< "$SAMPLES")" "$(jq -r '.shape | join(" ")' results/feature_table/feature-table.json.biom)"
check "alpha table reads match reads retained" "$(stat_of reads_retained)" \
    "$(awk -F'\t' 'NR > 1 { s += $2 } END { print s }' results/alpha_diversity.tsv)"
check "input reads read through cutadapt's thousands separators" \
    "$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "cutadapt_total_processed") c = i; next }
        { gsub(/,/, "", $c); s += $c } END { print s }' results/overall_summary.tsv)" "$(stat_of reads_total)"
check "read stages in the order the summary lists them" "cutadapt_passing_filters filtered merged nonchim" \
    "$(stat_of read_stages)"
check "chemistry from FastQC" "2 × 250 bp" "$(stat_of read_chemistry)"
check "no sample dropped" "" "$(stat_of samples_dropped)"
check "the scratch directory is gone" "" "$(ls -d .composition.* 2> /dev/null)"

echo "ampliseq, with a second sample, an empty one, a tree and an exclusion"
new_run ampliseq-more
cp -r "$WORK/ampliseq/results" results
rm -rf results/feature_table results/abundance_tables results/alpha_diversity.tsv
# The second sample takes the first one's counts in reverse order
awk -F'\t' -v OFS='\t' '
    NR == FNR { if (FNR > 1) count[++n] = $2; next }
    FNR == 1  { print $0, "SYN_B"; next }
    { print $0, count[n - FNR + 2] }
' results/dada2/ASV_table.tsv results/dada2/ASV_table.tsv > table.tsv
mv table.tsv results/dada2/ASV_table.tsv
{
    printf 'sample\tfastq_1\tfastq_2\n'
    for sample in $SAMPLES SYN_B SYN_EMPTY; do printf '%s\tr1.fq.gz\tr2.fq.gz\n' "$sample"; done
} > ampliseq_samplesheet.tsv
mkdir -p results/pplace
awk -F'\t' 'FNR > 1 { tree = tree == "" ? $1 ":0.1" : "(" tree "," $1 ":0.1):0.05" } END { print tree ";" }' \
    results/dada2/ASV_table.tsv > results/pplace/asv_tree.newick
EXCLUDED=$(awk -F'\t' 'FNR > 1 && tolower($3) ~ /bacteroidota/' results/dada2/ASV_tax_species.user.tsv | wc -l)
state_set_json params '{"exclude_taxa": "Bacteroidota", "sequencing_type": "illumina"}'

"$CODE/steps/ampliseq_composition.sh" results/ > composition.log 2>&1
check_step "composition step exits 0" "$?" composition.log
check "the empty sample is reported dropped" "SYN_EMPTY" "$(stat_of samples_dropped)"
check "two samples charted" "2" "$(json '.samples | length')"
check "the exclusion is recorded" "$EXCLUDED" "$(($(wc -l < results/feature_table/excluded_asvs.tsv) - 1))"
check "and the ASVs it took are gone" "$((TOTAL_ASVS - EXCLUDED))" "$(stat_of asvs)"
check "Faith's PD is offered with the tree" "yes" "$(json 'if any(.metrics[]; .key == "faith") then "yes" else "no" end')"
check "alpha table has Faith's PD" "yes" "$(head -n 1 results/alpha_diversity.tsv | grep -qw faith && echo yes)"
check "the HDF5 BIOM reads back with its tree" "2 $((TOTAL_ASVS - EXCLUDED)) TRUE" \
    "$(r_eval "b <- rbiom::read_biom('$PWD/results/feature_table/feature-table.hdf5.biom'); cat(b\$n_samples, b\$n_otus, !is.null(b\$tree))")"

echo "ampliseq, when the feature table can't be assembled"
new_run ampliseq-broken
mkdir -p results
cp "$WORK/ampliseq/results/overall_summary.tsv" results/
"$CODE/steps/ampliseq_composition.sh" > composition.log 2>&1
check "the step fails, because the feature table is a core result" "1" "$?"
check "and leaves no plot data" "no" "$([[ -e composition_data.json ]] && echo yes || echo no)"
check "and says why" "yes" "$(grep -q 'no ASV table' composition.log && echo yes)"

echo "taxprofiler, the test profile"
new_run taxprofiler
mkdir -p results
for dir in bracken taxpasta metaphlan nonpareil fastp bowtie2; do
    [[ -d $TAXPROFILER_RESULTS/$dir ]] && cp -r "$TAXPROFILER_RESULTS/$dir" results/
done
(cd "$TAXPROFILER_RESULTS" && find kraken2 -name '*.txt' -exec cp --parents {} "$WORK/taxprofiler/results/" \;)
state_set samples.platform ILLUMINA

"$CODE/steps/taxprofiler_composition.sh" > composition.log 2>&1
check_step "composition step exits 0" "$?" composition.log
KRAKEN_SAMPLES=$(ls results/bracken/*/*.report_bracken.txt | sed 's|.*/||; s|_[^_]*\.bracken\..*||' | sort | tr '\n' ' ' | sed 's/ $//')
check "plot data names bracken's samples" "$KRAKEN_SAMPLES" "$(json '.samples | join(" ")')"
check "ranks Phylum to Species are charted" "Phylum Class Order Family Genus Species" \
    "$(json '[.levels[].name] | join(" ")')"
check "every column closes at the whole sample" "true" "$(levels_close exact)"
check "the feature is a species" "species" "$(json '.feature.one')"
check "profiled by Bracken on db1" "Bracken db1" "$(stat_of profiler) $(stat_of database)"
check "reads total every read the kraken2 reports saw" \
    "$(awk -F'\t' '$(NF - 2) == "U" || ($(NF - 2) == "R" && $(NF - 1) == 1) { s += $2 } END { print s }' \
        results/kraken2/db2/*.kraken2.kraken2.report.txt)" "$(stat_of reads_total)"
check "host removal totals bowtie2's input" \
    "$(awk '/reads; of these:/ { s += $1 } END { print s }' results/bowtie2/align/*.bowtie2.log)" "$(stat_of host_total)"
check "quality filtering is counted" "yes" "$([[ $(stat_of qc_total) -gt 0 ]] && echo yes)"
check "platform names Illumina and a chemistry" "yes" "$([[ $(stat_of platform) == "Illumina, "*bp ]] && echo yes || stat_of platform)"
check "coverage leads the diversity chart" "coverage" "$(json '.metrics[0].key')"
check "alpha table has a row per sample" "$(json '.samples | length')" "$(($(wc -l < results/alpha_diversity.tsv) - 1))"
check "the bracken feature table is written, without a tree" "yes no" \
    "$([[ -s results/feature_table/feature-table.hdf5.biom ]] && echo yes) $([[ -e results/feature_table/taxonomy-tree.newick ]] && echo yes || echo no)"
check "nonpareil for 2612, from its deepest run" "100.0000 0.0584" \
    "$(awk -F'\t' '$1 == "2612" { print $4, $7 }' results/alpha_diversity.tsv)"

echo "taxprofiler, with trees, lineages, read statistics and mOTUs"
new_run taxprofiler-more
cp -r "$WORK/taxprofiler/results" results
rm -rf results/feature_table results/count_tables results/alpha_diversity.tsv results/metaphlan/metaphlan3 \
    results/metaphlan/metaphlan_metaphlan3_combined_reports.txt
state_set samples.platform ILLUMINA

# A taxonomy dump holding the lineages of the two species bracken found
mkdir -p "$WORK/db/kraken2/toy" "$WORK/db/metaphlan/toy"
while read -r id parent rank name; do
    printf '%s\t|\t%s\t|\t%s\t|\n' "$id" "$parent" "$rank" >> "$WORK/db/kraken2/toy/nodes.dmp"
    printf '%s\t|\t%s\t|\t\t|\tscientific name\t|\n' "$id" "${name//_/ }" >> "$WORK/db/kraken2/toy/names.dmp"
done << 'EOF'
1 1 no_rank root
2759 1 superkingdom Eukaryota
33208 2759 kingdom Metazoa
7711 33208 phylum Chordata
40674 7711 class Mammalia
9443 40674 order Primates
9604 9443 family Hominidae
9605 9604 genus Homo
9606 9605 species Homo_sapiens
4751 2759 kingdom Fungi
4890 4751 phylum Ascomycota
4891 4890 class Saccharomycetes
4892 4891 order Saccharomycetales
4893 4892 family Saccharomycetaceae
4930 4893 genus Saccharomyces
4932 4930 species Saccharomyces_cerevisiae
EOF
echo "(4933:0.2,(1111:0.1,2222:0.1):0.1);" > "$WORK/db/metaphlan/toy/mpa_toy.nwk"
printf '%s\n' 'tool,db_name,db_params,db_type,db_path' \
    'kraken2,db2,,short,db:kraken2/toy' \
    'metaphlan,mpa_toy,,short,db:metaphlan/toy' > taxprofiler_database.csv

# Bracken's merged table with the lineage columns gnoto's taxpasta settings add
BRACKEN_TABLE=results/taxpasta/bracken_db1.tsv
awk -F'\t' -v OFS='\t' '
    NR == 1 { $1 = "taxonomy_id\tname\trank\tlineage\tid_lineage\trank_lineage"; print; next }
    $1 == 9606 { $1 = "9606\tHomo sapiens\tspecies\tEukaryota;Chordata;Mammalia;Primates;Hominidae;Homo;Homo sapiens\t2759;7711;40674;9443;9604;9605;9606\tsuperkingdom;phylum;class;order;family;genus;species" }
    $1 == 4932 { $1 = "4932\tSaccharomyces cerevisiae\tspecies\tEukaryota;Ascomycota;Saccharomycetes;Saccharomycetales;Saccharomycetaceae;Saccharomyces;Saccharomyces cerevisiae\t2759;4890;4891;4892;4893;4930;4932\tsuperkingdom;phylum;class;order;family;genus;species" }
    { print }
' "$BRACKEN_TABLE" > table.tsv
mv table.tsv "$BRACKEN_TABLE"

# Per-sample MetaPhlAn profiles with read statistics, as -t rel_ab_w_read_stats
# writes them, and the merged profile from them
LINEAGE='k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Lachnospiraceae_unclassified|s__Eubacterium_rectale'
for sample in 2612 2613; do
    {
        printf '#mpa_toy\n#metaphlan -t rel_ab_w_read_stats\n#2000 reads processed\n#SampleID\t%s\n' "$sample"
        printf '#estimated_reads_mapped_to_known_clades:1500\n'
        printf '#clade_name\tclade_taxid\trelative_abundance\tcoverage\testimated_number_of_reads_from_the_clade\n'
        printf 'UNCLASSIFIED\t-1\t25.0\t-\t500\n'
        printf '%s\t39491\t75.0\t12.5\t1500\n' "$LINEAGE"
        printf '%s|t__SGB4933_group\t39491\t75.0\t12.5\t1500\n' "$LINEAGE"
    } > "results/metaphlan/metaphlan4/${sample}_metaphlan4.metaphlan_profile.txt"
done
rm -f results/metaphlan/metaphlan4/2611_metaphlan4.metaphlan_profile.txt

# The merged profile with a second SGB, since a phylogeny needs two tips
{
    printf '#mpa_toy\nclade_name\t2611_metaphlan4.metaphlan\t2612_metaphlan4.metaphlan\t2613_metaphlan4.metaphlan\n'
    printf 'UNCLASSIFIED\t100.0\t25.0\t25.0\n'
    printf '%s|t__SGB4933_group\t0.0\t50.0\t75.0\n' "$LINEAGE"
    printf '%s|t__SGB1111\t0.0\t25.0\t0.0\n' "${LINEAGE%|s__*}|s__Blautia_obeum"
} > results/metaphlan/metaphlan_metaphlan4_combined_reports.txt

# mOTUs profiles, per sample and merged
mkdir -p results/motus/db_mOTU
for sample in 2612 2613; do
    {
        printf '# motus version 3.1.0\n#consensus_taxonomy\tNCBI_tax_id\t%s\n' "$sample"
        printf 'Blautia obeum [ref_mOTU_v31_00001]\t40520\t12\n'
        printf 'Faecalibacterium prausnitzii [ref_mOTU_v31_00002]\t853\t%s\n' "$([[ $sample == 2612 ]] && echo 4 || echo 0)"
        printf 'unassigned\tNA\t3\n'
    } > "results/motus/db_mOTU/${sample}_db_mOTU.out"
done
{
    printf '# motus version 3.1.0\n#consensus_taxonomy\tNCBI_tax_id\t2612_db_mOTU\t2613_db_mOTU\n'
    printf 'Blautia obeum [ref_mOTU_v31_00001]\t40520\t12\t12\n'
    printf 'Faecalibacterium prausnitzii [ref_mOTU_v31_00002]\t853\t4\t0\n'
    printf 'unassigned\tNA\t3\t3\n'
} > results/motus/motus_db_mOTU_combined_reports.txt

"$CODE/steps/taxprofiler_composition.sh" > composition.log 2>&1
check_step "composition step exits 0" "$?" composition.log
check "db: names resolve to the taxonomy dump" "yes" "$(grep -q 'Building the taxonomy tree for 2 taxa' composition.log && echo yes)"
for file in taxonomy-tree.newick metaphlan-table.hdf5.biom metaphlan-tree.newick; do
    check "feature_table/$file written" "yes" "$([[ -s results/feature_table/$file ]] && echo yes)"
done
for file in bracken-reads.tsv metaphlan-reads.tsv metaphlan-cells.tsv motus-cells.tsv; do
    check "count_tables/$file written" "yes" "$([[ -s results/count_tables/$file ]] && echo yes)"
done
check "the feature table carries the ranks" "Saccharomyces" \
    "$(grep -o 'Saccharomyces[^;]*' results/feature_table/feature-table.tsv | head -n 1)"
check "the HDF5 feature table reads back with its tree" "2 TRUE" \
    "$(r_eval "b <- rbiom::read_biom('$PWD/results/feature_table/feature-table.hdf5.biom'); cat(b\$n_otus, !is.null(b\$tree))")"
check "the SGB table holds both SGBs, without the empty sample" "2 2 TRUE" \
    "$(r_eval "b <- rbiom::read_biom('$PWD/results/feature_table/metaphlan-table.hdf5.biom'); cat(b\$n_otus, b\$n_samples, !is.null(b\$tree))")"
check "Faith's PD on the taxonomy for 2612" "yes" \
    "$(awk -F'\t' '$1 == "2612" && $10 != "NA" { print "yes" }' results/alpha_diversity.tsv)"
check "Faith's PD on the SGB phylogeny for 2613" "yes" \
    "$(awk -F'\t' '$1 == "2613" && $12 != "NA" { print "yes" }' results/alpha_diversity.tsv)"
check "mOTUs counted, unassigned left out" "2 1" \
    "$(awk -F'\t' '$1 == "2612" || $1 == "2613" { printf "%s%s", sep, $9; sep = " " }' results/alpha_diversity.tsv)"
check "the chart offers mOTUs and the SGB Faith's PD" "coverage diversity motus effort95 faithsgb reads" \
    "$(json '[.metrics[].key] | join(" ")')"
check "MetaPhlAn mapped share is weighed by depth" "yes" "$([[ $(stat_of metaphlan_mapped) -gt 0 && $(stat_of metaphlan_mapped) -le $(stat_of metaphlan_total) ]] && echo yes)"

echo "biobakery, on synthetic outputs"
new_run biobakery
mkdir -p results/metaphlan/profiles results/kneaddata results/humann results/nonpareil \
    results/motus/profiles results/markermagu "$WORK/db/humann/v1/chocophlan" "$WORK/db/humann/v1/uniref90"
touch "$WORK/db/humann/v1/chocophlan/g__Blautia.s__Blautia_obeum.centroids.v201901_v31.ffn.gz"
touch "$WORK/db/humann/v1/uniref90/uniref90_201901b_full.dmnd"
printf 'sample,run_accession,instrument_platform,fastq_1,fastq_2,fasta\n' > biobakery_samplesheet.csv
for sample in S1 S2 S3; do
    printf '%s,run1,ILLUMINA,%s_1.fq.gz,%s_2.fq.gz,\n' "$sample" "$sample" "$sample" >> biobakery_samplesheet.csv
done
state_set samples.platform ILLUMINA
state_set_json params '{"humann_chocophlan": "db:humann/v1/chocophlan", "humann_uniref": "db:humann/v1/uniref90", "markermagu_db": "db:markermagu/v1.1"}'

# Two profiled samples, shaped like the MetaPhlAn module stub, S3 never profiled
profile() {
    local sample=$1 reads=$2 blautia=$3 bacteroides=$4
    printf '#mpa_vJun23_CHOCOPhlAnSGB_202403\n#metaphlan stub\n#%s reads processed\n#SampleID\t%s\n' "$reads" "$sample"
    printf '#estimated_reads_mapped_to_known_clades:1500\n'
    printf '#clade_name\tclade_taxid\trelative_abundance\tcoverage\testimated_number_of_reads_from_the_clade\n'
    printf 'UNCLASSIFIED\t-1\t%s\t-\t500\n' "$(awk -v a="$blautia" -v b="$bacteroides" 'BEGIN { print 100 - a - b }')"
    awk -v a="$blautia" -v b="$bacteroides" 'BEGIN {
        OFS = "\t"
        print "k__Bacteria", "2", a + b, "-", "1"
        print "k__Bacteria|p__Bacillota", "2|1239", a, "-", "1"
        print "k__Bacteria|p__Bacillota|c__Clostridia", "", a, "-", "1"
        print "k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales", "", a, "-", "1"
        print "k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae", "", a, "-", "1"
        print "k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia", "", a, "-", "1"
        print "k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia|s__Blautia_obeum", "", a, "1", "1"
        print "k__Bacteria|p__Bacteroidota", "", b, "-", "1"
        print "k__Bacteria|p__Bacteroidota|c__Bacteroidia", "", b, "-", "1"
        print "k__Bacteria|p__Bacteroidota|c__Bacteroidia|o__Bacteroidales", "", b, "-", "1"
        print "k__Bacteria|p__Bacteroidota|c__Bacteroidia|o__Bacteroidales|f__Bacteroidaceae", "", b, "-", "1"
        print "k__Bacteria|p__Bacteroidota|c__Bacteroidia|o__Bacteroidales|f__Bacteroidaceae|g__Bacteroides", "", b, "-", "1"
        print "k__Bacteria|p__Bacteroidota|c__Bacteroidia|o__Bacteroidales|f__Bacteroidaceae|g__Bacteroides|s__Bacteroides_uniformis", "", b, "1", "1"
    }'
}
profile S1 2000 60 15 > results/metaphlan/profiles/S1.metaphlan_profile.txt
profile S2 4000 30 50 > results/metaphlan/profiles/S2.metaphlan_profile.txt
printf 'sample\treads\tmarker_reads\nS1\t2000\t120\nS2\t4000\t300\n' > results/metaphlan/read-counts.tsv
printf '%s\n' 'sample	raw pair1	raw pair2	decontaminated chm13v2phix pair1	decontaminated chm13v2phix pair2	trimmed pair1	trimmed pair2	final pair1	final pair2' \
    'S1	1200	1200	1100	1100	1000	1000	1000	1000' \
    'S2	2400	2400	2200	2200	2000	2000	2000	2000' > results/kneaddata/read-counts.tsv
printf '%s\n' 'sample	prescreen_species	unaligned_after_nucleotide_pct	unaligned_after_translated_pct	gene_families' \
    'S1	10	60.0	40.0	1000' > results/humann/alignment-summary.tsv
printf '%s\n' 'kappa	C	LR	modelR	LRstar	diversity' \
    'S1	0.5	0.6	300000000	0.99	900000000	17.5' \
    'S2	0.7	0.8	600000000	0.98	NaN	18.25' > results/nonpareil/nonpareil-curves.tsv
for sample in S1 S2; do
    {
        printf '# motus version 3.1.0\n#consensus_taxonomy\tNCBI_tax_id\t%s\n' "$sample"
        printf 'Blautia obeum [ref_mOTU_v31_00001]\t40520\t12\n'
        printf 'Bacteroides uniformis [ref_mOTU_v31_00002]\t820\t%s\n' "$([[ $sample == S1 ]] && echo 0 || echo 5)"
        printf 'unassigned\tNA\t3\n'
    } > "results/motus/profiles/$sample.motus_profile.txt"
done
printf 'sample\treads\tbases\nS1\t3000\t450000\nS2\t3000\t450000\n' > results/markermagu/markermagu-input.tsv
printf '%s\n' 'taxonomy	RPKM	fraction	genes	reads	sample' \
    'k__Viruses|p__Uroviricota|s__phage_a	1.0	0.5	4	30	S1' \
    'k__Bacteria|p__Bacillota|s__Blautia_obeum	2.0	0.5	4	500	S1' \
    'k__Viruses|p__Uroviricota|s__phage_b	1.0	0.5	4	12	S2' > results/markermagu/markermagu-profile.tsv

"$CODE/steps/biobakery_composition.sh" > composition.log 2>&1
check_step "composition step exits 0" "$?" composition.log
check "plot data names the profiled samples" "S1 S2" "$(json '.samples | join(" ")')"
check "the reads MetaPhlAn processed are the depth" "2000 4000" "$(json '.reads | join(" ")')"
check "every column closes at the whole sample" "true" "$(levels_close exact)"
check "genus shares in ten-thousandths, with the unclassified rest" "Blautia:6000,3000 Bacteroides:1500,5000 Unclassified:2500,2000" \
    "$(json '.levels[] | select(.name == "Genus") | [range(0; .taxa | length - 1) as $i | "\(.taxa[$i].label):\(.values[$i] | join(","))"] | join(" ")')"
check "S3, never profiled, is reported dropped" "S3" "$(stat_of samples_dropped)"
check "HUMAnN's gap is reported, and Nonpareil has none" "S2 none" \
    "$(stat_of humann_missing) $(stat_of nonpareil_missing | grep . || echo none)"
check "layout and retained reads from KneadData" "paired-end 6000" "$(stat_of layout) $(stat_of retained_total)"
check "MetaPhlAn mapping from its read counts" "6000 420" "$(stat_of metaphlan_total) $(stat_of metaphlan_mapped)"
check "HUMAnN mapping weighed by depth" "2000 1200" "$(stat_of humann_total) $(stat_of humann_mapped)"
check "HUMAnN databases named from db: paths" "ChocoPhlAn v201901_v31 · UniRef90 v201901b" "$(stat_of humann_database)"
check "Marker-MAGu counts only viral reads" "6000 42 Marker-MAGu_markerDB_v1.1" \
    "$(stat_of markermagu_total) $(stat_of markermagu_mapped) $(stat_of markermagu_database)"
check "MetaPhlAn database off the profile header" "mpa_vJun23_CHOCOPhlAnSGB_202403" "$(stat_of metaphlan_database)"
check "alpha table holds Nd, coverage and mOTUs" "S1 17.5000 60.0000 1|S2 18.2500 80.0000 2" \
    "$(awk -F'\t' 'NR > 1 { printf "%s%s %s %s %s", sep, $1, $3, $4, $9; sep = "|" }' results/alpha_diversity.tsv)"
check "and NA for a reading Nonpareil couldn't fit" "NA" "$(awk -F'\t' '$1 == "S2" { print $8 }' results/alpha_diversity.tsv)"
check "the chart offers all four readings" "coverage diversity motus effort95 reads" "$(json '[.metrics[].key] | join(" ")')"

echo "biobakery, with no profiles"
new_run biobakery-empty
mkdir -p results
"$CODE/steps/biobakery_composition.sh" > composition.log 2>&1
check "the step exits 0" "0" "$?"
check "and writes no plot data" "no" "$([[ -e composition_data.json ]] && echo yes || echo no)"

exit $FAILED
