// sleep.nf - Tasks that run until they're cancelled, for the cancellation checks.

params.tasks = 3
params.seconds = 900

process SLEEP {
    container 'docker://ubuntu@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c'

    input:
    val i

    script:
    """
    sleep ${params.seconds}
    """
}

workflow {
    SLEEP(channel.of(1..params.tasks))
}
