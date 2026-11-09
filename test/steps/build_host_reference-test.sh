#!/bin/bash
#
# build_host_reference-test.sh - Builds the PhiX host reference twice with
# steps/build_host_reference.sh and checks its layout, its manifest, that the
# two builds are identical, and that a wrong md5 stops the build.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/steps/build_host_reference-test.sh
# Requires:  network access, for NCBI and the bowtie2 and minimap2 images
#
# The failure runs from a scratch copy of the code whose
# pipelines/databases.yaml points hostremoval/phix/v1 at an altered copy of the
# download, as a file:// url.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
WORK=$(mktemp -d "$DATA_DIR/test-host.XXXXXX")
FAILED=0
trap '[[ -n ${KEEP:-} ]] || rm -rf "$WORK"' EXIT
DB=hostremoval/phix/v1

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
    bash "$1/steps/build_host_reference.sh" "$DB" "$WORK/$2" > "$WORK/$2.log" 2>&1
}

echo "two builds"
build "$CODE" first
STATUS=$?
check "the build exits 0" "0" "$STATUS"
[[ $STATUS -eq 0 ]] || tail -5 "$WORK/first.log" | sed 's/^/      /'
build "$CODE" second
check "so does a second" "0" "$?"
check "the FASTA, the bowtie2 index, the minimap2 index and the manifest" "manifest.yaml phix phix.fa phix.mmi" \
    "$(ls -A "$WORK/first" | paste -sd ' ')"
check "the bowtie2 index is alone in its directory, as BOWTIE2_ALIGN finds it" \
    "phix.1.bt2 phix.2.bt2 phix.3.bt2 phix.4.bt2 phix.rev.1.bt2 phix.rev.2.bt2" "$(ls "$WORK/first/phix" | paste -sd ' ')"
check "the FASTA is PhiX's one sequence" "1 5386" \
    "$(grep -c '^>' "$WORK/first/phix.fa") $(grep -v '^>' "$WORK/first/phix.fa" | tr -d '\n' | wc -c)"
check "the two are identical" "$(digest "$WORK/first")" "$(digest "$WORK/second")"
check "manifest's tree digest" "$(digest "$WORK/first")" "$(yq .tree_sha256 "$WORK/first/manifest.yaml")"
check "manifest names the images it ran, as the lock pins them" \
    "$(yq .step_images.bowtie2 "$CODE/pipelines/taxprofiler/lock.yaml") $(yq .step_images.minimap2 "$CODE/pipelines/taxprofiler/lock.yaml")" \
    "$(yq '.bowtie2.image + " " + .minimap2.image' "$WORK/first/manifest.yaml")"
check "and commands that name no site path" "no" "$(grep -q "$WORK\|$DATA_DIR" "$WORK/first/manifest.yaml" && echo yes || echo no)"
check "minimap2's for map-ont, as taxprofiler's MINIMAP2_INDEX builds it" "yes" \
    "$(yq .minimap2.command "$WORK/first/manifest.yaml" | grep -q -- '-x map-ont -d phix.mmi phix.fa' && echo yes)"

echo "a wrong md5"
COPY=$WORK/code
mkdir "$COPY"
(cd "$CODE" && tar --exclude=.git -cf - .) | tar -xf - -C "$COPY"
URL=$(yq '.databases[] | select(.path == "hostremoval/phix/v1") | .sources[0].url' "$CODE/pipelines/databases.yaml")
curl -sSL --fail -o "$WORK/phix.fna.gz" "$URL" || { echo "Can't download $URL"; exit 1; }
gzip -dc "$WORK/phix.fna.gz" | sed '2s/^./N/' | gzip -n > "$WORK/altered.fna.gz"
U="file://$WORK/altered.fna.gz" B=$(stat -c %s "$WORK/altered.fna.gz") yq -i \
    '(.databases[] | select(.path == "hostremoval/phix/v1") | .sources[0]) |= (.url = strenv(U) | .bytes = (strenv(B) | tonumber))' \
    "$COPY/pipelines/databases.yaml"
build "$COPY" altered
check "fails before building" "1 yes no" \
    "$? $(grep -q 'pipelines/databases.yaml records, so upstream may have changed it' "$WORK/altered.log" && echo yes) $([[ -e $WORK/altered/phix ]] && echo yes || echo no)"

if (( FAILED )); then
    echo "Some checks failed. Logs: $WORK (kept with KEEP=1)."
    exit 1
fi
echo "All passed."
