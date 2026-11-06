// HUMAnN 3.9 functional profiling: one sample from reads to its three tables,
// and every sample's tables merged, regrouped, normalised and split.
//
// Included by workflows/biobakery and workflows/humann. Both hand HUMAnN a
// MetaPhlAn profile with --taxonomic-profile, so it skips its own MetaPhlAn
// pass. Everything is published to <outdir>/humann/.

// A MetaPhlAn profile rewritten into the -t rel_ab column layout. HUMAnN 3.9
// reads the abundance from the second-to-last column, which under
// -t rel_ab_w_read_stats is coverage rather than relative abundance. Comment
// lines are kept: HUMAnN exits unless one names the vJun23 database.
process HUMANN_PREPARE_PROFILE {
    tag "${sample}"

    container 'quay.io/biocontainers/humann:3.9--py312hdfd78af_0'

    input:
    tuple val(sample), path(profile)

    output:
    tuple val(sample), path("${sample}.humann_profile.tsv")

    script:
    """
    LC_ALL=C awk -v OFS='\\t' -F'\\t' '
        /^#clade_name/ {
            for (i = 1; i <= NF; i++) {
                field = \$i
                sub(/^#/, "", field)
                column[field] = i
            }

            abundance = column["relative_abundance"]
            taxid = column["clade_taxid"] ? column["clade_taxid"] : column["NCBI_tax_id"]

            if (!abundance || !taxid) exit 1

            print "#clade_name", "NCBI_tax_id", "relative_abundance", "additional_species"
            next
        }

        /^#/ { print; next }

        abundance {
            print \$1, \$taxid, \$abundance, ""
            rows++
        }

        END { if (!rows) exit 1 }
    ' ${profile} > ${sample}.humann_profile.tsv
    """
}

// One sample, from reads to the three tables HUMAnN writes.
//
// A sample HUMAnN cannot finish is one sample's functional profile rather than a
// failed run: the calling workflow's config retries it and then ignores it, and
// the tables below are built from the samples that did finish.
process HUMANN_PROFILE {
    tag "${sample}"

    container 'quay.io/biocontainers/humann:3.9--py312hdfd78af_0'

    publishDir "${params.outdir}/humann/logs", mode: 'copy', pattern: '*.log'

    input:
    tuple val(sample), path(reads), path(profile)
    path chocophlan
    path uniref

    output:
    path "${sample}_genefamilies.tsv" , emit: genefamilies
    path "${sample}_pathabundance.tsv", emit: pathabundance
    path "${sample}_pathcoverage.tsv" , emit: pathcoverage
    path "${sample}.log"              , emit: log

    script:
    """
    # HUMAnN takes one input file. A sample's mates and its runs are separate
    # files by this point and are profiled together: HUMAnN treats every read
    # independently, so concatenating them is what pairing would otherwise be.
    cat ${reads} > ${sample}_reads.fastq.gz

    humann \\
        --input ${sample}_reads.fastq.gz \\
        --output . \\
        --output-basename ${sample} \\
        --taxonomic-profile ${profile} \\
        --nucleotide-database ${chocophlan} \\
        --protein-database ${uniref} \\
        --threads ${task.cpus} \\
        --o-log ${sample}.log \\
        --remove-temp-output

    rm -f ${sample}_reads.fastq.gz
    """

    stub:
    """
    printf '# Gene Family\\t${sample}_Abundance-RPKs\\n' > ${sample}_genefamilies.tsv
    printf '# Pathway\\t${sample}_Abundance\\n' > ${sample}_pathabundance.tsv
    printf '# Pathway\\t${sample}_Coverage\\n' > ${sample}_pathcoverage.tsv
    touch ${sample}.log
    """
}

// Every sample's tables merged, regrouped, normalised and split into the files a
// requester loads. One process because each step reads what the one before it
// wrote, and all of it is minutes against the hours above.
process HUMANN_TABLES {
    container 'quay.io/biocontainers/humann:3.9--py312hdfd78af_0'

    publishDir "${params.outdir}/humann", mode: 'copy'

    input:
    path genefamilies , stageAs: 'genefamilies/*'
    path pathabundance, stageAs: 'pathabundance/*'
    path pathcoverage , stageAs: 'pathcoverage/*'
    path logs         , stageAs: 'logs/*'
    path utility_mapping

    output:
    path "*.tsv"

    script:
    """
    # The three tables as one each, sample by column
    humann_join_tables -i genefamilies  -o gene-families-rpk.tsv     --file_name genefamilies
    humann_join_tables -i pathabundance -o pathway-abundance-rpk.tsv --file_name pathabundance
    humann_join_tables -i pathcoverage  -o pathway-coverage.tsv      --file_name pathcoverage

    # UniRef90 gene families put on the two functional vocabularies whose
    # mappings HUMAnN ships. KEGG modules and KEGG pathways are not among them -
    # those definitions are licence-restricted - so nothing here regroups to
    # them. --custom rather than --groups: the built-in options are read off a
    # utility mapping directory recorded in the container when it was built,
    # which is not where this run's copy is.
    humann_regroup_table -i gene-families-rpk.tsv \\
        -c ${utility_mapping}/map_level4ec_uniref90.txt.gz -o regrouped-ec.tsv
    humann_regroup_table -i gene-families-rpk.tsv \\
        -c ${utility_mapping}/map_ko_uniref90.txt.gz -o regrouped-ko.tsv

    # EC numbers and KO identifiers are unreadable on their own, and both name
    # maps ship inside HUMAnN itself. Gene families keep their bare UniRef90
    # accessions: naming those needs a 1 GB mapping and makes the largest table
    # here larger still.
    humann_rename_table -i regrouped-ec.tsv -n ec             -o ec-rpk.tsv
    humann_rename_table -i regrouped-ko.tsv -n kegg-orthology -o ko-rpk.tsv

    rm -f regrouped-ec.tsv regrouped-ko.tsv

    # Relative abundance beside every table that carries a rate. Pathway coverage
    # is a confidence between 0 and 1 rather than an amount, and is not
    # normalised.
    for table in gene-families ec ko pathway-abundance; do
        humann_renorm_table -i \$table-rpk.tsv -o \$table-relab.tsv \\
            --units relab --mode community --update-snames
    done

    # Each table twice: the community totals, and the same numbers broken out by
    # the species HUMAnN attributed them to.
    mkdir -p split

    for table in gene-families-rpk gene-families-relab ec-rpk ec-relab \\
                 ko-rpk ko-relab pathway-abundance-rpk pathway-abundance-relab \\
                 pathway-coverage; do
        humann_split_stratified_table -i \$table.tsv -o split
        mv split/\${table}_unstratified.tsv \$table.tsv
        mv split/\${table}_stratified.tsv   \$table-by-taxon.tsv
    done

    rmdir split

    # Sample columns as the sample names, which is how every other table this
    # pipeline publishes is keyed. HUMAnN appends what the column measures to
    # each one - "_Abundance-RPKs", "_Abundance-RELAB", "_Abundance",
    # "_Coverage" - and the file name says that already.
    for table in *.tsv; do
        awk 'BEGIN { FS = OFS = "\\t" }
             NR == 1 {
                 for (i = 2; i <= NF; i++)
                     sub(/_(Abundance|Coverage)(-[A-Za-z]+)?\$/, "", \$i)
             }
             { print }' "\$table" > renamed.tsv && mv renamed.tsv "\$table"
    done

    # What HUMAnN could do with each sample, off the log it wrote: how many
    # species the prescreen put in that sample's pangenome database, and what
    # share of its reads was still unaligned after each of the two search tiers.
    # A sample whose translated search never ran leaves that column empty.
    {
        printf 'sample\\tprescreen_species\\tunaligned_after_nucleotide_pct'
        printf '\\tunaligned_after_translated_pct\\tgene_families\\n'

        for log in logs/*.log; do
            sample=\${log##*/}
            sample=\${sample%.log}

            awk -v sample="\$sample" '
                BEGIN { OFS = "\\t" }

                # Each log line is "<timestamp> - <module> - INFO: <message>",
                # and the message itself ends in ": <number>", so the reading is
                # the last colon-separated field rather than the second.
                function value(text,   parts, n) {
                    n = split(text, parts, ": ")
                    gsub(/[ %]/, "", parts[n])
                    return parts[n]
                }

                /Total species selected from prescreen/          { species = value(\$0) }
                /Unaligned reads after nucleotide alignment/     { nucleotide = value(\$0) }
                /Unaligned reads after translated alignment/     { translated = value(\$0) }
                /Total gene families from nucleotide alignment/  { families = value(\$0) }
                /Total gene families after translated alignment/ { families = value(\$0) }

                END { print sample, species, nucleotide, translated, families }
            ' "\$log"
        done
    } > alignment-summary.tsv
    """

    stub:
    """
    for table in gene-families ec ko pathway-abundance; do
        printf '# Gene Family\\n' > \$table-rpk.tsv
        printf '# Gene Family\\n' > \$table-relab.tsv
    done
    printf '# Pathway\\n' > pathway-coverage.tsv
    printf 'sample\\tprescreen_species\\tunaligned_after_nucleotide_pct\\tunaligned_after_translated_pct\\tgene_families\\n' > alignment-summary.tsv
    """
}
