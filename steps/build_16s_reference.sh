#!/bin/bash
#
# build_16s_reference.sh - Builds the landmark 16S reference the region detector
# aligns to.
#
# Pulls the 16S rRNA gene out of a handful of RefSeq genomes, concatenates them
# into one small FASTA, and records where every base of every landmark sits in
# E. coli numbering. The genomes, and the md5 of each file downloaded, are in
# the 16s/v1 entry of conf/databases.yaml. Each file is checked against its md5
# before anything is read from it.
#
# Reads are aligned to these landmarks rather than to a taxonomy database because
# the detector needs a coordinate, and a coordinate needs a reference whose
# numbering is fixed. E. coli K-12 MG1655 is that reference - variable regions
# and primer names are quoted in its numbering everywhere - so it must be in
# the set, and every other landmark is mapped onto it.
#
# The landmarks span the phyla a 16S survey returns, because usearch_global has
# to find a hit for a read before that read can vote on the region. One genome
# per phylum is enough: each carries the same coordinates, so any hit will do.
#
# NCBI replaces a RefSeq assembly's annotation files when it re-annotates the
# assembly, keeping the accession, so a recorded md5 can go stale. The build
# then fails naming the file, and a new set of md5s is a new path, 16s/v2.
#
# Usage:     build_16s_reference.sh <out_dir>
# Called by: the database fetch job, as the 16s/v1 setup line in
#            conf/databases.yaml, with <out_dir> appended. <out_dir> is an empty
#            directory the job made. On success the job renames it to
#            <db_dir>/16s/v1 and moves manifest.yaml beside it, as
#            16s/v1.manifest.yaml. On failure it removes it.
# Requires:  curl, md5sum, sha256sum, gzip, awk, yq and jq, from the gnoto image;
#            vsearch, from the image pipelines/ampliseq/lock.yaml pins. Under a
#            megabyte of downloads, 1 CPU and 1 GB of memory.
# Reads:     the 16s/v1 entry of conf/databases.yaml
# Writes:    into <out_dir>:
#              landmarks.fasta       the 16S genes, one per genome, named by
#                                    accession
#              landmarks.sam         each landmark aligned to the E. coli landmark
#              ecoli_positions.tsv   landmark, position in it, and the E. coli
#                                    position it is homologous to - one row per
#                                    base, read from the CIGARs
#              manifest.yaml         what went in, from where, and how
# Env:       CODE_DIR, DATA_DIR and the log/fail helpers, from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
source "$CODE_DIR/steps/fetch_files.sh"

readonly DB="16s/v1"

# The numbering reference. Its 16S is 1542 bp and carries the 515F site at
# position 515; both are checked below, since a landmark whose coordinates have
# shifted would misidentify every region.
readonly ECOLI_ACCESSION="GCF_000005845.2"
readonly ECOLI_16S_LENGTH=1542
readonly ECOLI_515F="GTG[CT]CAGC[AC]GCCGCGGTAA"
readonly ECOLI_515F_POSITION=515

# What counts as a 16S gene when picking one out of a genome's rRNA annotations.
# The eight in 16s/v1 run 1476-1556 bp; a 23S is nearer 2900 and a 5S nearer 120.
readonly MIN_16S_LENGTH=1400
readonly MAX_16S_LENGTH=1700

readonly LANDMARKS="landmarks.fasta"
readonly ALIGNMENT="landmarks.sam"
readonly POSITIONS="ecoli_positions.tsv"

# Run from the working directory, so the command the manifest records names no
# site path. One thread keeps the SAM in input order.
readonly VSEARCH_ARGS=(--usearch_global "$LANDMARKS" --db ecoli.fasta --id 0.5 --strand plus
    --maxaccepts 1 --maxrejects 0 --threads 1 --samout "$ALIGNMENT" --quiet)

[[ $# -eq 1 ]] || fail "Usage: build_16s_reference.sh <out_dir>"
OUT_DIR=$(out_dir_path "$1") || exit 1
# Away from the caller's directory, where fail would write to a run's state
cd "$OUT_DIR"

ENTRY=$(fetch_entry "$DB") || fail "conf/databases.yaml has no database $DB."
SOURCES=$(jq -c '[(.sources // [])[] | .file = (.url | tostring | split("/") | last)]' <<< "$ENTRY")
check_downloads "$SOURCES" "$DB"

BAD=$(jq -r 'first(.[] | select(.accession | tostring | test("^GCF_[0-9]{9}[.][0-9]+$") | not) | .url)' \
    <<< "$SOURCES")
[[ -z "$BAD" ]] || fail "conf/databases.yaml's $DB download $BAD doesn't name a RefSeq assembly accession."
BAD=$(jq -r 'first(group_by(.accession)[] | select(length > 1) | .[0].accession)' <<< "$SOURCES")
[[ -z "$BAD" ]] || fail "conf/databases.yaml's $DB entry lists $BAD twice."
if ! jq -e --arg ecoli "$ECOLI_ACCESSION" 'any(.accession == $ecoli)' <<< "$SOURCES" > /dev/null; then
    fail "conf/databases.yaml's $DB entry must include $ECOLI_ACCESSION, whose numbering the map is built in."
fi

log "Pulling vsearch..."
VSEARCH_IMAGE=$(lock_image ampliseq vsearch) || exit 1
container_sif "$VSEARCH_IMAGE" > /dev/null
VSEARCH_VERSION=$(container_exec "$VSEARCH_IMAGE" vsearch --version 2>&1) ||
    fail "vsearch didn't run from $VSEARCH_IMAGE: $VSEARCH_VERSION"
# The first line also names the machine's memory and cores, which aren't kept
VSEARCH_VERSION=$(awk 'NR == 1 { sub(/,$/, "", $2); print $1, $2 }' <<< "$VSEARCH_VERSION")

WORK_DIR=$(mktemp -d "$OUT_DIR/.build.XXXXXX") || fail "Couldn't make a working directory in $OUT_DIR."
trap 'rm -rf "$WORK_DIR"' EXIT

# Append the longest 16S rRNA gene of an _rna_from_genomic.fna to the landmark
# FASTA, and put that gene's own header and length in info_file for the manifest.
#
# Matched on gbkey plus "16S" anywhere in the product, because NCBI does not
# spell it one way - these eight genomes alone carry "16S ribosomal RNA", "16S
# Ribosomal RNA" and "ribosomal RNA-16S". The length bounds are what stop that
# loose match ever taking a 23S or a 5S.
#
# Longest rather than first, so a copy truncated at a contig edge cannot become
# the landmark. When nothing matches, info_file gets the rRNA products that were
# there instead, which is what the caller reports.
extract_16s() {
    local rna_file="$1"
    local id="$2"
    local info_file="$3"

    gzip -dc "$rna_file" | awk -v id="$id" -v info="$info_file" \
        -v minlen="$MIN_16S_LENGTH" -v maxlen="$MAX_16S_LENGTH" '
        function product(header) {
            if (match(header, /\[product=[^]]*\]/) == 0) return ""
            return substr(header, RSTART + 9, RLENGTH - 10)
        }

        /^>/ {
            keep = 0

            if ($0 ~ /\[gbkey=rRNA\]/) {
                seen[product($0)] = 1

                if (product($0) ~ /16[Ss]/) {
                    keep = 1
                    n++
                    header[n] = substr($0, 2)
                    seq[n] = ""
                }
            }
            next
        }
        keep { seq[n] = seq[n] $0 }
        END {
            best = 0
            for (i = 1; i <= n; i++) {
                len = length(seq[i])
                if (len < minlen || len > maxlen) continue
                if (best == 0 || len > length(seq[best])) best = i
            }

            if (best == 0) {
                for (p in seen) printf "%s\n", p > info
                exit 1
            }

            printf ">%s\n%s\n", id, toupper(seq[best])
            printf "%s\t%d\n", header[best], length(seq[best]) > info
        }'
}

# 1. Download each genome's RNA genes, check them, and take the 16S.
log "Building a 16S landmark set from $(jq 'length' <<< "$SOURCES") genomes..."

GENES="[]"
while IFS=$'\t' read -r accession url md5 bytes file; do
    log "Downloading $accession..."
    fetch_checked "$url" "$md5" "$bytes" "$WORK_DIR/$file"

    rm -f "$WORK_DIR/gene_info.tsv"
    if ! extract_16s "$WORK_DIR/$file" "$accession" "$WORK_DIR/gene_info.tsv" \
            >> "$WORK_DIR/$LANDMARKS"; then
        REASON="No rRNA gene of $MIN_16S_LENGTH-$MAX_16S_LENGTH bp is annotated as 16S"
        REASON+=" in $accession."

        if [[ -s "$WORK_DIR/gene_info.tsv" ]]; then
            REASON+=$'\n'"Its rRNA genes are annotated as:"
            REASON+=$'\n'"$(sed 's/^/  /' "$WORK_DIR/gene_info.tsv")"
        fi

        fail "$REASON"
    fi

    IFS=$'\t' read -r GENE_HEADER GENE_LENGTH < "$WORK_DIR/gene_info.tsv"

    log "  $accession: $GENE_LENGTH bp"

    GENES=$(jq -c --arg accession "$accession" --arg gene "$GENE_HEADER" \
        --argjson length "$GENE_LENGTH" '. + [{accession: $accession, gene: $gene, length: $length}]' \
        <<< "$GENES")
done < <(jq -r '.[] | [.accession, .url, .md5, (.bytes | tostring), .file] | @tsv' <<< "$SOURCES")

# 2. Check the numbering before anything is built on top of it.
ECOLI_SEQUENCE=$(awk -v want="$ECOLI_ACCESSION" '
    /^>/ { keep = (substr($0, 2) == want); next }
    keep { printf "%s", $0 }
    END { print "" }' "$WORK_DIR/$LANDMARKS")

if [[ ${#ECOLI_SEQUENCE} -ne $ECOLI_16S_LENGTH ]]; then
    REASON="The $ECOLI_ACCESSION 16S gene is ${#ECOLI_SEQUENCE} bp, not the expected $ECOLI_16S_LENGTH."
    REASON+=$'\n'"E. coli numbering can no longer be assumed; nothing was built."
    fail "$REASON"
fi

FOUND_515F=$(awk -v s="$ECOLI_SEQUENCE" -v p="$ECOLI_515F" 'BEGIN { print match(s, p) }')

if [[ "$FOUND_515F" -ne $ECOLI_515F_POSITION ]]; then
    REASON="The 515F site is at position $FOUND_515F of the $ECOLI_ACCESSION 16S gene,"
    REASON+=" not $ECOLI_515F_POSITION."
    REASON+=$'\n'"E. coli numbering can no longer be assumed; nothing was built."
    fail "$REASON"
fi

printf '>%s\n%s\n' "$ECOLI_ACCESSION" "$ECOLI_SEQUENCE" > "$WORK_DIR/ecoli.fasta"

# 3. Align every landmark to the E. coli one. --strand plus, because
#    _rna_from_genomic gives each gene in its transcribed orientation already.
log "Aligning the landmarks to $ECOLI_ACCESSION..."
cd "$WORK_DIR"
if ! container_exec "$VSEARCH_IMAGE" vsearch "${VSEARCH_ARGS[@]}"; then
    fail "vsearch could not align the landmarks to $ECOLI_ACCESSION."
fi

# 4. Walk each CIGAR for one row per base. M/=/X consume both sequences, I and S
#    only the landmark, D and N only E. coli. The flag bits are tested
#    arithmetically rather than with and(), which is a gawk extension.
awk -v OFS='\t' '
    /^@/ { next }
    {
        landmark = $1; flag = $2; pos = $4; cigar = $6

        if (int(flag / 4) % 2) next
        if (int(flag / 16) % 2) {
            printf "%s aligned on the minus strand.\n", landmark > "/dev/stderr"
            exit 1
        }

        qpos = 1
        tpos = pos
        while (match(cigar, /^[0-9]+[MIDNSHP=X]/)) {
            block = substr(cigar, RSTART, RLENGTH)
            cigar = substr(cigar, RSTART + RLENGTH)
            len = substr(block, 1, length(block) - 1) + 0
            op  = substr(block, length(block))

            if (op == "M" || op == "=" || op == "X") {
                for (i = 0; i < len; i++) print landmark, qpos + i, tpos + i
                qpos += len
                tpos += len
            } else if (op == "I" || op == "S") {
                qpos += len
            } else if (op == "D" || op == "N") {
                tpos += len
            }
        }
    }
' "$ALIGNMENT" > "$POSITIONS" \
    || fail "Could not map the landmarks onto E. coli numbering."

# A landmark with no rows would silently stop contributing reads to a call
cut -f1 "$POSITIONS" | LC_ALL=C sort -u > aligned.txt

while IFS= read -r accession; do
    grep -qx -- "$accession" aligned.txt \
        || fail "$accession did not align to $ECOLI_ACCESSION; it does not belong in the landmark set."
done < <(jq -r '.[].accession' <<< "$SOURCES")

mv "$LANDMARKS" "$ALIGNMENT" "$POSITIONS" "$OUT_DIR/"
cd "$OUT_DIR"
rm -rf "$WORK_DIR"

# 5. Record what was built.
ABOUT=$(jq -c \
    --arg numbering "$ECOLI_ACCESSION" \
    --argjson numbering_length "$ECOLI_16S_LENGTH" \
    --argjson landmarks "$(grep -c '^>' "$LANDMARKS")" \
    --argjson positions "$(wc -l < "$POSITIONS")" \
    --arg image "$VSEARCH_IMAGE" \
    --arg version "$VSEARCH_VERSION" \
    --arg command "vsearch ${VSEARCH_ARGS[*]}" \
    --argjson sources "$SOURCES" \
    --argjson genes "$GENES" '{
        name, release, doi,
        built_with: "steps/build_16s_reference.sh",
        numbering: {accession: $numbering, length: $numbering_length},
        landmarks: $landmarks, positions: $positions,
        vsearch: {image: $image, version: $version, command: $command},
        sources: [$sources[] | {label, accession, url, md5, bytes} as $s
            | $s + ($genes[] | select(.accession == $s.accession) | {gene, length})]
    }' <<< "$ENTRY")
write_manifest "$OUT_DIR" "$DB" "$ABOUT"

log "Built the 16S landmark set in $OUT_DIR:"
log "  landmarks: $LANDMARKS ($(grep -c '^>' "$LANDMARKS") genomes)"
log "  positions: $POSITIONS ($(wc -l < "$POSITIONS") rows)"
