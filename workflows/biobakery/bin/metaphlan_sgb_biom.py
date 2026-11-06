#!/usr/bin/env python3
"""metaphlan_sgb_biom.py - MetaPhlAn's SGB read counts as BIOM tables on its phylogeny.

Author: Daniel Smith
Date:   September 16th, 2026

Reads the merged read count table METAPHLAN_MERGE writes and keeps its SGB rows,
the t__ rows under each species. One row per SGB, keyed by the bare SGB number,
with its lineage from kingdom to SGB as the taxonomy. A t__SGB<n>_group row is
SGB <n>.

The tree is the maximum-likelihood SGB phylogeny MetaPhlAn ships for the
database named on the table's first line, pruned to the SGBs in the table. Its
tips are bare SGB numbers. SGBs the phylogeny has no tip for - the eukaryotic
EUK rows - are left out of the tables, since every feature of a table carrying
a tree has to be a tip on it. With no phylogeny for the database the tables are
written without one, and nothing is left out.

The tree goes into the BIOM 2.1 file at observation/group-metadata/phylogeny,
and into the BIOM 1.0 file as a top-level "phylogeny" string, which is where
rbiom reads and writes it.

Usage:     metaphlan_sgb_biom.py <reads_tsv> <table_prefix> <tree_newick>
Called by: METAPHLAN_MERGE, in modules/metaphlan.nf
Requires:  biom-format, dendropy, h5py and metaphlan, all in the MetaPhlAn container
Outputs:   <table_prefix>.tsv, <table_prefix>.json.biom, <table_prefix>.hdf5.biom,
           and the pruned tree at tree_newick when there is one
"""

import json
import os
import re
import sys

import dendropy
import h5py
import metaphlan
import numpy
from biom.table import Table

GENERATED_BY = "metaphlan_sgb_biom.py"
TABLE_ID = "MetaPhlAn SGB read counts"

SGB_RE = re.compile(r"^t__SGB(\d+)(?:_group)?$")


def note(message):
    print(f"{GENERATED_BY}: {message}", file=sys.stderr)


# The database line, the sample names, and every SGB as
# [id, lineage, counts], in the table's order. Rows naming one SGB are summed.
def read_sgbs(path):
    with open(path) as handle:
        database = handle.readline().strip().lstrip("#")
        samples = handle.readline().rstrip("\n").split("\t")[1:]

        order = []
        lineage = {}
        counts = {}

        for line in handle:
            fields = line.rstrip("\n").split("\t")
            ranks = fields[0].split("|")

            if not ranks[-1].startswith("t__"):
                continue

            match = SGB_RE.match(ranks[-1])
            sgb = match.group(1) if match else ranks[-1][3:]
            values = numpy.array([int(value) for value in fields[1:]])

            if sgb not in counts:
                order.append(sgb)
                lineage[sgb] = ranks
                counts[sgb] = values
            else:
                counts[sgb] = counts[sgb] + values

    return database, samples, [[sgb, lineage[sgb], counts[sgb]] for sgb in order]


# The phylogeny MetaPhlAn ships for this database, or None
def read_phylogeny(database):
    path = os.path.join(os.path.dirname(metaphlan.__file__), "utils", database + ".nwk")

    if not database or not os.path.isfile(path):
        note(f"MetaPhlAn ships no phylogeny for \"{database}\"; the tables carry no tree")
        return None

    return dendropy.Tree.get(path=path, schema="newick", preserve_underscores=True)


# A node and everything under it as newick, labels unquoted, without the edge
# above the root
def newick(node):
    if node.is_leaf():
        text = node.taxon.label
    else:
        text = "(" + ",".join(newick(child) for child in node.child_node_iter()) + ")"

    if node.parent_node is not None and node.edge.length is not None:
        text += ":%.10g" % node.edge.length

    return text


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {GENERATED_BY} <reads_tsv> <table_prefix> <tree_newick>", file=sys.stderr)
        return 2

    reads_tsv, prefix, tree_out = sys.argv[1:]

    database, samples, sgbs = read_sgbs(reads_tsv)
    tree = read_phylogeny(database)
    group_metadata = None

    if tree is not None:
        tips = {leaf.taxon.label for leaf in tree.leaf_node_iter()}
        placed = [row for row in sgbs if row[0] in tips]
        missing = [row for row in sgbs if row[0] not in tips]

        if missing:
            reads = sum(int(row[2].sum()) for row in missing)
            note(f"{len(missing)} of {len(sgbs)} SGBs, {reads} reads, have no tip on the "
                 f"phylogeny and are left out: {' '.join(row[0] for row in missing)}")

        sgbs = placed

        # A tree of one tip has no branches to measure
        if len(sgbs) >= 2:
            tree.retain_taxa_with_labels([row[0] for row in sgbs])
            text = newick(tree.seed_node) + ";"

            with open(tree_out, "w") as handle:
                handle.write(text + "\n")

            group_metadata = {"phylogeny": ("newick", text)}
        else:
            note(f"only {len(sgbs)} of the SGBs are on the phylogeny; the tables carry no tree")

    data = numpy.array([row[2] for row in sgbs], dtype=int).reshape(len(sgbs), len(samples))

    table = Table(
        data,
        [row[0] for row in sgbs],
        samples,
        observation_metadata=[{"taxonomy": row[1]} for row in sgbs] or None,
        table_id=TABLE_ID,
        type="Taxon table",
        observation_group_metadata=group_metadata,
    )

    # Classic tabular BIOM, written here so the counts stay whole numbers
    with open(prefix + ".tsv", "w") as handle:
        handle.write("# Constructed from biom file\n")
        handle.write("\t".join(["#OTU ID"] + samples + ["taxonomy"]) + "\n")

        for sgb, ranks, values in sgbs:
            handle.write("\t".join([sgb] + [str(value) for value in values] + ["; ".join(ranks)]) + "\n")

    # biom-format writes an empty table as JSON no reader accepts
    if not sgbs:
        note("no SGB to tabulate; only the empty classic table is written")
        return 0

    document = json.loads(table.to_json(GENERATED_BY))
    document["phylogeny"] = group_metadata["phylogeny"][1] if group_metadata else ""

    with open(prefix + ".json.biom", "w") as handle:
        json.dump(document, handle)

    with h5py.File(prefix + ".hdf5.biom", "w") as handle:
        table.to_hdf5(handle, GENERATED_BY, compress=True)

    note(f"wrote {len(sgbs)} SGBs over {len(samples)} samples"
         + (", on the phylogeny" if group_metadata else ", without a tree"))

    return 0


if __name__ == "__main__":
    sys.exit(main())
