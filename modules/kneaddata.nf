// KneadData 0.12.4: Trimmomatic trimming and tandem repeat removal over each
// sample's reads, once HOST_DEPLETION (modules/host_depletion.nf) has removed
// the host from each of its runs, or over its raw reads when no host is
// depleted. FastQC reports on the raw reads (KNEADDATA_FASTQC) and on what
// KneadData keeps, and every sample's read counts are one table. Published to
// <outdir>/kneaddata/.
//
// A sample with no reads to start with, or none left after host depletion,
// trimming or repeat removal, exits 10, which conf/base.config drops from the
// run.

// One sample's runs, host-depleted or raw, with HOST_DEPLETION's summary of
// each run when there are any. The cleaned reads are named as KneadData names
// them after a host step - <sample>_paired_{1,2}, <sample>_unmatched_{1,2} and
// <sample> for single-end reads - and are also published to cleaned_outdir,
// when it is set, as <sample>_{1,2}.fq.gz and <sample>_orphans.fq.gz, symlinks
// into the work directory.
process KNEADDATA {
    tag "${meta.id}"

    container 'quay.io/biocontainers/kneaddata:0.12.4--pyhdfd78af_0'

    publishDir "${params.outdir}/kneaddata/logs", mode: 'copy', pattern: '*.log'
    publishDir "${params.outdir}/kneaddata", mode: 'copy', pattern: 'fastqc/*.{html,zip}'
    publishDir "${params.cleaned_outdir}", mode: 'symlink', pattern: 'deliver/*.fq.gz',
        saveAs: { name -> name.tokenize('/').last() }, enabled: params.cleaned_outdir as boolean

    input:
    tuple val(meta), path(fastq_1, stageAs: 'reads/1/?/*'), path(fastq_2, stageAs: 'reads/2/?/*'), path(host, stageAs: 'host/*')

    output:
    tuple val(meta), path('clean/*.fastq.gz'), emit: reads
    path "${meta.id}.log"                    , emit: log
    path 'fastqc/*.zip'                      , emit: fastqc, optional: true
    path 'fastqc/*.html'                     , emit: fastqc_html, optional: true
    path 'deliver/*.fq.gz'                   , emit: delivered, optional: true

    script:
    def id       = meta.id
    def input    = meta.single_end ? "--unpaired ${id}_R1.fastq" : "--input1 ${id}_R1.fastq --input2 ${id}_R2.fastq"
    def heap     = task.memory ? "--max-memory ${(task.memory.toMega() * 3 / 4) as long}m" : ''
    def depleted = host ? true : false
    """
    no_reads() {
        echo "${id} has no reads \$1; dropping it from the run" >&2
        exit 10
    }

    # One field of HOST_DEPLETION's summaries, summed over the sample's runs
    host_sum() {
        awk -F '\\t' -v key="\$1" '\$1 == key { n += \$2 } END { print n + 0 }' host/*.host.tsv
    }

    # A sample's runs, in samplesheet order, as one file per mate, with the
    # identifiers KneadData would otherwise copy the whole sample to rewrite
    set -o pipefail
    gzip -cdf ${fastq_1} | kneaddata_identifiers.py 1 > ${id}_R1.fastq
    ${meta.single_end ? '' : "gzip -cdf ${fastq_2} | kneaddata_identifiers.py 2 > ${id}_R2.fastq"}

    if [ ! -s ${id}_R1.fastq ]; then
        ${depleted ? 'if [ "$(host_sum input)" -gt 0 ]; then no_reads "left after host depletion"; fi' : ''}
        no_reads "to trim"
    fi

    # KneadData applies --max-memory only when it runs Trimmomatic's jar itself.
    # Found on PATH, it runs the bioconda wrapper, which caps the heap at 1 GB.
    mkdir trimmomatic
    ln -s "\$(find -L /usr/local/share -name 'trimmomatic*.jar' | head -n 1)" trimmomatic/

    status=0
    kneaddata ${input} \\
        --output out \\
        --output-prefix ${id} \\
        --threads ${task.cpus} \\
        --trimmomatic trimmomatic \\
        ${heap} \\
        --sequencer-source ${params.kneaddata_sequencer_source} \\
        --remove-intermediate-output \\
        ${params.kneaddata_args ?: ''} \\
        2> kneaddata.err || status=\$?

    cat kneaddata.err >&2

    if [ \$status -ne 0 ]; then
        if grep -q 'Trimmomatic created empty output files' kneaddata.err; then
            no_reads "left after trimming"
        fi

        exit \$status
    fi

    rm -f ${id}_R1.fastq ${id}_R2.fastq kneaddata.err

    # The files the log lists as final, renamed by type into files.txt as
    # "<type> <file>". Intermediates are left beside them in out/.
    awk '/Final output files? created/ { final = 1; next }
         final && /^\\// { print; next }
         { final = 0 }' out/${id}.log > final.txt

    : > files.txt

    while read -r path; do
        name=\${path##*/}

        case "\$name" in
            *unmatched[._][12].fastq|*single[._][12].fastq)
                type="orphan\${name: -7:1}"
                file="${id}_unmatched_\${name: -7:1}.fastq" ;;
            *[._]1.fastq) type=pair1;  file=${id}_paired_1.fastq ;;
            *[._]2.fastq) type=pair2;  file=${id}_paired_2.fastq ;;
            *)            type=single; file=${id}.fastq ;;
        esac

        mv "out/\$name" "\$file"
        printf '%s\\t%s\\n' "\$type" "\$file" >> files.txt
    done < final.txt

    if [ ! -s files.txt ]; then
        echo "KneadData listed no final files for ${id}" >&2
        exit 1
    fi

    # Repeat removal can remove every read without KneadData failing
    kept=0

    while IFS=\$'\\t' read -r type file; do
        if [ -s "\$file" ]; then
            kept=\$((kept + 1))
        fi
    done < files.txt

    if [ \$kept -eq 0 ]; then
        no_reads "left after trimming and repeat removal"
    fi

    # KneadData logs no count after Tandem Repeats Finder, so the final files
    # are counted into the log in its own READ COUNT format
    while IFS=\$'\\t' read -r type file; do
        printf 'INFO: READ COUNT: final %s : Total reads counted by the workflow in the final output ( %s ): %d.0\\n' \\
            "\$type" "\$file" \$(( \$(wc -l < "\$file") / 4 )) >> out/${id}.log
    done < files.txt
${depleted ? hostCounts(id, meta.single_end, params.host_prefilter_bowtie2_options, params.host_bowtie2_options) : ''}
    mkdir fastqc
    fastqc --threads ${task.cpus} --outdir fastqc \$(cut -f 2 files.txt)

    mkdir clean

    while IFS=\$'\\t' read -r type file; do
        gzip -1 -c "\$file" > "clean/\$file.gz"
    done < files.txt

    ls clean/*.fastq.gz > /dev/null
${params.cleaned_outdir ? delivery(id) : ''}
    cut -f 2 files.txt | xargs rm -f
    rm -f final.txt files.txt

    mv out/${id}.log ${id}.log

    # The uncompressed reads left in out/, which would otherwise stay in a work
    # directory on the shared filesystem
    rm -rf out
    """

    stub:
    """
    if [ -z "\$(gzip -cdf ${fastq_1} | head -c 1)" ]; then
        echo "${meta.id} has no reads to trim; dropping it from the run" >&2
        exit 10
    fi

    mkdir clean fastqc

    for mate in 1 2; do
        printf '@r1\\nACGT\\n+\\nIIII\\n' | gzip > clean/${meta.id}_paired_\$mate.fastq.gz
    done

    printf 'INFO: READ COUNT: raw pair1 : Initial number of reads ( x ): 2000.0\\n' > ${meta.id}.log
    printf 'INFO: READ COUNT: final pair1 : Total reads counted by the workflow in the final output ( x ): 1500.0\\n' >> ${meta.id}.log
    touch fastqc/${meta.id}_paired_1_fastqc.zip

    if ${params.cleaned_outdir ? true : false}; then
        mkdir deliver
        cp clean/${meta.id}_paired_1.fastq.gz deliver/${meta.id}_1.fq.gz
        cp clean/${meta.id}_paired_2.fastq.gz deliver/${meta.id}_2.fq.gz
    fi
    """
}

// The read counts of a sample HOST_DEPLETION depleted. KneadData read what host
// depletion kept, so what it logged as raw is the decontaminated count, and the
// raw count is the runs' own.
def hostCounts(id, single_end, prefilter_options, options) {
    def types = single_end ? 'single' : 'pair1 pair2'
    def unit  = single_end ? 'reads' : 'pairs'

    """
    db=\$(awk -F '\\t' '\$1 == "index" { print \$2; exit }' host/*.host.tsv)

    awk -v db="\$db" '
        /READ COUNT: raw / {
            sub(/READ COUNT: raw /, "READ COUNT: decontaminated " db " ")
            sub(/Initial number of reads/, "Total reads after removing those found in reference database")
        }

        { print }
    ' out/${id}.log > log.tmp

    mv log.tmp out/${id}.log

    for type in ${types}; do
        printf 'INFO: READ COUNT: raw %s : Initial number of reads ( before host depletion ): %d.0\\n' \\
            "\$type" "\$(host_sum input)" >> out/${id}.log
    done

    printf 'INFO: Host depletion against %s: %d of %d ${unit} removed by bowtie2 %s, then %d by bowtie2 %s\\n' \\
        "\$db" "\$(host_sum pass1)" "\$(host_sum input)" "${prefilter_options}" \\
        "\$(host_sum pass2)" "${options}" >> out/${id}.log
"""
}

// The cleaned reads as cleaned_outdir names them: the pairs and single-end reads
// as links to clean/ named _1 and _2, and both mates' orphans joined in one file
def delivery(id) {
    """
    mkdir deliver

    while IFS=\$'\\t' read -r type file; do
        case "\$type" in
            pair1|single) target=deliver/${id}_1.fq.gz ;;
            pair2)        target=deliver/${id}_2.fq.gz ;;
            *)
                cat "clean/\$file.gz" >> deliver/${id}_orphans.fq.gz
                continue ;;
        esac

        ln -s "../clean/\$file.gz" "\$target"
    done < files.txt
"""
}

// FastQC over each sample's reads as they were sequenced, its runs joined into
// one file per mate named as KneadData named its input: <sample>_R1 and
// <sample>_R2. A sample with no reads gets no report.
process KNEADDATA_FASTQC {
    tag "${meta.id}"

    container 'quay.io/biocontainers/kneaddata:0.12.4--pyhdfd78af_0'

    publishDir "${params.outdir}/kneaddata", mode: 'copy', pattern: 'fastqc/*.{html,zip}'

    input:
    tuple val(meta), path(fastq_1, stageAs: 'raw/1/?/*'), path(fastq_2, stageAs: 'raw/2/?/*')

    output:
    path 'fastqc/*.zip' , emit: zip, optional: true
    path 'fastqc/*.html', emit: html, optional: true

    script:
    def id = meta.id
    """
    # A mate's runs as one file, named for that mate
    join_runs() {
        local name="\$1"
        shift

        case "\$1" in
            *.gz) name="\$name.fastq.gz" ;;
            *)    name="\$name.fastq" ;;
        esac

        if [ \$# -eq 1 ]; then
            ln -s "\$1" "\$name"
        else
            cat "\$@" > "\$name"
        fi

        echo "\$name"
    }

    files=\$(join_runs ${id}_R1 ${fastq_1})
    ${meta.single_end ? '' : "files=\"\$files \$(join_runs ${id}_R2 ${fastq_2})\""}

    mkdir fastqc

    if [ -n "\$(gzip -cdf ${fastq_1} | head -c 1)" ]; then
        fastqc --threads ${task.cpus} --outdir fastqc \$files
    fi

    rm -f \$files
    """

    stub:
    """
    mkdir fastqc
    touch fastqc/${meta.id}_R1_fastqc.zip fastqc/${meta.id}_R1_fastqc.html
    """
}

// Every sample's READ COUNT log lines as one table: a row per sample, a column
// per stage and file type ("raw pair1", "decontaminated host pair1", ...)
// ordered raw, decontaminated, trimmed, final. A count a sample has no line
// for is NA. kneaddata_read_count_table is not used: it names a sample by its
// log file name up to the first dot.
process KNEADDATA_COUNTS {
    container 'quay.io/biocontainers/kneaddata:0.12.4--pyhdfd78af_0'

    publishDir "${params.outdir}/kneaddata", mode: 'copy'

    input:
    path logs, stageAs: 'logs/*'

    output:
    path 'read-counts.tsv'                , emit: table
    path 'kneaddata_read_counts_mqc.tsv'  , emit: multiqc

    script:
    """
    LC_ALL=C awk -F': ' '
        FNR == 1 {
            sample = FILENAME
            sub(/^.*\\//, "", sample)
            sub(/\\.log\$/, "", sample)
            samples[++n] = sample
        }

        /READ COUNT: / {
            type = \$0
            sub(/.*READ COUNT: /, "", type)
            sub(/ : .*/, "", type)

            if (!(type in seen)) {
                seen[type] = 1
                types[++t] = type
            }

            count[sample, type] = sprintf("%d", \$NF)
        }

        END {
            split("raw decontaminated trimmed final", stages, " ")

            for (s = 1; s <= 4; s++)
                for (i = 1; i <= t; i++)
                    if (index(types[i], stages[s] " ") == 1) order[++m] = types[i]

            printf "sample"
            for (i = 1; i <= m; i++) printf "\\t%s", order[i]
            printf "\\n"

            for (j = 1; j <= n; j++) {
                printf "%s", samples[j]
                for (i = 1; i <= m; i++)
                    printf "\\t%s", ((samples[j], order[i]) in count) ? count[samples[j], order[i]] : "NA"
                printf "\\n"
            }
        }
    ' logs/*.log > read-counts.tsv

    # The same table as a MultiQC section of its own
    {
        printf '# id: "kneaddata"\\n'
        printf '# section_name: "KneadData"\\n'
        printf '# description: "Reads per sample after each KneadData step."\\n'
        printf '# plot_type: "table"\\n'
        cat read-counts.tsv
    } > kneaddata_read_counts_mqc.tsv
    """
}
