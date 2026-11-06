// EsViritu 1.3.3 detection of human, animal and plant viruses by read mapping,
// and every sample's tables joined with summarize_esv_runs.
//
// Needs a database of v3.1.0 or later. KneadData has already trimmed the reads
// and removed the host, so EsViritu's own filters (-q, -f) are left off.
// Published to <outdir>/esviritu/.

// One sample: KneadData's mates as -p paired, or a single-end sample's reads as
// -p unpaired. Orphans are left out, since EsViritu takes one layout per call.
//
// EsViritu exits 0 without writing its tables both when no read aligns to a
// virus and when it stops on an error, so the log tells the two apart. A sample
// with no virus emits only its read counts. The HTML reports read the dataui R
// package, which EsViritu installs from its own copy on first use, into a
// library in the task directory.
process ESVIRITU {
    tag "${meta.id}"

    container 'quay.io/biocontainers/esviritu:1.3.3--pyhdfd78af_0'

    publishDir "${params.outdir}/esviritu/consensus", mode: 'copy', pattern: '*.consensus.fasta'

    input:
    tuple val(meta), path(reads)
    path db

    output:
    tuple val(meta), path('results/*'), emit: results
    path "${meta.id}.consensus.fasta" , emit: consensus, optional: true
    path "${meta.id}.log"             , emit: log

    script:
    """
    forward=()
    reverse=()
    single=()

    for file in ${reads}; do
        if ${meta.single_end}; then
            single+=("\$file")
            continue
        fi

        case "\${file%.gz}" in
            *unmatched[._][12].fastq|*single[._][12].fastq) ;;
            *[._]1.fastq) forward+=("\$file") ;;
            *[._]2.fastq) reverse+=("\$file") ;;
        esac
    done

    # One file per mate, as EsViritu takes them
    combine() {
        local out=\$1
        shift

        if [ \$# -eq 1 ]; then
            ln -s "\$1" "\$out"
        else
            cat "\$@" > "\$out"
        fi
    }

    if [ \${#single[@]} -gt 0 ]; then
        layout=unpaired
        combine reads.fastq.gz "\${single[@]}"
        inputs=(reads.fastq.gz)
    elif [ \${#forward[@]} -gt 0 ] && [ \${#forward[@]} -eq \${#reverse[@]} ]; then
        layout=paired
        combine reads_1.fastq.gz "\${forward[@]}"
        combine reads_2.fastq.gz "\${reverse[@]}"
        inputs=(reads_1.fastq.gz reads_2.fastq.gz)
    else
        echo "${meta.id} has no paired or single-end reads for EsViritu" >&2
        exit 1
    fi

    mkdir Rlib
    export R_LIBS=\$PWD/Rlib

    status=0

    EsViritu \\
        -r "\${inputs[@]}" \\
        -p \$layout \\
        -s ${meta.id} \\
        -o out \\
        -t ${task.cpus} \\
        --db ${db} \\
        ${params.esviritu_args ?: ''} \\
        || status=\$?

    if [ -e out/${meta.id}_esviritu.log ]; then
        mv out/${meta.id}_esviritu.log ${meta.id}.log
    else
        touch ${meta.id}.log
    fi

    if [ ! -s out/${meta.id}_esviritu.readstats.yaml ]; then
        echo "EsViritu stopped before counting the reads of ${meta.id} (exit \$status); see ${meta.id}.log" >&2
        exit 1
    fi

    # The taxonomic profile is the last table EsViritu writes; after it come only
    # the HTML report and the removal of its temporary files
    if [ ! -s out/${meta.id}.tax_profile.tsv ]; then
        if ! grep -qE 'No reads aligned to the EsViritu DB|CoverM-like table is empty' ${meta.id}.log; then
            echo "EsViritu wrote no tables for ${meta.id} (exit \$status); see ${meta.id}.log" >&2
            exit 1
        fi

        echo "No read of ${meta.id} aligned to a virus in the database" >&2
    elif [ \$status -ne 0 ]; then
        echo "EsViritu exited \$status after writing the tables for ${meta.id}; its HTML report may be missing" >&2
    fi

    mkdir results

    for file in out/${meta.id}.*.tsv out/${meta.id}_esviritu.*.yaml; do
        if [ -e "\$file" ]; then
            mv "\$file" results/
        fi
    done

    if [ -s out/${meta.id}_final_consensus.fasta ]; then
        mv out/${meta.id}_final_consensus.fasta ${meta.id}.consensus.fasta
    fi

    rm -rf out reads.fastq.gz reads_1.fastq.gz reads_2.fastq.gz Rlib
    """

    stub:
    """
    mkdir results

    printf 'reads for EsViritu denominator: 3000\\n' > results/${meta.id}_esviritu.readstats.yaml
    printf 'spthresh: 0.9\\nsubspthresh: 0.95\\n' > results/${meta.id}_esviritu.params.yaml

    {
        printf 'sample_ID\\tfiltered_reads_in_sample\\tkingdom\\tphylum\\ttclass\\torder\\tfamily\\tgenus\\tspecies\\tsubspecies\\tread_count\\tRPKMF\\tavg_read_identity\\tconsensus_ref_identity\\tassembly_list\\n'
        printf '${meta.id}\\t3000\\tk__Viruses\\tp__Pisuviricota\\tc__Pisoniviricetes\\to__Picornavirales\\tf__Secoviridae\\tg__Sequivirus\\ts__Sequivirus pastinacae\\tt__Parsnip yellow fleck virus\\t800\\t16884.5\\t0.993\\t1.0\\tset:D14066\\n'
    } > results/${meta.id}.tax_profile.tsv

    printf '>D14066.1_${meta.id}_consensus\\nACGT\\n' > ${meta.id}.consensus.fasta
    touch ${meta.id}.log
    """
}

// Every sample's tables as one of each, sorted by sample, under this pipeline's
// names: read-counts.tsv for every sample, and the virus tables and HTML report
// for the samples in which EsViritu found a virus
process ESVIRITU_SUMMARY {
    container 'quay.io/biocontainers/esviritu:1.3.3--pyhdfd78af_0'

    publishDir "${params.outdir}/esviritu", mode: 'copy'

    input:
    path results, stageAs: 'esviritu/*'

    output:
    path 'read-counts.tsv'  , emit: read_counts
    path 'virus-*.tsv'      , emit: tables, optional: true
    path 'virus-report.html', emit: report, optional: true

    script:
    """
    mkdir Rlib
    export R_LIBS=\$PWD/Rlib

    summarize_esv_runs esviritu --outdir summary

    if [ ! -s summary/esviritu.readstats.tsv ]; then
        echo "summarize_esv_runs wrote no read counts" >&2
        exit 1
    fi

    # A table with its rows sorted by its sample_ID column
    sorted() {
        local column

        column=\$(head -n 1 "\$1" | tr '\\t' '\\n' | grep -nx sample_ID | cut -d: -f1)

        head -n 1 "\$1"
        tail -n +2 "\$1" | LC_ALL=C sort -s -t \$'\\t' -k\$column,\$column
    }

    for table in detected_virus.info:virus-contigs detected_virus.assembly_summary:virus-assemblies \\
                 tax_profile:virus-taxa virus_coverage_windows:virus-coverage; do
        if [ -e summary/esviritu.\${table%%:*}.tsv ]; then
            sorted summary/esviritu.\${table%%:*}.tsv > \${table#*:}.tsv
        fi
    done

    # One column per read count EsViritu kept, named without spaces; the reads
    # its abundances are divided by are filtered_reads, as the tables above call
    # them
    sorted summary/esviritu.readstats.tsv \\
        | awk 'BEGIN { FS = OFS = "\\t" }
               NR == 1 {
                   for (i = 1; i <= NF; i++) {
                       if (\$i == "sample_ID") \$i = "sample"
                       else if (\$i == "reads for EsViritu denominator") \$i = "filtered_reads"
                       else gsub(/[ -]/, "_", \$i)
                   }
               }
               { print }' > read-counts.tsv

    if [ -e summary/esviritu_EsViritu_project_reactable.html ]; then
        mv summary/esviritu_EsViritu_project_reactable.html virus-report.html
    fi

    rm -rf summary Rlib
    """

    stub:
    """
    {
        printf 'sample\\tfiltered_reads\\n'

        for yaml in esviritu/*_esviritu.readstats.yaml; do
            name=\${yaml##*/}
            printf '%s\\t3000\\n' "\${name%_esviritu.readstats.yaml}"
        done
    } > read-counts.tsv

    {
        head -q -n 1 esviritu/*.tax_profile.tsv | head -n 1
        tail -q -n +2 esviritu/*.tax_profile.tsv
    } > virus-taxa.tsv
    """
}
