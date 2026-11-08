# Dockerfile - The gnoto-rbiom image: R with rbiom and h5lite, which the
# composition steps run steps/R/ in.
#
# Built by:  images/publish.sh, from CI, which publishes it to GHCR; and
#            test/testbed/testbed.sh image gnoto-rbiom, for a test of an
#            unpublished change
#
# Every version is pinned:
#
#   - Ubuntu and R by the base image's digest, rocker's build of the most recent
#     R release, which also brings R's recommended packages
#   - every other R package by pkg.lock, which pak resolved against Posit's CRAN
#     snapshot of SNAPSHOT. Its Linux binaries install without compiling.
#   - rbiom by its GitHub commit, RBIOM, because the release on CRAN, 3.1.0,
#     drops a dimension when it subsets a run of one sample. Move to CRAN, by a
#     later snapshot, once a release there has the fix.
#
# lock.sh remakes pkg.lock from these three. A rebuild isn't the same image byte
# for byte, so the digest it's published with is its identity.

FROM rocker/r-ver:4.6.2@sha256:7b0bfa4b4af875756b3e28801ad81cfcddeef713598834549bfdf12d20a80db4

ARG SNAPSHOT=2026-11-06
ARG RBIOM=cmmr/rbiom@1248db3f1f71dc8668b144947044b59f2be7e2c1

COPY pkg.lock /tmp/pkg.lock

# pak comes from the same snapshot, and goes once it has installed the rest
RUN . /etc/os-release && \
    Rscript -e "options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/__linux__/$VERSION_CODENAME/$SNAPSHOT'))" \
        -e "install.packages('pak')" \
        -e "pak::lockfile_install('/tmp/pkg.lock')" \
        -e "remove.packages('pak')" && \
    rm -rf /tmp/pkg.lock /tmp/Rtmp* /root/.cache && \
    Rscript -e "stopifnot(packageVersion('rbiom') >= '4.0.0', requireNamespace('h5lite'))"

ENV LC_ALL=C.UTF-8 TZ=UTC

# Links the package on GHCR to the repository
LABEL org.opencontainers.image.source="https://github.com/cmmr/gnoto"
