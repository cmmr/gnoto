#
# args.sh - The command-line parser that gnoto's commands in the image share.
#
# Sourced by:  lib/main.sh, and the tests that call a command's function
# Defines:     args_parse, which sets ARG_FLAGS, ARG_KEYS, ARG_VALUES and
#              ARG_WORDS
# Requires:    fail, from lib/utilities.sh
#
# args_parse "<usage>" "<flags>" <arguments>. <flags> names the command's
# valueless flags, such as "debug yes", and --<flag> sets ARG_FLAGS[<flag>].
# Every other --<key> takes a value, as --<key>=<value> or --<key> <value>, and
# goes in ARG_KEYS and ARG_VALUES, in the order given. A value can be empty, or
# hold spaces or =, but after a space it can't start with --. Anything else is a
# word, in ARG_WORDS. A key given twice, or a flag given a value, fails with the
# usage. gnoto init, which runs in the launcher, follows the same rules.

args_parse() {
    local usage=$1 flags=" $2 " arg key value
    shift 2

    declare -gA ARG_FLAGS=()
    ARG_KEYS=()
    ARG_VALUES=()
    ARG_WORDS=()
    while [[ $# -gt 0 ]]; do
        arg=$1
        shift
        if [[ $arg != --* ]]; then
            [[ $arg != -?* ]] || fail "$arg isn't an option. $usage"
            ARG_WORDS+=("$arg")
            continue
        fi
        key=${arg#--}
        key=${key%%=*}
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fail "$arg isn't an option. $usage"
        if [[ $flags == *" $key "* ]]; then
            [[ $arg != *=* ]] || fail "--$key takes no value. $usage"
            ARG_FLAGS[$key]=1
            continue
        fi
        if [[ $arg == *=* ]]; then
            value=${arg#*=}
        elif [[ $# -gt 0 && $1 != --* ]]; then
            value=$1
            shift
        else
            fail "--$key needs a value, as --$key=<value>. $usage"
        fi
        [[ " ${ARG_KEYS[*]} " != *" $key "* ]] || fail "--$key is given twice."
        ARG_KEYS+=("$key")
        ARG_VALUES+=("$value")
    done
}
