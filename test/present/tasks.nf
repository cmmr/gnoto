// tasks.nf - Tasks that succeed, are retried, have their error ignored, and
// fail, for test/present/progress-test.sh to read the progress of. The one
// that fails waits for the others, so the counts don't race it.

process QUICK {
    tag "sample_$i"

    input:
    val i

    output:
    val i

    script:
    """
    sleep 1
    """
}

process FLAKY {
    tag "sample_$i"
    errorStrategy { task.attempt < 2 ? 'retry' : 'terminate' }

    input:
    val i

    output:
    val i

    script:
    """
    [ ${task.attempt} -ge 2 ] || exit 7
    """
}

process IGNORED {
    errorStrategy 'ignore'

    input:
    val i

    script:
    """
    exit 5
    """
}

process FAILS {
    input:
    val i

    script:
    """
    sleep 2
    echo "Reads in ${workflow.launchDir}/raw-sequences ran out" >&2
    exit 3
    """
}

workflow {
    IGNORED(channel.of(1))
    FAILS(QUICK(channel.of(1, 2, 3)).mix(FLAKY(channel.of(1, 2))).collect())
}
