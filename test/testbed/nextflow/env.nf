// env.nf - Records the environment a Slurm task sees on the host, before its
// container starts, and inside the container.

params.outdir = 'results'

process ENV {
    container 'docker://ubuntu@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c'
    beforeScript 'env | LC_ALL=C sort > host_env.txt'
    publishDir params.outdir, mode: 'copy'

    output:
    path '*.txt'

    script:
    """
    env | LC_ALL=C sort > container_env.txt
    """
}

workflow {
    ENV()
}
