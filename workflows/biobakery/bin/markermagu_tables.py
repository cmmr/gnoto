#!/usr/bin/env python3
"""markermagu_tables.py - Marker-MAGu's viral SGB read counts as BIOM tables.

Author: Daniel Smith
Date:   September 17th, 2026

The counterpart of metaphlan_sgb_biom.py for Marker-MAGu. Marker-MAGu reports
one row per species-level genome bin (SGB) per sample, in long form, for
bacteria, archaea, microeukaryotes and viruses alike. This keeps the viral rows
- those whose lineage begins k__Viruses - and writes them as one feature table,
one row per SGB keyed by its name with the rank prefix taken off (vSGB_8081),
with its lineage from kingdom to SGB as the taxonomy: virome-counts.tsv in
classic tabular BIOM, and the same table as BIOM 1.0 JSON and BIOM 2.1 HDF5.
virome-relab.tsv is the same table as Marker-MAGu's relative abundance over the
viruses alone, as percentages, so each sample's viruses make 100%.

The rest are left out because MetaPhlAn profiles them better. Marker-MAGu's
bacterial markers are an older MetaPhlAn release, and its detection threshold
is a share of an SGB's markers - three quarters of them, by default - which a
phage with a handful of markers clears and a bacterium with a couple of hundred
rarely does. markermagu-profile.tsv, which MARKERMAGU_MERGE writes before this,
keeps every row.

A viral lineage stops at its SGB, s__vSGB_<n>, so an SGB is also its species.
The counts are reads aligned to marker genes, not an estimate of every read a
virus contributed the way MetaPhlAn's are, so a sample's column totals its viral
marker gene reads rather than its sequencing depth.

Marker-MAGu's relative abundance is an SGB's RPKM - its reads per kilobase of
marker per million reads the sample brought - over the sum of every reported
SGB's RPKM in that sample, bacteria included, rounded to five decimals. The
percentages here are the same division over the viral SGBs alone, taken from
the unrounded RPKM column: what rel_abundance would be had Marker-MAGu reported
only viruses. Because it divides by marker length, a virus's share is not its
share of the viral reads in virome-counts.tsv.

The samples and their order come from the read counts rather than from the
profile, so a sample Marker-MAGu detected no virus in is a column of zeros
rather than a column missing, in both tables.

Marker-MAGu publishes no phylogeny of its SGBs - its viral genera and species
are clusters rather than named clades - so the tables carry no tree, and
UniFrac and Faith's PD cannot be computed from them.

Usage:     markermagu_tables.py <profile_tsv> <read_counts_tsv>
Called by: MARKERMAGU_TABLES, in modules/markermagu.nf
Requires:  biom-format, h5py and numpy, in the biom-format container
Outputs:   virome-counts.tsv, virome-counts.json.biom, virome-counts.hdf5.biom
           and virome-relab.tsv
"""

import sys

import h5py
import numpy
from biom.table import Table

GENERATED_BY = "markermagu_tables.py"
TABLE_ID = "Marker-MAGu viral SGB read counts"

KINGDOM = "k__Viruses"
PREFIX = "virome-counts"
RELAB = "virome-relab.tsv"

# lineage, total_genes, detected_genes, total_length, total_aligned_reads,
# RPKM, rel_abundance, sampleID
READS_COLUMN = 4
RPKM_COLUMN = 5
SAMPLE_COLUMN = 7


def note(message):
    print(f"{GENERATED_BY}: {message}", file=sys.stderr)


# The samples in the order the read counts list them
def read_samples(path):
    with open(path) as handle:
        handle.readline()

        return [line.split("\t")[0] for line in handle if line.strip()]


# Every viral SGB as [lineage, counts, rpkm], sorted by lineage
def read_sgbs(path, samples):
    column = {sample: index for index, sample in enumerate(samples)}
    counts = {}
    rpkm = {}
    left_out = 0

    with open(path) as handle:
        handle.readline()

        for line in handle:
            fields = line.rstrip("\n").split("\t")

            if len(fields) <= SAMPLE_COLUMN:
                continue

            lineage, sample = fields[0], fields[SAMPLE_COLUMN]

            if sample not in column:
                note(f"the profile has a row for {sample}, which the read counts do not list")
                continue

            if lineage.split("|")[0] != KINGDOM:
                left_out += 1
                continue

            if lineage not in counts:
                counts[lineage] = numpy.zeros(len(samples), dtype=int)
                rpkm[lineage] = numpy.zeros(len(samples))

            counts[lineage][column[sample]] += int(fields[READS_COLUMN])
            rpkm[lineage][column[sample]] += float(fields[RPKM_COLUMN])

    if left_out:
        note(f"left out {left_out} rows outside {KINGDOM}; markermagu-profile.tsv keeps them")

    return [[lineage, counts[lineage], rpkm[lineage]] for lineage in sorted(counts)]


# An SGB as the feature table keys it: its own name, without the rank prefix
def feature_id(lineage):
    return lineage.split("|")[-1].split("__", 1)[-1]


# A table in classic tabular BIOM, each value written with template
def write_classic(path, samples, sgbs, ids, template):
    with open(path, "w") as handle:
        handle.write("# Constructed from biom file\n")
        handle.write("\t".join(["#OTU ID"] + samples + ["taxonomy"]) + "\n")

        for (lineage, values), sgb in zip(sgbs, ids):
            handle.write("\t".join([sgb] + [template % value for value in values]
                                   + ["; ".join(lineage.split("|"))]) + "\n")


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {GENERATED_BY} <profile_tsv> <read_counts_tsv>", file=sys.stderr)
        return 2

    profile_tsv, read_counts_tsv = sys.argv[1:]

    samples = read_samples(read_counts_tsv)
    sgbs = read_sgbs(profile_tsv, samples)
    ids = [feature_id(lineage) for lineage, _, _ in sgbs]

    if len(set(ids)) != len(ids):
        repeated = sorted({name for name in ids if ids.count(name) > 1})
        note(f"these SGB names are not unique and the feature table cannot key "
             f"rows by them: {' '.join(repeated)}")
        return 1

    # Classic tabular BIOM, written here so the counts stay whole numbers
    counts = [[lineage, reads] for lineage, reads, _ in sgbs]
    write_classic(PREFIX + ".tsv", samples, counts, ids, "%d")

    # Each SGB's RPKM over the viral total; a sample with no virus stays at zero
    totals = numpy.zeros(len(samples))

    for _, _, rpkm in sgbs:
        totals += rpkm

    divisor = numpy.where(totals > 0, totals, 1)
    shares = [[lineage, rpkm * 100 / divisor] for lineage, _, rpkm in sgbs]

    write_classic(RELAB, samples, shares, ids, "%.5f")

    # biom-format writes an empty table as JSON no reader accepts
    if not sgbs:
        note("no viral SGB to tabulate; only the empty classic tables are written")
        return 0

    table = Table(
        numpy.array([reads for _, reads in counts], dtype=int),
        ids,
        samples,
        observation_metadata=[{"taxonomy": lineage.split("|")} for lineage, _ in counts],
        table_id=TABLE_ID,
        type="Taxon table",
    )

    with open(PREFIX + ".json.biom", "w") as handle:
        handle.write(table.to_json(GENERATED_BY))

    with h5py.File(PREFIX + ".hdf5.biom", "w") as handle:
        table.to_hdf5(handle, GENERATED_BY, compress=True)

    note(f"wrote {len(sgbs)} viral SGBs over {len(samples)} samples")

    return 0


if __name__ == "__main__":
    sys.exit(main())
