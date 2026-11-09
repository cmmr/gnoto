#
# pipeline.sh - biobakery: shotgun metagenomics with the bioBakery tools.
# bowtie2 depletes the host, KneadData trims and removes tandem repeats,
# MetaPhlAn profiles the taxonomy and HUMAnN the functions. mOTUs and Nonpareil
# measure diversity, and Marker-MAGu profiles phages alongside bacteria and
# archaea. EsViritu, for human, animal and plant viruses, is off.
#
# Sourced by:  the job, from the run directory, with lib/env.sh loaded
# Defines:     NEXTFLOW_ARGS, PARAMS_FILE, PARAMS_LOCKED, PRE_PROCESS_CMDS,
#              POST_PROCESS_CMDS, PIPELINE_DATABASES, ONE_READ_LAYOUT,
#              and the parameter defaults
# Env:         GNOTO_JOB_PARAMS, the job's own parameters as JSON, for
#              run_esviritu
#
# Which host is depleted is the hostremoval_reference answer, PhiX alone when
# it's unanswered.

NEXTFLOW_ARGS=(
    -log nextflow.log
    run "$CODE_DIR/workflows/biobakery"
    -profile apptainer
    -c "$CODE_DIR/pipelines/biobakery/resources.config"
    -params-file biobakery_args.yaml
)

PARAMS_FILE="biobakery_args.yaml"

params_reset
params_set input "biobakery_samplesheet.csv"
params_set outdir "results"

params_set run_humann true
params_set run_motus true
params_set run_nonpareil true
params_set run_esviritu false
params_set run_markermagu true

# "None", "PhiX", "Human + PhiX" or "Mouse + PhiX": the first word names the host
BIOBAKERY_HOST=$(form_answer hostremoval_reference)
BIOBAKERY_HOST=${BIOBAKERY_HOST:-PhiX}
BIOBAKERY_HOST=${BIOBAKERY_HOST,,}
BIOBAKERY_HOST=${BIOBAKERY_HOST%% *}

case "$BIOBAKERY_HOST" in
    none) BIOBAKERY_HOST_REFERENCE="" ;;
    phix) BIOBAKERY_HOST_REFERENCE="phix" ;;
    human) BIOBAKERY_HOST_REFERENCE="chm13v2phix" ;;
    mouse) BIOBAKERY_HOST_REFERENCE="grcm39phix" ;;
    *) fail "\"$BIOBAKERY_HOST\" isn't a host this pipeline can deplete." ;;
esac

# The bowtie2 index. Empty trims without depleting anything.
if [[ -n "$BIOBAKERY_HOST_REFERENCE" ]]; then
    params_set kneaddata_db "db:hostremoval/$BIOBAKERY_HOST_REFERENCE/v1/$BIOBAKERY_HOST_REFERENCE"
else
    params_set kneaddata_db ""
fi

# bowtie2 end to end over every read, then in local mode, KneadData's own
# setting, over the pairs left
params_set host_prefilter_bowtie2_options "--fast"
params_set host_bowtie2_options "--very-sensitive-local"

params_set kneaddata_sequencer_source "NexteraPE"

# The read sets delivered beside the results: any of "Raw", "Host Depleted" and
# "Cleaned", or none. The workflow writes the last two, and the raw reads are
# taken from the inputs. A run that depletes no host has no host-depleted reads.
params_set host_depleted_outdir ""
params_set cleaned_outdir ""

if form_answer_includes delivered_reads "Host Depleted"; then
    if [[ -n "$BIOBAKERY_HOST_REFERENCE" ]]; then
        params_set host_depleted_outdir "host-depleted-sequences"
    else
        state_append notes "No host was removed from these reads, so there are no host-depleted reads in the download."
    fi
fi

if form_answer_includes delivered_reads "Cleaned"; then
    params_set cleaned_outdir "cleaned-sequences"
fi

# The newest MetaPhlAn database HUMAnN 3.9 accepts profiles from
params_set metaphlan_db "db:metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403"

params_set humann_chocophlan "db:humann/v201901b/chocophlan"
params_set humann_uniref "db:humann/v201901b/uniref90"
params_set humann_utility_mapping "db:humann/v201901b/utility_mapping"

# The database mOTUs 3.1.0 accepts, shared with taxprofiler
params_set motus_db "db:motus/db_mOTU_v3.1.0/db_mOTU"

params_set nonpareil_mode "kmer"

# Named only when EsViritu runs, so the record names no database the run didn't
# read. A job turns it on with its own run_esviritu, which is applied after this
# file, so that's read from the job's parameters.
if jq -e --argjson default "$(params_get run_esviritu)" \
    '(. // {}) | if has("run_esviritu") then .run_esviritu else $default end | . == true' \
    > /dev/null 2>&1 <<< "${GNOTO_JOB_PARAMS:-null}"; then
    params_set esviritu_db "db:esviritu/v3.2.4"
fi

params_set markermagu_db "db:markermagu/v1.1"
params_set markermagu_detection "default"

# The run writes or reads the first two where it expects them. The read sets
# delivered are this request's answer, not those of a run it repeats.
PARAMS_LOCKED=(input outdir host_depleted_outdir cleaned_outdir)

PRE_PROCESS_CMDS=(
    "$CODE_DIR/steps/biobakery_samplesheet.sh"
)

POST_PROCESS_CMDS=()
