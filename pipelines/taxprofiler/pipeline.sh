#
# pipeline.sh - taxprofiler: shotgun metagenomics. fastp trims, then kraken2,
# bracken, MetaPhlAn and mOTUs profile, nonpareil measures how much of each
# community was sequenced, and HUMAnN profiles functions afterwards.
#
# Sourced by:  the job, from the run directory, with lib/env.sh loaded
# Defines:     NEXTFLOW_ARGS, PARAMS_FILE, PARAMS_LOCKED, PRE_PROCESS_CMDS,
#              POST_PROCESS_CMDS, PIPELINE_DATABASES, ONE_READ_LAYOUT,
#              and the parameter defaults
#
# Which host is depleted is the hostremoval_reference answer, PhiX alone when
# it's unanswered.

NEXTFLOW_ARGS=(
    -log nextflow.log
    run "$(lock_get taxprofiler .upstream.repository)"
    -r "$(lock_get taxprofiler .upstream.commit)"
    -profile apptainer
    -c "$CODE_DIR/pipelines/taxprofiler/resources.config"
    -params-file taxprofiler_args.yaml
)

PARAMS_FILE="taxprofiler_args.yaml"

params_reset
params_set input "taxprofiler_samplesheet.csv"
params_set databases "taxprofiler_database.csv"
params_set outdir "results"

# nf-core pipelines otherwise load nf-core/configs from its master branch at run
# time, which the commit doesn't pin
params_set custom_config_base ""

params_set perform_shortread_qc true
params_set shortread_qc_tool "fastp"

# 35 is kraken2's k: a shorter read holds no 35-mer, so it can't be classified
# and only pads the totals shares are taken against. It also clears nonpareil's
# 24-mer minimum, below which it fails on whichever samples hold a short read.
params_set shortread_qc_minlength 35

# Homopolymers, poly-G tails and microsatellites carry no taxonomic signal and
# land on the repeat-rich genomes PlusPF holds. fastp's filter runs in the
# trimming task already running, rather than as a second pass.
params_set perform_shortread_complexityfilter true
params_set shortread_complexityfilter_tool "fastp"
params_set shortread_complexityfilter_fastp_threshold 30

params_set perform_longread_qc true
params_set perform_runmerging true
params_set run_kraken2 true
params_set run_bracken true
params_set run_metaphlan true
params_set run_motus true

# The distinct-minimizer columns. Downstream steps get the standard report,
# which taxprofiler derives when this is on.
params_set kraken2_save_minimizers true

# The marker gene cluster read counts the mOTUs profile is computed from
params_set motus_save_mgc_read_counts true

# HUMAnN runs on exactly the reads the classifiers saw, so the functional and
# taxonomic profiles describe the same sample. They're deleted once HUMAnN has
# read them.
params_set save_analysis_ready_fastqs true

params_set run_krona true
params_set run_profile_standardisation true
params_set standardisation_taxpasta_format "tsv"
params_set taxpasta_taxonomy_dir "db:kraken2/pluspf_20260626"
params_set taxpasta_add_name true
params_set taxpasta_add_rank true

# Lineage columns make the merged tables self-contained, and the id lineage is
# what the table builder rolls strains up and pads higher ranks down with
params_set taxpasta_add_lineage true
params_set taxpasta_add_ranklineage true
params_set taxpasta_add_idlineage true

# Diversity that no classifier measures honestly, because about half a sample's
# reads reach no taxon. Nonpareil reads redundancy off the reads, before host
# removal and run merging, where taxprofiler 2.0.1 runs it. mOTUs counts the
# species-level clusters it finds in marker genes.
params_set perform_shortread_redundancyestimation true
params_set shortread_redundancyestimation_mode "kmer"

# "None", "PhiX", "Human + PhiX" or "Mouse + PhiX": the first word names the host
TAXPROFILER_HOST=$(form_answer hostremoval_reference)
TAXPROFILER_HOST=${TAXPROFILER_HOST:-PhiX}
TAXPROFILER_HOST=${TAXPROFILER_HOST,,}
TAXPROFILER_HOST=${TAXPROFILER_HOST%% *}

case "$TAXPROFILER_HOST" in
    none) TAXPROFILER_HOST_REFERENCE="" ;;
    phix) TAXPROFILER_HOST_REFERENCE="phix" ;;
    human) TAXPROFILER_HOST_REFERENCE="chm13v2phix" ;;
    mouse) TAXPROFILER_HOST_REFERENCE="grcm39phix" ;;
    *) fail "\"$TAXPROFILER_HOST\" isn't a host this pipeline can deplete." ;;
esac

# Every depleting answer also removes PhiX, the Illumina spike-in, which
# PlusPF's viral genomes would otherwise classify. A host the requester didn't
# name isn't depleted.
if [[ -n "$TAXPROFILER_HOST_REFERENCE" ]]; then
    params_set perform_shortread_hostremoval true
    params_set hostremoval_reference "db:hostremoval/$TAXPROFILER_HOST_REFERENCE.fa"
    params_set shortread_hostremoval_index "db:hostremoval/$TAXPROFILER_HOST_REFERENCE"
    params_set perform_longread_hostremoval true
    params_set longread_hostremoval_index "db:hostremoval/$TAXPROFILER_HOST_REFERENCE.mmi"
else
    params_set perform_shortread_hostremoval false
    params_set perform_longread_hostremoval false
fi

# The run writes these files, or reads them where it expects them
PARAMS_LOCKED=(input databases outdir custom_config_base)

# The databases taxprofiler reads through its database sheet
mapfile -t PIPELINE_DATABASES < <(grep -o 'db:[^,]*' "$CODE_DIR/pipelines/taxprofiler/database.csv" | sort -u)

PRE_PROCESS_CMDS=(
    "$CODE_DIR/steps/taxprofiler_samplesheet.sh"
)

POST_PROCESS_CMDS=(
    "$CODE_DIR/steps/taxprofiler_humann.sh"
)
