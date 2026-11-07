<!--
  abstract.md - The opening section of ampliseq's summary report.

  Passed to nf-core/ampliseq as --report_abstract, which replaces the report's
  own "Abstract" section with this file. It's read as Markdown, so raw HTML
  passes through, which is how the dashboard link opens outside the frame the
  report is read in. Written for the reader whose data it is, and for any site
  that runs gnoto, so it names none.

  Links are relative to summary_report/summary_report.html, where the report is
  published, so they resolve inside the dashboard or on their own.
-->

# About this analysis

This report is the pipeline's own account of how your samples were analysed:
what came off the sequencer, what was filtered out and why, and which organisms
were found in what proportions. The analysis was run with
[gnoto](https://github.com/cmmr/gnoto), using
[nf-core/ampliseq](https://nf-co.re/ampliseq): reads are quality filtered and
denoised into amplicon sequence variants (ASVs) &mdash; exact sequences rather
than clustered approximations &mdash; and each ASV is classified against a
reference database.

<p><strong>The report is one part of your results.</strong> The
<a href="../index.html" target="_top">results dashboard</a> also carries the
sequencing quality report, the feature table in the formats QIIME 2, phyloseq
and R read, an index of every other output, and a download of everything.</p>

<p class="text-muted">Questions about these results are best put to whoever ran
this analysis for you.</p>
