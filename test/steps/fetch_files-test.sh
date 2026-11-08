#!/bin/bash
#
# fetch_files-test.sh - Fetches SILVA 138.2 and the 16s-v4 fixture with
# steps/fetch_files.sh, compares them with the copies already in db_dir, and
# checks that a wrong md5, a wrong size, an unreachable url and a bad entry each
# stop the fetch, naming the url, with no unchecked file left behind.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/steps/fetch_files-test.sh
# Requires:  network access, and dada2/silva-138.2 and fixtures/16s-v4/v1 in
#            <db_dir>, to compare against. Downloads about 210 MB.
#
# The failures run from a scratch copy of the code whose
# pipelines/databases.yaml has extra fixtures, so the real file is never
# changed.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
WORK=$(mktemp -d "$DATA_DIR/test-fetch.XXXXXX")
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

# The tree digest, computed independently of fetch_files.sh
digest() {
    (cd "$1" && find . -type f ! -path ./manifest.yaml -printf '%P\0' | LC_ALL=C sort -z |
        xargs -0r sha256sum -- | sha256sum | cut -d' ' -f1)
}

# Fetches <db path> with the given code into a new directory <dir>, logging to <dir>.log
fetch() {
    mkdir "$WORK/$3"
    bash "$1/steps/fetch_files.sh" "$2" "$WORK/$3" > "$WORK/$3.log" 2>&1
}

echo "dada2/silva-138.2"
fetch "$CODE" dada2/silva-138.2 silva
check "fetch exits 0" "0" "$?"
check "the same two files as the copy in db_dir" "$(ls "$DB_DIR/dada2/silva-138.2")" \
    "$(ls "$WORK/silva" | grep -vx manifest.yaml)"
for file in "$DB_DIR"/dada2/silva-138.2/*; do
    check "${file##*/} identical" "yes" "$(cmp -s "$file" "$WORK/silva/${file##*/}" && echo yes)"
done
check "manifest's tree digest matches the copy in db_dir" "$(digest "$DB_DIR/dada2/silva-138.2")" \
    "$(yq '.tree_sha256' "$WORK/silva/manifest.yaml")"
check "manifest's path, count and size" "dada2/silva-138.2 2 210915821" \
    "$(yq '[.path, .files, .bytes] | join(" ")' "$WORK/silva/manifest.yaml")"
check "manifest names each source with its md5" \
    "$(yq '[.databases[] | select(.path == "dada2/silva-138.2") | .files[].md5] | join(" ")' "$CODE/pipelines/databases.yaml")" \
    "$(yq '[.sources[].md5] | join(" ")' "$WORK/silva/manifest.yaml")"
check "manifest says how" "steps/fetch_files.sh 138.2" \
    "$(yq '[.built_with, .release] | join(" ")' "$WORK/silva/manifest.yaml")"
check "no partial files left" "" "$(find "$WORK/silva" -name '*.part' -o -name '.*' -type d)"
rm -rf "$WORK/silva"

echo "fixtures/16s-v4/v1"
fetch "$CODE" fixtures/16s-v4/v1 fixture
check "fetch exits 0" "0" "$?"
check "the same tree as the copy in db_dir" "$(digest "$DB_DIR/fixtures/16s-v4/v1")" "$(digest "$WORK/fixture")"
check "manifest's tree digest" "$(digest "$WORK/fixture")" "$(yq '.tree_sha256' "$WORK/fixture/manifest.yaml")"
check "a fixture's manifest has no name or release" "fixtures/16s-v4/v1 false false" \
    "$(yq '[.path, has("name"), has("release")] | join(" ")' "$WORK/fixture/manifest.yaml")"

echo "refusals"
mkdir "$WORK/full"
touch "$WORK/full/leftover"
bash "$CODE/steps/fetch_files.sh" fixtures/16s-v4/v1 "$WORK/full" > "$WORK/full.log" 2>&1
check "a directory that isn't empty is refused" "1 yes" "$? $(grep -q "isn't empty" "$WORK/full.log" && echo yes)"
fetch "$CODE" nothing/v1 unknown
check "an unknown path is refused" "1 yes" "$? $(grep -q 'has no database or fixture nothing/v1' "$WORK/unknown.log" && echo yes)"
fetch "$CODE" fixtures/16s-v4/v2 version
check "a fixture version other than v1 is refused" "1" "$?"
bash "$CODE/steps/fetch_files.sh" fixtures/16s-v4/v1 "$WORK/missing" > "$WORK/missing.log" 2>&1
check "a missing directory is refused" "1 yes" "$? $(grep -q "isn't a writable directory" "$WORK/missing.log" && echo yes)"

echo "failures, from a scratch copy of the code"
mkdir "$WORK/code"
cp -r "$CODE/lib" "$CODE/steps" "$CODE/pipelines" "$WORK/code/"
SCRATCH=$WORK/code/pipelines/databases.yaml
GOOD_URL=$(yq '.fixtures."16s-v4"[0].url' "$SCRATCH")
GOOD_MD5=$(yq '.fixtures."16s-v4"[0].md5' "$SCRATCH")
GOOD_BYTES=$(yq '.fixtures."16s-v4"[0].bytes' "$SCRATCH")
add_fixture() {
    NAME=$1 URL=$2 MD5=$3 BYTES=$4 yq -i \
        '.fixtures[strenv(NAME)] = [{"url": strenv(URL), "md5": strenv(MD5), "bytes": (strenv(BYTES) | tonumber)}]' \
        "$SCRATCH"
}
add_fixture bad-md5 "$GOOD_URL" 0123456789abcdef0123456789abcdef "$GOOD_BYTES"
add_fixture bad-size "$GOOD_URL" "$GOOD_MD5" 1201430
add_fixture unresolvable https://gnoto.invalid/reads.fastq.gz "$GOOD_MD5" "$GOOD_BYTES"
add_fixture refused http://127.0.0.1:9/reads.fastq.gz "$GOOD_MD5" "$GOOD_BYTES"
NAME=no-md5 URL=$GOOD_URL yq -i '.fixtures[strenv(NAME)] = [{"url": strenv(URL), "bytes": 5}]' "$SCRATCH"

for name in bad-md5 bad-size unresolvable refused no-md5; do
    fetch "$WORK/code" "fixtures/$name/v1" "$name"
    STATUS=$?
    url=$(yq ".fixtures.\"$name\"[0].url" "$SCRATCH")
    check "$name: fails" "1" "$STATUS"
    check "$name: the message names the url" "yes" "$(grep 'ERROR' "$WORK/$name.log" | grep -qF "$url" && echo yes)"
    check "$name: nothing left in the directory" "" "$(ls -A "$WORK/$name")"
done
grep -h 'ERROR' "$WORK"/{bad-md5,bad-size,unresolvable,refused,no-md5}.log | sed 's/^\[[^]]*\] /      /'

exit $FAILED
