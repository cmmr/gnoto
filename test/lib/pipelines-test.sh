#!/bin/bash
#
# pipelines-test.sh - Sources each pipelines/<name>/pipeline.sh with fixture
# answers and checks the parameters and commands it sets.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/lib/pipelines-test.sh

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
source "$CODE/lib/env.sh" || exit 1
source "$CODE/lib/jobfile.sh"
WORK=$(mktemp -d "$DATA_DIR/test-pipelines.XXXXXX")
FAILED=0
trap 'rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Sources a pipeline in a fresh run directory whose state holds the answers
# given as a JSON object, then runs the command given
with_pipeline() {
    local name=$1 answers=$2
    shift 2
    rm -rf "$WORK/run"
    mkdir -p "$WORK/run"
    (
        cd "$WORK/run" || exit 1
        state_init abcdefgh
        state_set_json answers "$answers"
        source "$CODE/pipelines/$name/pipeline.sh"
        eval "$*"
    )
}

param() {
    jq -r --arg k "$1" '.[$k] | if type == "string" then . else tojson end'
}

JSON=$(with_pipeline ampliseq '{}' params_json)
check "ampliseq: SILVA by default, as local files" \
    "db:dada2/silva-138.2/silva_nr99_v138.2_toSpecies_trainset.fa.gz db:dada2/silva-138.2/silva_v138.2_assignSpecies.fa.gz" \
    "$(param dada_ref_tax_custom <<< "$JSON") $(param dada_ref_tax_custom_sp <<< "$JSON")"
check "ampliseq: no download parameter left" "null" "$(param dada_ref_taxonomy <<< "$JSON")"
check "ampliseq: custom_config_base empty" '""' "$(jq -c .custom_config_base <<< "$JSON")"
check "ampliseq: typed values" "true 3" "$(jq -r '.skip_qiime_downstream' <<< "$JSON") $(jq -r 'keys | map(select(startswith("skip_"))) | length' <<< "$JSON")"
check "ampliseq: revision from lock.yaml" "nf-core/ampliseq -r b9bd579c0480ee23ecf24655f51c0c67777cd6b3" \
    "$(with_pipeline ampliseq '{}' 'echo "${NEXTFLOW_ARGS[3]} ${NEXTFLOW_ARGS[4]} ${NEXTFLOW_ARGS[5]}"')"
check "ampliseq: steps exist" "ok" \
    "$(with_pipeline ampliseq '{}' 'for c in "${PRE_PROCESS_CMDS[@]}" "${POST_PROCESS_CMDS[@]}" "${NEXTFLOW_ARGS[9]}"; do [[ -f $c ]] || echo "missing $c"; done; echo ok')"
check "ampliseq: pairs joined with Ns skip the exact species match" "null true true" \
    "$(for s in merge concatenate consensus; do with_pipeline ampliseq "{\"mergepairs_strategy\": \"$s\"}" params_json |
        jq -r .skip_dada_addspecies; done | paste -sd ' ')"
check "ampliseq: picrust and exclude_taxa answers" "true chloroplast" \
    "$(with_pipeline ampliseq '{"picrust": "true", "exclude_taxa": "chloroplast"}' params_json | jq -r '"\(.picrust) \(.exclude_taxa)"')"
check "ampliseq: a choice without a database fails" "1" \
    "$(with_pipeline ampliseq '{"dada_ref_taxonomy": "unknown=1"}' params_json > /dev/null 2>&1; echo $?)"
with_pipeline ampliseq '{}' 'params_write params.yaml; cat params.yaml' > "$WORK/ampliseq.yaml"
check "ampliseq: params file resolves db: names" "$DB_DIR/pplace/v1/bac16s.newick" "$(yq .pplace_tree "$WORK/ampliseq.yaml")"
check "ampliseq: and code: names" "$CODE_DIR/present/templates/ampliseq/abstract.md" "$(yq .report_abstract "$WORK/ampliseq.yaml")"
check "ampliseq: the record keeps the code: name" "code:present/templates/ampliseq/abstract.md" \
    "$(with_pipeline ampliseq '{}' params_json | jq -r .report_abstract)"
check "ampliseq: merge by default, or the answer" "merge concatenate" \
    "$(with_pipeline ampliseq '{}' params_json | jq -r .mergepairs_strategy) $(with_pipeline ampliseq '{"mergepairs_strategy": "concatenate"}' params_json | jq -r .mergepairs_strategy)"

JSON=$(with_pipeline taxprofiler '{}' params_json)
check "taxprofiler: PhiX by default" "db:hostremoval/phix/v1/phix.fa db:hostremoval/phix/v1/phix" \
    "$(param hostremoval_reference <<< "$JSON") $(param shortread_hostremoval_index <<< "$JSON")"
JSON=$(with_pipeline taxprofiler '{"hostremoval_reference": "Human + PhiX"}' params_json)
check "taxprofiler: human" "db:hostremoval/chm13v2phix/v1/chm13v2phix.mmi" "$(param longread_hostremoval_index <<< "$JSON")"
JSON=$(with_pipeline taxprofiler '{"hostremoval_reference": "None"}' params_json)
check "taxprofiler: no host" "false null" "$(param perform_shortread_hostremoval <<< "$JSON") $(param hostremoval_reference <<< "$JSON")"
check "taxprofiler: an unknown host fails" "1" \
    "$(with_pipeline taxprofiler '{"hostremoval_reference": "Yeti"}' params_json > /dev/null 2>&1; echo $?)"
check "taxprofiler: revision from lock.yaml" "70ecc15e49b4f1fcf79d876643b5d14b65c66178" \
    "$(with_pipeline taxprofiler '{}' 'echo "${NEXTFLOW_ARGS[5]}"')"

JSON=$(with_pipeline biobakery '{"hostremoval_reference": "Mouse + PhiX", "delivered_reads": "Raw,Cleaned"}' params_json)
check "biobakery: mouse, cleaned reads only" "db:hostremoval/grcm39phix/v1/grcm39phix cleaned-sequences " \
    "$(param kneaddata_db <<< "$JSON") $(param cleaned_outdir <<< "$JSON") $(param host_depleted_outdir <<< "$JSON")"
check "biobakery: no EsViritu database while it's off" "null" "$(param esviritu_db <<< "$JSON")"
# A job's own parameters, applied after pipeline.sh, as lint and the job apply them
JSON=$(pipeline_eval biobakery '{}' '{"run_esviritu": true}' | jq .params)
check "biobakery: a job that turns EsViritu on names its database" "true db:esviritu/v3.2.4" \
    "$(param run_esviritu <<< "$JSON") $(param esviritu_db <<< "$JSON")"
JSON=$(pipeline_eval biobakery '{}' '{"run_esviritu": false}' | jq .params)
check "biobakery: one that turns it off doesn't" "false null" \
    "$(param run_esviritu <<< "$JSON") $(param esviritu_db <<< "$JSON")"
JSON=$(pipeline_eval biobakery '{}' '{"run_motus": false}' | jq .params)
check "biobakery: nor one that leaves it off" "false null" \
    "$(param run_esviritu <<< "$JSON") $(param esviritu_db <<< "$JSON")"
check "biobakery: host-depleted reads without a host leave a note" "No host was removed from these reads, so there are no host-depleted reads in the download." \
    "$(with_pipeline biobakery '{"hostremoval_reference": "None", "delivered_reads": "Host Depleted"}' 'state_get notes | jq -r ".[0]"')"

check "no file in pipelines/ or lib/ names an old path" "" \
    "$(grep -rn -E 'NEXTFLOW_DIR|NEXTFLOW_DB_DIR|/data/prod' "$CODE/pipelines" "$CODE/lib")"

exit $FAILED
