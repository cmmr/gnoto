#!/bin/bash
#
# fetch_shotgun_db-test.sh - Runs steps/fetch_shotgun_db.sh for each of its six
# databases on small fake archives, and checks each layout, its manifest, and
# that a wrong md5, an unpacked Kraken2 file its list disagrees with, a
# ChocoPhlAn file of another version, and a missing file each stop the fetch.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/steps/fetch_shotgun_db-test.sh
# Requires:  the gnoto image, and 200 GB free in the data directory, which the
#            Kraken2 fetch asks for before it starts
#
# The fetches run from a scratch copy of the code whose pipelines/databases.yaml
# points each entry at the fake archives, as file:// urls. The real downloads
# come to 160 GB, so they run only on a site's own fetch.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
WORK=$(mktemp -d "$DATA_DIR/test-shotgun.XXXXXX")
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

COPY=$WORK/code
mkdir "$COPY"
(cd "$CODE" && tar --exclude=.git -cf - .) | tar -xf - -C "$COPY"
FAKE=$WORK/fake
mkdir -p "$FAKE"

# The sources for an entry, as JSON, from files in FAKE
sources() {
    local file
    for file in "$@"; do
        jq -n --arg url "file://$FAKE/${file#*=}" --arg md5 "$(md5sum < "$FAKE/${file#*=}" | cut -d' ' -f1)" \
            --argjson bytes "$(stat -c %s "$FAKE/${file#*=}")" --arg component "${file%%=*}" \
            '{url: $url, md5: $md5, bytes: $bytes} + (if $component != "" then {component: $component} else {} end)'
    done | jq -s -c .
}

# Points an entry of the copy's databases.yaml at fake sources
point() {
    P=$1 S=$2 yq -i '(.databases[] | select(.path == strenv(P)) | .sources) = env(S)' "$COPY/pipelines/databases.yaml"
}

# Fetches an entry with the copy into a new directory named for its tool
fetch() {
    local out=$WORK/${1%%/*}
    rm -rf "$out" && mkdir "$out"
    bash "$COPY/steps/fetch_shotgun_db.sh" "$1" "$out" > "$out.log" 2>&1
}

# Archives a directory's contents, or one top directory, from a staging area
pack() {
    local archive=$1 dir=$2
    shift 2
    tar -czf "$FAKE/$archive" -C "$dir" "$@"
}

STAGE=$WORK/stage

echo "kraken2"
mkdir -p "$STAGE/k2"
for f in hash.k2d opts.k2d taxo.k2d nodes.dmp names.dmp database150mers.kmer_distrib database200mers.kmer_distrib; do
    echo "$f" > "$STAGE/k2/$f"
done
pack k2_pluspf_20260626.tar.gz "$STAGE/k2" .
(cd "$STAGE/k2" && md5sum -- * && md5sum "$FAKE/k2_pluspf_20260626.tar.gz" | sed "s|$FAKE/||") > "$FAKE/pluspf.md5"
point kraken2/pluspf_20260626 "$(sources =pluspf.md5 =k2_pluspf_20260626.tar.gz)"
fetch kraken2/pluspf_20260626
check "it fetches" "0" "$?"
check "the files, the publisher's list and the manifest" \
    "database150mers.kmer_distrib database200mers.kmer_distrib hash.k2d manifest.yaml names.dmp nodes.dmp opts.k2d pluspf.md5 taxo.k2d" \
    "$(ls -A "$WORK/kraken2" | paste -sd ' ')"
check "the manifest's notes" "7 files, each checked against pluspf.md5. Bracken distributions for 150,200-mers." \
    "$(yq .notes "$WORK/kraken2/manifest.yaml")"
check "and its digest" "$(cd "$WORK/kraken2" && find . -type f ! -path ./manifest.yaml -printf '%P\0' | LC_ALL=C sort -z | xargs -0r sha256sum -- | sha256sum | cut -d' ' -f1)" \
    "$(yq .tree_sha256 "$WORK/kraken2/manifest.yaml")"
echo changed > "$STAGE/k2/taxo.k2d"
pack k2_pluspf_20260626.tar.gz "$STAGE/k2" .
point kraken2/pluspf_20260626 "$(sources =pluspf.md5 =k2_pluspf_20260626.tar.gz)"
fetch kraken2/pluspf_20260626
check "a file its list disagrees with fails" "1 yes" \
    "$? $(grep -q "kraken2/pluspf_20260626's taxo.k2d doesn't match its md5 in pluspf.md5" "$WORK/kraken2.log" && echo yes)"
point kraken2/pluspf_20260626 "$(sources =pluspf.md5 =k2_pluspf_20260626.tar.gz | jq -c '.[1].md5 = "0123456789abcdef0123456789abcdef"')"
fetch kraken2/pluspf_20260626
check "a wrong md5 fails before unpacking" "1 yes no" \
    "$? $(grep -q 'not the 0123456789abcdef0123456789abcdef pipelines/databases.yaml records' "$WORK/kraken2.log" && echo yes) $([[ -e $WORK/kraken2/hash.k2d ]] && echo yes || echo no)"

echo "metaphlan"
I=mpa_vJun23_CHOCOPhlAnSGB_202403
mkdir -p "$STAGE/bt2" "$STAGE/pkl"
echo index | lbzip2 > "$STAGE/bt2/$I.1.bt2l.bz2"
echo index | lbzip2 > "$STAGE/bt2/$I.rev.1.bt2l.bz2"
echo markers > "$STAGE/pkl/$I.pkl"
tar -cf "$FAKE/${I}_bt2.tar" -C "$STAGE/bt2" .
tar -cf "$FAKE/$I.tar" -C "$STAGE/pkl" .
awk 'BEGIN { printf "("; for (i = 1; i <= 10001; i++) printf "%s%d:0.1", (i > 1 ? "," : ""), i; print ");" }' > "$FAKE/$I.nwk"
point "metaphlan/$I" "$(sources "=${I}_bt2.tar" "=$I.tar" "=$I.nwk")"
fetch "metaphlan/$I"
check "it fetches" "0" "$?"
check "the index decompressed, the markers, the marker file and the tree" \
    "manifest.yaml mpa_latest $I.1.bt2l $I.nwk $I.pkl $I.rev.1.bt2l" "$(ls -A "$WORK/metaphlan" | paste -sd ' ')"
check "mpa_latest names the index" "$I" "$(cat "$WORK/metaphlan/mpa_latest")"
check "the notes count the tips" "$I.nwk is the SGB phylogeny for this release, with 10001 tips." "$(yq .notes "$WORK/metaphlan/manifest.yaml")"
awk 'BEGIN { print "(1:0.1,2:0.1);" }' > "$FAKE/$I.nwk"
point "metaphlan/$I" "$(sources "=${I}_bt2.tar" "=$I.tar" "=$I.nwk")"
fetch "metaphlan/$I"
check "a tree of 2 tips fails" "1 yes" "$? $(grep -q "$I.nwk has only 2 tips" "$WORK/metaphlan.log" && echo yes)"

echo "motus"
mkdir -p "$STAGE/motus/db_mOTU"
for f in db_mOTU_DB_NR.fasta db_mOTU_bam_header_NR db_mOTU_MAP_MGCs_to_mOTUs.tsv db_mOTU_taxonomy_ref-mOTUs.tsv; do
    echo "$f" > "$STAGE/motus/db_mOTU/$f"
done
pack db_mOTU_v3.1.0.tar.gz "$STAGE/motus" db_mOTU
point motus/db_mOTU_v3.1.0 "$(sources =db_mOTU_v3.1.0.tar.gz)"
fetch motus/db_mOTU_v3.1.0
check "it fetches" "0" "$?"
check "the version file mOTUs checks" "motus 3.1.0" "$(head -n 1 "$WORK/motus/db_mOTU/db_mOTU_versions" | tr '\t' ' ')"
rm "$STAGE/motus/db_mOTU/db_mOTU_bam_header_NR"
pack db_mOTU_v3.1.0.tar.gz "$STAGE/motus" db_mOTU
point motus/db_mOTU_v3.1.0 "$(sources =db_mOTU_v3.1.0.tar.gz)"
fetch motus/db_mOTU_v3.1.0
check "a missing file fails" "1 yes" \
    "$? $(grep -q 'motus/db_mOTU_v3.1.0 is missing db_mOTU/db_mOTU_bam_header_NR' "$WORK/motus.log" && echo yes)"

echo "humann"
mkdir -p "$STAGE/choco" "$STAGE/uniref" "$STAGE/mapping"
echo genes | gzip > "$STAGE/choco/g__Bacteroides.s__Bacteroides_fragilis.centroids.v201901_v31.ffn.gz"
echo dmnd > "$STAGE/uniref/uniref90_201901b_full.dmnd"
for f in map_level4ec_uniref90.txt.gz map_ko_uniref90.txt.gz map_uniref90_name.txt.bz2; do
    echo "$f" > "$STAGE/mapping/$f"
done
pack full_chocophlan.v201901_v31.tar.gz "$STAGE/choco" .
pack uniref90_annotated_v201901b_full.tar.gz "$STAGE/uniref" .
pack full_mapping_v201901b.tar.gz "$STAGE/mapping" .
point humann/v201901b "$(sources chocophlan=full_chocophlan.v201901_v31.tar.gz \
    uniref90=uniref90_annotated_v201901b_full.tar.gz utility_mapping=full_mapping_v201901b.tar.gz)"
fetch humann/v201901b
check "it fetches" "0" "$?"
check "a directory per component" "chocophlan manifest.yaml uniref90 utility_mapping" "$(ls -A "$WORK/humann" | paste -sd ' ')"
check "the manifest names each source's component" "chocophlan uniref90 utility_mapping" \
    "$(yq '.sources[].component' "$WORK/humann/manifest.yaml" | paste -sd ' ')"
echo readme > "$STAGE/choco/README"
pack full_chocophlan.v201901_v31.tar.gz "$STAGE/choco" .
point humann/v201901b "$(sources chocophlan=full_chocophlan.v201901_v31.tar.gz \
    uniref90=uniref90_annotated_v201901b_full.tar.gz utility_mapping=full_mapping_v201901b.tar.gz)"
fetch humann/v201901b
check "a ChocoPhlAn file of no version fails, as HUMAnN would" "1 yes" \
    "$? $(grep -q "ChocoPhlAn holds README, which isn't v201901_v31" "$WORK/humann.log" && echo yes)"

echo "esviritu and markermagu"
mkdir -p "$STAGE/esv/v3.2.4" "$STAGE/mm/v1.1"
for f in virus_pathogen_database.fna virus_pathogen_database.mmi virus_pathogen_database.all_metadata.tsv; do
    printf '>v\nACGT\n' > "$STAGE/esv/v3.2.4/$f"
done
printf '>m1\nACGT\n>m2\nACGT\n' > "$STAGE/mm/v1.1/Marker-MAGu_markerDB.fna"
pack esviritu_db_v3.2.4.tar.gz "$STAGE/esv" v3.2.4
pack Marker-MAGu_markerDB_v1.1.tar.gz "$STAGE/mm" v1.1
point esviritu/v3.2.4 "$(sources =esviritu_db_v3.2.4.tar.gz)"
point markermagu/v1.1 "$(sources =Marker-MAGu_markerDB_v1.1.tar.gz)"
fetch esviritu/v3.2.4
check "esviritu fetches, its release directory's contents in place" \
    "0 manifest.yaml virus_pathogen_database.all_metadata.tsv virus_pathogen_database.fna virus_pathogen_database.mmi" \
    "$? $(ls -A "$WORK/esviritu" | paste -sd ' ')"
fetch markermagu/v1.1
check "markermagu fetches, counting its genes" "0 2 marker genes." "$? $(yq .notes "$WORK/markermagu/manifest.yaml")"
mv "$STAGE/mm/v1.1" "$STAGE/mm/v1.0"
pack Marker-MAGu_markerDB_v1.1.tar.gz "$STAGE/mm" v1.0
point markermagu/v1.1 "$(sources =Marker-MAGu_markerDB_v1.1.tar.gz)"
fetch markermagu/v1.1
check "an archive of another release fails" "1 yes" \
    "$? $(grep -q "didn't unpack to one directory named v1.1" "$WORK/markermagu.log" && echo yes)"

check "no download is left in a fetched database" "" "$(find "$WORK/esviritu" -name '.download')"

if (( FAILED )); then
    echo "Some checks failed. Logs: $WORK (kept with KEEP=1)."
    exit 1
fi
echo "All passed."
