# Dockerfile - The gnoto-dada2 image: DADA2 1.38.0 with its classifier's ties
# broken reproducibly, on the image nf-core/ampliseq runs DADA2 in, which
# DADA2_TAXONOMY runs in instead.
#
# Built by:  images/publish.sh, from CI, which publishes it to GHCR
#
# Every version is pinned:
#
#   - R, Rcpp, RcppParallel, TBB, the compilers and every other package, by the
#     digest of the image ampliseq 3.1.0's DADA2 modules name
#   - DADA2's code by its commit on cmmr/dada2's RELEASE_3_22-seeded-tie-breaks,
#     Bioconductor's 1.38.0 with one change, whose tarball is checked against
#     its SHA-256. 1.38.0's assignTaxonomy breaks an exact tie between two
#     reference taxa with a generator seeded from std::random_device, which
#     set.seed() doesn't reach, so its bootstrap confidences, and a taxon whose
#     confidence is near minBoot, vary from run to run. The change seeds a
#     generator for each sequence from R's. It's offered upstream as
#     benjjneb/dada2 pull request 2230. Move back to ampliseq's image once it
#     runs a DADA2 release with the fix.
#
# The rebuilt package replaces the image's own, and still reports 1.38.0.
# A rebuild isn't the same image byte for byte, so the digest it's published
# with is its identity.

FROM community.wave.seqera.io/library/bioconductor-dada2_r-base_r-digest_tbb:38acac09bac46f36@sha256:44d1e1927575a4e623759b68820caba070262704a5ac406781957810cf5a8314

ADD --checksum=sha256:8edfc46efa133341257d1f4da9ec88454a1cb0cdb4a4fcd5cf5ffbf09269bae7 \
    https://github.com/cmmr/dada2/archive/c54fb89731f827ca5c79fe31f4cdd84b4767fb76.tar.gz \
    /tmp/dada2.tar.gz

COPY check.R /tmp/check.R

RUN set -e && \
    tar -xzf /tmp/dada2.tar.gz -C /tmp && \
    R CMD INSTALL --library=/opt/conda/lib/R/library /tmp/dada2-c54fb89731f827ca5c79fe31f4cdd84b4767fb76 && \
    ! grep -q random_device /opt/conda/lib/R/library/dada2/libs/dada2.so && \
    Rscript /tmp/check.R && \
    rm -rf /tmp/dada2.tar.gz /tmp/dada2-* /tmp/check.R

# Links the package on GHCR to the repository
LABEL org.opencontainers.image.source="https://github.com/cmmr/gnoto"
