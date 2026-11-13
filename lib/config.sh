#
# config.sh - gnoto config: lists the sections of config.yaml, asks for one
# section's settings or takes them as arguments, or turns a section on or off.
#
# Sourced by:  lib/main.sh, for
#              gnoto config [<section> [--on|--off] [--<key>=<value> ...]],
#              gnoto config s3|sqs|systemd and gnoto config slurm --probe
# Defines:     config_main, config_set, config_confirm, generated_set,
#              run_id_salt
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
# section is on unless --off says otherwise. gnoto config slurm --probe checks
# every compute node with a Slurm job, from lib/nodes.sh, and writes nothing to
# config.yaml.
#
# Once a section that's on is written, its step, config_<section>_step, does
# its one-time setup: core's makes RUN_ID_SALT, and wrike's and globus's are in
# service/. s3, sqs and systemd are steps with no section of their own. Each
# step shows its plan, through config_confirm, and asks before changing
# anything; --dry-run stops after the plan, and --yes answers for a script.
# Machine-made values go to <data_dir>/generated.yaml, through generated_set.
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

# Sets section.key in config.yaml. The key's line is changed in place, with its
# comment kept in the same column, so the rest of the file stays as it was. A
# missing enabled goes first in its section, and any other missing key last.
# Only what that can't place, such as a missing section, goes through yq, which
# respaces the file. The text is written into the existing file, because the
# image can't give a new file the install's group: its user namespace doesn't
# map it.
config_set() {
    local section="$1" key="$2" value="$3" tmp

    [[ "$value" != *'"'* && "$value" != *$'\n'* ]] ||
        fail "A value with a double quote or a line break can't go in config.yaml: $value"
    (
        flock -w 30 9 || fail "Can't lock $CONFIG_FILE."
        tmp=$(mktemp) || exit 1
        VALUE=$(config_yaml "$section.$key" "$value")
        export SECTION="$section" KEY="$key" VALUE
        if ! awk '
                BEGIN { prefix = "  " ENVIRON["KEY"] ":"; header = "^" ENVIRON["SECTION"] ":[ ]*(#.*)?$" }
                NR == FNR {
                    if ($0 ~ /^[^ #]/) {
                        here = ($0 ~ header)
                        if (here) last = FNR
                    } else if (here) {
                        if (index($0, prefix) == 1) found = 1
                        if ($0 ~ /^ +[^ ]/) last = FNR
                    }
                    next
                }
                FNR == 1 { here = 0 }
                /^[^ #]/ {
                    here = ($0 ~ header)
                    print
                    if (here && !found && (ENVIRON["KEY"] == "enabled" || FNR == last)) {
                        print prefix " " ENVIRON["VALUE"]
                        done = 1
                    }
                    next
                }
                here && !done && index($0, prefix) == 1 {
                    rest = substr($0, length(prefix) + 1)
                    if (match(rest, /^ *"[^"]*"/) || match(rest, /^ *[^ #"]*/)) {
                        tail = substr(rest, RLENGTH + 1)
                        if (tail ~ /^ *(#.*)?$/) {
                            text = prefix " " ENVIRON["VALUE"]
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
                { print }
                !found && !done && FNR == last {
                    print prefix " " ENVIRON["VALUE"]
                    done = 1
                }
                END { exit !done }' "$CONFIG_FILE" "$CONFIG_FILE" > "$tmp" &&
            ! yq '.[strenv(SECTION)][strenv(KEY)] = env(VALUE)
                | (.[strenv(SECTION)][strenv(KEY)] | select(tag == "!!str")) style="double"' \
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
# creating the file at mode 660 in the user's own group if there isn't one
config_add_section() {
    local section=$1 key text tmp

    text="$section:"
    [[ $section == core ]] || text+=$'\n'"  enabled: $2"
    for key in ${CONFIG_KEYS[$section]}; do
        [[ $key != enabled && -n ${CONFIG_NEW[$key]+set} ]] || continue
        text+=$'\n'"  $key: $(config_yaml "$section.$key" "${CONFIG_NEW[$key]}")"
    done
    (
        flock -w 30 9 || fail "Can't lock $CONFIG_FILE."
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

config_has_section() {
    [[ -e $CONFIG_FILE ]] && SECTION=$1 yq -e 'has(strenv(SECTION))' "$CONFIG_FILE" > /dev/null 2>&1
}

# Prints what to suggest for section.key: what the section's suggest function
# finds, or else the current value, which is the default when it's unset
config_suggest() {
    local section=$1 key=$2 name=${2^^}
    [[ $section == core ]] || name=${section^^}_$name
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

# gnoto config s3|sqs|systemd: the steps that have no section of their own
config_step_main() {
    local step=$1 i usage
    case $step in
        s3) usage="Usage: gnoto config s3 [--deploy [--profile=<name>] [--domain=<name> --certificate=<arn>]] [--dry-run] [--yes]" ;;
        sqs) usage="Usage: gnoto config sqs [--deploy [--profile=<name>]] [--dry-run] [--yes]" ;;
        systemd) usage="Usage: gnoto config systemd [--move] [--dry-run] [--yes]" ;;
    esac
    [[ -z ${ARG_FLAGS[on]:-}${ARG_FLAGS[off]:-}${ARG_FLAGS[probe]:-} ]] || fail "$usage"
    [[ $step == systemd || -z ${ARG_FLAGS[move]:-} ]] || fail "$usage"
    [[ $step != systemd || -z ${ARG_FLAGS[deploy]:-} ]] || fail "$usage"
    CONFIG_DEPLOY=${ARG_FLAGS[deploy]:-}
    CONFIG_MOVE=${ARG_FLAGS[move]:-}
    CONFIG_DRY_RUN=${ARG_FLAGS[dry-run]:-}
    CONFIG_YES=${ARG_FLAGS[yes]:-}
    CONFIG_PROFILE="" CONFIG_DOMAIN="" CONFIG_CERTIFICATE=""
    for (( i = 0; i < ${#ARG_KEYS[@]}; i++ )); do
        case $step:${ARG_KEYS[i]} in
            s3:profile | sqs:profile) CONFIG_PROFILE=${ARG_VALUES[i]} ;;
            s3:domain) CONFIG_DOMAIN=${ARG_VALUES[i]} ;;
            s3:certificate) CONFIG_CERTIFICATE=${ARG_VALUES[i]} ;;
            *) fail "--${ARG_KEYS[i]} isn't an option here. $usage" ;;
        esac
    done
    [[ -n $CONFIG_DEPLOY || -z $CONFIG_PROFILE$CONFIG_DOMAIN$CONFIG_CERTIFICATE ]] ||
        fail "--profile, --domain and --certificate are for --deploy. $usage"
    "config_${step}_step"
}

config_main() {
    local usage="Usage: gnoto config [<section> [--on|--off] [--<key>=<value> ...] [--dry-run] [--yes]], gnoto config s3|sqs [--deploy], gnoto config systemd [--move], or gnoto config slurm --probe"
    local section option="" present="" enabled key settings i why step_only=""

    args_parse "$usage" "on off probe deploy move dry-run yes" "$@"
    if [[ ${#ARG_WORDS[@]} -eq 0 ]]; then
        [[ ${#ARG_KEYS[@]} -eq 0 && ${#ARG_FLAGS[@]} -eq 0 ]] || fail "$usage"
        for section in "${CONFIG_SECTIONS[@]}"; do
            printf '%-10s %s\n' "$section" "${CONFIG_ABOUT[$section]}"
        done
        printf '%-10s %s\n' s3 "Check the S3 bucket and results address, or with --deploy, build them" \
            sqs "Check the SQS queue for Wrike's webhook, or with --deploy, build it" \
            systemd "Install the units that expire results, scan Wrike and listen to SQS"
        return 0
    fi
    [[ ${#ARG_WORDS[@]} -eq 1 ]] || fail "$usage"
    section=${ARG_WORDS[0]}
    case $section in
        s3 | sqs | systemd)
            config_step_main "$section"
            return
            ;;
    esac
    [[ -z ${ARG_FLAGS[deploy]:-}${ARG_FLAGS[move]:-} ]] ||
        fail "--deploy is for gnoto config s3 and sqs, and --move for gnoto config systemd."
    CONFIG_DRY_RUN=${ARG_FLAGS[dry-run]:-}
    CONFIG_YES=${ARG_FLAGS[yes]:-}
    [[ -n ${CONFIG_ABOUT[$section]-} ]] || fail "gnoto config has no section $section. Run $(gnoto_command config) to list them."
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
        fail "$(gnoto_command config "$section") asks questions, so run it from a terminal, or give --on, --off or its settings as --<key>=<value>."
    fi
    enabled=true
    [[ $option != --off ]] || enabled=false
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
    elif [[ $(SECTION=$section yq '.[strenv(SECTION)].enabled' "$CONFIG_FILE") == true ]]; then
        echo "$section is on, in $CONFIG_FILE." >&2
    else
        echo "$section is off, in $CONFIG_FILE. To turn it on, run: $(gnoto_command config "$section" --on)" >&2
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
