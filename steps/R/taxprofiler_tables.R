#!/usr/bin/env Rscript
#
# taxprofiler_tables.R - Assemble the feature tables a shotgun run is delivered as.
#
# Run inside the rbiom container by taxprofiler_composition.sh, which finds
# every file named here and builds the taxonomy tree before calling this. This
# owns the files a requester loads: the profile as a BIOM with a tree in it, so
# UniFrac and Faith's PD can be computed the way they can from the 16S
# pipeline's output.
#
# Two BIOM tables are built, from the two profiles that can carry a tree at all:
#
#   feature_table/feature-table.{tsv,json.biom,hdf5.biom}
#       Bracken's species counts, keyed by NCBI taxon id, with the taxonomy
#       collapsed to seven ranks. Its tree is the NCBI taxonomy over exactly
#       those taxa with branch lengths assigned by depth - a taxonomy with
#       lengths on it rather than an inferred phylogeny, built by
#       steps/taxprofiler_taxonomy_tree.sh. Kraken2's table is the fallback
#       for a run without Bracken, filtered to its species rows.
#
#   feature_table/metaphlan-table.hdf5.biom
#       MetaPhlAn's SGB relative abundances, on the maximum-likelihood phylogeny
#       published with that database. A real phylogeny over fewer taxa.
#
# Both trees are written out beside the tables as newick, and both go into the
# BIOM 2.1 files at observation/group-metadata/phylogeny, which is the spec's
# own place for them.
#
# Faith's PD is computed from each into the table named on the command line,
# with the abundance it was computed over beside it. taxprofiler_composition.sh
# turns that into the share of the run's reads the reading covers and publishes
# both in alpha_diversity.tsv: a phylogenetic index over a shotgun profile
# describes only the fraction of the sample that was classified, and that
# fraction is what makes it readable.
#
# count_tables/ holds the same profiles as plain matrices, one per profiler and
# unit, for a reader who wants counts rather than a BIOM:
#
#   bracken-reads.tsv, kraken2-reads.tsv
#       Reads per species. kraken2 rows below species roll up into it and rows
#       above it become one "<taxon> unclassified" species, so the table totals
#       every classified read rather than the 55% that land at species.
#
#   metaphlan-cells.tsv, metaphlan-reads.tsv
#       MetaPhlAn's own coverage and read estimates, merged from the per-sample
#       profiles that -t rel_ab_w_read_stats writes. merge_metaphlan_tables.py
#       reads only the relative abundance column, so the merged report beside
#       these two carries percentages and neither of these does.
#
#   motus-cells.tsv
#       mOTUs scaled insert counts, already per-cell: its markers are universal
#       single-copy genes, so a count is already a count of organisms.
#
# Nothing is rarefied. The read depth every index was computed at is published
# beside it, and the feature table is there to be rarefied downstream.
#
# Usage: taxprofiler_tables.R <results_dir> <faith_out> <profile_tsv>
#            <species_only> <taxonomy_tree> <lineage_tsv> <metaphlan_profile>
#            <metaphlan_tree> <metaphlan_dir> <motus_profile>
#        Every path after faith_out may be empty, which leaves out whatever
#        needed it; species_only is 1 for a kraken2 table and 0 for a bracken one
#
# Requires: rbiom (>= 3.1.0), and h5lite for the HDF5 output

suppressPackageStartupMessages(library(rbiom))

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2)
    stop("usage: taxprofiler_tables.R <results_dir> <faith_out> <profile_tsv> ",
         "<species_only> <taxonomy_tree> <lineage_tsv> <metaphlan_profile> ",
         "<metaphlan_tree> <metaphlan_dir> <motus_profile>")

argument <- function (i) if (length(args) >= i) args[[i]] else ""

results_dir       <- sub("/$", "", args[[1]])
faith_out         <- args[[2]]
profile_tsv       <- argument(3)
species_only      <- identical(argument(4), "1")
taxonomy_tree     <- argument(5)
lineage_tsv       <- argument(6)
metaphlan_profile <- argument(7)
metaphlan_tree    <- argument(8)
metaphlan_dir     <- argument(9)
motus_profile     <- argument(10)

table_dir <- file.path(results_dir, "feature_table")
count_dir <- file.path(results_dir, "count_tables")

# The ranks taxprofiler_taxonomy_tree.sh writes, in the order it writes them
RANKS <- c("Domain", "Phylum", "Class", "Order", "Family", "Genus", "Species")

# What taxpasta names its own columns. Everything else in one of its tables is a
# sample.
TAXPASTA_FIELDS <- c("taxonomy_id", "name", "rank", "lineage",
                     "id_lineage", "rank_lineage")


# -- Reporting ---------------------------------------------------------------

# A step that cannot run costs what is read off it rather than the run: the
# other table is still worth publishing, and so is everything the pipeline
# wrote. So every failure below is reported and stepped over.
note <- function (...) message("NOTE: ", ...)

attempt <- function (what, action) {
    done <- try(action(), silent = TRUE)

    if (inherits(done, "try-error")) {
        note("leaving out ", what, ": ", conditionMessage(attr(done, "condition")))
        return(invisible(NULL))
    }

    invisible(done)
}

usable <- function (path) nzchar(path) && file.exists(path)


# -- Reading a profile -------------------------------------------------------

# taxpasta's merged table, as a counts matrix keyed by taxon id. A kraken2 table
# carries every rank, so only its species rows are kept - a clade count and the
# counts inside it are the same reads twice, and a tree cannot hold both.
read_taxpasta <- function (path) {
    table <- utils::read.delim(path, check.names = FALSE, quote = "",
                               colClasses = "character")

    if (!"taxonomy_id" %in% colnames(table))
        stop(basename(path), " has no taxonomy_id column")

    if (species_only) {
        if (!"rank" %in% colnames(table))
            stop(basename(path), " has no rank column to filter species on")

        table <- table[table$rank == "species", , drop = FALSE]
    }

    ids  <- trimws(table$taxonomy_id)
    keep <- grepl("^[0-9]+$", ids) & !ids %in% c("0", "1")

    table <- table[keep, , drop = FALSE]
    ids   <- ids[keep]

    if (nrow(table) == 0) stop(basename(path), " carries no classified taxa")

    counts <- numeric_matrix(table[setdiff(colnames(table), TAXPASTA_FIELDS)], ids,
                             paste(basename(path), "names no samples"))

    #    "bracken_<db_name>.tsv" or "kraken2_<db_name>.tsv"
    database <- sub("^[^_]+_", "", sub("\\.tsv$", "", basename(path)))
    colnames(counts) <- strip_database(colnames(counts), database)

    counts[, sort(colnames(counts)), drop = FALSE]
}

# The merged MetaPhlAn profile, reduced to its t__SGB rows and keyed by the bare
# SGB number the published phylogeny labels its tips with. Sample columns are
# named after the files they were merged from, so the database and the tool are
# trimmed back off.
read_metaphlan <- function (path) {
    lines <- readLines(path, warn = FALSE)
    lines <- lines[!startsWith(lines, "#")]

    if (length(lines) < 2) stop(basename(path), " carries no profile")

    table <- utils::read.delim(text = lines, check.names = FALSE, quote = "",
                               colClasses = "character")

    clades <- table[[1]]
    keep   <- grepl("\\|t__SGB", clades)

    if (!any(keep)) stop(basename(path), " carries no t__SGB rows")

    table <- table[keep, , drop = FALSE]
    sgbs  <- sub("_group$", "", sub(".*\\|t__SGB", "", clades[keep]))

    counts <- numeric_matrix(table[-1], sgbs,
                             paste(basename(path), "names no samples"))

    #    "<sample>_<db_name>.metaphlan", from what merge_metaphlan_tables.py
    #    names a column after
    database <- sub("_combined_reports.*$", "",
                    sub("^metaphlan_", "", basename(path)))

    colnames(counts) <- strip_database(colnames(counts), database)

    #    Two clades can collapse onto one SGB number
    rowsum(counts, group = rownames(counts), reorder = FALSE)
}

# Every merged table names its columns after the files it merged, so a sample
# arrives as "<sample>_<db_name>" or "<sample>_<db_name>.<tool>". The database
# is trimmed back off, or the BIOM names samples something nothing else in the
# run does. Matched rather than substituted, since a db_name may contain the
# characters a pattern would read as syntax and a sample name may contain dots.
strip_database <- function (samples, database) {
    tail <- paste0("_", database)

    without_tool <- sub("\\.[^.]*$", "", samples)
    tooled       <- endsWith(without_tool, tail)

    samples[tooled] <- without_tool[tooled]

    trimmed <- endsWith(samples, tail)
    samples[trimmed] <- substr(samples[trimmed], 1,
                               nchar(samples[trimmed]) - nchar(tail))

    samples
}

# The sample columns of a table read as characters, as one numeric matrix in
# sample-name order
numeric_matrix <- function (columns, ids, complaint) {
    if (length(columns) == 0) stop(complaint)

    values <- vapply(columns, function (column) {
        numbers <- suppressWarnings(as.numeric(column))
        numbers[is.na(numbers)] <- 0
        numbers
    }, numeric(length(ids)))

    counts <- matrix(values, nrow = length(ids),
                     dimnames = list(ids, names(columns)))

    counts[, sort(colnames(counts)), drop = FALSE]
}


# -- Assembling and writing one table ----------------------------------------

# One column per rank, named as rbiom wants them, for the ids that are left
lineage_taxonomy <- function (path, ids) {
    lineage <- utils::read.delim(path, check.names = FALSE, quote = "",
                                 colClasses = "character")

    rownames(lineage) <- trimws(lineage$taxonomy_id)
    lineage <- lineage[ids, , drop = FALSE]

    taxonomy <- data.frame(.otu = ids, stringsAsFactors = FALSE)

    for (rank in RANKS) {
        column <- tolower(rank)
        values <- if (column %in% colnames(lineage)) lineage[[column]] else ""

        values[is.na(values)] <- ""
        taxonomy[[rank]] <- values
    }

    taxonomy
}

# Features the tree has no tip for are dropped rather than left to fail the
# assignment: rbiom needs every feature on the tree, and what is dropped is
# reported so the count can be read against the table.
on_tree <- function (counts, tree, what) {
    covered <- rownames(counts) %in% tree$tip.label

    if (!any(covered)) stop("no ", what, " is on the tree")

    if (!all(covered))
        note(sum(!covered), " of ", nrow(counts), " ", what,
             " are not on the tree and are left out of it")

    counts[covered, , drop = FALSE]
}

write_table <- function (biom, formats) {
    dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

    for (spec in formats) {
        path <- file.path(table_dir, spec$file)
        unlink(path)

        attempt(spec$file, function ()
            rbiom::write_biom(biom, path, format = spec$format))
    }
}

write_newick <- function (biom, name) {
    path <- file.path(table_dir, name)
    unlink(path)

    attempt(name, function () rbiom::write_tree(biom, path))
}

# Faith's PD per sample, with the abundance it was computed over beside it
faith_of <- function (biom) {
    pd <- rbiom::adiv_matrix(biom, adiv = "faith")

    if (!"faith" %in% colnames(pd)) stop("rbiom computed no Faith's PD")

    data.frame(sample = rownames(pd),
               pd     = as.numeric(pd[, "faith"]),
               placed = as.numeric(rbiom::sample_sums(biom)[rownames(pd)]),
               stringsAsFactors = FALSE)
}


# -- Count tables ------------------------------------------------------------

# One matrix as a plain table, with the taxon it is keyed by named beside it
write_counts <- function (file, ids, names, counts, key, what) {
    if (nrow(counts) == 0) stop("there are no ", what, " to write")

    dir.create(count_dir, recursive = TRUE, showWarnings = FALSE)

    frame <- data.frame(ids, names, round(counts),
                        check.names = FALSE, stringsAsFactors = FALSE)

    colnames(frame) <- c(key, "name", colnames(counts))

    utils::write.table(frame, file = file.path(count_dir, file), sep = "\t",
                       quote = FALSE, row.names = FALSE)

    message("Wrote ", file, ": ", nrow(counts), " ", what, ", ",
            ncol(counts), " samples")
}

# A matrix rescaled so each sample totals what is named for it, which is what
# turns a coverage into a count that still carries sequencing depth
scale_to <- function (values, totals) {
    scale <- totals / colSums(values)
    scale[!is.finite(scale)] <- 0

    sweep(values, 2, scale, "*")
}

# Where each row of a taxpasta table sits relative to species. A row below
# species takes the species in its own lineage; a row above it becomes an
# unclassified species of its own, so that no assigned read is dropped.
species_keys <- function (table) {
    ids   <- trimws(table$taxonomy_id)
    ranks <- trimws(table$rank)
    names <- trimws(table$name)

    if (!all(c("id_lineage", "rank_lineage", "lineage") %in% colnames(table)))
        stop("the profile carries no lineage columns to place its ranks with")

    split_at <- function (column, at) {
        parts <- strsplit(column, ";", fixed = TRUE)

        trimws(vapply(seq_along(parts), function (i)
            if (at[[i]] > 0 && length(parts[[i]]) >= at[[i]])
                parts[[i]][[at[[i]]]] else NA_character_, character(1)))
    }

    at <- vapply(strsplit(table$rank_lineage, ";", fixed = TRUE),
                 function (ranks) match("species", trimws(ranks), nomatch = 0L),
                 integer(1))

    keys   <- ids
    labels <- names

    below <- ranks != "species" & at > 0
    if (any(below)) {
        at_below <- ifelse(below, at, 0L)

        keys[below]   <- split_at(table$id_lineage, at_below)[below]
        labels[below] <- split_at(table$lineage, at_below)[below]
    }

    above <- ranks != "species" & at == 0
    if (any(above)) {
        keys[above]   <- paste0("u", ids[above])
        labels[above] <- ifelse(nzchar(names[above]),
                                paste(names[above], "unclassified"),
                                "unclassified")
    }

    unplaced <- is.na(keys) | !nzchar(keys)
    keys[unplaced]   <- paste0("u", ids[unplaced])
    labels[unplaced] <- "unclassified"

    data.frame(key = keys, label = labels, stringsAsFactors = FALSE)
}

# A taxpasta table as a counts matrix at species, keeping every assigned read
read_at_species <- function (path) {
    table <- utils::read.delim(path, check.names = FALSE, quote = "",
                               colClasses = "character")

    if (!"taxonomy_id" %in% colnames(table))
        stop(basename(path), " has no taxonomy_id column")

    placed <- species_keys(table)

    counts <- numeric_matrix(table[setdiff(colnames(table), TAXPASTA_FIELDS)],
                             placed$key, paste(basename(path), "names no samples"))

    database <- sub("^[^_]+_", "", sub("\\.tsv$", "", basename(path)))
    colnames(counts) <- strip_database(colnames(counts), database)

    counts <- rowsum(counts, group = placed$key, reorder = FALSE)
    labels <- placed$label[!duplicated(placed$key)]

    list(counts = counts[, sort(colnames(counts)), drop = FALSE],
         labels = labels[match(rownames(counts), placed$key[!duplicated(placed$key)])])
}

# Every per-sample MetaPhlAn profile that -t rel_ab_w_read_stats wrote, as one
# matrix of the named column. Rows are the species clades; the UNCLASSIFIED row
# is kept so that what the profiler could not place stays visible.
read_metaphlan_stats <- function (dir, column) {
    files <- list.files(dir, pattern = "_profile\\.txt$", recursive = TRUE,
                        full.names = TRUE)

    if (length(files) == 0) stop("no per-sample MetaPhlAn profile is in ", dir)

    clades <- character(0)
    columns <- list()

    for (path in files) {
        lines  <- readLines(path, warn = FALSE)
        header <- lines[startsWith(lines, "#clade_name")]

        if (length(header) == 0)
            stop(basename(path), " carries no rel_ab_w_read_stats header")

        fields <- strsplit(sub("^#", "", header[[1]]), "\t", fixed = TRUE)[[1]]

        if (!column %in% fields)
            stop(basename(path), " has no ", column, " column")

        rows <- lines[!startsWith(lines, "#") & nzchar(lines)]
        if (length(rows) == 0) next

        split <- strsplit(rows, "\t", fixed = TRUE)
        clade <- vapply(split, function (row) row[[1]], character(1))
        value <- suppressWarnings(as.numeric(vapply(split, function (row)
            if (length(row) >= match(column, fields))
                row[[match(column, fields)]] else NA_character_, character(1))))

        # Rows ending at s__, not the t__SGB row under each one, which repeats
        # the same value one rank deeper
        keep  <- grepl("\\|s__[^|]*$", clade) | clade == "UNCLASSIFIED"
        value[is.na(value)] <- 0

        sample <- sub("_profile\\.txt$", "", basename(path))
        columns[[sample]] <- stats::setNames(value[keep], clade[keep])
        clades <- union(clades, clade[keep])
    }

    if (length(columns) == 0) stop("every MetaPhlAn profile in ", dir, " is empty")

    counts <- vapply(columns, function (values) {
        placed <- values[clades]
        placed[is.na(placed)] <- 0
        placed
    }, numeric(length(clades)))

    counts <- matrix(counts, nrow = length(clades),
                     dimnames = list(clades, names(columns)))

    database <- sub("^[^_]+_", "", names(columns)[[1]])
    colnames(counts) <- strip_database(colnames(counts),
                                       sub("\\.metaphlan$", "", database))

    counts[, sort(colnames(counts)), drop = FALSE]
}

# The merged mOTUs report, which is already one scaled insert count per marker
# gene cluster. Rows that no sample saw are dropped.
read_motus <- function (path) {
    lines <- readLines(path, warn = FALSE)
    lines <- lines[!startsWith(lines, "# ")]

    if (length(lines) < 2) stop(basename(path), " carries no profile")

    table <- utils::read.delim(text = sub("^#", "", lines), check.names = FALSE,
                               quote = "", colClasses = "character")

    if (ncol(table) < 3) stop(basename(path), " names no samples")

    taxa <- trimws(table[[1]])

    counts <- numeric_matrix(table[-(1:2)], taxa,
                             paste(basename(path), "names no samples"))

    database <- sub("_combined_reports.*$", "",
                    sub("^motus_", "", basename(path)))

    colnames(counts) <- strip_database(colnames(counts), database)

    seen <- rowSums(counts) > 0

    list(counts = counts[seen, sort(colnames(counts)), drop = FALSE],
         ids    = trimws(table[[2]])[seen])
}


# -- The species table, on the taxonomy --------------------------------------

taxonomy_faith <- NULL

if (!usable(profile_tsv)) {
    note("there is no merged taxpasta profile; no feature table will be written")
} else attempt("the feature table", function () {
    message("Reading ", basename(profile_tsv), "...")

    counts   <- read_taxpasta(profile_tsv)
    tree     <- NULL
    taxonomy <- NULL

    if (usable(taxonomy_tree)) {
        tree <- attempt("the taxonomy tree", function ()
            rbiom::read_tree(taxonomy_tree))
    } else {
        note("no taxonomy tree was built; the feature table will carry none")
    }

    if (!is.null(tree)) {
        counts <- on_tree(counts, tree, "taxa")

        if (usable(lineage_tsv))
            taxonomy <- attempt("the rank columns", function ()
                lineage_taxonomy(lineage_tsv, rownames(counts)))
    }

    biom <- if (is.null(taxonomy)) {
        rbiom::as_rbiom(biom = counts,
                        id = "Shotgun metagenomic taxonomic profile")
    } else {
        rbiom::as_rbiom(biom = counts, taxonomy = taxonomy,
                        id = "Shotgun metagenomic taxonomic profile")
    }

    if (!is.null(tree)) attempt("the taxonomy tree", function () biom$tree <- tree)

    write_table(biom, list(
        list(file = "feature-table.tsv",       format = "tab"),
        list(file = "feature-table.json.biom", format = "json"),
        list(file = "feature-table.hdf5.biom", format = "hdf5")))

    if (!is.null(biom$tree)) {
        write_newick(biom, "taxonomy-tree.newick")
        taxonomy_faith <<- attempt("Faith's PD", function () faith_of(biom))
    }

    message("Wrote the feature table: ", biom$n_otus, " taxa, ",
            biom$n_samples, " samples",
            if (is.null(biom$tree)) ", without a tree" else ", on the taxonomy tree")
})


# -- The MetaPhlAn table, on the published phylogeny -------------------------

sgb_faith <- NULL

if (!usable(metaphlan_profile) || !usable(metaphlan_tree)) {
    note("no MetaPhlAn profile and phylogeny to pair; no SGB table will be written")
} else attempt("the MetaPhlAn table", function () {
    message("Reading ", basename(metaphlan_profile), "...")

    counts <- read_metaphlan(metaphlan_profile)
    tree   <- rbiom::read_tree(metaphlan_tree)
    counts <- on_tree(counts, tree, "SGBs")

    biom <- rbiom::as_rbiom(
        biom = counts,
        id   = "MetaPhlAn SGB profile, on the CHOCOPhlAn phylogeny")

    biom$tree <- tree

    write_table(biom, list(list(file = "metaphlan-table.hdf5.biom",
                                format = "hdf5")))
    write_newick(biom, "metaphlan-tree.newick")

    sgb_faith <<- attempt("Faith's PD over the SGB phylogeny",
                          function () faith_of(biom))

    message("Wrote the MetaPhlAn table: ", biom$n_otus, " SGBs, ",
            biom$n_samples, " samples, on the published phylogeny")
})


# -- The count tables --------------------------------------------------------

if (!usable(profile_tsv)) {
    note("there is no merged taxpasta profile; no read count table")
} else attempt("the profile count tables", function () {
    tool   <- if (species_only) "kraken2" else "bracken"
    placed <- read_at_species(profile_tsv)

    write_counts(paste0(tool, "-reads.tsv"), rownames(placed$counts),
                 placed$labels, placed$counts, "taxonomy_id", "species")
})

if (!usable(metaphlan_dir)) {
    note("no per-sample MetaPhlAn profiles; no MetaPhlAn count table")
} else attempt("the MetaPhlAn count tables", function () {
    reads <- read_metaphlan_stats(metaphlan_dir,
                                  "estimated_number_of_reads_from_the_clade")

    write_counts("metaphlan-reads.tsv", rownames(reads),
                 sub(".*\\|s__", "", rownames(reads)), reads,
                 "clade_name", "clades")

    # Coverage is genome copies, so it runs well below 1 and would round to
    # nothing; it is put on the scale of the reads placed beside it. The
    # unclassified row has no genome to be a copy of and keeps its read count.
    attempt("metaphlan-cells.tsv", function () {
        cover  <- read_metaphlan_stats(metaphlan_dir, "coverage")
        shared <- intersect(rownames(reads), rownames(cover))

        cover <- cover[shared, colnames(reads), drop = FALSE]
        seen  <- reads[shared, colnames(reads), drop = FALSE]

        placed <- rownames(cover) != "UNCLASSIFIED"
        cells  <- cover

        cells[placed, ]  <- scale_to(cover[placed, , drop = FALSE],
                                     colSums(seen[placed, , drop = FALSE]))
        cells[!placed, ] <- seen[!placed, , drop = FALSE]

        write_counts("metaphlan-cells.tsv", rownames(cells),
                     sub(".*\\|s__", "", rownames(cells)), cells,
                     "clade_name", "clades")
    })
})

if (!usable(motus_profile)) {
    note("no merged mOTUs profile; no mOTUs count table")
} else attempt("motus-cells.tsv", function () {
    profile <- read_motus(motus_profile)

    write_counts("motus-cells.tsv", profile$ids, rownames(profile$counts),
                 profile$counts, "ncbi_tax_id", "mOTUs")
})


# -- What the diversity table takes from both --------------------------------

samples <- sort(unique(c(taxonomy_faith$sample, sgb_faith$sample)))

if (length(samples) == 0) {
    note("no phylogenetic diversity could be computed")
    quit(save = "no", status = 0)
}

reading <- function (frame, column) {
    if (is.null(frame)) return(rep("NA", length(samples)))

    values <- frame[[column]][match(samples, frame$sample)]

    ifelse(is.na(values), "NA", formatC(values, format = "f", digits = 4))
}

utils::write.table(
    data.frame(sample        = samples,
               faith_pd      = reading(taxonomy_faith, "pd"),
               faith_reads   = reading(taxonomy_faith, "placed"),
               faith_pd_sgb  = reading(sgb_faith, "pd"),
               faith_sgb_pct = reading(sgb_faith, "placed"),
               stringsAsFactors = FALSE),
    file = faith_out, sep = "\t", quote = FALSE, row.names = FALSE)

message("Wrote phylogenetic diversity for ", length(samples), " samples.")
