// MetaPhlAn 4.1.1 taxonomic profiling, and every sample's profile merged.
//
// Pinned to 4.1.1 and the mpa_vJun23 database because HUMAnN 3.9 accepts only
// profiles that name vJun23. Profiles are written with -t rel_ab_w_read_stats
// and --unclassified_estimation, so each row carries coverage and an estimated
// read count, and relative abundance is a share of every read processed.
// Published to <outdir>/metaphlan/.

process METAPHLAN {
    tag "${meta.id}"

    container 'quay.io/biocontainers/metaphlan:4.1.1--pyhdfd78af_0'

    publishDir "${params.outdir}/metaphlan/profiles", mode: 'copy', pattern: '*.metaphlan_profile.txt'

    input:
    tuple val(meta), path(reads)
    path db

    output:
    tuple val(meta), path("${meta.id}.metaphlan_profile.txt"), emit: profile
    path "${meta.id}.marker-counts.tsv"                      , emit: counts

    script:
    def input = [reads].flatten().join(',')
    """
    # The release named by the directory when it holds that index, otherwise the
    # one index the directory holds
    INDEX=${db.name}

    if ! ls ${db}/\$INDEX.rev.1.bt2* > /dev/null 2>&1; then
        INDEX=\$(find -L ${db} -maxdepth 1 -name '*.rev.1.bt2*' \\
            | sed 's#.*/##; s#\\.rev\\.1\\.bt2.*##' | sort -u)

        if [ "\$(printf '%s\\n' "\$INDEX" | grep -c .)" -ne 1 ]; then
            echo "Expected one MetaPhlAn index in ${db}, found: \$INDEX" >&2
            exit 1
        fi
    fi

    metaphlan ${input} \\
        --input_type fastq \\
        --bowtie2db ${db} \\
        --index \$INDEX \\
        --nproc ${task.cpus} \\
        --bowtie2out ${meta.id}.bowtie2out.txt \\
        --sample_id ${meta.id} \\
        -t rel_ab_w_read_stats \\
        --unclassified_estimation \\
        ${params.metaphlan_args ?: ''} \\
        -o ${meta.id}.metaphlan_profile.txt

    if [ ! -s ${meta.id}.bowtie2out.txt ]; then
        echo "MetaPhlAn wrote no bowtie2 output for ${meta.id}" >&2
        exit 1
    fi

    # The reads bowtie2 actually placed on a marker gene, which is one line
    # each: secondary alignments are left out, so a read is counted once. The
    # reads it read them from are the "#nreads" trailer, and the mean read
    # length after that is left alone.
    {
        printf 'sample\\treads\\tmarker_reads\\n'

        awk -v sample=${meta.id} '
            BEGIN { FS = OFS = "\\t" }

            \$1 == "#nreads" { reads = \$2; next }

            /^#/ { next }

            { aligned++ }

            END { print sample, reads + 0, aligned + 0 }
        ' ${meta.id}.bowtie2out.txt
    } > ${meta.id}.marker-counts.tsv

    rm -f ${meta.id}.bowtie2out.txt
    """

    stub:
    """
    {
        printf '#mpa_vJun23_CHOCOPhlAnSGB_202403\\n'
        printf '#metaphlan stub\\n'
        printf '#2000 reads processed\\n'
        printf '#SampleID\\t${meta.id}\\n'
        printf '#estimated_reads_mapped_to_known_clades:1500\\n'
        printf '#clade_name\\tclade_taxid\\trelative_abundance\\tcoverage\\testimated_number_of_reads_from_the_clade\\n'
        printf 'UNCLASSIFIED\\t-1\\t25.0\\t-\\t500\\n'
        printf 'k__Bacteria\\t2\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota\\t2|1239\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia\\t2|1239|186801\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales\\t2|1239|186801|186802\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae\\t2|1239|186801|186802|186803\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia\\t2|1239|186801|186802|186803|572511\\t75.0\\t-\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia|s__Blautia_obeum\\t2|1239|186801|186802|186803|572511|40520\\t75.0\\t12.5\\t1500\\n'
        printf 'k__Bacteria|p__Bacillota|c__Clostridia|o__Eubacteriales|f__Lachnospiraceae|g__Blautia|s__Blautia_obeum|t__SGB4810\\t2|1239|186801|186802|186803|572511|40520|\\t75.0\\t12.5\\t1500\\n'
    } > ${meta.id}.metaphlan_profile.txt

    {
        printf 'sample\\treads\\tmarker_reads\\n'
        printf '${meta.id}\\t2000\\t120\\n'
    } > ${meta.id}.marker-counts.tsv
    """
}

// The per-sample profiles as one table of estimated read counts and one of
// relative abundances, sample by column, with every rank and UNCLASSIFIED
// (metaphlan-*), and both again restricted to species rows and UNCLASSIFIED
// (species-*). The SGB read counts are written as classic tabular, JSON
// (BIOM 1.0) and HDF5 (BIOM 2.1) tables carrying the SGB phylogeny MetaPhlAn
// ships, pruned to those SGBs and also written on its own (taxa-*), by
// bin/metaphlan_sgb_biom.py.
process METAPHLAN_MERGE {
    container 'quay.io/biocontainers/metaphlan:4.1.1--pyhdfd78af_0'

    publishDir "${params.outdir}/metaphlan", mode: 'copy'

    input:
    path profiles, stageAs: 'profiles/*'
    path counts  , stageAs: 'counts/*'

    output:
    path 'read-counts.tsv'     , emit: read_counts
    path 'metaphlan-counts.tsv', emit: counts
    path 'metaphlan-relab.tsv' , emit: relab
    path 'species-counts.tsv'  , emit: species_counts
    path 'species-relab.tsv'   , emit: species_relab
    path 'taxa-counts.*'       , emit: taxa
    path 'taxa-tree.newick'    , emit: tree, optional: true

    script:
    """
    # One row per sample: the reads MetaPhlAn read, and the reads bowtie2 placed
    # on one of its marker genes
    {
        head -q -n 1 counts/*.marker-counts.tsv | head -n 1
        tail -q -n +2 counts/*.marker-counts.tsv | LC_ALL=C sort
    } > read-counts.tsv

    # merge_metaphlan_tables.py names each column after its file, so each
    # profile is linked in under its sample name
    mkdir named

    for profile in profiles/*.metaphlan_profile.txt; do
        name=\${profile##*/}
        ln -s ../\$profile named/\${name%.metaphlan_profile.txt}.txt
    done

    merge_metaphlan_tables.py named/*.txt > metaphlan-relab.tsv

    # The estimated_number_of_reads_from_the_clade column in the same layout: the
    # database line, then clade_name and one column per sample. A clade a sample
    # did not report, or reported as -, is 0.
    awk -F'\\t' '
        FNR == 1 {
            version = \$0
            name = FILENAME
            sub(/.*\\//, "", name)
            sub(/\\.txt\$/, "", name)
            samples[++n] = name
        }

        /^#/ { next }

        !(\$1 in seen) { seen[\$1]; clades[++m] = \$1 }

        { reads[\$1, n] = \$5 + 0 }

        END {
            print version
            printf "clade_name"
            for (j = 1; j <= n; j++) printf "\\t%s", samples[j]
            print ""

            for (i = 1; i <= m; i++) {
                printf "%s", clades[i]
                for (j = 1; j <= n; j++) printf "\\t%d", reads[clades[i], j]
                print ""
            }
        }
    ' named/*.txt > metaphlan-counts.tsv

    for unit in counts relab; do
        awk -F'\\t' 'NR <= 2 || \$1 == "UNCLASSIFIED" || (\$1 ~ /\\|s__/ && \$1 !~ /\\|t__/)' metaphlan-\$unit.tsv \\
            > species-\$unit.tsv
    done

    metaphlan_sgb_biom.py metaphlan-counts.tsv taxa-counts taxa-tree.newick
    """
}
