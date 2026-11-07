#!/bin/bash
#
# index_directories.sh - Gives every folder of a results tree a listing page.
#
# Run by:    present/ampliseq.sh, taxprofiler.sh and biobakery.sh, once the
#            pages are in the results folder
# Usage:     index_directories.sh [results_dir] [reads_dir]...
#            results_dir defaults to ./results
# Requires:  GNU find and awk
# Reads:     present/templates/listing.html
#
# Object stores serve objects, not directories, so a folder link in a report
# would land on nothing. This writes present/templates/listing.html into every
# folder of the results, the folder itself included, as directory_listing.html:
# folders first, then files with their sizes, each linked, and a link up. Never
# as index.html, which across a run means a page written to be read. Every link
# names its file outright, so an unpacked zip browses the same way.
#
# Each folder of reads the run delivers, beside the results, gets a listing
# written inside them under its own name, such as raw-sequences/. Those reads
# are published only in the zip, so its rows are held: greyed and not followed
# until the page is read off disk, where the reads are two levels up, which is
# where its links point.

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh"

RESULTS_DIR=${1:-results}
RESULTS_DIR=${RESULTS_DIR%/}
STAGED_DIRS=("${@:2}")
LISTING_NAME=directory_listing.html
LISTING_TEMPLATE=$CODE_DIR/present/templates/listing.html

[[ -d $RESULTS_DIR ]] || fail "There's no '$RESULTS_DIR' directory to index."
[[ -r $LISTING_TEMPLATE ]] || fail "The listing template $LISTING_TEMPLATE is missing."

# One directory's entries as table rows, folders before files and each by name.
# Files named in omit are left out, which is how a listing leaves out itself;
# prefix goes before every href, for a listing kept away from its files; held
# marks every row held; and files named in top open in the whole window rather
# than the frame. Symlinks are followed, since what the zip holds is the file
# behind the link.
render_rows() {
    local dir=$1 omit=${2:-} prefix=${3:-} held=${4:-} top=${5:-}

    find -L "$dir" -mindepth 1 -maxdepth 1 -printf '%y\t%s\t%f\n' |
        LC_ALL=C sort -t$'\t' -k1,1 -k3,3 |
        LC_ALL=C awk -F'\t' -v omit="$omit" -v listing="$LISTING_NAME" \
            -v prefix="$prefix" -v held="$held" -v top="$top" '
            function esc(s,   out, i, c) {
                out = ""
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    if      (c == "&") out = out "&amp;"
                    else if (c == "<") out = out "&lt;"
                    else if (c == ">") out = out "&gt;"
                    else if (c == "\"") out = out "&quot;"
                    else               out = out c
                }
                return out
            }

            # Percent-encodes a name byte by byte, which the C locale makes
            # this loop walk, so an accented name comes out as its UTF-8 bytes
            function enc(s,   out, i, c) {
                out = ""
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    if (c ~ /[A-Za-z0-9._~-]/) out = out c
                    else                       out = out sprintf("%%%02X", ord[c])
                }
                return out
            }

            function human(bytes,   i) {
                i = 1
                while (bytes >= 1024 && i < 6) { bytes /= 1024; i++ }
                if (i == 1) return sprintf("%d %s", bytes, unit[i])
                return sprintf("%.1f %s", bytes, unit[i])
            }

            BEGIN {
                for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
                split("B KB MB GB TB PB", unit, " ")
                split(omit, hidden, " ")
                for (i in hidden) skip[hidden[i]] = 1
                split(top, whole, " ")
                for (i in whole) window[whole[i]] = 1
            }

            $1 == "f" && ($3 in skip) { next }

            {
                n++
                type[n] = $1
                size[n] = $2
                name[n] = $3
            }

            END {
                if (n == 0) exit 0
                row = held ? "<tr class=\"held\">" : "<tr>"
                print "<table><tbody>"
                for (i = 1; i <= n; i++) {
                    if (type[i] == "d")
                        printf "%s<td class=\"name\"><a class=\"dir\" href=\"%s%s/%s\">%s/</a></td>" \
                               "<td class=\"size\"></td></tr>\n", row, prefix, enc(name[i]), \
                               listing, esc(name[i])
                    else
                        printf "%s<td class=\"name\"><a href=\"%s%s\"%s>%s</a></td>" \
                               "<td class=\"size\">%s</td></tr>\n", row, prefix, enc(name[i]), \
                               (name[i] in window) ? " target=\"_top\"" : "", \
                               esc(name[i]), human(size[i])
                }
                print "</tbody></table>"
            }
        '
}

# One listing page. A listing that can't be built isn't worth failing a run
# over: the folder gets a page either way, with whatever rows came out. The
# arguments after omit are for a folder of reads: where its page goes, the way
# back from there to its files, and the note saying why. Naming a page
# directory is also what holds its rows. The last names the files that open in
# the whole window. Rows come escaped from render_rows.
write_listing() {
    local dir=$1 title=$2 up_link=$3 omit=${4:-} page=${5:-$1} prefix=${6:-} note=${7:-} top=${8:-}
    local rows=""

    if ! rows=$(render_rows "$dir" "$omit" "$prefix" "${5:-}" "$top"); then
        warn "The contents of $dir couldn't all be listed."
    fi
    [[ -n $rows ]] || rows="<p class=\"empty\">This folder is empty.</p>"
    render_template "$LISTING_TEMPLATE" \
        DIR_PATH "$(escape_html "$title")" \
        UP_LINK "$up_link" \
        NOTE "$note" \
        ROWS "$rows" > "$page/$LISTING_NAME"
}

source "$CODE_DIR/present/dashboard.sh"

log "Indexing the folders under $RESULTS_DIR..."
INDEXED=0

# Real directories only: a listing written through a symlink would land in
# Nextflow's work directory
while IFS= read -r DIR; do
    write_listing "$DIR" "${DIR#"$RESULTS_DIR"/}" \
        "<a href=\"../$LISTING_NAME\">&uarr; Up one folder</a>" "$LISTING_NAME"
    INDEXED=$((INDEXED + 1))
done < <(find "$RESULTS_DIR" -mindepth 1 -type d)

# After the walk, so it doesn't overwrite these, and before the results
# folder's own listing, so that names them
STAGED_NOTE='<p class="note">These sequencing files aren'"'"'t published beside'
STAGED_NOTE+=" these results: take them with the <strong>Download everything</strong>"
STAGED_NOTE+=" button on the Overview, and the names below become live links in the"
STAGED_NOTE+=" copy that comes down with it.</p>"

for STAGED_DIR in ${STAGED_DIRS[@]+"${STAGED_DIRS[@]}"}; do
    STAGED_DIR=${STAGED_DIR%/}
    [[ -n $STAGED_DIR && -d $STAGED_DIR ]] || continue
    STAGED_NAME=${STAGED_DIR##*/}
    mkdir -p "$RESULTS_DIR/$STAGED_NAME"
    write_listing "$STAGED_DIR" "$STAGED_NAME" \
        "<a href=\"../$LISTING_NAME\">&uarr; Up one folder</a>" "" \
        "$RESULTS_DIR/$STAGED_NAME" "../../$STAGED_NAME/" "$STAGED_NOTE"
    log "Listed the reads in $STAGED_DIR."
done

# The results folder, where every "up one folder" ends. The landing page opens
# from it in the whole window, because loading it into its own frame would nest
# a second dashboard in the first.
write_listing "$RESULTS_DIR" "All output files" \
    "<a href=\"index.html\" target=\"_top\">&uarr; Results dashboard</a>" \
    "$LISTING_NAME" "" "" "" "index.html"

log "Indexed $INDEXED folders, and the results folder itself."
