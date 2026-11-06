#!/bin/bash
#
# stub.sh - A stand-in for a host command, for test/helper/stub-test.sh.
#
# Linked under each allowed command name. The first argument picks what it does.

MODE=$1
shift
case $MODE in
    exit) exit "$1" ;;
    args) printf '[%s]\n' "$@" ;;
    big) seq "$1" | gzip -n -1 ;;
    stderr) echo "out" && echo "err" >&2 ;;
    env) tr '\0' '\n' < /proc/$$/environ | LC_ALL=C sort ;;
    pwd) pwd ;;
    stdin) cat ;;
    signals) grep -E '^Sig(Ign|Blk)' /proc/$$/status ;;
    sleep)
        echo $$ > "$1"
        exec sleep "$2"
        ;;
esac
