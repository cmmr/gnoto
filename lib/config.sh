#
# config.sh - gnoto config: lists the sections of config.yaml, asks for one
# section's settings or takes them as arguments, or turns a section on or off.
#
# Sourced by:  lib/main.sh, for
#              gnoto config [<section> [--on|--off] [--<key>=<value> ...]],
#              gnoto config s3|sqs [--deploy] [--dry-run] [--yes], gnoto
#              config systemd and gnoto config slurm --probe
# Defines:     config_main, config_set, config_add_section, config_get,
#              config_has_section, config_choose, config_text, config_yes,
#              config_confirm, config_proceed, generated_set, run_id_salt
# Requires:    yq, flock; the settings and helpers from lib/env.sh, which loads
#              each section's declarations from lib/config/; args_parse from
#              lib/args.sh
# Env:         INSTALL_DIR and the current settings, from lib/env.sh;
#              GNOTO_FOUND_APPTAINER_BIN_DIR, GNOTO_FOUND_SLURM_BIN_DIR and
#              GNOTO_FOUND_SLURM_CONF, what the launcher found on the host
#
# gnoto config prints each section and what it's for. gnoto config <section>
# asks for each of its settings, suggesting what the section's own suggest
# function finds, or else the current value. Given settings as --<key>=<value>,
# it sets those and asks nothing, and an empty value clears one. --on and --off
# set its enabled. When config.yaml doesn't have the section yet, any of these
# adds the whole section, with what's given and suggestions for the rest, and
# only that section, so config.yaml holds only what a site has chosen. A new
# section is on unless --off says otherwise. A subsection, such as aws's s3, is
# named by its last part, and adding it adds its parent too; turning it on
# turns its parent on. gnoto config slurm --probe checks every compute node
# with a Slurm job, from lib/nodes.sh, and writes nothing to config.yaml.
#
# Once a section that's on is written, its step, config_<section>_step, does
# its one-time setup: core's makes RUN_ID_SALT, and wrike's and globus's are in
# service/. s3 and sqs instead ask their own questions, offering what the AWS
# account has, while --deploy takes what config.yaml holds; either shows every
# setting it's about to apply and what deploying them changes, and asks to go
# ahead, yes by default, through config_proceed, before writing or deploying
# anything (service/aws/config.sh). Their --on and --off only write what to
# fill in. systemd is a step with no section of its own. Each other step shows
# its plan, through config_confirm, and asks before changing anything, no by
# default. Everywhere, --dry-run stops after the plan, and --yes answers for a
# script. Machine-made values go to <data_dir>/generated.yaml, through
# generated_set.
#
# Strings are written double-quoted, because the launcher reads its bootstrap
# settings with an awk that accepts only   key: "value", true or false.

CONFIG_FILE="$INSTALL_DIR/config.yaml"
CONFIG_HEADER="# This install's settings. gnoto config lists the sections, and adds or changes one."

# Prints a value as YAML for the type of setting $1, such as slurm.max_cpus
config_yaml() {
    case ${CONFIG_TYPE[$1]} in
        bool) printf '%s' "$2" ;;
        int) if [[ -n $2 ]]; then printf '%s' "$2"; else printf '""'; fi ;;
        *) printf '"%s"' "$2" ;;
    esac
}

# The awk functions config_set and config_add_section share, which follow the
# path each line of config.yaml sits at: after track(line), depth is how deep
# its key is, at[1..depth] its path, and within() whether that path starts with
# the section path part[1..n]. Blank and comment lines leave the path as it is.
CONFIG_AWK_PATH='
    function track(line,   lead, name, l) {
        if (line ~ /^ *(#.*)?$/) return 0
        match(line, /^ */)
        lead = RLENGTH
        name = substr(line, lead + 1)
        sub(/:.*/, "", name)
        depth = int(lead / 2) + 1
        at[depth] = name
        for (l = depth + 1; l <= 9; l++) delete at[l]
        return 1
    }
    function within(   l) {
        if (depth < n) return 0
        for (l = 1; l <= n; l++) if (at[l] != part[l]) return 0
        return 1
    }'

# Sets section.key in config.yaml, where a section may be a subsection, such
# as aws.s3. The key's line is changed in place, with its comment kept in the
# same column, so the rest of the file stays as it was. A missing enabled goes
# first in its section, and any other missing key after the section's last
# setting. Only what that can't place, such as a missing section, goes through
# yq, which respaces the file. The text is written into the existing file,
# because the image can't give a new file the install's group: its user
# namespace doesn't map it.
config_set() {
    local section="$1" key="$2" value="$3" tmp path

    [[ "$value" != *'"'* && "$value" != *$'\n'* ]] ||
        fail "A value with a double quote or a line break can't go in config.yaml: $value"
    path=.${section}.$key
    (
        flock -w 30 9 || fail "Can't lock $CONFIG_FILE."
        tmp=$(mktemp) || exit 1
        VALUE=$(config_yaml "$section.$key" "$value")
        export SECTION="$section" KEY="$key" VALUE
        if ! awk "$CONFIG_AWK_PATH"'
                BEGIN {
                    n = split(ENVIRON["SECTION"], part, ".")
                    prefix = sprintf("%" (2 * n) "s", "") ENVIRON["KEY"] ":"
                    line = prefix " " ENVIRON["VALUE"]
                }
                NR == FNR {
                    if (track($0) && within()) {
                        if (depth == n) {
                            header = FNR
                        } else if (depth == n + 1) {
                            if ($0 ~ /^ *[^ :#]+: *[^ #]/) own = FNR
                            if (at[depth] == ENVIRON["KEY"]) found = FNR
                        }
                    }
                    next
                }
                FNR == 1 { split("", at) }
                {
                    track($0)
                    if (FNR == found && index($0, prefix) == 1) {
                        rest = substr($0, length(prefix) + 1)
                        if (match(rest, /^ *"[^"]*"/) || match(rest, /^ *[^ #"]*/)) {
                            tail = substr(rest, RLENGTH + 1)
                            if (tail ~ /^ *(#.*)?$/) {
                                text = line
                                if (match(tail, /^ *#/)) {
                                    column = length($0) - length(tail) + RLENGTH - 1
                                    if (length(text) < column) {
                                        text = sprintf("%-" column "s", text)
                                    } else {
                                        text = text "  "
                                    }
                                    text = text substr(tail, RLENGTH)
                                }
                                print text
                                done = 1
                                next
                            }
                        }
                    }
                    print
                    if (!found && !done && header &&
                        FNR == (ENVIRON["KEY"] == "enabled" || !own ? header : own)) {
                        print line
                        done = 1
                    }
                }
                END { exit !done }' "$CONFIG_FILE" "$CONFIG_FILE" > "$tmp" &&
            ! yq "$path = env(VALUE) | ($path | select(tag == \"!!str\")) style=\"double\"" \
                "$CONFIG_FILE" > "$tmp"; then
            rm -f "$tmp"
            fail "Can't write $section.$key to $CONFIG_FILE."
        fi
        if ! cat "$tmp" > "$CONFIG_FILE"; then
            rm -f "$tmp"
            fail "Can't write $CONFIG_FILE."
        fi
        rm -f "$tmp"
    ) 9> "$CONFIG_FILE.lock" || exit 1
}

# Adds a section to config.yaml with the values in CONFIG_NEW and enabled $2,
# creating the file at mode 660 in the user's own group if there isn't one. A
# subsection goes at the end of its parent, which must be there.
config_add_section() {
    local section=$1 key text tmp pad="" name=$1

    if [[ $section == *.* ]]; then
        pad="  "
        name=${section##*.}
    fi
    text="$pad$name:"
    [[ $section == core ]] || text+=$'\n'"$pad  enabled: $2"
    for key in ${CONFIG_KEYS[$section]}; do
        [[ $key != enabled && -n ${CONFIG_NEW[$key]+set} ]] || continue
        text+=$'\n'"$pad  $key: $(config_yaml "$section.$key" "${CONFIG_NEW[$key]}")"
    done
    (
        flock -w 30 9 || fail "Can't lock $CONFIG_FILE."
        if [[ -n $pad ]]; then
            tmp=$(mktemp) || exit 1
            if ! PARENT=${section%.*} TEXT=$text awk "$CONFIG_AWK_PATH"'
                    BEGIN { n = split(ENVIRON["PARENT"], part, ".") }
                    NR == FNR { if (track($0) && within()) last = FNR; next }
                    FNR == 1 { split("", at) }
                    { print }
                    FNR == last { print ENVIRON["TEXT"] }
                    END { exit !last }' "$CONFIG_FILE" "$CONFIG_FILE" > "$tmp" ||
                ! cat "$tmp" > "$CONFIG_FILE"; then
                rm -f "$tmp"
                fail "Can't add $section to $CONFIG_FILE."
            fi
            rm -f "$tmp"
            exit 0
        fi
        if [[ -e $CONFIG_FILE ]]; then
            printf '\n%s\n' "$text" >> "$CONFIG_FILE" || fail "Can't write $CONFIG_FILE."
            exit 0
        fi
        tmp=$(mktemp "$CONFIG_FILE.XXXXXX") || fail "Can't write in $INSTALL_DIR."
        if ! printf '%s\n\n%s\n' "$CONFIG_HEADER" "$text" > "$tmp" || ! chgrp "$(id -g)" "$tmp" ||
            ! chmod 660 "$tmp" || ! mv "$tmp" "$CONFIG_FILE"; then
            rm -f "$tmp"
            fail "Can't write $CONFIG_FILE."
        fi
    ) 9> "$CONFIG_FILE.lock" || exit 1
}

# generated_set [--keep] <dotted key> <value>: writes a machine-made value, such
# as a Wrike ID or a stack's output, into <data_dir>/generated.yaml under a
# lock, and sets its variable here too: core.run_id_salt is RUN_ID_SALT, and
# wrike.statuses.running is WRIKE_STATUSES_RUNNING. An empty value removes the
# key. --keep leaves a value that's already there, and sets the variable to
# it. A new file is mode 660 and takes the data directory's group, which its
# setgid gives it.
generated_set() {
    local keep="" key value file=$DATA_DIR/generated.yaml name tmp
    [[ $1 != --keep ]] || { keep=1; shift; }
    key=$1 value=$2
    name=${key//./_}
    name=${name^^}
    name=${name#CORE_}
    value=$( {
        flock -w 30 9 || fail "Can't lock $file."
        if [[ -n $keep && -s $file ]]; then
            old=$(yq -o=json . "$file" | jq -r --arg key "$key" 'getpath($key | split(".")) // ""') ||
                fail "Can't read $file."
            [[ -z $old ]] || { printf '%s' "$old"; exit 0; }
        fi
        tmp=$(mktemp "$file.XXXXXX") || fail "Can't write in $DATA_DIR."
        if ! { printf '# Written by gnoto config: IDs and outputs it made or found. A value in config.yaml wins.\n'
            { if [[ -s $file ]]; then yq -o=json . "$file"; else echo "{}"; fi; } | jq --arg key "$key" --arg value "$value" '
                (. // {}) | ($key | split(".")) as $path
                | if $value == "" then delpaths([$path]) else setpath($path; $value) end' |
                yq -P -oy '.'; } > "$tmp" || ! chmod 660 "$tmp"; then
            rm -f "$tmp"
            fail "Can't write $key to $file."
        fi
        if [[ -e $file ]]; then
            # Into the file itself, which keeps its group
            cat "$tmp" > "$file" && rm -f "$tmp" || { rm -f "$tmp"; fail "Can't write $file."; }
        else
            mv "$tmp" "$file" || { rm -f "$tmp"; fail "Can't write $file."; }
        fi
        printf '%s' "$value"
    } 9>> "$DATA_DIR/generated.yaml.lock") || exit 1
    printf -v "$name" '%s' "$value"
}

# Makes RUN_ID_SALT, which turns a Wrike task's ID into its run's uid, once
run_id_salt() {
    [[ -z ${RUN_ID_SALT:-} ]] || return 0
    mkdir -p "$DATA_DIR" || fail "Can't create $DATA_DIR."
    generated_set --keep core.run_id_salt "$(head -c 30 /dev/urandom | base64 | tr -d '/+=')"
}

# Whether config.yaml has a section, or a subsection such as aws.s3
config_has_section() {
    [[ -e $CONFIG_FILE ]] && yq -o=json . "$CONFIG_FILE" 2> /dev/null |
        jq -e --arg path "$1" 'getpath($path | split(".")) | type == "object"' > /dev/null 2>&1
}

# A section's value as config.yaml has it, or nothing: config_get <section> <key>
config_get() {
    [[ -e $CONFIG_FILE ]] || return 0
    yq -o=json . "$CONFIG_FILE" 2> /dev/null |
        jq -r --arg path "$1.$2" 'getpath($path | split(".")) // empty | tostring' 2> /dev/null
}

# The section a word names: a section, or a subsection by its last part, so s3
# is aws.s3. Prints nothing for neither.
config_resolve() {
    local section found=""
    if [[ -n ${CONFIG_ABOUT[$1]-} ]]; then
        printf '%s' "$1"
        return 0
    fi
    for section in "${CONFIG_SECTIONS[@]}"; do
        [[ $section != *."$1" ]] || found=$section
    done
    printf '%s' "$found"
}

# config_choose <question> <default> <option> ...: lists the options, numbered,
# and sets CHOICE to the number chosen. Enter takes the default.
config_choose() {
    local question=$1 default=$2 i answer
    shift 2
    printf '%s\n' "$question" >&2
    for (( i = 1; i <= $#; i++ )); do
        printf '  %d) %s\n' "$i" "${!i}" >&2
    done
    while :; do
        read -r -e -p "  [$default] " answer || fail "No answer, so nothing more was written."
        answer=${answer:-$default}
        if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= $# )); then
            CHOICE=$answer
            return 0
        fi
        echo "  Give a number from 1 to $#." >&2
    done
}

# config_text <question> <suggestion> [secret]: sets ANSWER to what's typed, or
# the suggestion. A secret isn't shown as it's typed.
config_text() {
    local shown=${2:-none}
    printf '%s\n' "$1" >&2
    if [[ -n ${3:-} ]]; then
        [[ -z $2 ]] || shown="set, hidden"
        read -r -s -p "  [$shown] " ANSWER || fail "No answer, so nothing more was written."
        echo >&2
    else
        read -r -e -p "  [$shown] " ANSWER || fail "No answer, so nothing more was written."
    fi
    ANSWER=${ANSWER:-$2}
}

# Asks whether to go ahead with what was just shown, yes by default. --dry-run
# stops here, returning 1, and --yes answers for a script.
config_proceed() {
    if [[ -n ${CONFIG_DRY_RUN:-} ]]; then
        echo "Nothing was changed, with --dry-run." >&2
        return 1
    fi
    [[ -z ${CONFIG_YES:-} ]] || return 0
    [[ -t 0 ]] || fail "No terminal to confirm on. Add --yes to go ahead, or --dry-run to see the settings alone."
    config_yes "Go ahead?" yes || fail "Nothing was changed."
}

# config_yes <question> <yes|no>: whether the answer is yes, Enter giving the
# default
config_yes() {
    local answer hint="[y/N]"
    [[ $2 != yes ]] || hint="[Y/n]"
    read -r -e -p "$1 $hint " answer || answer=""
    answer=${answer:-$2}
    [[ $answer == [yY]* ]]
}

# Prints what to suggest for section.key: what the section's suggest function
# finds, or else the current value, which is the default when it's unset
config_suggest() {
    local section=$1 key=$2 name=${2^^}
    [[ $section == core ]] || name=${section^^}_$name
    name=${name//./_}
    if declare -F "config_${section}_suggest" > /dev/null && "config_${section}_suggest" "$key"; then
        return 0
    fi
    printf '%s' "${!name}"
}

# Prints what's wrong with a value for a type of setting, and returns 1, or
# prints nothing
config_check() {
    local type=$1 value=$2
    if [[ $value == *'"'* || $value == *$'\n'* ]]; then
        echo "A double quote or a line break can't go in config.yaml."
        return 1
    fi
    case $type in
        int) [[ -z $value || $value =~ ^[0-9]+$ ]] || { echo "Give a whole number."; return 1; } ;;
        path) [[ -z $value || $value == /* ]] || { echo "Give an absolute path."; return 1; } ;;
        paths)
            [[ -z $value || ",$value," =~ ^(,/[^,]+)+,$ ]] ||
                { echo "Give absolute paths, separated by commas."; return 1; }
            ;;
        dir)
            if [[ $value != /* ]]; then
                echo "Give an absolute path."
                return 1
            elif [[ -d $value && ! -w $value ]]; then
                echo "You can't write to $value."
                return 1
            fi
            ;;
    esac
}

# Asks for section.key, offering a suggestion, until the answer suits its type,
# and sets ANSWER. Enter keeps the suggestion, and "none" clears it. A secret
# isn't shown, as it's typed or as a suggestion.
config_ask() {
    local section=$1 key=$2 suggestion=$3 type=${CONFIG_TYPE[$1.$2]} shown why

    while :; do
        printf '%s\n' "${CONFIG_QUESTION[$section.$key]}" >&2
        shown=${suggestion:-none}
        if [[ $type == secret ]]; then
            [[ -z $suggestion ]] || shown="set, hidden"
            read -r -s -p "  [$shown] " ANSWER || fail "No answer, so nothing more was written."
            echo >&2
        else
            read -r -e -p "  [$shown] " ANSWER || fail "No answer, so nothing more was written."
        fi
        ANSWER=${ANSWER:-$suggestion}
        [[ $ANSWER != none ]] || ANSWER=""
        why=$(config_check "$type" "$ANSWER") && return 0
        echo "  $why" >&2
    done
}

# Fills CONFIG_NEW with a value for each of a section's settings but enabled:
# what CONFIG_GIVEN holds, then asked for, or with $2 empty, the suggestions as
# they are. Each value can shape the suggestions after it.
config_walk() {
    local section=$1 ask=$2 key why

    for key in ${CONFIG_KEYS[$section]}; do
        [[ $key != enabled ]] || continue
        # A setting with no question is gnoto's to fill in, unless given
        [[ -n ${CONFIG_QUESTION[$section.$key]} || -n ${CONFIG_GIVEN[$key]+set} ]] || continue
        if [[ -n ${CONFIG_GIVEN[$key]+set} ]]; then
            ANSWER=${CONFIG_GIVEN[$key]}
        elif [[ -n $ask ]]; then
            config_ask "$section" "$key" "$(config_suggest "$section" "$key")"
        else
            ANSWER=$(config_suggest "$section" "$key")
            why=$(config_check "${CONFIG_TYPE[$section.$key]}" "$ANSWER") ||
                fail "Can't use \"$ANSWER\" for $section.$key, so nothing was written: $why"
        fi
        CONFIG_NEW[$key]=$ANSWER
    done
}

# config_confirm <where> <plan item> ...: shows what a step is about to change,
# and asks before it does. --dry-run stops after the plan, returning 1, and
# --yes answers for a script.
config_confirm() {
    local where=$1 item answer
    shift
    echo "This changes $where:"
    for item in "$@"; do
        echo "  - $item"
    done
    if [[ -n ${CONFIG_DRY_RUN:-} ]]; then
        echo "Nothing was changed, with --dry-run."
        return 1
    fi
    [[ -z ${CONFIG_YES:-} ]] || return 0
    [[ -t 0 ]] || fail "No terminal to confirm on. Add --yes to go ahead, or --dry-run to see the plan alone."
    printf 'Go ahead? [y/N] ' >&2
    read -r answer || answer=""
    [[ $answer == [yY]* ]] || fail "Nothing was changed."
}

# gnoto config systemd: the step that has no section of its own
config_step_main() {
    local usage="Usage: gnoto config systemd [--move] [--dry-run] [--yes]"
    [[ -z ${ARG_FLAGS[on]:-}${ARG_FLAGS[off]:-}${ARG_FLAGS[probe]:-}${ARG_FLAGS[deploy]:-} && ${#ARG_KEYS[@]} -eq 0 ]] ||
        fail "$usage"
    CONFIG_MOVE=${ARG_FLAGS[move]:-}
    CONFIG_DRY_RUN=${ARG_FLAGS[dry-run]:-}
    CONFIG_YES=${ARG_FLAGS[yes]:-}
    config_systemd_step
}

# Adds a subsection's parent with its suggestions alone, as --on or --off adds
# a section, keeping what CONFIG_GIVEN holds for the subsection
config_add_parent() {
    local parent=$1 enabled=$2 key
    local -A given=()
    for key in "${!CONFIG_GIVEN[@]}"; do
        given[$key]=${CONFIG_GIVEN[$key]}
    done
    declare -gA CONFIG_GIVEN=() CONFIG_NEW=()
    config_walk "$parent" ""
    config_add_section "$parent" "$enabled"
    declare -gA CONFIG_NEW=()
    for key in "${!given[@]}"; do
        CONFIG_GIVEN[$key]=${given[$key]}
    done
}

config_main() {
    local usage="Usage: gnoto config [<section> [--on|--off] [--<key>=<value> ...] [--dry-run] [--yes]], gnoto config s3|sqs [--deploy] [--dry-run] [--yes], gnoto config systemd [--move], or gnoto config slurm --probe"
    local word section short option="" present="" enabled key settings i why step_only=""

    args_parse "$usage" "on off probe deploy move dry-run yes" "$@"
    if [[ ${#ARG_WORDS[@]} -eq 0 ]]; then
        [[ ${#ARG_KEYS[@]} -eq 0 && ${#ARG_FLAGS[@]} -eq 0 ]] || fail "$usage"
        for section in "${CONFIG_SECTIONS[@]}"; do
            if [[ $section == *.* ]]; then
                printf '  %-8s %s\n' "${section##*.}" "${CONFIG_ABOUT[$section]}"
            else
                printf '%-10s %s\n' "$section" "${CONFIG_ABOUT[$section]}"
            fi
        done
        printf '%-10s %s\n' systemd "Install the units that expire results, scan Wrike and listen to SQS"
        return 0
    fi
    [[ ${#ARG_WORDS[@]} -eq 1 ]] || fail "$usage"
    word=${ARG_WORDS[0]}
    if [[ $word == systemd ]]; then
        config_step_main
        return
    fi
    section=$(config_resolve "$word")
    [[ -n $section ]] || fail "gnoto config has no section $word. Run $(gnoto_command config) to list them."
    short=${section##*.}
    [[ -z ${ARG_FLAGS[move]:-} ]] || fail "--move is for $(gnoto_command config systemd)."
    CONFIG_DRY_RUN=${ARG_FLAGS[dry-run]:-}
    CONFIG_YES=${ARG_FLAGS[yes]:-}

    # s3 and sqs: --deploy deploys what config.yaml holds, and with no options,
    # they ask their own questions. Either shows the settings and what deploying
    # them changes, and asks before going ahead, unless given --yes.
    if declare -F "config_${short}_deploy" > /dev/null; then
        if [[ -n ${ARG_FLAGS[deploy]:-} ]]; then
            [[ ${#ARG_KEYS[@]} -eq 0 && -z ${ARG_FLAGS[on]:-}${ARG_FLAGS[off]:-}${ARG_FLAGS[probe]:-} ]] ||
                fail "--deploy deploys with what config.yaml holds, so it takes only --dry-run and --yes."
            "config_${short}_deploy"
            return
        fi
        if [[ ${#ARG_KEYS[@]} -eq 0 && -z ${ARG_FLAGS[on]:-}${ARG_FLAGS[off]:-}${ARG_FLAGS[probe]:-} ]]; then
            [[ -t 0 ]] || fail "$(gnoto_command config "$word") asks questions, so run it from a terminal, or give --deploy, --on or --off."
            "config_${short}_interactive"
            return
        fi
    fi
    [[ -z ${ARG_FLAGS[deploy]:-} ]] || fail "--deploy is for $(gnoto_command config s3) and $(gnoto_command config sqs)."
    if [[ -n ${ARG_FLAGS[probe]:-} ]]; then
        [[ $section == slurm ]] || fail "--probe is for $(gnoto_command config slurm), which checks every compute node."
        [[ ${#ARG_FLAGS[@]} -eq 1 && ${#ARG_KEYS[@]} -eq 0 ]] || fail "gnoto config slurm --probe takes nothing else."
        nodes_probe
        return
    fi
    [[ -z ${ARG_FLAGS[on]:-} || -z ${ARG_FLAGS[off]:-} ]] || fail "Give --on or --off, not both."
    [[ -z ${ARG_FLAGS[on]:-} ]] || option=--on
    [[ -z ${ARG_FLAGS[off]:-} ]] || option=--off
    if [[ -n $option ]]; then
        [[ $section != core ]] || fail "core is always on. Run $(gnoto_command config core) to change its settings."
        [[ $section != apptainer || $option == --on ]] ||
            fail "Apptainer is gnoto's only container engine, so it can't be turned off."
    fi

    # Settings given as arguments, each checked as an answer would be
    declare -gA CONFIG_GIVEN=()
    settings=$(for key in ${CONFIG_KEYS[$section]}; do [[ $key == enabled ]] || printf '%s ' "$key"; done)
    for (( i = 0; i < ${#ARG_KEYS[@]}; i++ )); do
        key=${ARG_KEYS[i]}
        [[ $key != enabled || $section == core ]] ||
            fail "--enabled: turn $section on or off with --on or --off."
        if [[ " $settings" != *" $key "* ]]; then
            settings=${settings% }
            fail "--$key: $section has no setting $key. Its settings are ${settings// /, }."
        fi
        why=$(config_check "${CONFIG_TYPE[$section.$key]}" "${ARG_VALUES[i]}") || fail "--$key: $why"
        CONFIG_GIVEN[$key]=${ARG_VALUES[i]}
    done
    declare -gA CONFIG_NEW=()
    ! config_has_section "$section" || present=1
    # With --dry-run or --yes alone, a section that's there keeps its settings,
    # and only its step runs
    if [[ ${#ARG_KEYS[@]} -eq 0 && -z $option && -n $present && -n $CONFIG_DRY_RUN$CONFIG_YES ]]; then
        step_only=1
    elif [[ ${#ARG_KEYS[@]} -eq 0 && -z $option && ! -t 0 ]]; then
        fail "$(gnoto_command config "$word") asks questions, so run it from a terminal, or give --on, --off or its settings as --<key>=<value>."
    fi
    enabled=true
    [[ $option != --off ]] || enabled=false
    # A subsection needs its parent, which turning it on turns on too
    if [[ $section == *.* && -z $step_only ]]; then
        if ! config_has_section "${section%.*}"; then
            config_add_parent "${section%.*}" "$enabled"
        elif [[ $option != --off && $(config_get "${section%.*}" enabled) != true ]]; then
            config_set "${section%.*}" enabled true
        fi
    fi
    if [[ -n $step_only ]]; then
        :
    elif [[ ${#ARG_KEYS[@]} -eq 0 && -z $option ]]; then
        echo "Press Enter to keep a suggestion, or type none to clear it." >&2
        config_walk "$section" ask
        if [[ -z $present ]]; then
            config_add_section "$section" true
        else
            for key in ${CONFIG_KEYS[$section]}; do
                [[ $key == enabled || -z ${CONFIG_NEW[$key]+set} ]] || config_set "$section" "$key" "${CONFIG_NEW[$key]}"
            done
        fi
    elif [[ -z $present ]]; then
        config_walk "$section" ""
        config_add_section "$section" "$enabled"
    else
        [[ -z $option ]] || config_set "$section" enabled "$enabled"
        for (( i = 0; i < ${#ARG_KEYS[@]}; i++ )); do
            config_set "$section" "${ARG_KEYS[i]}" "${ARG_VALUES[i]}"
        done
    fi

    if [[ $section == core ]]; then
        echo "core is set, in $CONFIG_FILE." >&2
    elif [[ $(config_get "$section" enabled) == true ]]; then
        echo "$word is on, in $CONFIG_FILE." >&2
    else
        echo "$word is off, in $CONFIG_FILE. To turn it on, run: $(gnoto_command config "$word" --on)" >&2
        return 0
    fi

    # s3 and sqs deploy only when asked
    if declare -F "config_${short}_deploy" > /dev/null; then
        echo "Fill in what it needs there, or let $(gnoto_command config "$word") ask, then deploy it with: $(gnoto_command config "$word" --deploy)" >&2
        return 0
    fi

    # The section's one-time setup, with the settings just written
    if declare -F "config_${section}_step" > /dev/null; then
        source "$CODE_DIR/lib/env.sh"
        "config_${section}_step"
    fi
}

# What gnoto config core does once its settings are written: the data
# directory, and the salt that turns a Wrike task's ID into its run's uid
config_core_step() {
    mkdir -p "$DATA_DIR" || fail "Can't create $DATA_DIR."
    chmod g+s "$DATA_DIR" 2> /dev/null || :
    run_id_salt
}

# lint.sh brings the integrations' steps, from service/, with their checks
source "$CODE_DIR/lib/lint.sh"
source "$CODE_DIR/lib/jobfile.sh"
