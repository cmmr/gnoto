# Dockerfile - The gnoto-kneaddata image: KneadData's code from its
# repository's master branch, on the BioContainers image of its latest release,
# which KNEADDATA, KNEADDATA_FASTQC and KNEADDATA_COUNTS run in.
#
# Built by:  images/publish.sh, from CI, which publishes it to GHCR
#
# Every version is pinned:
#
#   - Python and every tool KneadData runs, Trimmomatic, TRF, Bowtie2 and
#     FastQC, by the digest of KneadData 0.12.4's BioContainers image
#   - KneadData's own code by its commit on master, whose tarball is checked
#     against its SHA-256. 0.12.4's parallel TRF fails a sample whose reads,
#     split across --threads processes, end just as one process's share is
#     closed; master has the fix, but no release does yet. Move to the
#     BioContainers image of the first release with it, 0.12.5 or later.
#
# Master's kneaddata package replaces the release's, keeping the release's
# Trimmomatic adapters, which setup.py downloads and the repository doesn't
# hold. pip still lists 0.12.4, and kneaddata --version reports master's
# version.
# A rebuild isn't the same image byte for byte, so the digest it's published
# with is its identity.

FROM quay.io/biocontainers/kneaddata:0.12.4--pyhdfd78af_0@sha256:1be0e0706e46a831965ceb9b0c7f6bb4936a8884236e661dd1fde34fa6830937

ADD --checksum=sha256:69d79d81f45e1c050470ff28d79ac7af1f574f2f173c9f550344a3c9df33c029 \
    https://github.com/biobakery/kneaddata/archive/353d1caf1632e99a839901f67cc5ea338a70b9e8.tar.gz \
    /tmp/kneaddata.tar.gz

RUN set -e && \
    site=$(python3 -c 'import kneaddata, os; print(os.path.dirname(kneaddata.__file__))') && \
    tar -xzf /tmp/kneaddata.tar.gz -C /tmp && \
    mv "$site/adapters" /tmp/adapters && \
    rm -rf "$site" && \
    cp -r /tmp/kneaddata-353d1caf1632e99a839901f67cc5ea338a70b9e8/kneaddata "$site" && \
    rm -rf "$site/adapters" && \
    mv /tmp/adapters "$site/adapters" && \
    python3 -m compileall -q "$site" && \
    rm -rf /tmp/kneaddata.tar.gz /tmp/kneaddata-* && \
    kneaddata --version 2>&1 | grep -qx 'kneaddata v0.12.5' && \
    grep -q 'if file_handle_write is not None' "$site/trf_parallel.py"

# Links the package on GHCR to the repository
LABEL org.opencontainers.image.source="https://github.com/cmmr/gnoto"
