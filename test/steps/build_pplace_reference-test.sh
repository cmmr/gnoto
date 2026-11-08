#!/bin/bash
#
# build_pplace_reference-test.sh - Runs steps/build_pplace_reference.sh on small
# synthetic references, served as file:// urls, and checks that it accepts a
# good pair and refuses a wrong md5, a ragged alignment, a short one and a tree
# that doesn't match. Then checks the built pplace/v1 in db_dir, if there is one,
# against its manifest and conf/databases.yaml.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/steps/build_pplace_reference-test.sh
# Requires:  nothing beyond the gnoto image. Needs no network.
#
# The builds run from a scratch copy of the code whose conf/databases.yaml
# points pplace/v1 at the synthetic files, so the real file is never changed.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
WORK=$(mktemp -d "$DATA_DIR/test-pplace.XXXXXX")
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

mkdir "$WORK/code" "$WORK/src"
cp -r "$CODE/lib" "$CODE/steps" "$CODE/conf" "$CODE/pipelines" "$WORK/code/"
SCRATCH=$WORK/code/conf/databases.yaml

# An alignment of <count> rows, 20 columns wide, with row <short> one column
# short, and a tree over the same names, with an internal node and support
# values, leaving out tip <drop>, and with each tip's leading S as <prefix>
make_reference() {
    local name=$1 count=$2 short=${3:-0} drop=${4:-0} prefix=${5:-S}
    awk -v n="$count" -v short="$short" 'BEGIN {
        for (i = 1; i <= n; i++) {
            printf ">S%05d some description\n", i
            row = "ACGT-ACGTACGT-ACGTA"
            print (i == short) ? row : row "C"
        }
    }' > "$WORK/src/$name.alnfna"
    awk -v n="$count" -v drop="$drop" -v p="$prefix" 'BEGIN {
        printf "((%s00001:0.1,%s00002:0.2)95:0.05", p, p
        for (i = 3; i <= n; i++) if (i != drop) printf ",%s%05d:0.1", p, i
        print ");"
    }' > "$WORK/src/$name.newick"
}

# Points pplace/v1 at a synthetic pair, recording their real md5s and sizes,
# or a wrong md5 for the tree when asked
use_reference() {
    local name=$1 tree_md5=${2:-}
    local aln=$WORK/src/$name.alnfna tree=$WORK/src/$name.newick
    [[ -n "$tree_md5" ]] || tree_md5=$(md5sum < "$tree" | cut -d' ' -f1)
    ALN_URL="file://$aln" ALN_MD5=$(md5sum < "$aln" | cut -d' ' -f1) ALN_BYTES=$(stat -c %s "$aln") \
        TREE_URL="file://$tree" TREE_MD5=$tree_md5 TREE_BYTES=$(stat -c %s "$tree") yq -i '
        (.databases[] | select(.path == "pplace/v1") | .sources) = [
            {"file": "bac16s.alnfna", "url": strenv(ALN_URL), "md5": strenv(ALN_MD5),
             "bytes": (strenv(ALN_BYTES) | tonumber)},
            {"file": "bac16s.newick", "url": strenv(TREE_URL), "md5": strenv(TREE_MD5),
             "bytes": (strenv(TREE_BYTES) | tonumber)}]' "$SCRATCH"
}

# Builds into a new directory <name>, logging to <name>.log
build() {
    mkdir "$WORK/$1"
    bash "$WORK/code/steps/build_pplace_reference.sh" "$WORK/$1" > "$WORK/$1.log" 2>&1
}

echo "synthetic references"
make_reference good 10001
use_reference good
build good
STATUS=$?
check "a good pair builds" "0" "$STATUS"
[[ $STATUS -eq 0 ]] || tail -5 "$WORK/good.log" | sed 's/^/      /'
check "it holds the two files and the manifest" "bac16s.alnfna bac16s.newick manifest.yaml" \
    "$(ls "$WORK/good" | tr '\n' ' ' | sed 's/ $//')"
check "the files are the downloads" "yes" \
    "$(cmp -s "$WORK/good/bac16s.alnfna" "$WORK/src/good.alnfna" && cmp -s "$WORK/good/bac16s.newick" "$WORK/src/good.newick" && echo yes)"
check "manifest counts sequences, columns and tips" "10001 20 10001 GTR+F+I+G4" \
    "$(yq '[.sequences, .alignment_width, .tips, .model] | join(" ")' "$WORK/good/manifest.yaml")"
check "manifest's tree digest" "$(digest "$WORK/good")" "$(yq '.tree_sha256' "$WORK/good/manifest.yaml")"
check "manifest's path and file count" "pplace/v1 2" "$(yq '[.path, .files] | join(" ")' "$WORK/good/manifest.yaml")"

make_reference ragged 10001 5000
use_reference ragged
build ragged
check "a ragged alignment is refused" "1 yes" \
    "$? $(grep -q 'ragged: S05000 is not 20 columns' "$WORK/ragged.log" && echo yes)"

make_reference short 9999
use_reference short
build short
check "an alignment under 10000 rows is refused" "1 yes" \
    "$? $(grep -q 'holds 9999 sequences' "$WORK/short.log" && echo yes)"

make_reference mismatch 10001 0 10001
use_reference mismatch
build mismatch
check "a tree missing a tip is refused, naming it" "1 yes" \
    "$? $(grep -q 'In the alignment only: S10001' "$WORK/mismatch.log" && echo yes)"

make_reference renamed 10001 0 0 T
use_reference renamed
build renamed
check "a tree with no tip in common is refused, with the explanation" "1 yes" \
    "$? $(grep -q '10001 tips against 10001 sequences' "$WORK/renamed.log" && echo yes)"

use_reference good 0123456789abcdef0123456789abcdef
build badmd5
check "a wrong md5 stops it before any check" "1 yes" \
    "$? $(grep -q 'has md5 .* not the 0123456789abcdef' "$WORK/badmd5.log" && ! grep -q 'Checking' "$WORK/badmd5.log" && echo yes)"
check "and leaves no tree" "no" "$([[ -e $WORK/badmd5/bac16s.newick || -e $WORK/badmd5/bac16s.newick.part ]] && echo yes || echo no)"

echo "pplace/v1 in db_dir"
if [[ -d $DB_DIR/pplace/v1 ]]; then
    MANIFEST=$DB_DIR/pplace/v1.manifest.yaml
    check "its tree digest matches its manifest" "$(yq '.tree_sha256' "$MANIFEST")" "$(digest "$DB_DIR/pplace/v1")"
    check "its files have the md5s conf/databases.yaml records" \
        "$(yq '[.databases[] | select(.path == "pplace/v1") | .sources[].md5] | join(" ")' "$CODE/conf/databases.yaml")" \
        "$(cd "$DB_DIR/pplace/v1" && md5sum bac16s.alnfna bac16s.newick | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
    check "and 54322 sequences and tips" "54322 54322" "$(yq '[.sequences, .tips] | join(" ")' "$MANIFEST")"
else
    echo "skip  there's no $DB_DIR/pplace/v1"
fi

exit $FAILED
