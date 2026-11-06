#
# pipeline.sh - ampliseq: 16S amplicons, Illumina or Oxford Nanopore.
#
# Sourced by:  the job, from the run directory, with lib/env.sh loaded
# Defines:     NEXTFLOW_ARGS, PARAMS_FILE, PARAMS_LOCKED, PRE_PROCESS_CMDS,
#              POST_PROCESS_CMDS, and the parameter defaults
#
# Neither the platform nor the region is requested: ampliseq_detect_region.sh
# measures both and supplies sequencing_type, the primers, skip_cutadapt, and
# the Savont settings an ONT run needs.

NEXTFLOW_ARGS=(
    -log nextflow.log
    run "$(lock_get ampliseq .upstream.repository)"
    -r "$(lock_get ampliseq .upstream.commit)"
    -profile apptainer
    -c "$CODE_DIR/conf/ampliseq/resources.config"
    -params-file ampliseq_args.yaml
)

PARAMS_FILE="ampliseq_args.yaml"

params_reset
params_set input "ampliseq_samplesheet.tsv"
params_set outdir "results"

# nf-core pipelines otherwise load nf-core/configs from its master branch at run
# time, which the commit doesn't pin
params_set custom_config_base ""

# The reference is fetched by gnoto and passed as local files, so ampliseq
# downloads nothing
DADA_REF_TAXONOMY=$(form_answer dada_ref_taxonomy)
params_reference dada_ref_taxonomy "${DADA_REF_TAXONOMY:-silva=138.2}"
params_set cut_dada_ref_taxonomy true

for AMPLISEQ_PARAM in qiime_ref_taxonomy kraken2_ref_taxonomy; do
    AMPLISEQ_ANSWER=$(form_answer "$AMPLISEQ_PARAM")
    if [[ -n "$AMPLISEQ_ANSWER" ]]; then
        params_reference "$AMPLISEQ_PARAM" "$AMPLISEQ_ANSWER"
    fi
done

# Applied by steps/R/ampliseq_tables.R rather than by the pipeline, because the
# QIIME 2 step that filtered taxa no longer runs. Declared here so the record
# holds it, which is where that script reads it.
EXCLUDE_TAXA=$(form_answer exclude_taxa)
params_set exclude_taxa "${EXCLUDE_TAXA:-mitochondria,chloroplast,Francisella}"

# QIIME 2's downstream analyses are skipped: steps/R/ampliseq_tables.R builds
# one feature table from DADA2's and writes it three ways, so every download
# and plot shows the same object. The QIIME 2 classifier still runs when
# qiime_ref_taxonomy asks for it.
params_set skip_qiime_downstream true

# Built from the unfiltered DADA2 table, a different set of ASVs from the
# published feature table. rbiom's convert_to_phyloseq() rebuilds phyloseq from
# the published BIOM.
params_set skip_phyloseq true
params_set skip_tse true

# Keeps bacterial and archaeal SSU only. Host and organellar products carry no
# SSU, and left in, each becomes a long branch that unweighted UniFrac and
# Faith's PD weigh like any other.
params_set filter_ssu "bac,arc"

# Pinned because this release changed the default from independent, and because
# Savont rejects the third value, pseudo
params_set sample_inference "pooled"

# A sample DADA2's filter empties is dropped rather than failing the run. The
# Overview names any sample missing from the feature table.
params_set ignore_failed_filtering true

# Phylogenetic placement onto the GTDB bacterial 16S tree, in place of a de novo
# tree. ampliseq_prune_tree.sh cuts it back to this run's ASVs. pplace_taxonomy
# stays unset: ampliseq would prefer it to DADA2's, putting GTDB names in every
# table.
params_set pplace_name "gtdb_bac16s"
params_set pplace_tree "db:pplace/bac16s.newick"
params_set pplace_aln "db:pplace/bac16s.alnfna"
params_set pplace_model "GTR+F+I+G4"
params_set pplace_alnmethod "clustalo"

# ampliseq analyses only the samples its metadata sheet lists, and
# ampliseq_samplesheet.sh writes it from the same samples. It carries no
# grouping, so nothing is compared between groups.
params_set metadata "ampliseq_metadata.tsv"

params_set report_title "Amplicon sequencing analysis"
params_set report_abstract "$CODE_DIR/present/templates/ampliseq/abstract.md"

if [[ "$(form_answer picrust)" == "Yes" ]]; then
    params_set picrust true
fi

# The run writes these files, or reads them where it expects them
PARAMS_LOCKED=(input outdir metadata custom_config_base)

PRE_PROCESS_CMDS=(
    "$CODE_DIR/steps/ampliseq_samplesheet.sh"
    "$CODE_DIR/steps/ampliseq_detect_region.sh"
)

POST_PROCESS_CMDS=(
    "$CODE_DIR/steps/ampliseq_prune_tree.sh"
)
