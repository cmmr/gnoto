// Host depletion ahead of KneadData: one sequencing run's reads aligned with
// bowtie2 2.5.4, the version in KneadData's own image, against one host index.
// Every read is aligned on its own, as KneadData's strict mode aligns them, and
// a pair is removed when either mate aligns.
//
// Two passes: host_prefilter_bowtie2_options (end to end) over every read, then
// host_bowtie2_options (--very-sensitive-local, KneadData's default) over the
// pairs the first pass left. The second pass decides what is kept; the first
// removes what the second would also remove, so that the second reads less.
//
// The reads kept are the input records unchanged, named <sample>_<run>_{1,2}.fq.gz
// as raw-sequences/ names them, and published to host_depleted_outdir, as
// symlinks into the work directory, when it is set. <sample>_<run>.host.tsv
// counts them for KNEADDATA's log, in pairs for paired reads:
//
//   index    the bowtie2 index's name
//   input    reads given
//   pass1    removed by the first pass
//   pass2    removed by the second
//   kept     left

process HOST_DEPLETION {
    tag "${meta.id} ${meta.run}"

    container 'community.wave.seqera.io/library/bowtie2_htslib_samtools_pigz:edeb13799090a2a6'

    publishDir "${params.host_depleted_outdir}", mode: 'symlink', pattern: '*.fq.gz',
        enabled: params.host_depleted_outdir as boolean

    input:
    tuple val(meta), path(fastq_1, stageAs: 'raw/1/*'), path(fastq_2, stageAs: 'raw/2/*')
    path db

    output:
    tuple val(meta), path("${meta.id}_${meta.run}_[12].fq.gz"), path("${meta.id}_${meta.run}.host.tsv"), emit: reads

    script:
    def prefix = "${meta.id}_${meta.run}"
    def fields = meta.single_end ? 4 : 8
    """
    set -o pipefail

    index=\$(find -L ${db}/ -maxdepth 1 -name '*.rev.1.bt2*' | head -n 1)
    index=\${index%.rev.1.bt2*}

    if [ -z "\$index" ]; then
        echo "No bowtie2 index in ${db}" >&2
        exit 1
    fi

    # Each read as one line of its four, a pair as both mates on one line
    records() {
        paste <(gzip -cdf ${fastq_1} | paste - - - -) ${meta.single_end ? '' : "<(gzip -cdf ${fastq_2} | paste - - - -)"}
    }

    # The reads of every pair, or of the pairs a flags file marks 1, as FASTQ
    # with each pair's mates one after the other
    reads_for() {
        records | awk -F '\\t' -v flags="\$1" -v fields=${fields} '
            NF != fields || substr(\$1, 1, 1) != "@" || (fields == 8 && substr(\$5, 1, 1) != "@") {
                print "Malformed FASTQ, or mates out of step, at read " NR > "/dev/stderr"
                exit 1
            }

            flags != "" {
                if ((getline keep < flags) <= 0) {
                    print "Fewer flags than reads at read " NR > "/dev/stderr"
                    exit 1
                }

                if (keep != 1) next
            }

            { for (i = 1; i <= NF; i++) print \$i }
        '
    }

    # One line per pair from bowtie2 output in input order: 1 when no mate aligned
    flags() {
        cut -f 2 | awk -v mates=${meta.single_end ? 1 : 2} '
            { unaligned = int(\$1 / 4) % 2 }
            mates == 1 { print unaligned; next }
            NR % 2 { first = unaligned; next }
            { print (first && unaligned) ? 1 : 0 }
        '
    }

    # bowtie2 over the reads one pass is given, into the flags file it writes
    align() {
        local flags_in="\$1" flags_out="\$2" log="\$3"
        shift 3

        reads_for "\$flags_in" \\
            | bowtie2 -p ${task.cpus} --reorder --no-hd "\$@" -x "\$index" -U - 2> "\$log" \\
            | flags > "\$flags_out"

        cat "\$log" >&2
    }

    align "" pass1.flags pass1.log ${params.host_prefilter_bowtie2_options}
    align pass1.flags pass2.flags pass2.log ${params.host_bowtie2_options}

    # The pairs both passes left
    awk -v second=pass2.flags '
        \$1 == 1 {
            if ((getline keep < second) <= 0) exit 1
            print keep
            next
        }

        { print 0 }

        END { if ((getline keep < second) > 0) exit 1 }
    ' pass1.flags > keep.flags

    # One mate's records for the pairs kept, unchanged
    write() {
        paste keep.flags <(gzip -cdf "\$1" | paste - - - -) \\
            | awk -F '\\t' '
                NF != 5 || \$1 == "" || substr(\$2, 1, 1) != "@" { exit 1 }
                \$1 == 1 { print \$2; print \$3; print \$4; print \$5 }
            ' \\
            | pigz -p ${task.cpus} > "\$2"
    }

    write ${fastq_1} ${prefix}_1.fq.gz &
    one=\$!

    ${meta.single_end ? '' : "write ${fastq_2} ${prefix}_2.fq.gz &"}
    ${meta.single_end ? '' : 'two=$!'}

    wait \$one
    ${meta.single_end ? '' : 'wait $two'}

    awk -v OFS='\\t' -v name="\${index##*/}" '
        FILENAME == "pass1.flags" { input++; if (\$1 == 0) pass1++; next }
        FILENAME == "pass2.flags" { if (\$1 == 0) pass2++; next }
        \$1 == 1 { kept++ }

        END {
            print "index", name
            print "input", input + 0
            print "pass1", pass1 + 0
            print "pass2", pass2 + 0
            print "kept", kept + 0
        }
    ' pass1.flags pass2.flags keep.flags > ${prefix}.host.tsv

    rm -f pass1.flags pass2.flags keep.flags pass1.log pass2.log
    """

    stub:
    def prefix = "${meta.id}_${meta.run}"
    """
    gzip -cdf ${fastq_1} | gzip > ${prefix}_1.fq.gz
    ${meta.single_end ? '' : "gzip -cdf ${fastq_2} | gzip > ${prefix}_2.fq.gz"}

    printf 'index\\tstub\\ninput\\t%d\\npass1\\t0\\npass2\\t0\\nkept\\t%d\\n' \\
        \$(( \$(gzip -cdf ${fastq_1} | wc -l) / 4 )) \$(( \$(gzip -cdf ${fastq_1} | wc -l) / 4 )) \\
        > ${prefix}.host.tsv
    """
}
