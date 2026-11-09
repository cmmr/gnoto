#!/bin/bash
#
# fetch_shotgun_db.sh - Fetches one of the databases the shotgun pipelines read,
# which come as archives: Kraken2, MetaPhlAn, mOTUs, HUMAnN, EsViritu or
# Marker-MAGu.
#
# Every download is listed under its entry's sources in pipelines/databases.yaml,
# with its md5 and size, and is checked against them before it's unpacked. Each
# database is then checked for the files its tool opens, so a bad download
# fails here rather than in a run. Kraken2's unpacked files are also checked
# against the md5 list its publisher ships beside the archive.
#
# Each entry pins the newest release the pinned tool reads: MetaPhlAn 4.1.1,
# which taxprofiler 2.0.1 runs, can't read the database mpa_latest now names,
# and mOTUs 3.1.0 rejects the v4 catalogues outright.
#
# Usage:     fetch_shotgun_db.sh <db path> <out_dir>
#            <db path> is the entry's path, such as kraken2/pluspf_20260626,
#            whose first part names the tool
# Called by: the database fetch job, as the entry's setup line, with <out_dir>
#            appended. <out_dir> is an empty directory the job made. On success
#            the job renames it into place and moves manifest.yaml beside it, as
#            <db path>.manifest.yaml. On failure it removes it.
# Requires:  curl, md5sum, sha256sum, tar, gzip, lbzcat, awk, yq and jq, from
#            the gnoto image. Room for an archive and its unpacked copy at once.
# Reads:     the entry in pipelines/databases.yaml
# Writes:    the database into <out_dir>, and <out_dir>/manifest.yaml
# Env:       CODE_DIR and the log/fail helpers, from lib/env.sh

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
source "$CODE_DIR/steps/fetch_files.sh"

[[ $# -eq 2 ]] || fail "Usage: fetch_shotgun_db.sh <db path> <out_dir>"
readonly DB=$1
OUT=$(out_dir_path "$2") || exit 1
# Away from the caller's directory, where fail would write to a run's state
cd "$OUT"

ENTRY=$(fetch_entry "$DB") || fail "pipelines/databases.yaml has no database $DB."
SOURCES=$(jq -c '[(.sources // [])[] | .file = (.file // (.url | tostring | split("/") | last))]' <<< "$ENTRY")
check_downloads "$SOURCES" "$DB"
RELEASE=$(jq -r '.release // ""' <<< "$ENTRY")
NOTES=""

# Downloads land here, inside the directory the job removes on a failure, and
# go before the manifest is written
DOWNLOADS=$OUT/.download
mkdir "$DOWNLOADS"

# Refuses to start what can't land: an archive and its unpacked copy at once
require_free_space() {
    local needed_gb=$1 available_gb
    available_gb=$(df -BG --output=avail "$OUT" | tail -n 1 | tr -d 'G ')
    (( available_gb >= needed_gb )) || fail "$OUT has ${available_gb}G free, and $DB needs about ${needed_gb}G."
}

# Downloads the source saved as a file name into a directory, checked, and
# prints its path
fetch_source() {
    local file=$1 dir=${2:-$DOWNLOADS} url md5 bytes
    IFS=$'\t' read -r url md5 bytes < <(jq -r --arg file "$file" \
        '.[] | select(.file == $file) | [.url, .md5, (.bytes | tostring)] | @tsv' <<< "$SOURCES")
    [[ -n ${url:-} ]] || fail "pipelines/databases.yaml lists no $file for $DB."
    log "Downloading $file, $(human_size "$bytes")..." >&2
    fetch_checked "$url" "$md5" "$bytes" "$dir/$file"
    printf '%s' "$dir/$file"
}

# Unpacks an archive into a directory, then deletes it, so the next download
# has room
unpack() {
    local archive=$1 dir=$2 flags=-xf
    [[ $archive != *gz ]] || flags=-xzf
    log "Unpacking ${archive##*/}..."
    mkdir -p "$dir"
    tar "$flags" "$archive" -C "$dir" || fail "Couldn't unpack ${archive##*/}."
    rm -f "$archive"
}

# Unpacks an archive whose one top directory is named for the release, and
# moves what it holds into <out_dir>
unpack_release() {
    local archive=$1 top=$2 unpacked=$DOWNLOADS/unpacked
    unpack "$archive" "$unpacked"
    [[ -d $unpacked/$top && $(ls -A "$unpacked") == "$top" ]] ||
        fail "${archive##*/} didn't unpack to one directory named $top."
    find "$unpacked/$top" -mindepth 1 -maxdepth 1 -exec mv -t "$OUT" -- {} +
}

# The tip labels of a newick tree, one per line. Records start after "(" or ",",
# so a leaf reads "NAME:length" while a closing branch reads ")support:length"
# and is dropped by trimming from its ")".
tree_tips() {
    awk 'BEGIN { RS = "[(,]" }
        {
            sub(/\).*/, "")
            sub(/:.*/, "")
            gsub(/[ \t\r\n;]/, "")
            if ($0 != "") print
        }' "$1"
}

require_files() {
    local dir=$1 file
    shift
    for file in "$@"; do
        [[ -s $dir/$file ]] || fail "$DB is missing ${dir#$OUT/}/$file, so the download is incomplete."
    done
}

# Kraken2 and Bracken, from the Langmead lab's prebuilt collection, with
# nodes.dmp and names.dmp, which taxpasta reads. The publisher's md5 list stays
# with the database.
fetch_kraken2() {
    local list archive md5 file checked=0
    require_free_space 200
    list=$(fetch_source "$(jq -r '.[] | select(.file | endswith(".md5")) | .file' <<< "$SOURCES")")
    archive=$(fetch_source "$(jq -r '.[] | select(.file | endswith(".tar.gz")) | .file' <<< "$SOURCES")")
    unpack "$archive" "$OUT"
    log "Checking the unpacked files against ${list##*/}..."
    while read -r md5 file; do
        [[ -n $file && $file != "${archive##*/}" ]] || continue
        [[ -f $OUT/$file ]] || fail "$DB is missing $file, which ${list##*/} lists."
        [[ $(md5sum < "$OUT/$file") == "$md5 "* ]] || fail "$DB's $file doesn't match its md5 in ${list##*/}."
        checked=$((checked + 1))
    done < "$list"
    (( checked > 0 )) || fail "${list##*/} lists no files."
    require_files "$OUT" hash.k2d opts.k2d taxo.k2d nodes.dmp names.dmp
    mv "$list" "$OUT/"
    NOTES="$checked files, each checked against ${list##*/}. Bracken distributions for $(cd "$OUT" && ls database*mers.kmer_distrib 2> /dev/null | sed 's/^database//; s/mers.*//' | paste -sd, -)-mers."
}

# MetaPhlAn: the bowtie2 index and the pickled marker metadata, as two tars, and
# the SGB phylogeny beside them, which steps/R/taxprofiler_tables.R reads for
# UniFrac and Faith's PD
fetch_metaphlan() {
    local index=${DB##*/} tar archive file tree tips
    require_free_space 60
    for tar in $(jq -r '.[] | select(.file | endswith(".tar")) | .file' <<< "$SOURCES"); do
        archive=$(fetch_source "$tar")
        unpack "$archive" "$OUT"
    done
    # Through lbzcat: lbunzip2 copies the archive's owner and group onto what it
    # writes, which fails where the image's user namespace doesn't map them
    for file in "$OUT"/*.bz2; do
        [[ -e $file ]] || continue
        log "Decompressing ${file##*/}..."
        lbzcat "$file" > "${file%.bz2}" && rm -f "$file" || fail "Couldn't decompress ${file##*/}."
    done
    compgen -G "$OUT/*.pkl" > /dev/null || fail "$DB has no .pkl file, so the download is incomplete."
    compgen -G "$OUT/*.bt2l" > /dev/null || compgen -G "$OUT/*.bt2" > /dev/null ||
        fail "$DB has no bowtie2 index, so the download is incomplete."
    # The marker file metaphlan writes itself, naming the index it should use
    printf '%s\n' "$index" > "$OUT/mpa_latest"
    tree=$(fetch_source "$index.nwk" "$OUT")
    tips=$(tree_tips "$tree" | sort -u | wc -l)
    (( tips > 10000 )) || fail "$index.nwk has only $tips tips, so the download is incomplete."
    NOTES="$index.nwk is the SGB phylogeny for this release, with $tips tips."
}

# mOTUs: the database "motus downloadDB" installs for the release, which unpacks
# to db_mOTU. mOTUs resolves its files relative to a folder of that name.
fetch_motus() {
    local db=$OUT/db_mOTU archive
    require_free_space 20
    archive=$(fetch_source "$(jq -r '.[0].file' <<< "$SOURCES")")
    unpack "$archive" "$OUT"
    [[ -d $db ]] || fail "$DB didn't unpack to db_mOTU, which mOTUs reads."
    # The version file mOTUs checks itself against before it profiles anything.
    # The archive doesn't carry it: "motus downloadDB" writes this after
    # unpacking, and so does this.
    {
        printf 'motus\t%s\n' "$RELEASE"
        printf '#\tdatabase\n'
        printf 'nr\t%s\ncen\t%s\n' "$RELEASE" "$RELEASE"
        printf '#\tscripts\n'
        printf 'append\t%s\n' "$RELEASE"
        printf 'map_genes_to_mOTUs\t%s\n' "$RELEASE"
        printf 'map_mOTUs_to_LGs\t%s\n' "$RELEASE"
        printf 'runBWA\t%s\n' "$RELEASE"
        printf '#\ttaxonomy\n'
        printf 'specI_tax\t%s\n' "$RELEASE"
        printf 'mOTULG_tax\t%s\n' "$RELEASE"
    } > "$db/db_mOTU_versions" || fail "Couldn't write $DB's version file."
    require_files "$db" db_mOTU_DB_NR.fasta db_mOTU_bam_header_NR db_mOTU_MAP_MGCs_to_mOTUs.tsv \
        db_mOTU_taxonomy_ref-mOTUs.tsv
    NOTES="db_mOTU/db_mOTU_versions is written here, as motus downloadDB writes it, since the archive doesn't carry it."
}

# HUMAnN's three databases, each in a directory of its own, which the run
# names: chocophlan, uniref90 and utility_mapping. Each archive goes before the
# next downloads, because the three only just fit beside each other.
fetch_humann() {
    local component file archive chocophlan=$OUT/chocophlan version path pangenomes=0
    require_free_space 130
    while IFS=$'\t' read -r component file; do
        archive=$(fetch_source "$file")
        unpack "$archive" "$OUT/$component"
    done < <(jq -r '.[] | [.component, .file] | @tsv' <<< "$SOURCES")

    # HUMAnN's own two checks on a ChocoPhlAn directory, so a bad download
    # fails here rather than on a run's first sample. HUMAnN refuses a
    # ChocoPhlAn directory holding any file without the version in its name, so
    # nothing else may be written there.
    version=$(jq -r '.components.chocophlan.release' <<< "$ENTRY")
    for path in "$chocophlan"/*; do
        [[ -e $path ]] || fail "$DB's ChocoPhlAn is empty."
        [[ ${path##*/} == *"$version"* ]] || fail "$DB's ChocoPhlAn holds ${path##*/}, which isn't $version, so HUMAnN would refuse it."
        [[ ${path##*/} != g__*s__* ]] || pangenomes=$((pangenomes + 1))
    done
    (( pangenomes > 0 )) || fail "$DB's ChocoPhlAn holds no g__*s__* pangenome, so it's incomplete."
    compgen -G "$OUT/uniref90/*.dmnd" > /dev/null || fail "$DB's UniRef90 holds no DIAMOND index, so it's incomplete."
    # The two humann_regroup_table reads, and the names humann_rename_table would
    require_files "$OUT/utility_mapping" map_level4ec_uniref90.txt.gz map_ko_uniref90.txt.gz map_uniref90_name.txt.bz2
    NOTES="ChocoPhlAn $version holds $pangenomes species pangenomes."
}

# EsViritu: the virus genomes, their minimap2 index, and the metadata it names
# each genome by
fetch_esviritu() {
    local genomes archive
    require_free_space 2
    archive=$(fetch_source "$(jq -r '.[0].file' <<< "$SOURCES")")
    unpack_release "$archive" "$RELEASE"
    require_files "$OUT" virus_pathogen_database.fna virus_pathogen_database.mmi \
        virus_pathogen_database.all_metadata.tsv
    genomes=$(grep -c '^>' "$OUT/virus_pathogen_database.fna")
    NOTES="$genomes sequences."
}

# Marker-MAGu: one multi-FASTA of marker genes, which minimap2 indexes at run
# time
fetch_markermagu() {
    local genes archive
    require_free_space 16
    archive=$(fetch_source "$(jq -r '.[0].file' <<< "$SOURCES")")
    unpack_release "$archive" "$RELEASE"
    require_files "$OUT" Marker-MAGu_markerDB.fna
    genes=$(grep -c '^>' "$OUT/Marker-MAGu_markerDB.fna")
    NOTES="$genes marker genes."
}

log "Fetching $DB: $(jq length <<< "$SOURCES") downloads, $(human_size "$(jq 'map(.bytes) | add' <<< "$SOURCES")")..."
case ${DB%%/*} in
    kraken2) fetch_kraken2 ;;
    metaphlan) fetch_metaphlan ;;
    motus) fetch_motus ;;
    humann) fetch_humann ;;
    esviritu) fetch_esviritu ;;
    markermagu) fetch_markermagu ;;
    *) fail "fetch_shotgun_db.sh doesn't know how to fetch $DB." ;;
esac
rm -rf "$DOWNLOADS"

ABOUT=$(jq -c --argjson sources "$SOURCES" --arg notes "$NOTES" '{
        name, release, doi,
        built_with: "steps/fetch_shotgun_db.sh",
        sources: ($sources | map({file, url, md5, bytes} + (if .component then {component} else {} end))),
        notes: (if $notes == "" then null else $notes end)
    }' <<< "$ENTRY")
write_manifest "$OUT" "$DB" "$ABOUT"
log "Fetched $DB into $OUT."
