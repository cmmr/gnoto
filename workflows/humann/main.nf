// HUMAnN 3.9 functional profiling, over the reads and the taxonomic profiles a
// finished nf-core/taxprofiler run already produced.
//
// nf-core/taxprofiler has no functional profiling of any kind, so this runs as a
// second workflow after it rather than as part of it.
// steps/taxprofiler_humann.sh pairs each sample with its analysis-ready reads
// and its MetaPhlAn profile and runs this; see docs/pipelines/taxprofiler.md.
//
// --taxonomic-profile hands HUMAnN the profile taxprofiler already computed, so
// it skips its own MetaPhlAn pass - one bowtie2 alignment of every read against
// the marker database - and the taxonomy stratifying every by-taxon table below
// is the same taxonomy the run publishes as its taxonomic deliverable.
//
// It is the profile that is reused, not MetaPhlAn's alignments. Those are reads
// against a small set of marker genes per species; HUMAnN aligns the reads
// again, to the whole pangenomes of the species in the profile, then sends what
// is left to UniRef90.
//
// The processes are in modules/humann.nf, shared with workflows/biobakery.
// Everything is published to <outdir>/humann/.

nextflow.enable.dsl = 2

params.input           = null
params.outdir          = null
params.chocophlan      = null
params.uniref          = null
params.utility_mapping = null

include { HUMANN_PROFILE; HUMANN_TABLES } from '../../modules/humann.nf'

workflow {
    if (!params.input)  { error "No samplesheet: pass --input" }
    if (!params.outdir) { error "No output directory: pass --outdir" }

    // sample, its reads as a ";"-separated list, and its taxonomic profile
    ch_samples = Channel
        .fromPath(params.input, checkIfExists: true)
        .splitCsv(header: true)
        .map { row ->
            [ row.sample,
              row.reads.split(';').collect { file(it, checkIfExists: true) },
              file(row.taxonomic_profile, checkIfExists: true) ]
        }

    HUMANN_PROFILE(
        ch_samples,
        file(params.chocophlan, checkIfExists: true),
        file(params.uniref, checkIfExists: true)
    )

    HUMANN_TABLES(
        HUMANN_PROFILE.out.genefamilies.collect(),
        HUMANN_PROFILE.out.pathabundance.collect(),
        HUMANN_PROFILE.out.pathcoverage.collect(),
        HUMANN_PROFILE.out.log.collect(),
        file(params.utility_mapping, checkIfExists: true)
    )
}
