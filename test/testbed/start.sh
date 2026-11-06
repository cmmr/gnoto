#!/bin/bash
#
# start.sh - Starts munge, slurmctld and slurmd in the gnoto test bed.
#
# The container's entrypoint. Docker's --init process is PID 1 and reaps
# orphans, as init does on a real host.

set -euo pipefail

# cgroup v2 allows processes only in leaf cgroups, so move everything already
# running out of the root before slurmd delegates controllers below it
mkdir -p /sys/fs/cgroup/init
for PID in $(cat /sys/fs/cgroup/cgroup.procs); do
    echo "$PID" > /sys/fs/cgroup/init/cgroup.procs 2> /dev/null || :
done
for CONTROLLER in $(cat /sys/fs/cgroup/cgroup.controllers); do
    echo "+$CONTROLLER" > /sys/fs/cgroup/cgroup.subtree_control
done

if [[ ! -f /etc/munge/munge.key ]]; then
    runuser -u munge -- mungekey --create
fi
mkdir -p /run/munge
chown munge:munge /run/munge
runuser -u munge -- /usr/sbin/munged

/usr/sbin/slurmctld
/usr/sbin/slurmd

exec sleep infinity
