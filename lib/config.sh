#
# config.sh - gnoto config: lists the sections of config.yaml, asks for one
# section's settings, or turns a section on or off.
#
# Sourced by:  lib/main.sh, for gnoto config [<section> [--on|--off]] and
#              gnoto config slurm --probe
# Defines:     config_main, config_set
# Requires:    yq, flock; the settings and helpers from lib/env.sh, which loads
#              each section's declarations from lib/config/
# Env:         INSTALL_DIR and the current settings, from lib/env.sh;
#              GNOTO_FOUND_APPTAINER_BIN_DIR, GNOTO_FOUND_SLURM_BIN_DIR and
#              GNOTO_FOUND_SLURM_CONF, what the launcher found on the host
#
# gnoto config prints each section and what it's for. gnoto config <section>
# asks for each of its settings, suggesting what the section's own suggest
# function finds, or else the current value. --on and --off set its enabled
# without asking. When config.yaml doesn't have the section yet, either way adds
# the whole section, and only that section, so config.yaml holds only what a
# site has chosen. Asking turns a new section on. gnoto config slurm --probe
# checks every compute node with a Slurm job, from lib/nodes.sh, and writes
# nothing to config.yaml.
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
        [[ $key != enabled ]] || continue
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

# Says what's wrong with a value for a type of setting, if anything
config_check() {
    local type=$1 value=$2
    if [[ $value == *'"'* ]]; then
        echo "  A double quote can't go in config.yaml." >&2
        return 1
    fi
    case $type in
        int) [[ -z $value || $value =~ ^[0-9]+$ ]] || { echo "  Give a whole number." >&2; return 1; } ;;
        path) [[ -z $value || $value == /* ]] || { echo "  Give an absolute path, or none." >&2; return 1; } ;;
        paths)
            [[ -z $value || ",$value," =~ ^(,/[^,]+)+,$ ]] ||
                { echo "  Give absolute paths, separated by commas, or none." >&2; return 1; }
            ;;
        dir)
            if [[ $value != /* ]]; then
                echo "  Give an absolute path." >&2
                return 1
            elif [[ -d $value && ! -w $value ]]; then
                echo "  You can't write to $value." >&2
                return 1
            fi
            ;;
    esac
}

# Asks for section.key, offering a suggestion, until the answer suits its type,
# and sets ANSWER. Enter keeps the suggestion, and "none" clears it. A secret
# isn't shown, as it's typed or as a suggestion.
config_ask() {
    local section=$1 key=$2 suggestion=$3 type=${CONFIG_TYPE[$1.$2]} shown

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
        config_check "$type" "$ANSWER" && return 0
    done
}

# Fills CONFIG_NEW with a value for each of a section's settings but enabled:
# asked for, or with $2 empty, the suggestions as they are
config_walk() {
    local section=$1 ask=$2 key

    for key in ${CONFIG_KEYS[$section]}; do
        [[ $key != enabled ]] || continue
        if [[ -n $ask ]]; then
            config_ask "$section" "$key" "$(config_suggest "$section" "$key")"
        else
            ANSWER=$(config_suggest "$section" "$key")
            config_check "${CONFIG_TYPE[$section.$key]}" "$ANSWER" ||
                fail "Can't use \"$ANSWER\" for $section.$key, so nothing was written."
        fi
        CONFIG_NEW[$key]=$ANSWER
    done
}

config_main() {
    local section=${1:-} option=${2:-} present="" enabled key

    if [[ -z $section ]]; then
        for section in "${CONFIG_SECTIONS[@]}"; do
            printf '%-10s %s\n' "$section" "${CONFIG_ABOUT[$section]}"
        done
        return 0
    fi
    [[ -n ${CONFIG_ABOUT[$section]-} ]] || fail "gnoto config has no section $section. Run gnoto config to list them."
    [[ $# -le 2 ]] || fail "gnoto config $section takes --on or --off, and nothing else."
    case $option in
        "") [[ -t 0 ]] || fail "gnoto config $section asks questions, so run it from a terminal, or give --on or --off." ;;
        --probe)
            [[ $section == slurm ]] || fail "--probe is for gnoto config slurm, which checks every compute node."
            source "$CODE_DIR/lib/lint.sh"
            nodes_probe
            return
            ;;
        --on | --off)
            [[ $section != core ]] || fail "core is always on. Run gnoto config core to change its settings."
            [[ $section != apptainer || $option == --on ]] ||
                fail "Apptainer is gnoto's only container engine, so it can't be turned off."
            ;;
        *) fail "gnoto config $section takes --on or --off, not $option." ;;
    esac

    declare -gA CONFIG_NEW=()
    ! config_has_section "$section" || present=1
    if [[ -z $option ]]; then
        echo "Press Enter to keep a suggestion, or type none to clear it." >&2
        config_walk "$section" ask
        if [[ -z $present ]]; then
            config_add_section "$section" true
        else
            for key in ${CONFIG_KEYS[$section]}; do
                [[ $key == enabled ]] || config_set "$section" "$key" "${CONFIG_NEW[$key]}"
            done
        fi
    else
        enabled=false
        [[ $option == --off ]] || enabled=true
        if [[ -z $present ]]; then
            config_walk "$section" ""
            config_add_section "$section" "$enabled"
        else
            config_set "$section" enabled "$enabled"
        fi
    fi

    if [[ $section == core ]]; then
        echo "core is set, in $CONFIG_FILE." >&2
    elif [[ $(SECTION=$section yq '.[strenv(SECTION)].enabled' "$CONFIG_FILE") == true ]]; then
        echo "$section is on, in $CONFIG_FILE." >&2
    else
        echo "$section is off, in $CONFIG_FILE. To turn it on, run: gnoto config $section --on" >&2
    fi
}
