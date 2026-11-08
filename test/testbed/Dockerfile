# Dockerfile - A single-node Slurm cluster with Apptainer, for testing gnoto
# before the real cluster.
#
# Built and run by test/testbed/testbed.sh. Runs privileged, so Apptainer gets
# FUSE and user namespaces and slurmd gets its own cgroup tree. Slurm is built
# in a separate stage, so the host side keeps only Slurm, Apptainer and the base
# image's Unix tools, as a cluster would.

FROM rockylinux/rockylinux:10.2@sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834 AS slurm

ARG SLURM_VERSION=26.05.5
ARG SLURM_SHA256=4680cafc82b0689865c885eb703441e7ebf764896c40fd03a50f2fcb60664f68

RUN dnf -y install epel-release dnf-plugins-core \
    && dnf config-manager --set-enabled crb \
    && dnf -y install gcc make bzip2 perl python3 munge-devel readline-devel dbus-devel \
        kernel-headers \
    && dnf clean all

RUN curl -fsSL -o /tmp/slurm.tar.bz2 \
        "https://download.schedmd.com/slurm/slurm-$SLURM_VERSION.tar.bz2" \
    && echo "$SLURM_SHA256  /tmp/slurm.tar.bz2" | sha256sum -c \
    && mkdir /tmp/slurm && tar -xjf /tmp/slurm.tar.bz2 -C /tmp/slurm --strip-components 1 \
    && cd /tmp/slurm \
    && ./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc/slurm > /dev/null \
    && make -j"$(nproc)" > /dev/null \
    && make install DESTDIR=/out > /dev/null


FROM rockylinux/rockylinux:10.2@sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834

ARG APPTAINER_VERSION=1.5.5
ARG APPTAINER_SHA256=e0247700d633f520a22ba43e5cd2a5dcf621ec82ac6496716ed040d95eca575d

RUN dnf -y install epel-release \
    && dnf -y install munge readline dbus-libs procps-ng util-linux hostname git-core \
    && curl -fsSL -o /tmp/apptainer.rpm \
        "https://github.com/apptainer/apptainer/releases/download/v$APPTAINER_VERSION/apptainer-$APPTAINER_VERSION-1.el10.x86_64.rpm" \
    && echo "$APPTAINER_SHA256  /tmp/apptainer.rpm" | sha256sum -c \
    && dnf -y install /tmp/apptainer.rpm \
    && rm /tmp/apptainer.rpm \
    && dnf clean all

COPY --from=slurm /out/ /

RUN groupadd -r slurm && useradd -r -g slurm -d /var/spool/slurmctld -s /sbin/nologin slurm \
    && groupadd -g 2000 gnoto \
    && useradd -m -u 2001 -G gnoto alice \
    && useradd -m -u 2002 -G gnoto bob \
    && mkdir -p /etc/slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm \
    && chown slurm:slurm /var/spool/slurmctld /var/log/slurm

COPY slurm.conf cgroup.conf /etc/slurm/
COPY start.sh /usr/local/sbin/start.sh

ENTRYPOINT ["/bin/bash", "/usr/local/sbin/start.sh"]
