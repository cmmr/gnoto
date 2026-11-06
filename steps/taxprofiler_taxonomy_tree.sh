#!/bin/bash
#
# taxprofiler_taxonomy_tree.sh - Build the tree a shotgun feature table is read against.
#
# A shotgun run has no sequences to build a phylogeny from, only taxon ids. This
# writes the tree those ids imply: the NCBI taxonomy restricted to the taxa a
# run observed, collapsed to the seven ranks a profile is read at, with a branch
# length on every edge.
#
# Branch length is the reciprocal of the child's depth, so a phylum-level branch
# is 1/2 and a species-level one 1/7. WGSUniFrac (Wei and Koslicki, WABI 2022)
# tested UniFrac with these lengths on GTDB's bac120 tree and recovered the same
# clustering as with the fitted ones.
#
# It's a taxonomy with lengths on it, not an inferred phylogeny, so a diversity
# computed over it isn't comparable with a Faith's PD from a 16S run.
# steps/R/taxprofiler_tables.R labels it as such wherever it publishes one.
#
# Ranks between the seven (subspecies, suborder, clade, no rank) are skipped
# rather than counted, so every lineage is measured on the same scale. A taxon
# whose lineage is missing one of the seven sits one step shallower, and its
# branch is that much longer.
#
# Only tips are labelled. An id that is an ancestor of another id in the same
# list is emitted as an internal node and so isn't a tip. The caller drops it
# from the table.
#
# The same walk writes the lineage table, one row per observed id with its
# ancestor at each of the seven ranks, named. That's the taxonomy the feature
# table carries, and it agrees with the tree by construction.
#
# Usage:     taxprofiler_taxonomy_tree.sh <taxdump_dir> <taxid_file> [lineage_tsv]
#            taxdump_dir holds nodes.dmp and names.dmp, as the Kraken2 database
#            directory does; taxid_file is one NCBI taxon id per line
# Called by: steps/taxprofiler_composition.sh, which hands the tree and lineage
#            table to steps/R/taxprofiler_tables.R
# Requires:  GNU awk
# Writes:    the tree, in newick, on stdout, and the lineage table at
#            lineage_tsv when one is named

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'Usage: %s <taxdump_dir> <taxid_file> [lineage_tsv]\n' "${0##*/}" >&2
    exit 2
fi

TAXDUMP_DIR="${1%/}"
TAXID_FILE="$2"
LINEAGE_TSV="${3:-}"

NODES="$TAXDUMP_DIR/nodes.dmp"
NAMES="$TAXDUMP_DIR/names.dmp"

for required in "$NODES" "$NAMES"; do
    if [[ ! -r "$required" ]]; then
        printf '%s: %s is not readable\n' "${0##*/}" "$required" >&2
        exit 1
    fi
done

if [[ ! -r "$TAXID_FILE" ]]; then
    printf '%s: %s is not readable\n' "${0##*/}" "$TAXID_FILE" >&2
    exit 1
fi

# Both dumps are "value\t|\tvalue\t|\t...", so the fields wanted are the odd ones
# of a plain tab split: nodes.dmp gives id, parent and rank as 1, 3 and 5, and
# names.dmp gives id, name and name class as 1, 3 and 7.
#
# nodes.dmp is read before the ids so the walk has a parent for everything, and
# names.dmp after them so only the names of nodes that were placed are held.
LC_ALL=C awk -F'\t' -v nodes="$NODES" -v names="$NAMES" -v lineage_tsv="$LINEAGE_TSV" '
    # The nearest ancestor holding one of the seven ranks. The walk stops when a
    # node is its own parent, which is how nodes.dmp writes the root.
    function collapsed_parent(id,   up, seen) {
        up = parent[id]

        while (up != "" && up != seen) {
            if (rank[up] in RANKED) return up

            seen = up
            up = parent[up]
        }

        return "root"
    }

    # Every node between a tip and the root, added once
    function attach(id,   up) {
        while (id != "root" && !(id in placed)) {
            placed[id] = 1
            up = collapsed_parent(id)

            up_of[id] = up
            children[up] = children[up] " " id

            id = up
        }
    }

    function depth_of(id,   steps) {
        steps = 0

        while (id != "root") {
            steps++
            id = up_of[id]
        }

        return steps
    }

    # A node and everything under it. Internal nodes carry no label, so an id
    # that is an ancestor of another cannot be mistaken for a tip.
    function subtree(id,   kids, i, n, out, child) {
        if (!(id in children)) return id sprintf(":%.6f", 1 / depth_of(id))

        n = split(children[id], kids, " ")
        out = ""

        for (i = 1; i <= n; i++) {
            child = kids[i]
            if (child == "") continue

            out = out (out == "" ? "" : ",") subtree(child)
        }

        if (id == "root") return "(" out ")"

        return "(" out ")" sprintf(":%.6f", 1 / depth_of(id))
    }

    function write_lineage(   i, r, id, up, row, held) {
        row = "taxonomy_id"
        for (i = 1; i <= 7; i++) row = row "\t" COLUMN[i]
        print row > lineage_tsv

        for (id in observed) {
            for (i = 1; i <= 7; i++) held[i] = ""

            up = id
            while (up != "root") {
                if (rank[up] in RANKED) held[RANKED[rank[up]]] = name[up]
                up = up_of[up]
            }

            row = id
            for (i = 1; i <= 7; i++) row = row "\t" held[i]

            print row > lineage_tsv
        }

        close(lineage_tsv)
    }

    BEGIN {
        split("domain phylum class order family genus species", COLUMN, " ")
        for (i = 1; i <= 7; i++) RANKED[COLUMN[i]] = i

        # Recent taxdumps call the top rank "domain", and older ones "superkingdom"
        RANKED["superkingdom"] = 1
    }

    FILENAME == nodes {
        parent[$1] = $3
        rank[$1]   = $5
        next
    }

    FILENAME == names {
        if ($7 == "scientific name" && ($1 in placed)) name[$1] = $3
        next
    }

    # the observed taxon ids
    {
        gsub(/[ \t\r]/, "", $1)
        if ($1 == "" || $1 !~ /^[0-9]+$/) next
        if (!($1 in parent)) { missing++; next }

        observed[$1] = 1
        attach($1)
    }

    END {
        if (!("root" in children)) {
            print "taxprofiler_taxonomy_tree.sh: no observed taxon could be placed" > "/dev/stderr"
            exit 1
        }

        if (missing > 0)
            printf "taxprofiler_taxonomy_tree.sh: %d taxon ids are not in this taxonomy\n", \
                missing > "/dev/stderr"

        print subtree("root") ";"

        if (lineage_tsv != "") write_lineage()
    }
' "$NODES" "$TAXID_FILE" "$NAMES"
