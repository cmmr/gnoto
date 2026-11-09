// MultiQC over whatever reports the enabled modules wrote. Published to
// <outdir>/multiqc/.

process MULTIQC {
    container 'quay.io/biocontainers/multiqc@sha256:b65e3fe879df27b92334dda0fd987a6e21bdee09a2848551d4f287099a93b7ac' // quay.io/biocontainers/multiqc:1.35--pyhdfd78af_1

    publishDir "${params.outdir}/multiqc", mode: 'copy'

    input:
    path reports, stageAs: 'reports/?/*'

    output:
    path 'multiqc_report.html', emit: report
    path 'multiqc_data'       , emit: data, optional: true

    script:
    """
    multiqc --force --filename multiqc_report.html reports
    """

    stub:
    """
    touch multiqc_report.html
    """
}
