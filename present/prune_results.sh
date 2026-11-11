#!/bin/bash
#
# prune_results.sh - Deletes what a pipeline wrote for itself out of a results
# folder.
#
# Run by:    present/ampliseq.sh, taxprofiler.sh and biobakery.sh, before the
#            pages, listings and zip are made, and outputs_published in
#            lib/outputs.sh, on a copy of the core tables
# Usage:     prune_results.sh <results_dir> <prune_conf>
# Requires:  GNU find and awk
#
# A finished run writes many times more bytes than anyone reads, nearly all a
# tool's own scratch or a second copy of something published in a usable form.
# This deletes that in place, so the listings, the file index and the zip all
# describe the same files. present/templates/<pipeline>/prune.conf names what
# goes, read as
#
#     action | path | argument
#
# with the fields trimmed and blank or "#" lines skipped. The actions:
#
#   remove          delete everything the path matches. A path is relative to
#                   the results folder and may be a glob; one ending in "/"
#                   matches directories only.
#   drop-zero-rows  rewrite a merged table, keeping the rows with a nonzero
#                   number. The argument is the first data column, from 1, so
#                   the names and ids before it aren't read as data.
#
# A path matching nothing is skipped: a conf names what a pipeline can produce,
# and no run produces all of it. Folders the deletions empty go too.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

RESULTS_DIR=${1:-}
RESULTS_DIR=${RESULTS_DIR%/}
PRUNE_CONF=${2:-}

[[ -d $RESULTS_DIR ]] || fail "There's no '$RESULTS_DIR' directory to prune."
[[ -r $PRUNE_CONF ]] || fail "There's no prune list at $PRUNE_CONF."

REMOVED_FILES=0
REMOVED_BYTES=0

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Everything one pattern matches. IFS is emptied so the unquoted glob doesn't
# also split a match on the spaces some tools put in a file name.
remove_matches() {
    local pattern=$1 path bytes IFS=
    for path in "$RESULTS_DIR"/$pattern; do
        # An unmatched glob comes back as itself
        [[ -e $path || -L $path ]] || continue
        bytes=$(find "$path" -type f -printf '%s\n' 2> /dev/null | awk '{ t += $1 } END { print t + 0 }')
        REMOVED_FILES=$((REMOVED_FILES + $(find "$path" -type f 2> /dev/null | wc -l)))
        REMOVED_BYTES=$((REMOVED_BYTES + bytes))
        rm -rf -- "$path" || warn "Couldn't delete $path from the results."
    done
}

# A merged table without its empty rows. A profile has a row for every taxon in
# the database, most of them zero in every sample: 33,039 of 34,344 rows on the
# run this was written for. Written beside the table and moved over it, so a
# failure leaves the table whole.
drop_zero_rows() {
    local pattern=$1 first=$2 path before after IFS=
    if [[ ! $first =~ ^[0-9]+$ ]] || (( first < 1 )); then
        warn "drop-zero-rows on \"$pattern\" names no first data column, so it's skipped."
        return 0
    fi
    for path in "$RESULTS_DIR"/$pattern; do
        [[ -f $path ]] || continue
        before=$(wc -l < "$path")
        if ! LC_ALL=C awk -F'\t' -v first="$first" '
                /^#/ || NF < first { print; next }
                {
                    for (i = first; i <= NF; i++) {
                        if ($i + 0 != 0) { print; next }
                    }
                }
            ' "$path" > "$path.pruned"; then
            warn "Couldn't drop the empty rows from $path, so it's left as it is."
            rm -f "$path.pruned"
            continue
        fi
        after=$(wc -l < "$path.pruned")
        REMOVED_BYTES=$((REMOVED_BYTES + $(stat -L -c %s "$path") - $(stat -c %s "$path.pruned")))
        mv -f "$path.pruned" "$path" || warn "Couldn't replace $path with its pruned copy."
        log "Pruned $((before - after)) empty row(s) from ${path#"$RESULTS_DIR/"}."
    done
}

log "Pruning $RESULTS_DIR against $PRUNE_CONF..."

while IFS= read -r LINE || [[ -n $LINE ]]; do
    LINE=${LINE//$'\r'/}
    LINE=$(trim "$LINE")
    [[ -z $LINE || $LINE == \#* ]] && continue
    IFS='|' read -r ACTION PATTERN ARGUMENT <<< "$LINE"
    ACTION=$(trim "$ACTION")
    PATTERN=$(trim "$PATTERN")
    ARGUMENT=$(trim "${ARGUMENT:-}")
    [[ -n $ACTION && -n $PATTERN ]] || continue

    # A pattern that leaves the results folder would delete what this was
    # never pointed at
    if [[ $PATTERN == /* || $PATTERN == *..* ]]; then
        warn "Refusing \"$PATTERN\": a prune list names paths inside the results folder."
        continue
    fi
    case $ACTION in
        remove) remove_matches "$PATTERN" ;;
        drop-zero-rows) drop_zero_rows "$PATTERN" "$ARGUMENT" ;;
        *) warn "There's no prune action \"$ACTION\", so \"$PATTERN\" is skipped." ;;
    esac
done < "$PRUNE_CONF"

# Deepest first, so a folder holding only emptied folders goes too. The results
# folder itself is never a candidate.
find "$RESULTS_DIR" -mindepth 1 -depth -type d -empty -delete 2> /dev/null || :

log "Pruned $REMOVED_FILES file(s), $(human_size "$REMOVED_BYTES") in all, from $RESULTS_DIR."
