// mOTUs 3.1.0 profiling from universal single-copy marker genes, and every
// sample's profile merged.
//
// Pinned to 3.1.0, the version taxprofiler 2.0.1 runs, because mOTUs refuses a
// database built for any other version and db_mOTU_v3.1.0 is shared with it.
// Profiles are scaled insert counts (-c) with NCBI taxon ids (-p). Published to
// <outdir>/motus/.

process MOTUS {
    tag "${meta.id}"

    container 'quay.io/biocontainers/motus:3.1.0--pyhdfd78af_0'

    publishDir "${params.outdir}/motus/profiles", mode: 'copy', pattern: '*.motus_profile.txt'

    input:
    tuple val(meta), path(reads)
    path db

    output:
    tuple val(meta), path("${meta.id}.motus_profile.txt"), emit: profile
    path "${meta.id}.log"                                , emit: log

    script:
    """
    # KneadData's mates as -f and -r, and its orphans, or a single-end sample's
    # reads, as -s. Empty files are left out.
    forward=()
    reverse=()
    single=()

    for file in ${reads}; do
        [ -n "\$(gzip -cd "\$file" | head -c 1)" ] || continue

        if ${meta.single_end}; then
            single+=("\$file")
            continue
        fi

        case "\${file%.gz}" in
            *unmatched[._][12].fastq|*single[._][12].fastq) single+=("\$file") ;;
            *[._]1.fastq) forward+=("\$file") ;;
            *[._]2.fastq) reverse+=("\$file") ;;
            *)            single+=("\$file") ;;
        esac
    done

    inputs=()
    join() { local IFS=,; printf '%s' "\$*"; }

    [ \${#forward[@]} -gt 0 ] && inputs+=(-f "\$(join "\${forward[@]}")" -r "\$(join "\${reverse[@]}")")
    [ \${#single[@]} -gt 0 ]  && inputs+=(-s "\$(join "\${single[@]}")")

    if [ \${#inputs[@]} -eq 0 ]; then
        echo "${meta.id} has no reads for mOTUs" >&2
        exit 1
    fi

    motus profile \\
        "\${inputs[@]}" \\
        -db ${db} \\
        -t ${task.cpus} \\
        -n ${meta.id} \\
        -p \\
        -c \\
        ${params.motus_args ?: ''} \\
        -o ${meta.id}.motus_profile.txt \\
        2> >(tee ${meta.id}.log >&2)
    """

    stub:
    """
    {
        printf '# git tag version 3.1.0 |  motus version 3.1.0 | map_tax 3.1.0 | gene database: nr3.1.0 | calc_mgc 3.1.0 -y insert.scaled_counts -l 75 | calc_motu 3.1.0 -k mOTU -C no_CAMI -g 3 -c -p | taxonomy: ref_mOTU_3.1.0 meta_mOTU_3.1.0\\n'
        printf '# call: python motus profile -n ${meta.id} -p -c\\n'
        printf '#consensus_taxonomy\\tNCBI_tax_id\\t${meta.id}\\n'
        printf 'Blautia obeum [ref_mOTU_v31_00001]\\t40520\\t12\\n'
        printf 'Faecalibacterium prausnitzii [ref_mOTU_v31_00002]\\t853\\t0\\n'
        printf 'unassigned\\tNA\\t3\\n'
    } > ${meta.id}.motus_profile.txt

    touch ${meta.id}.log
    """
}

// The per-sample profiles as one table, a row per cluster in the database and a
// column per sample
process MOTUS_MERGE {
    container 'quay.io/biocontainers/motus:3.1.0--pyhdfd78af_0'

    publishDir "${params.outdir}/motus", mode: 'copy'

    input:
    path profiles, stageAs: 'profiles/*'
    path db

    output:
    path 'motus-counts.tsv', emit: merged

    script:
    """
    motus merge -db ${db} -d profiles -o motus-counts.tsv
    """

    stub:
    """
    cat profiles/* > motus-counts.tsv
    """
}
