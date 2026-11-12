# check.R - Run while gnoto-dada2 is built: classifies a sequence tied exactly
# between two species, at 1 thread and at 4, each after set.seed(100), and
# stops unless every call gives the same species and confidence.
suppressPackageStartupMessages(library(dada2))
stopifnot(packageVersion("dada2") == "1.38.0")
set.seed(1)
random_seq <- function(n) paste(sample(c("A", "C", "G", "T"), n, replace = TRUE), collapse = "")
shared <- random_seq(250)
other <- random_seq(250)
ref <- tempfile(fileext = ".fa")
writeLines(c(
  ">Bacteria;P1;C1;O1;F1;G1;alpha;", shared,
  ">Bacteria;P1;C1;O1;F1;G1;beta;", shared,
  ">Bacteria;P1;C1;O1;F1;G2;gamma;", other
), ref)
calls <- character()
for (threads in c(1, 1, 4, 4)) {
  set.seed(100)
  t <- assignTaxonomy(shared, ref, minBoot = 50, outputBootstraps = TRUE, multithread = threads)
  calls <- c(calls, paste(t$tax[1, "Species"], t$boot[1, "Species"]))
}
if (length(unique(calls)) != 1) stop("ties broke differently with one seed: ", paste(calls, collapse = ", "))
cat("Ties repeat with set.seed():", calls[1], "\n")
