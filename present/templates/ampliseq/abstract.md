<!--
  abstract.md - The opening section of ampliseq's summary report.

  Passed to nf-core/ampliseq as --report_abstract, which replaces the pipeline's
  own "Abstract" section with this file. It is read as Markdown, so raw HTML
  passes straight through - which is how the links below open outside the frame
  the report is read in.

  Written for the client whose data it is. Everything after this section is
  ampliseq's own account of the run and is not ours to edit here.

  Links are relative to summary_report/summary_report.html, which is where this
  report is published, so they resolve whether it is read inside the dashboard
  or on its own.
-->

# About this analysis

Your samples were sequenced and analysed by the Alkek Center for Metagenomics
and Microbiome Research at Baylor College of Medicine. This report is the
pipeline's own account of that analysis: what came off the sequencer, what was
filtered out and why, and what organisms were found in what proportions.

The analysis was run with [nf-core/ampliseq](https://nf-co.re/ampliseq), an
open-source amplicon sequencing pipeline. Reads are quality filtered and
denoised into amplicon sequence variants (ASVs) &mdash; exact sequences rather
than clustered approximations &mdash; and each ASV is then classified against a
reference database. The sections below follow that order, and every figure is
backed by a file you can download.

<p><strong>The report is one part of your results.</strong> The
<a href="../index.html" target="_top">results dashboard</a> also carries the
per-sample sequencing quality report, the abundance table in the formats QIIME
2, phyloseq and R expect, your raw sequencing files, and an index of every other
output with a note on what each one holds.</p>

<p class="text-muted">Questions about anything here are welcome &mdash; please
get in touch with your contact at the CMMR.</p>
