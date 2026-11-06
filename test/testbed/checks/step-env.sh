#!/bin/bash
#
# step-env.sh - Prints what a step container sees: its environment, R's locale
# and the time zone. Two users running it should get the same output.
#
# Run by:  a developer, as each user in turn, after ampliseq-16s-v4.sh has
#          cached the phyloseq image, which has R:
#          gnoto exec bash <install>/test/testbed/checks/step-env.sh > <user>.txt
#
# Runs inside the image. Calls apptainer through the stand-in with the flags
# lib/containers.sh will use: --cleanenv --no-home, LC_ALL=C.UTF-8 and TZ=UTC.

set -euo pipefail

IMAGE=$(ls "$GNOTO_DATA_DIR"/images/*bioconductor-phyloseq* | head -1)
echo "image: ${IMAGE##*/}"

cd "$GNOTO_DATA_DIR"
apptainer exec --cleanenv --no-home --env LC_ALL=C.UTF-8 --env TZ=UTC "$IMAGE" \
    Rscript -e 'e <- Sys.getenv(); e <- e[!names(e) %in% c("PWD")]; print(e); print(Sys.getlocale()); print(Sys.timezone()); print(.libPaths())'
