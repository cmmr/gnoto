#!/bin/bash
#
# build_16s_reference-test.sh - Builds the 16S landmark reference twice with
# steps/build_16s_reference.sh and checks that the two are identical, then runs
# region detection on the 16s-v4 fixture against it. Then checks that a wrong
# md5, an E. coli gene of the wrong length, a genome with no 16S and a set
# without E. coli each stop the build.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/steps/build_16s_reference-test.sh
# Requires:  network access, for NCBI and the vsearch image; the 16s-v4 fixture
#            in <db_dir>/fixtures/16s-v4/v1. Compares with <db_dir>/16s/v1 when
#            there is one.
#
# The failures run from a scratch copy of the code whose
# pipelines/databases.yaml points 16s/v1 at altered copies of the downloads, as
# file:// urls, so the real file is never changed.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
FIXTURE=$DB_DIR/fixtures/16s-v4/v1
INSTALLED=$DB_DIR/16s/v1
WORK=$(mktemp -d "$DATA_DIR/test-16s.XXXXXX")
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

digest() {
    (cd "$1" && find . -type f ! -path ./manifest.yaml -printf '%P\0' | LC_ALL=C sort -z |
        xargs -0r sha256sum -- | sha256sum | cut -d' ' -f1)
}

# Builds with the given code into a new directory <name>, logging to <name>.log
build() {
    mkdir "$WORK/$2"
    bash "$1/steps/build_16s_reference.sh" "$WORK/$2" > "$WORK/$2.log" 2>&1
}

echo "two builds"
build "$CODE" first
STATUS=$?
check "the build exits 0" "0" "$STATUS"
[[ $STATUS -eq 0 ]] || tail -5 "$WORK/first.log" | sed 's/^/      /'
build "$CODE" second
check "so does a second" "0" "$?"
check "it holds the three files and the manifest" "ecoli_positions.tsv landmarks.fasta landmarks.sam manifest.yaml" \
    "$(ls "$WORK/first" | tr '\n' ' ' | sed 's/ $//')"
check "the two are identical" "$(digest "$WORK/first")" "$(digest "$WORK/second")"
check "manifest's tree digest" "$(digest "$WORK/first")" "$(yq '.tree_sha256' "$WORK/first/manifest.yaml")"
if [[ -d $INSTALLED ]]; then
    check "identical to the reference in db_dir" "$(digest "$INSTALLED")" "$(digest "$WORK/first")"
fi

ACCESSIONS=$(yq '[.databases[] | select(.path == "16s/v1") | .sources[].accession] | join(" ")' "$CODE/pipelines/databases.yaml")
check "a landmark per genome, in order" "$ACCESSIONS" \
    "$(grep '^>' "$WORK/first/landmarks.fasta" | cut -c2- | tr '\n' ' ' | sed 's/ $//')"
check "every genome has positions" "$ACCESSIONS" \
    "$(cut -f1 "$WORK/first/ecoli_positions.tsv" | uniq | tr '\n' ' ' | sed 's/ $//')"
check "E. coli maps onto itself, base for base" "1542 0" \
    "$(awk -F'\t' '$1 == "GCF_000005845.2" { n++; if ($2 != $3) bad++ } END { print n, bad + 0 }' "$WORK/first/ecoli_positions.tsv")"
check "positions are landmark, position and E. coli position" "0" \
    "$(awk -F'\t' 'NF != 3 || $2 !~ /^[0-9]+$/ || $3 < 1 || $3 > 1542' "$WORK/first/ecoli_positions.tsv" | wc -l)"
check "the SAM has no header naming a path" "0" "$(grep -c '^@' "$WORK/first/landmarks.sam")"
check "manifest records the vsearch image it ran" "$(yq '.step_images.vsearch' "$CODE/pipelines/ampliseq/lock.yaml")" \
    "$(yq '.vsearch.image' "$WORK/first/manifest.yaml")"
check "and each gene's length" "1542 1536 1555 1557 1529 1526 1512 1477" \
    "$(yq '[.sources[].length] | join(" ")' "$WORK/first/manifest.yaml")"

echo "region detection on 16s-v4"
if [[ -r $FIXTURE/SRR17380142_1.fastq.gz ]]; then
    # Under both the current name and the versioned one
    mkdir -p "$WORK/install" "$WORK/db/16s/v1" "$WORK/run"
    cp "$WORK/first"/{landmarks.fasta,landmarks.sam,ecoli_positions.tsv} "$WORK/db/16s/"
    cp "$WORK/first"/{landmarks.fasta,landmarks.sam,ecoli_positions.tsv} "$WORK/db/16s/v1/"
    printf 'core:\n  data_dir: "%s"\n  db_dir: "%s"\n' "$DATA_DIR" "$WORK/db" > "$WORK/install/config.yaml"
    (
        export GNOTO_INSTALL_DIR=$WORK/install
        source "$CODE/lib/env.sh" || exit 1
        cd "$WORK/run" || exit 1
        state_init abcdefgh
        printf '%s\t%s\t%s\n' SRR17380142 "$FIXTURE/SRR17380142_1.fastq.gz" \
            "$FIXTURE/SRR17380142_2.fastq.gz" > original_samplesheet.tsv
        "$CODE/steps/ampliseq_samplesheet.sh" > samplesheet.log 2>&1 || exit 2
        "$CODE/steps/ampliseq_detect_region.sh" > detect.log 2>&1 || exit 3
        state_get region
    ) > "$WORK/region.txt" 2> "$WORK/region.err"
    STATUS=$?
    check "detection exits 0" "0" "$STATUS"
    [[ $STATUS -eq 0 ]] || tail -5 "$WORK/run/detect.log" | sed 's/^/      /'
    check "and finds V4" "16SV4" "$(tail -1 "$WORK/region.txt")"
    check "with the V4 primers" "GTGCCAGCMGCCGCGGTAA" \
        "$(yq '.primer_fwd' "$WORK/run/detected_params.yaml" 2> /dev/null)"
else
    echo "skip  there's no 16s-v4 fixture in $FIXTURE"
fi

echo "failures, from a scratch copy of the code"
mkdir "$WORK/code" "$WORK/src"
cp -r "$CODE/lib" "$CODE/steps" "$CODE/pipelines" "$WORK/code/"
SCRATCH=$WORK/code/pipelines/databases.yaml
REAL=$(yq -o=json '.databases[] | select(.path == "16s/v1") | .sources' "$SCRATCH")
for i in $(seq 0 7); do
    url=$(jq -r ".[$i].url" <<< "$REAL")
    curl -sS --fail --retry 3 -o "$WORK/src/${url##*/}" "$url" || { echo "FAIL  couldn't download $url"; exit 1; }
done
ECOLI=$(jq -r '.[0].url | split("/") | last' <<< "$REAL")
AKK=$(jq -r '.[6].url | split("/") | last' <<< "$REAL")

# Every 16S record of E. coli loses its first base
gzip -dc "$WORK/src/$ECOLI" | awk '
    /^>/ { cut = ($0 ~ /\[gbkey=rRNA\]/ && $0 ~ /16S/); print; next }
    cut { print substr($0, 2); cut = 0; next }
    { print }' | gzip -n > "$WORK/src/short-$ECOLI"
# Akkermansia loses its 16S records
gzip -dc "$WORK/src/$AKK" | awk '
    /^>/ { skip = ($0 ~ /\[gbkey=rRNA\]/ && $0 ~ /16S/) }
    !skip' | gzip -n > "$WORK/src/no16s-$AKK"

# Points 16s/v1 at local copies, with the md5 and size of each, except that
# file <index> is replaced by <file>, and its md5 by <md5> when one is given
use_sources() {
    local index=${1:--1} file=${2:-} md5=${3:-} json
    json=$(jq --arg src "$WORK/src" --argjson index "$index" --arg file "$file" '
        to_entries | map(.value + {url: ("file://" + $src + "/" +
            (if .key == $index then $file else (.value.url | split("/") | last) end))})' <<< "$REAL")
    while IFS=$'\t' read -r i path; do
        json=$(jq --argjson i "$i" --arg md5 "$(md5sum < "$path" | cut -d' ' -f1)" \
            --argjson bytes "$(stat -c %s "$path")" '.[$i].md5 = $md5 | .[$i].bytes = $bytes' <<< "$json")
    done < <(jq -r 'to_entries[] | [.key, (.value.url | ltrimstr("file://"))] | @tsv' <<< "$json")
    [[ -z "$md5" ]] || json=$(jq --argjson i "$index" --arg md5 "$md5" '.[$i].md5 = $md5' <<< "$json")
    SOURCES=$json yq -i '(.databases[] | select(.path == "16s/v1") | .sources) = env(SOURCES)' "$SCRATCH"
}

use_sources
build "$WORK/code" local
check "local copies of the real downloads build the same reference" "0 $(digest "$WORK/first")" \
    "$? $(digest "$WORK/local")"

use_sources 3 "$(jq -r '.[3].url | split("/") | last' <<< "$REAL")" 0123456789abcdef0123456789abcdef
build "$WORK/code" badmd5
check "a wrong md5 stops the build" "1 yes" "$? $(grep -q 'has md5 .* not the 0123456789abcdef' "$WORK/badmd5.log" && echo yes)"
check "before any landmark is kept" "no" "$([[ -e $WORK/badmd5/landmarks.fasta ]] && echo yes || echo no)"

use_sources 0 "short-$ECOLI"
build "$WORK/code" short
check "an E. coli gene of the wrong length stops it" "1 yes" \
    "$? $(grep -q '16S gene is 1541 bp, not the expected 1542' "$WORK/short.log" && echo yes)"

use_sources 6 "no16s-$AKK"
build "$WORK/code" no16s
check "a genome with no 16S stops it, listing its rRNA products" "1 yes yes" \
    "$? $(grep -q 'annotated as 16S in GCF_000020225.1' "$WORK/no16s.log" && echo yes) $(grep -q '23S' "$WORK/no16s.log" && echo yes)"

SOURCES=$(jq -c '.[1:]' <<< "$REAL") yq -i '(.databases[] | select(.path == "16s/v1") | .sources) = env(SOURCES)' "$SCRATCH"
build "$WORK/code" noecoli
check "a set without E. coli is refused" "1 yes" "$? $(grep -q 'must include GCF_000005845.2' "$WORK/noecoli.log" && echo yes)"

exit $FAILED
