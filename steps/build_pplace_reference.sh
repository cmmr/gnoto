#!/bin/bash
#
# build_pplace_reference.sh - Builds the reference tree ASVs are grafted onto.
#
# Downloads SBDI's GTDB bacterial 16S reference - one 16S sequence per GTDB
# species representative, aligned, plus the maximum-likelihood tree built from
# that alignment - checks each file against the md5 conf/databases.yaml records,
# then checks the two against each other.
#
# EPA-NG aligns a run's ASVs to this alignment and grafts them onto this tree,
# and that grafted tree is what UniFrac and Faith's PD are computed over. Its
# branch lengths and its root come from the reference rather than from the run,
# so two runs produce the same tree with different tips added.
#
# ampliseq also carries these files, under --run_pplace, but that route feeds
# them to taxonomy assignment and never puts the tree into the diversity
# calculation. They are fetched here so --pplace_tree and --pplace_aln can name
# them as local paths, which is the route that does.
#
# The two figshare files conf/databases.yaml names are the ones ampliseq pins
# for sbdi-gtdb's bac16s at the commit pipelines/ampliseq/lock.yaml pins. A new
# ampliseq pin means checking that its conf/ref_databases.config still names
# them. A different pair is a new database path, such as pplace/v2.
#
# Usage:     build_pplace_reference.sh <out_dir>
# Called by: the database fetch job, as the pplace/v1 setup line in
#            conf/databases.yaml, with <out_dir> appended. <out_dir> is an empty
#            directory the job made. On success the job renames it to
#            <db_dir>/pplace/v1 and moves manifest.yaml beside it, as
#            pplace/v1.manifest.yaml. On failure it removes it.
# Requires:  curl, md5sum, sha256sum, awk, sort, comm, yq and jq, from the gnoto
#            image. About 100 MB of disk, 1 CPU and 1 GB of memory.
# Reads:     the pplace/v1 entry of conf/databases.yaml
# Writes:    into <out_dir>:
#              bac16s.alnfna    the reference alignment, one row per species
#                               representative
#              bac16s.newick    the tree built from it, one tip for each of those
#              manifest.yaml    what went in, from where, and how
# Env:       CODE_DIR and the log/fail helpers, from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
source "$CODE_DIR/steps/fetch_files.sh"

readonly DB="pplace/v1"
readonly ALIGNMENT="bac16s.alnfna"
readonly TREE="bac16s.newick"

# The substitution model the reference tree was fitted under, which EPA-NG has to
# be given to place onto it. pipelines/ampliseq/pipeline.sh passes the same
# string as pplace_model, and the manifest records it so the two can be compared.
readonly TREE_MODEL="GTR+F+I+G4"

# A reference smaller than this is a truncated download rather than a smaller
# release: R11-RS232-1 carries 54322 representatives.
readonly MIN_REFERENCE_TIPS=10000

[[ $# -eq 1 ]] || fail "Usage: build_pplace_reference.sh <out_dir>"
OUT_DIR=$(out_dir_path "$1") || exit 1
# Away from the caller's directory, where fail would write to a run's state
cd "$OUT_DIR"

ENTRY=$(fetch_entry "$DB") || fail "conf/databases.yaml has no database $DB."
SOURCES=$(jq -c '.sources // []' <<< "$ENTRY")
check_downloads "$SOURCES" "$DB"
if [[ $(jq -r '[.[].file] | sort | join(" ")' <<< "$SOURCES") != "$ALIGNMENT $TREE" ]]; then
    fail "conf/databases.yaml's $DB entry must download exactly $ALIGNMENT and $TREE."
fi

WORK_DIR=$(mktemp -d "$OUT_DIR/.build.XXXXXX") || fail "Couldn't make a working directory in $OUT_DIR."
trap 'rm -rf "$WORK_DIR"' EXIT

# The tip labels of a newick tree, one per line. Records start after "(" or ",",
# so a leaf reads "NAME:length" while a closing branch reads ")support:length"
# and is dropped by trimming from its ")".
tree_tips() {
    awk 'BEGIN { RS = "[(,]" }
        {
            sub(/\).*/, "")
            sub(/:.*/, "")
            gsub(/^[ \t'"'"']+|[ \t'"'"'\r\n]+$/, "")
            if ($0 != "") print
        }' "$1"
}

log "Downloading the $(jq -r '.release' <<< "$ENTRY") placement reference..."
while IFS=$'\t' read -r url md5 bytes file; do
    log "  $file, $(human_size "$bytes"), from $url"
    fetch_checked "$url" "$md5" "$bytes" "$OUT_DIR/$file"
done < <(jq -r '.[] | [.url, .md5, (.bytes | tostring), .file] | @tsv' <<< "$SOURCES")

# 1. The alignment has to be aligned: EPA-NG reads it as a matrix, and one row of
#    a different width is a truncated or concatenated download rather than a gap.
log "Checking the alignment..."

read -r SEQUENCE_COUNT ALIGNMENT_WIDTH RAGGED_ID < <(awk '
    /^>/ {
        if (n > 0 && length(seq) != width) { ragged = id; exit }
        n++
        id = substr($1, 2)
        if (n == 1) width = 0
        seq = ""
        next
    }
    {
        gsub(/[\r\n]/, "")
        seq = seq $0
        if (n == 1) width = length(seq)
    }
    END {
        if (!ragged && n > 0 && length(seq) != width) ragged = id
        printf "%d %d %s\n", n, width, (ragged ? ragged : "-")
    }' "$ALIGNMENT")

if [[ "$RAGGED_ID" != "-" ]]; then
    REASON="The reference alignment is ragged: $RAGGED_ID is not $ALIGNMENT_WIDTH columns wide."
    REASON+=$'\n'"The download is incomplete; nothing was built."
    fail "$REASON"
fi

if [[ "$SEQUENCE_COUNT" -lt "$MIN_REFERENCE_TIPS" ]]; then
    REASON="The reference alignment holds $SEQUENCE_COUNT sequences, fewer than the"
    REASON+=" $MIN_REFERENCE_TIPS a GTDB release carries. The download is incomplete;"
    REASON+=" nothing was built."
    fail "$REASON"
fi

# 2. Every sequence in the alignment needs a tip of the same name in the tree, and
#    the other way round. EPA-NG refuses the pair otherwise, and it refuses after
#    the run has already paid for cutadapt and DADA2.
log "Checking the tree against it..."

tree_tips "$TREE" | LC_ALL=C sort > "$WORK_DIR/tips.txt"
awk '/^>/ { print substr($1, 2) }' "$ALIGNMENT" | LC_ALL=C sort > "$WORK_DIR/sequences.txt"

TIP_COUNT=$(wc -l < "$WORK_DIR/tips.txt")

# sed reads to the end, where head would stop comm with SIGPIPE and pipefail
# would end the script before it explains
TREE_ONLY=$(LC_ALL=C comm -23 "$WORK_DIR/tips.txt" "$WORK_DIR/sequences.txt" | sed -n 1,3p)
ALIGNMENT_ONLY=$(LC_ALL=C comm -13 "$WORK_DIR/tips.txt" "$WORK_DIR/sequences.txt" | sed -n 1,3p)

if [[ -n "$TREE_ONLY" || -n "$ALIGNMENT_ONLY" ]]; then
    REASON="The reference tree and alignment do not describe the same sequences:"
    REASON+=" $TIP_COUNT tips against $SEQUENCE_COUNT sequences."

    [[ -n "$TREE_ONLY" ]] && REASON+=$'\n'"In the tree only: $(printf '%s' "$TREE_ONLY" | tr '\n' ' ')"
    [[ -n "$ALIGNMENT_ONLY" ]] && REASON+=$'\n'"In the alignment only: $(printf '%s' "$ALIGNMENT_ONLY" | tr '\n' ' ')"

    REASON+=$'\n'"Nothing was built."
    fail "$REASON"
fi

rm -rf "$WORK_DIR"

# 3. Record what was built.
ABOUT=$(jq -c \
    --arg model "$TREE_MODEL" \
    --argjson sequences "$SEQUENCE_COUNT" \
    --argjson width "$ALIGNMENT_WIDTH" \
    --argjson tips "$TIP_COUNT" \
    --argjson sources "$SOURCES" '{
        name, release, doi,
        built_with: "steps/build_pplace_reference.sh",
        model: $model, sequences: $sequences, alignment_width: $width, tips: $tips,
        sources: ($sources | map({file, url, md5, bytes}))
    }' <<< "$ENTRY")
write_manifest "$OUT_DIR" "$DB" "$ABOUT"

log "Built the placement reference in $OUT_DIR:"
log "  alignment: $ALIGNMENT ($SEQUENCE_COUNT sequences, $ALIGNMENT_WIDTH columns)"
log "  tree:      $TREE ($TIP_COUNT tips, $TREE_MODEL)"
