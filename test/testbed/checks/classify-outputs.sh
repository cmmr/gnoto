#!/bin/bash
#
# classify-outputs.sh - Sorts every file three runs of one job made by how it
# repeats, for choosing a pipeline's stable-files: the test in design.md's
# "What same output means".
#
# Run by:  a developer, as any user who can read the runs, on the host or in
#          the image: bash classify-outputs.sh <results> <results again> <results at other CPUs>
#          Each is a run's results/ directory, or any directory of its files.
#          The first two ran the same job at the same slurm.max_cpus, the
#          third at another.
# Prints:  a line for each file, "<class>\t<path>\t<detail>", sorted by class:
#            stable      the same bytes in all three
#            cpus        the same in the first two, but not at other CPUs
#            unstable    different between the first two
#            missing     not in all three
#          For one that isn't stable, detail says whether it's the same once
#          its lines are sorted ("rows reordered"), or once lines that look
#          like a date or time are taken out ("timestamp"), or neither.
# Requires: sha256sum, sort, grep and gzip

set -u

[[ $# -eq 3 ]] || { sed -n '7,10p' "$0" >&2; exit 1; }
for DIR in "$@"; do
    [[ -d $DIR ]] || { echo "$DIR isn't a directory." >&2; exit 1; }
done
A=$1 B=$2 C=$3

# What a file holds, decompressed if it's gzipped
content() {
    if [[ $1 == *.gz ]]; then gzip -dc -- "$1" 2> /dev/null; else cat -- "$1"; fi
}

same() {
    [[ $(content "$1" | sha256sum) == "$(content "$2" | sha256sum)" ]]
}

sorted_same() {
    [[ $(content "$1" | LC_ALL=C sort | sha256sum) == "$(content "$2" | LC_ALL=C sort | sha256sum)" ]]
}

# Lines holding a date, a time of day, or a Unix time in milliseconds
DATED='[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}:[0-9]{2}:[0-9]{2}|(Mon|Tue|Wed|Thu|Fri|Sat|Sun),? |1[0-9]{12}'

undated_same() {
    [[ $(content "$1" | grep -Ev "$DATED" | sha256sum) == "$(content "$2" | grep -Ev "$DATED" | sha256sum)" ]]
}

why() {
    if sorted_same "$1" "$2"; then
        echo "rows reordered"
    elif undated_same "$1" "$2"; then
        echo "timestamp"
    elif [[ $(content "$1" | grep -Ev "$DATED" | LC_ALL=C sort | sha256sum) == "$(content "$2" | grep -Ev "$DATED" | LC_ALL=C sort | sha256sum)" ]]; then
        echo "timestamp, rows reordered"
    else
        echo "content"
    fi
}

{
    (cd "$A" && find . -type f -printf '%P\n')
    (cd "$B" && find . -type f -printf '%P\n')
    (cd "$C" && find . -type f -printf '%P\n')
} | LC_ALL=C sort -u | while IFS= read -r FILE; do
    if [[ ! -f $A/$FILE || ! -f $B/$FILE || ! -f $C/$FILE ]]; then
        printf 'missing\t%s\t%s\n' "$FILE" "$(for D in "$A" "$B" "$C"; do [[ -f $D/$FILE ]] && printf 'y' || printf 'n'; done)"
    elif ! same "$A/$FILE" "$B/$FILE"; then
        printf 'unstable\t%s\t%s\n' "$FILE" "$(why "$A/$FILE" "$B/$FILE")"
    elif ! same "$A/$FILE" "$C/$FILE"; then
        printf 'cpus\t%s\t%s\n' "$FILE" "$(why "$A/$FILE" "$C/$FILE")"
    else
        printf 'stable\t%s\t\n' "$FILE"
    fi
done | LC_ALL=C sort -t $'\t' -k1,1 -k2,2
