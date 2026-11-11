#
# outputs.sh - A run's core tables: the checksums its record keeps, and how
# another run's tables compare with them.
#
# Sourced by:  lib/env.sh
# Defines:     outputs_measure, outputs_compare, outputs_summary,
#              outputs_keep_recorded, compare_tables
# Requires:    gawk, sha256sum, gzip, grep, sort and jq
# Env:         CODE_DIR, from lib/env.sh
#
# pipelines/<name>/stable-files lists a pipeline's core tables, one a line, as
# paths under results/, where * and ? match any characters, such as a sample's
# name. A line may add how the file is read for its checksum:
#
#   <path> sort             its lines in byte order, for a table whose rows
#                           come in an order that varies from run to run
#   <path> strip <regex>    without the lines that match the extended regular
#                           expression, such as one holding a timestamp
#   <path> drop <columns>   without the columns its header names, comma-separated,
#                           for values that vary with a known cause
#   <path> round <digits>   with every number rounded to that many significant
#                           digits, for sums whose last digit varies from run to run
#   <path> unordered        as a table whose columns and rows come in any order,
#                           such as samples merged in the order their tasks
#                           ended: without the lines above its header, the first
#                           line of the most fields, with every column after the
#                           first in its header's order, and its rows sorted
#
# A file ending in .gz is read decompressed, and one ending in .csv, or .csv.gz,
# is split on commas, any other on tabs. The published file is left as it is. A
# run's outputs are each matching file's path and the SHA-256 of what's read, in
# path order.
#
# Two runs' tables are identical when their checksums match. Otherwise
# compare_tables reads both, matches rows by their first field and columns by
# position, and reports the largest relative difference over every numeric
# cell, |a - b| / max(|a|, |b|), and where it is. Rows only one has, and text
# cells that differ, are counted, not compared.

# Each of a pipeline's core tables under a directory, as "<path>\t<how>\t<arg>"
# in path order
outputs_list() {
    local list=$CODE_DIR/pipelines/$1/stable-files dir=$2 pattern how arg file
    [[ -f $list ]] || return 0
    while read -r pattern how arg; do
        [[ -n $pattern && $pattern != \#* ]] || continue
        while IFS= read -r file; do
            [[ -n $file && -f $dir/$file ]] && printf '%s\t%s\t%s\n' "$file" "$how" "$arg"
        done < <(cd "$dir" 2> /dev/null && compgen -G "$pattern" || :)
    done < "$list" | LC_ALL=C sort -t $'\t' -k1,1 -u
}

# How a core table's path is read for its checksum, as "<how>\t<arg>", from the
# first line of stable-files whose pattern matches it
outputs_how() {
    local list=$CODE_DIR/pipelines/$1/stable-files path=$2 pattern how arg
    [[ -f $list ]] || return 0
    while read -r pattern how arg; do
        [[ -n $pattern && $pattern != \#* ]] || continue
        # shellcheck disable=SC2053
        if [[ $path == $pattern ]]; then
            printf '%s\t%s' "$how" "$arg"
            return 0
        fi
    done < "$list"
}

# A core table's text, as its checksum is taken: outputs_read <file> <how> <arg>
outputs_read() {
    local file=$1 how=${2:-} arg=${3:-} status=0 sep=$'\t'
    [[ $file != *.csv && $file != *.csv.gz ]] || sep=,
    {
        if [[ $file == *.gz ]]; then gzip -dc -- "$file"; else cat -- "$file"; fi
    } | case $how in
        "") cat ;;
        sort) LC_ALL=C sort ;;
        strip) grep -Ev -- "$arg" || status=$?; (( status <= 1 )) ;;
        drop)
            gawk -F "$sep" -v OFS="$sep" -v names="$arg" '
                NR == 1 {
                    n = split(names, list, ",")
                    for (i = 1; i <= n; i++) gone[list[i]] = 1
                    for (i = 1; i <= NF; i++) if ($i in gone) skip[i] = 1
                }
                {
                    line = ""
                    kept = 0
                    for (i = 1; i <= NF; i++) if (!(i in skip)) line = line (kept++ ? OFS : "") $i
                    print line
                }'
            ;;
        round)
            [[ $arg =~ ^[1-9][0-9]?$ ]] || { echo "stable-files: round takes a number of digits, not \"$arg\"" >&2; return 1; }
            gawk -F "$sep" -v OFS="$sep" -v digits="$arg" '
                BEGIN { number = "^[-+]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][-+]?[0-9]+)?$" }
                {
                    for (i = 1; i <= NF; i++) if ($i ~ number) $i = sprintf("%." digits "g", $i)
                    print
                }'
            ;;
        unordered)
            gawk -F "$sep" -v OFS="$sep" '
                function reorder(line,    f, out, j) {
                    split(line, f, FS)
                    out = f[1]
                    for (j = 1; j <= k; j++) out = out OFS f[order[j]]
                    return out
                }
                { row[NR] = $0; width[NR] = NF; if (NF > widest) widest = NF }
                END {
                    for (top = 1; top <= NR && width[top] < widest; top++) ;
                    if (top > NR) exit
                    n = split(row[top], head, FS)
                    for (i = 2; i <= n; i++) name[i] = head[i] SUBSEP sprintf("%09d", i)
                    PROCINFO["sorted_in"] = "@val_str_asc"
                    for (i in name) order[++k] = i
                    print reorder(row[top])
                    fflush()
                    sorter = "LC_ALL=C sort"
                    for (r = top + 1; r <= NR; r++) print reorder(row[r]) | sorter
                    close(sorter)
                }'
            ;;
        *) echo "stable-files: \"$how\" isn't a way to read a table" >&2; return 1 ;;
    esac
}

# The checksums of a pipeline's core tables under a directory, as a JSON list
# of {path, sha256}: outputs_measure <pipeline> <directory>
outputs_measure() {
    local pipeline=$1 dir=$2 path how arg sum lines=""
    while IFS=$'\t' read -r path how arg; do
        sum=$(set -o pipefail; outputs_read "$dir/$path" "$how" "$arg" | sha256sum) || return 1
        lines+="$path"$'\t'"${sum%% *}"$'\n'
    done < <(outputs_list "$pipeline" "$dir")
    printf '%s' "$lines" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {path: .[0], sha256: .[1]})'
}

# Copies, from beside a record, each core table whose checksum is the one the
# record holds, so a re-run can compare its own tables with them later:
# outputs_keep_recorded <pipeline> <recorded outputs> <from> <to>. Prints how
# many it copied.
outputs_keep_recorded() {
    local pipeline=$1 recorded=$2 from=$3 to=$4 path sum how arg kept=0
    while IFS=$'\t' read -r path sum; do
        [[ -n $path && $path != /* && $path != *..* && -f $from/$path ]] || continue
        IFS=$'\t' read -r how arg < <(outputs_how "$pipeline" "$path"; echo)
        [[ $(set -o pipefail; outputs_read "$from/$path" "$how" "$arg" | sha256sum) == "$sum "* ]] || continue
        mkdir -p "$to/$(dirname "$path")" && cp "$from/$path" "$to/$path" || return 1
        kept=$((kept + 1))
    done < <(jq -r '.[]? | [.path, .sha256] | @tsv' <<< "$recorded")
    printf '%s' "$kept"
}

# Compares two tables cell by cell, and prints a JSON object: rows matched,
# rows only in the first or second, numeric cells compared and how many
# differ, text cells that differ, and the largest relative difference, with its
# row, column and the two values. compare_tables <first> <second> <name>, where
# name, the table's path, says whether it's comma-separated.
compare_tables() {
    local sep=$'\t' fields
    [[ $3 != *.csv && $3 != *.csv.gz ]] || sep=,
    fields=$(gawk -v sep="$sep" '
        BEGIN {
            FS = sep
            number = "^[-+]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][-+]?[0-9]+)?$"
            max = 0
        }
        ARGIND == 1 {
            if (FNR == 1) for (i = 1; i <= NF; i++) head[i] = $i
            key = $1 SUBSEP (++count_a[$1])
            row_a[key] = $0
            next
        }
        {
            key = $1 SUBSEP (++count_b[$1])
            if (!(key in row_a)) { only_b++; next }
            matched[key] = 1
            rows++
            n = split(row_a[key], a, FS)
            last = n > NF ? n : NF
            for (i = 1; i <= last; i++) {
                x = a[i]
                y = $i
                if (x ~ number && y ~ number) {
                    cells++
                    if (x + 0 == y + 0) continue
                    differing++
                    d = x - y
                    if (d < 0) d = -d
                    big = x < 0 ? -x : x + 0
                    if ((y < 0 ? -y : y + 0) > big) big = y < 0 ? -y : y + 0
                    rel = big > 0 ? d / big : 0
                    if (rel > max || differing == 1) {
                        max = rel
                        at_row = $1
                        at_column = (i in head && head[i] != "") ? head[i] : "column " i
                        value_a = x
                        value_b = y
                    }
                } else if (x != y) {
                    text++
                }
            }
        }
        END {
            for (key in row_a) if (!(key in matched)) only_a++
            printf "%d\t%d\t%d\t%d\t%d\t%d\t%.3g\t%s\t%s\t%s\t%s\n", rows, only_a, only_b, cells,
                differing, text, max, at_row, at_column, value_a, value_b
        }' "$1" "$2") || return 1
    jq -R -c 'split("\t") | {rows: (.[0] | tonumber), only_recorded: (.[1] | tonumber),
        only_new: (.[2] | tonumber), numbers: (.[3] | tonumber), numbers_differing: (.[4] | tonumber),
        text_differing: (.[5] | tonumber)}
        + if (.[4] | tonumber) > 0 then {largest_relative_difference: (.[6] | tonumber),
            row: .[7], column: .[8], recorded: .[9], new: .[10]} else {} end' <<< "$fields"
}

# Compares a run's core tables with another's, and prints a JSON object:
# identical, true only when every table's checksum matches, and tables, each
# {path, result: identical, differs, missing or new}, with compare_tables'
# figures for one that differs when the other run's copy is at hand.
# outputs_compare <pipeline> <expected outputs> <actual outputs>
#                 <directory of the expected tables, or ""> <directory of the actual ones>
outputs_compare() {
    local pipeline=$1 expected=$2 actual=$3 reference=$4 dir=$5 path want got how arg figures tables=()
    # An absent checksum is -, because read collapses an empty field between tabs
    while IFS=$'\t' read -r path want got; do
        if [[ $want == "$got" ]]; then
            tables+=("$(jq -cn --arg path "$path" '{path: $path, result: "identical"}')")
        elif [[ $got == - ]]; then
            tables+=("$(jq -cn --arg path "$path" '{path: $path, result: "missing"}')")
        elif [[ $want == - ]]; then
            tables+=("$(jq -cn --arg path "$path" '{path: $path, result: "new"}')")
        else
            figures=null
            if [[ -n $reference && -f $reference/$path && -f $dir/$path ]]; then
                IFS=$'\t' read -r how arg < <(outputs_how "$pipeline" "$path"; echo)
                figures=$(compare_tables <(outputs_read "$reference/$path" "$how" "$arg") \
                    <(outputs_read "$dir/$path" "$how" "$arg") "$path") || figures=null
            fi
            tables+=("$(jq -cn --arg path "$path" --argjson figures "$figures" '
                {path: $path, result: "differs"} + if $figures == null then {} else {figures: $figures} end')")
        fi
    done < <(jq -rn --argjson want "$expected" --argjson got "$actual" '
        ($want | map({(.path): .sha256}) | add // {}) as $w
        | ($got | map({(.path): .sha256}) | add // {}) as $g
        | ($w + $g | keys[]) as $path | [$path, $w[$path] // "-", $g[$path] // "-"] | @tsv')
    printf '%s\n' ${tables[@]+"${tables[@]}"} |
        jq -s -c '{identical: (length > 0 and all(.result == "identical")), tables: .}'
}

# A comparison as one sentence, for a run's notes: outputs_summary
# <comparison> <what it's compared with, such as "the record's">
outputs_summary() {
    jq -r --arg with "$2" '
        def figures: if .figures.largest_relative_difference then
                "largest relative difference \(.figures.largest_relative_difference), at \(.figures.row), \(.figures.column)"
                + (if .figures.only_recorded + .figures.only_new > 0
                    then ", with \(.figures.only_recorded + .figures.only_new) rows only in one" else "" end)
            elif .figures then "\(.figures.only_recorded + .figures.only_new) rows only in one, \(.figures.text_differing) text cells differing, no number different"
            else "no copy to compare its numbers with" end;
        (.tables | length) as $n
        | if $n == 0 then "There were no core tables to compare with \($with)."
          elif .identical then "Its \($n) core tables are identical to \($with)."
          else ([.tables[] | select(.result != "identical")]) as $off
            | "\($off | length) of its \($n) core tables differ from \($with): "
              + ([$off[] | "\(.path), " + (if .result == "differs" then figures
                    elif .result == "missing" then "not made this time" else "not in \($with)" end)] | join("; "))
              + "."
          end' <<< "$1"
}
