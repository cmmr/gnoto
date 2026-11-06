// Marker-MAGu 0.4.0 marker gene profiling of the virome: phages from the Trove
// of Gut Virus Genomes, profiled in one pass with the bacteria, archaea and
// microeukaryotes of MetaPhlAn 4's vOct22 markers.
//
// Only the viral rows are published as tables; its other calls are a small,
// older subset of what MetaPhlAn reports, and stay in markermagu-profile.tsv.
// Published to <outdir>/markermagu/: the viral feature table as virome-counts
// and virome-relab, and the long form and input read counts over everything,
// named markermagu-.

// One sample: every cleaned file at once. Marker-MAGu pools the reads it is
// given and takes no account of pairing, so mates and orphans all go in.
//
// KneadData has already trimmed the reads and removed the host, so Marker-MAGu's
// own -q (fastp) and -f (minimap2 against a filter set) are left off. Its
// wrapper drops the exit code of the script that does the work, so markermagu
// exits 0 whether it profiled the sample or stopped on its first check; the
// tables it should have written are what says which happened.
process MARKERMAGU {
    tag "${meta.id}"

    container 'quay.io/biocontainers/marker-magu:0.4.0--pyhdfd78af_1'

    publishDir "${params.outdir}/markermagu/profiles", mode: 'copy', pattern: '*.detected_species.tsv'

    input:
    tuple val(meta), path(reads)
    path db

    output:
    tuple val(meta), path("${meta.id}.detected_species.tsv"), emit: profile
    path "${meta.id}.seq_stats.tsv"                         , emit: stats
    path "${meta.id}.log"                                   , emit: log

    script:
    """
    # Empty files are left out; Marker-MAGu stops on one it cannot read
    inputs=()

    for file in ${reads}; do
        [ -n "\$(gzip -cd "\$file" | head -c 1)" ] || continue
        inputs+=("\$file")
    done

    if [ \${#inputs[@]} -eq 0 ]; then
        echo "${meta.id} has no reads for Marker-MAGu" >&2
        exit 1
    fi

    markermagu \\
        -r "\${inputs[@]}" \\
        -s ${meta.id} \\
        -o out \\
        -t ${task.cpus} \\
        --db ${db} \\
        --detection ${params.markermagu_detection} \\
        ${params.markermagu_args ?: ''}

    if [ -e out/${meta.id}_markermagu.log ]; then
        mv out/${meta.id}_markermagu.log ${meta.id}.log
    else
        touch ${meta.id}.log
    fi

    # The read counts and the profile, which is written with its header alone
    # for a sample nothing passed the thresholds in
    if [ ! -s out/${meta.id}.MM_input.seq_stats.tsv ] || [ ! -s out/${meta.id}.detected_species.tsv ]; then
        echo "Marker-MAGu wrote no tables for ${meta.id}; see ${meta.id}.log" >&2
        exit 1
    fi

    mv out/${meta.id}.MM_input.seq_stats.tsv ${meta.id}.seq_stats.tsv
    mv out/${meta.id}.detected_species.tsv ${meta.id}.detected_species.tsv

    rm -rf out
    """

    stub:
    """
    {
        printf 'file\\tformat\\ttype\\tnum_seqs\\tsum_len\\tmin_len\\tavg_len\\tmax_len\\n'
        printf '${meta.id}.MM_input.fastq\\tFASTQ\\tDNA\\t3000\\t450000\\t150\\t150.0\\t150\\n'
    } > ${meta.id}.seq_stats.tsv

    {
        printf 'lineage\\ttotal_genes\\tdetected_genes\\ttotal_length\\ttotal_aligned_reads\\tRPKM\\trel_abundance\\tsampleID\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia|s__Blautia_obeum|t__SGB99999\\t42\\t40\\t63000\\t900\\t4761.9\\t0.6\\t${meta.id}\\n'
        printf 'k__Viruses|p__Uroviricota|c__Caudoviricetes|o__Caudovirales|f__Unclassified_viruses|g__VC_1_0|s__vSGB_00001\\t7\\t7\\t8400\\t300\\t3174.6\\t0.4\\t${meta.id}\\n'
    } > ${meta.id}.detected_species.tsv

    touch ${meta.id}.log
    """
}

// Every sample's profile as one long table, and the reads each abundance was
// measured against
process MARKERMAGU_MERGE {
    container 'quay.io/biocontainers/marker-magu:0.4.0--pyhdfd78af_1'

    publishDir "${params.outdir}/markermagu", mode: 'copy'

    input:
    path profiles, stageAs: 'profiles/*'
    path stats   , stageAs: 'stats/*'

    output:
    path 'markermagu-profile.tsv', emit: profile
    path 'markermagu-input.tsv'  , emit: read_counts

    script:
    """
    # The reads Marker-MAGu read from each sample, which its RPKM is per million
    # of, off the last line of each seqkit stats table
    {
        printf 'sample\\treads\\tbases\\n'

        for file in stats/*.seq_stats.tsv; do
            name=\${file##*/}

            tail -n 1 "\$file" \\
                | awk -v sample="\${name%.seq_stats.tsv}" \\
                      'BEGIN { FS = OFS = "\\t" } { print sample, \$4, \$5 }'
        done | LC_ALL=C sort
    } > markermagu-input.tsv

    # Marker-MAGu's own combiner, which writes <directory>.combined_profile.tsv
    # into the working directory
    combine=\$(python -c 'import markermagu, os; print(os.path.dirname(markermagu.__file__))')

    Rscript "\$combine/combine_sample_tables1.R" profiles

    if [ ! -s profiles.combined_profile.tsv ]; then
        echo "combine_sample_tables1.R wrote no combined profile" >&2
        exit 1
    fi

    {
        head -n 1 profiles.combined_profile.tsv
        tail -n +2 profiles.combined_profile.tsv | LC_ALL=C sort -t \$'\\t' -k8,8 -k1,1
    } > markermagu-profile.tsv

    rm -f profiles.combined_profile.tsv
    """

    stub:
    """
    {
        printf 'sample\\treads\\tbases\\n'

        for file in stats/*.seq_stats.tsv; do
            name=\${file##*/}
            printf '%s\\t3000\\t450000\\n' "\${name%.seq_stats.tsv}"
        done
    } > markermagu-input.tsv

    {
        head -q -n 1 profiles/*.detected_species.tsv | head -n 1
        tail -q -n +2 profiles/*.detected_species.tsv
    } > markermagu-profile.tsv
    """
}

// The viral SGB rows of the long table as a feature table in three BIOM
// formats, as METAPHLAN_MERGE writes MetaPhlAn's, and the classic table again as
// percentages of each sample's viral reads. Run in the biom-format container,
// which is where biom-format, h5py and numpy are; the Marker-MAGu image has
// none of them.
process MARKERMAGU_TABLES {
    container 'quay.io/biocontainers/biom-format:2.1.17'

    publishDir "${params.outdir}/markermagu", mode: 'copy'

    input:
    path profile
    path read_counts

    output:
    path 'virome-counts.*' , emit: counts
    path 'virome-relab.tsv', emit: relab

    script:
    """
    markermagu_tables.py ${profile} ${read_counts}
    """
}
