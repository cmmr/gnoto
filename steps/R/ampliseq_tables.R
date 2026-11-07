#!/usr/bin/env Rscript
#
# ampliseq_tables.R - Assemble a run's feature table, and everything read off it.
#
# Run in the gnoto-rbiom image by steps/ampliseq_composition.sh, which owns the
# numbers that come from outside the feature table. This owns the feature table
# itself and everything derived from it, so the file a requester downloads and
# the numbers the Overview plots are the same object read twice.
#
# The run's ASVs are assembled from what the pipeline published - the counts and
# sequences as its last filter left them, DADA2's taxonomy, and the phylogeny
# EPA-NG placed them on - into one rbiom object. as_rbiom() takes those files as
# they are and matches them up by the identifiers each one carries, so nothing
# here reorders one table against another.
#
# That object is then written out three ways, and summarised two ways:
#
#   feature_table/feature-sequences.fasta   the sequences of exactly those ASVs
#   feature_table/excluded_asvs.tsv         what exclude_taxa removed, and why
#   feature_table/feature-table.tsv         counts and taxonomy, classic tabular
#   feature_table/feature-table.json.biom   BIOM 1.0
#   feature_table/feature-table.hdf5.biom   BIOM 2.1, and the only one of the
#                                           three that carries the tree - the
#                                           spec's own place for it is
#                                           observation/group-metadata/phylogeny
#   abundance_tables/L<n>-<rank>-counts.tsv     counts collapsed to each rank
#   abundance_tables/L<n>-<rank>-relative.tsv   the same as sample shares
#   alpha_diversity.tsv                     per-sample diversity, unrarefied,
#                                           every index rbiom offers that a
#                                           denoised table supports
#   <plot data>                             what the Overview's charts draw
#   <statistics>                            counts for the Overview's sidebar
#
# Every rank is collapsed by rbiom's own taxa_matrix(). The published tables
# take unc = "grouped", which names an ASV the classifier stopped short on for
# the deepest rank it did reach, so every ASV has a row at every rank; the chart
# takes unc = "drop", so it draws what was found and a column stands short of
# the whole sample by what was not.
#
# Taxa named in exclude_taxa are dropped before any of that, so every file here
# describes the same set of ASVs. The match is a case-insensitive substring
# against the whole lineage, which is what QIIME 2's own filter did before this
# replaced it.
#
# Nothing is rarefied. These runs have no experimental grouping to compare, and
# a delivery platform is the wrong place to decide a sampling depth on a
# requester's behalf. The read depth every index was computed at is published
# beside it, and the feature table is there to be rarefied downstream.
#
# Usage: ampliseq_tables.R <results_dir> <plot_data.json> <statistics.tsv>
#            [exclude_taxa]
#        exclude_taxa is a comma-separated list, or "none"
#
# Requires: rbiom (>= 4.0.0), and h5lite for the HDF5 output, as the gnoto-rbiom
#           image pins them

suppressPackageStartupMessages(library(rbiom))

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 3)
    stop("usage: ampliseq_tables.R <results_dir> <plot_data.json> <statistics.tsv> [exclude_taxa]")

results_dir  <- sub("/$", "", args[[1]])
plot_data    <- args[[2]]
stats_file   <- args[[3]]
exclude_taxa <- if (length(args) >= 4) args[[4]] else "none"

# The eleven the palette carries; everything rarer is summed into "Other"
TOP_TAXA <- 11

# What DADA2 writes into its taxonomy table that is not a rank: the bootstrap
# confidences and the sequence itself
NOT_A_RANK <- c("confidence", "sequence")


# -- Finding what DADA2 published --------------------------------------------

# The first file a glob matches, or NULL. DADA2 names its taxonomy after the
# database the run used, so those are matched rather than spelled out.
first_file <- function (...) {
    hits <- Sys.glob(file.path(results_dir, ...))
    hits <- hits[file.exists(hits)]

    if (length(hits) == 0) NULL else hits[[1]]
}

# The ASV set the run actually settled on. Every filter ampliseq applies
# republishes the table and the sequences under its own name, so the last one
# that ran is the run's answer - and the one EPA-NG placed on the tree. DADA2's
# own table is the fallback and still holds everything barrnap and the length
# window removed, so reading it would publish ASVs the pipeline had thrown out
# and leave the phylogeny covering only some of them.
#
# Most filtered first, and the table and the sequences are taken from the same
# stage so they cannot describe different ASVs.
ASV_SOURCES <- list(
    list(dir = "asv_length_filter", table = "ASV_table.len.tsv",
         fasta = "ASV_seqs.len.fasta", step = "the ASV length filter"),
    list(dir = "barrnap",           table = "ASV_table.ssu.tsv",
         fasta = "ASV_seqs.ssu.fasta", step = "the rRNA filter"),
    list(dir = "dada2",             table = "ASV_table.tsv",
         fasta = "ASV_seqs.fasta",    step = "DADA2"))

source      <- NULL
counts_file <- NULL

for (candidate in ASV_SOURCES) {
    counts_file <- first_file(candidate$dir, candidate$table)

    if (!is.null(counts_file)) {
        source <- candidate
        break
    }
}

if (is.null(source))
    stop("no ASV table under ", results_dir)

message("Reading the ASVs as ", source$step, " left them: ",
        sub(paste0("^", results_dir, "/"), "", counts_file))

# The one table read by hand: rbiom's TSV reader wants the classic BIOM header,
# which DADA2 does not write. Every non-numeric column goes with it, since some
# stages publish the sequence beside the counts.
counts <- utils::read.delim(counts_file, row.names = 1, check.names = FALSE)
counts <- as.matrix(counts[, vapply(counts, is.numeric, logical(1)), drop = FALSE])
counts[is.na(counts)] <- 0

# The taxonomy with species where the run reached it, and without where it did
# not
tax_file <- first_file("dada2", "ASV_tax_species.*.tsv")
if (is.null(tax_file)) tax_file <- first_file("dada2", "ASV_tax.*.tsv")


# -- The one object everything else is read from -----------------------------

# as_rbiom() reads the taxonomy file itself and matches it to the counts by ASV
# id, dropping whatever belongs to a stage this table no longer carries
biom <- rbiom::as_rbiom(
    biom        = counts,
    taxonomy    = tax_file,
    underscores = TRUE,
    id          = "16S rRNA amplicon sequencing analysis")

# Everything DADA2 wrote into that table is a rank as far as rbiom is concerned,
# so the columns that are not one are dropped here.
if (biom$n_ranks > 1) {
    taxonomy <- as.data.frame(biom$taxonomy)
    keep     <- setdiff(colnames(taxonomy), c(".otu", NOT_A_RANK))
    keep     <- keep[!endsWith(keep, "_confidence")]

    #    addSpecies renames DADA2's own species column when it adds its exact
    #    matches, so at most one of the two is kept as "Species"
    if ("Species_exact" %in% keep) {
        if ("Species" %in% keep) {
            keep <- setdiff(keep, "Species_exact")
        } else {
            colnames(taxonomy)[colnames(taxonomy) == "Species_exact"] <- "Species"
            keep[keep == "Species_exact"] <- "Species"
        }
    }

    biom$taxonomy <- taxonomy[, c(".otu", keep), drop = FALSE]
}

ranks <- setdiff(biom$ranks, ".otu")

# Taxa the run was told to exclude, matched the way QIIME 2 matched them: a
# case-insensitive substring against the whole lineage.
if (!identical(tolower(exclude_taxa), "none") && nzchar(exclude_taxa) &&
    length(ranks) > 0) {

    patterns <- trimws(strsplit(exclude_taxa, ",", fixed = TRUE)[[1]])
    patterns <- patterns[nzchar(patterns)]

    if (length(patterns) > 0) {
        asvs     <- biom$taxonomy[[".otu"]]
        lineages <- apply(
            biom$taxonomy[, ranks, drop = FALSE], 1,
            function (row) paste(stats::na.omit(row), collapse = "; "))

        #    Which pattern took each ASV, and nothing for one that stays
        matched <- vapply(
            lineages,
            function (lineage) paste(
                Filter(function (p) grepl(p, lineage, ignore.case = TRUE),
                       patterns),
                collapse = ", "),
            character(1))

        drop <- nzchar(matched)

        if (all(drop))
            stop("excluding ", exclude_taxa, " removed every ASV")

        if (any(drop)) {
            message("Excluded ", sum(drop), " of ", length(drop),
                    " ASVs matching: ", exclude_taxa)

            #    What went, and which pattern took it. Every other filtering
            #    step the pipeline runs publishes its own record of what it
            #    removed; without this one the last step in the chain is the
            #    only one a reader cannot trace.
            dir.create(file.path(results_dir, "feature_table"),
                       recursive = TRUE, showWarnings = FALSE)

            #    taxa_sums() comes back in its own order, so the reads are
            #    taken from it by ASV id rather than by position
            utils::write.table(
                data.frame(
                    asv_id           = asvs[drop],
                    matched          = unname(matched[drop]),
                    taxonomy         = unname(lineages[drop]),
                    reads            = as.integer(round(
                                           rbiom::taxa_sums(biom, ".otu")[asvs[drop]])),
                    stringsAsFactors = FALSE),
                file.path(results_dir, "feature_table", "excluded_asvs.tsv"),
                sep = "\t", quote = FALSE, row.names = FALSE, na = "")

            #    Subsetting takes the samples the exclusion emptied with it:
            #    rbiom drops any row or column left with no reads in it
            biom <- biom[asvs[!drop], ]
        }
    }
}

# The sample order every table and every array below follows
biom <- biom[, sort(biom$samples)]

# The phylogeny and the sequences describe the ASVs of the stage they were
# published at, so they are attached once the exclusion has taken its ASVs out.
# rbiom refuses either if it covers only some of what is left - Faith's PD needs
# every ASV on the tree - and a run reaching that has read them from a different
# stage than the counts. Either one missing costs what is read off it rather
# than the run, so it is reported and left out.
attach_or_warn <- function (what, attach) {
    attached <- try(attach(), silent = TRUE)

    if (inherits(attached, "try-error"))
        message("NOTE: leaving the ", what, " out: ",
                conditionMessage(attr(attached, "condition")))
}

tree_file <- first_file("pplace", "asv_tree.newick")

if (!is.null(tree_file))
    attach_or_warn("phylogeny", function () biom$tree <- tree_file)

seqs_file <- first_file(source$dir, source$fasta)

#    read_fasta() returns a list, which the $sequences setter will not take;
#    naming the ASVs it has to find also gets the fasta checked against them
if (!is.null(seqs_file))
    attach_or_warn("sequences", function ()
        biom$sequences <- unlist(rbiom::read_fasta(seqs_file, ids = biom$otus)))


# -- The feature table, three ways -------------------------------------------

table_dir <- file.path(results_dir, "feature_table")
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

# An output that cannot be written warns and leaves the rest of the run alone
write_or_warn <- function (name, write) {
    path <- file.path(table_dir, name)
    unlink(path)

    written <- try(write(path), silent = TRUE)

    if (inherits(written, "try-error"))
        message("WARNING: could not write ", name, ": ",
                conditionMessage(attr(written, "condition")))
}

# The sequences of exactly the ASVs in the table beside it. Every fasta the
# pipeline publishes belongs to some earlier stage of the filtering, so without
# this one nothing on disk matches the feature table - the sequences are inside
# the BIOM files, but only rbiom and biom-format will get them out.
if (!is.null(biom$sequences))
    write_or_warn(
        "feature-sequences.fasta",
        function (path) rbiom::write_fasta(biom, path))

for (spec in list(
        list(file = "feature-table.tsv",       format = "tab"),
        list(file = "feature-table.json.biom", format = "json"),
        list(file = "feature-table.hdf5.biom", format = "hdf5")))

    write_or_warn(spec$file, function (path)
        rbiom::write_biom(biom, path, format = spec$format))


# -- Counts collapsed to each rank -------------------------------------------

# One row per taxon, one column per sample, at one rank. Both the tables and the
# chart come out of taxa_matrix(), and the two differ only in how they take an
# ASV the classifier stopped short on:
#
#   unc = "grouped"  names it for the deepest rank it did reach - "Unc.
#                    Bacillota" at genus for one placed no further than its
#                    phylum - so every ASV has a row at every rank. This is what
#                    the published tables collapse with: a table that quietly
#                    dropped rows would not add up to the feature table beside
#                    it.
#
#   unc = "drop"     leaves it out. This is what the chart draws: a band is a
#                    taxon that was actually found, and a column falls short of
#                    the whole sample by exactly what was not. rbiom counts
#                    "uncultured" and "incertae sedis" as unreached here, which
#                    is what they are.
#
# transform = "percent" takes each share against the sample's whole read total
# before either of those runs, so dropping a taxon does not redistribute it.

# What sits above a drawn name, for the line under it in the legend. taxa_map()
# groups the ASVs exactly as taxa_matrix() does, so the two agree on what a row
# is called; asking it for the lineage as well gives the path, and the taxon's
# own name comes off the end since the legend has that on the line above.
rank_lineages <- function (rank) {
    labels <- as.character(rbiom::taxa_map(biom, rank = rank, unc = "drop"))
    paths  <- strsplit(
        rbiom::taxa_map(biom, rank = rank, unc = "drop", lineage = TRUE),
        "; ", fixed = TRUE)

    above <- vapply(
        paths,
        function (path) paste(head(path, -1), collapse = "; "),
        character(1))

    stats::setNames(above, labels)[!duplicated(labels)]
}

levels   <- list()
rank_dir <- file.path(results_dir, "abundance_tables")

if (length(ranks) > 0) {

    dir.create(rank_dir, recursive = TRUE, showWarnings = FALSE)

    for (depth in seq_along(ranks)) {

        rank <- ranks[[depth]]

        #    Published for anyone who wants every row, at every rank the
        #    classifier reached
        stem      <- sprintf("L%d-%s", depth, tolower(rank))
        collapsed <- rbiom::taxa_matrix(biom, rank = rank, unc = "grouped")
        shares    <- rbiom::taxa_matrix(biom, rank = rank, unc = "grouped",
                                        transform = "percent")

        utils::write.table(
            data.frame(taxon = rownames(collapsed), collapsed,
                       check.names = FALSE),
            file.path(rank_dir, paste0(stem, "-counts.tsv")),
            sep = "\t", quote = FALSE, row.names = FALSE, na = "")

        utils::write.table(
            data.frame(taxon = rownames(shares), round(shares, 8),
                       check.names = FALSE),
            file.path(rank_dir, paste0(stem, "-relative.tsv")),
            sep = "\t", quote = FALSE, row.names = FALSE, na = "")

        #    Domain is published like every other rank, but not offered as a
        #    chart: every sequence in a 16S run is expected to land in one
        if (depth < 2) next

        #    A rank no ASV reached has no chart, and taxa_matrix() will not be
        #    asked for one: it has no taxa to rank
        if (length(rbiom::taxa_map(biom, rank = rank, unc = "drop")) == 0) next

        #    And the eleven the chart draws, by mean share of the whole sample
        #    and most abundant first, with everything rarer that was reached
        #    summed into "Other", in the ten-thousandths of a sample the chart
        #    is drawn in.
        #
        #    taxa_matrix(taxa = ) is not used to pick them: it ranks by share of
        #    what each sample kept, which is 0/0 for a sample with nothing
        #    classified at this rank, and stops on an empty selection.
        found   <- rbiom::taxa_matrix(biom, rank = rank, unc = "drop",
                                      transform = "percent")
        top     <- head(order(rowMeans(found), decreasing = TRUE), TOP_TAXA)
        drawn   <- round(10000 * rbind(
                       found[top, , drop = FALSE],
                       Other = colSums(found[-top, , drop = FALSE])))
        lineage <- c(rank_lineages(rank), Other = "")

        levels[[length(levels) + 1]] <- list(
            rank = depth,
            name = rank,
            taxa = lapply(rownames(drawn), function (label) list(
                       label      = label,
                       lineage    = unname(lineage[[label]]),
                       mean       = round(mean(drawn[label, ])),
                       prevalence = round(mean(drawn[label, ] > 0) * 100))),
            values = lapply(rownames(drawn), function (label)
                        I(as.integer(drawn[label, ]))))
    }
}


# -- Per-sample diversity ----------------------------------------------------

# Every index rbiom offers that means anything on a denoised ASV table, in the
# order the chart offers them: Shannon first, since that is the one a requester
# asks for by name, and the rest behind it.
#
# ace, chao1 and squares are left out. All three estimate the richness a sample
# would have shown if it had been read deeper, and all three read that off the
# ASVs seen exactly once and twice - which DADA2's denoising is built to remove.
# On this data they collapse towards the observed count and describe the
# denoiser rather than the sample.
#
# "reads" is the read total rather than an index, and comes from sample_sums()
# rather than from adiv_matrix().
ADIV <- list(
    list(key = "shannon",     title = "Shannon index",
         note = "richness and evenness together", places = 2),
    list(key = "observed",    title = "Observed ASVs",
         note = "distinct ASVs seen in the sample", integer = TRUE),
    list(key = "reads",       title = "Read depth",
         note = "reads assigned to ASVs", integer = TRUE, scale = "sqrt"),
    list(key = "simpson",     title = "Simpson index",
         note = "the chance two reads are different ASVs", places = 3),
    list(key = "inv_simpson", title = "Inverse Simpson",
         note = "effective number of equally common ASVs", places = 2),
    list(key = "faith",       title = "Faith's PD",
         note = "branch length of the phylogeny this sample covers", places = 2),
    list(key = "berger",      title = "Berger-Parker dominance",
         note = "the share of the sample held by its most abundant ASV", places = 3),
    list(key = "brillouin",   title = "Brillouin index",
         note = "Shannon's index for a community counted in full", places = 3),
    list(key = "fisher",      title = "Fisher's alpha",
         note = "richness fitted to a log-series abundance model", places = 2),
    list(key = "margalef",    title = "Margalef richness",
         note = "richness adjusted for how deeply the sample was read", places = 2),
    list(key = "menhinick",   title = "Menhinick richness",
         note = "ASVs per square root of read depth", places = 3),
    list(key = "mcintosh",    title = "McIntosh evenness",
         note = "evenness from the Euclidean norm of the abundances", places = 3))

# Faith's PD is the one index here that reads the phylogeny, so a run without
# one simply does not offer it
wanted <- setdiff(vapply(ADIV, function (spec) spec$key, character(1)), "reads")

if (is.null(biom$tree)) wanted <- setdiff(wanted, "faith")

adiv <- rbiom::adiv_matrix(biom, adiv = wanted)[biom$samples, , drop = FALSE]

# An index rbiom could not compute for this run is dropped rather than
# published as a column of nothing
have <- intersect(wanted, colnames(adiv))
have <- have[vapply(have, function (k) any(is.finite(adiv[, k])), logical(1))]

rounding <- function (key) {
    for (spec in ADIV) if (identical(spec$key, key)) return (spec)
    list(places = 4)
}

alpha <- data.frame(
    sample = biom$samples,
    reads  = as.integer(round(rbiom::sample_sums(biom))),
    stringsAsFactors = FALSE)

for (key in have) {
    spec   <- rounding(key)
    values <- adiv[, key]
    values[!is.finite(values)] <- 0

    alpha[[key]] <- if (isTRUE(spec$integer)) as.integer(round(values))
                    else round(values, spec$places)
}

# The column DADA2's own tables call it, kept as the name the file has always
# carried
if ("observed" %in% have)
    colnames(alpha)[colnames(alpha) == "observed"] <- "observed_asvs"

utils::write.table(
    alpha, file.path(results_dir, "alpha_diversity.tsv"),
    sep = "\t", quote = FALSE, row.names = FALSE, na = "")


# -- What the Overview draws -------------------------------------------------

# Which indices the diversity chart offers, and how each is written out. Only
# the ones this run actually has, in the order declared above.
metric_specs <- Filter(
    function (spec) identical(spec$key, "reads") || spec$key %in% have,
    ADIV)

# Keyed by the name the chart asks for, taken from the column the table wrote
alpha_values <- lapply(stats::setNames(nm = have), function (key)
    I(alpha[[if (key == "observed") "observed_asvs" else key]]))

data <- list(
    samples = I(alpha$sample),
    reads   = I(alpha$reads),
    alpha   = alpha_values,
    metrics = metric_specs,
    levels  = levels)

# I() marks the values that stay an array however few entries they have;
# everything else here is a scalar, which is what the page reads it as.
writeLines(
    jsonlite::toJSON(data, auto_unbox = TRUE, digits = NA, na = "null"),
    plot_data)


# -- What the sidebar counts -------------------------------------------------

stats <- list(
    samples = biom$n_samples,
    asvs    = biom$n_otus)

# Every read that reached an ASV and survived the taxon exclusion, which is what
# the sidebar's "Retained reads" bar is taken against the run's input total
stats$reads_retained <- sum(alpha$reads)

stats$reads_min    <- min(alpha$reads)
stats$reads_median <- round(stats::median(alpha$reads))
stats$reads_max    <- max(alpha$reads)

# How far down the taxonomy the classifier got, as the number of ASVs that
# reached each rank
for (entry in list(c("phylum_asvs", "Phylum"),
                   c("genus_asvs",  "Genus"),
                   c("species_asvs", "Species")))
    if (entry[[2]] %in% ranks)
        stats[[entry[[1]]]] <- sum(!is.na(biom$taxonomy[[entry[[2]]]]))

writeLines(
    vapply(names(stats),
           function (k) paste(k, stats[[k]], sep = "\t"),
           character(1)),
    stats_file)

message("Wrote the feature table and its summaries for ", biom$n_samples,
        " samples and ", biom$n_otus, " ASVs.")
