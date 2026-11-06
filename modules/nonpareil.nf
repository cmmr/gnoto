// Nonpareil 3.5.5 redundancy curves: how much of each community the reads
// cover, the sequence diversity Nd, and the sequencing 95% coverage would take.
// Needs no database. Published to <outdir>/nonpareil/.

// One curve per sample, over the first mate of KneadData's pairs, or over a
// single-end sample's reads. -R is the task's memory, which k-mer mode fills.
process NONPAREIL {
    tag "${meta.id}"

    container 'quay.io/biocontainers/nonpareil:3.5.5--r43hdcf5f25_0'

    publishDir "${params.outdir}/nonpareil", mode: 'copy', pattern: '*.npo'

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("${meta.id}.npo"), emit: npo

    script:
    def memory = task.memory ? task.memory.toMega() : 1024
    """
    input=()

    for file in ${reads}; do
        if ${meta.single_end}; then
            input+=("\$file")
            continue
        fi

        case "\${file%.gz}" in
            *unmatched[._][12].fastq|*single[._][12].fastq) ;;
            *[._]1.fastq) input+=("\$file") ;;
        esac
    done

    if [ \${#input[@]} -eq 0 ]; then
        echo "${meta.id} has no first-mate or single-end reads for Nonpareil" >&2
        exit 1
    elif [ \${#input[@]} -eq 1 ]; then
        ln -s "\${input[0]}" reads.fastq.gz
    else
        cat "\${input[@]}" > reads.fastq.gz
    fi

    nonpareil \\
        -s reads.fastq.gz \\
        -f fastq \\
        -T ${params.nonpareil_mode} \\
        -t ${task.cpus} \\
        -R ${memory} \\
        -b ${meta.id} \\
        ${params.nonpareil_args ?: ''}

    rm -f reads.fastq.gz ${meta.id}.npa ${meta.id}.npc
    """

    stub:
    """
    touch ${meta.id}.npo
    """
}

// Every curve fitted and summarised together, each labelled with its sample:
// the summary table, the curves as JSON for MultiQC, and one plot of them all
process NONPAREIL_CURVES {
    container 'quay.io/biocontainers/nonpareil:3.5.5--r43hdcf5f25_0'

    publishDir "${params.outdir}/nonpareil", mode: 'copy'

    input:
    path npos, stageAs: 'npo/*'

    output:
    path 'nonpareil-curves.tsv' , emit: tsv
    path 'nonpareil-curves.json', emit: json, optional: true
    path 'nonpareil-curves.pdf' , emit: pdf, optional: true

    script:
    """
    # Each curve labelled with its sample, in the order the files are given
    labels=()

    for npo in npo/*.npo; do
        name=\${npo##*/}
        labels+=("\${name%.npo}")
    done

    NonpareilCurves.R \\
        --labels "\$(IFS=,; printf '%s' "\${labels[*]}")" \\
        --tsv nonpareil-curves.tsv \\
        --json nonpareil-curves.json \\
        --pdf nonpareil-curves.pdf \\
        npo/*.npo
    """

    stub:
    """
    {
        printf 'kappa\\tC\\tLR\\tmodelR\\tLRstar\\tdiversity\\n'

        for npo in npo/*.npo; do
            name=\${npo##*/}
            printf '%s\\t0.62\\t0.71\\t1500000000\\t0.998\\t8200000000\\t18.4\\n' "\${name%.npo}"
        done
    } > nonpareil-curves.tsv
    """
}
