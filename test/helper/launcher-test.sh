#!/bin/bash
#
# launcher-test.sh - Tests how the gnoto launcher reads config.yaml and IMAGE and
# builds its apptainer command, with a stub apptainer.
#
# Usage:     test/helper/launcher-test.sh
# Requires:  bash, dash and coreutils, as in debian:13-slim
#
# Copies the launcher and host/ into a scratch install directory per case, so
# config.yaml and IMAGE can vary, and runs it with dash as sh. The stub prints
# its arguments and the APPTAINERENV_ variables it was given.

set -u

CODE_DIR=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
FAILED=0
trap 'rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

mkdir -p "$WORK/stub/bin"
cat > "$WORK/stub/bin/apptainer" << 'EOF'
#!/bin/bash
if [[ $1 == pull ]]; then
    echo "pull $3" >&2
    : > "$2"
    exit 0
fi
printf 'arg %s\n' "$@"
env | grep '^APPTAINERENV_' | sort | sed 's/^/env /'
EOF
chmod +x "$WORK/stub/bin/apptainer"

# Makes an install directory with the given config.yaml core section and IMAGE
install_case() {
    local dir=$WORK/$1
    mkdir -p "$dir/lib" "$dir/data/images"
    cp -r "$CODE_DIR/gnoto" "$CODE_DIR/host" "$dir/"
    printf '%s\n' "$2" > "$dir/config.yaml"
    echo "${3:-gnoto-test.sif}" > "$dir/IMAGE"
    : > "$dir/data/images/gnoto-test.sif"
    echo "$dir"
}

launch() {
    local dir=$1
    shift
    env -i PATH="$WORK/stub/bin:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" "$@" dash "$dir/gnoto" exec true 2>&1
}

binds() {
    awk '/^arg -B$/ { getline; sub(/^arg /, ""); printf "%s ", $0 }' | sed 's/ $//'
}

DIR=$(install_case defaults 'core:
  data_dir: ""
  db_dir: ""')
OUT=$(launch "$DIR")
PRIVATE=$(sed -n 's/^env APPTAINERENV_GNOTO_HELPER_DIR=//p' <<< "$OUT")
check "defaults: binds" "$DIR $DIR/data $DIR/data/db $PRIVATE" "$(binds <<< "$OUT")"
check "defaults: image" "arg $DIR/data/images/gnoto-test.sif" "$(grep -F "arg $DIR/data/images/" <<< "$OUT")"
check "defaults: command" "arg /bin/bash arg $DIR/lib/main.sh arg exec arg true" \
    "$(sed -n '/^arg \/bin\/bash$/,$p' <<< "$OUT" | grep '^arg' | tr '\n' ' ' | sed 's/ $//')"
check "defaults: private directory removed" "gone" "$([[ -e $PRIVATE ]] && echo there || echo gone)"

DIR=$(install_case settings 'wrike:
  data_dir: "/wrong/section"
core:
  data_dir: "'"$WORK"'/elsewhere"   # with a comment
  db_dir: "'"$WORK"'/db dir"
  apptainer_binds: "/a,/b"
    nested: "/ignored"
aws:
  region: ""')
mkdir -p "$WORK/elsewhere/images"
: > "$WORK/elsewhere/images/gnoto-test.sif"
OUT=$(launch "$DIR")
PRIVATE=$(sed -n 's/^env APPTAINERENV_GNOTO_HELPER_DIR=//p' <<< "$OUT")
check "settings: binds" "$DIR $WORK/elsewhere $WORK/db dir $PRIVATE /a,/b" "$(binds <<< "$OUT")"
check "settings: data directory passed in" "env APPTAINERENV_GNOTO_DATA_DIR=$WORK/elsewhere" \
    "$(grep '^env APPTAINERENV_GNOTO_DATA_DIR=' <<< "$OUT")"

DIR=$(install_case unquoted 'core:
  data_dir: /unquoted')
check "unquoted value refused" "gnoto: config.yaml: write core.data_dir as   data_dir: \"value\"   with the value in double quotes" \
    "$(launch "$DIR")"

DIR=$(install_case trailing 'core:
  data_dir: "/x" trailing')
check "trailing text refused" "1" "$(launch "$DIR" > /dev/null; echo $?)"

DIR=$(install_case caller-env 'core:
  data_dir: ""')
OUT=$(launch "$DIR" APPTAINERENV_LEAK=1 SINGULARITYENV_LEAK=1)
check "caller's APPTAINERENV_ variables dropped" "" "$(grep -E 'LEAK' <<< "$OUT")"
check "image environment" "APPTAINERENV_GNOTO_CODE_DIR APPTAINERENV_GNOTO_DATA_DIR APPTAINERENV_GNOTO_DB_DIR APPTAINERENV_GNOTO_HELPER_DIR APPTAINERENV_GNOTO_INSTALL_DIR APPTAINERENV_PREPEND_PATH APPTAINERENV_USER" \
    "$(sed -n 's/^env \(APPTAINERENV_[A-Z_]*\)=.*/\1/p' <<< "$OUT" | tr '\n' ' ' | sed 's/ $//')"

DIR=$(install_case home "core:
  apptainer_home: \"$WORK/stub\"")
check "apptainer_home puts apptainer on PATH" "0" \
    "$(env -i PATH=/usr/bin:/bin HOME="$WORK" TMPDIR="$WORK" dash "$DIR/gnoto" exec true > /dev/null 2>&1; echo $?)"

DIR=$(install_case pull 'core:
  data_dir: ""' 'docker://ghcr.io/cmmr/gnoto@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef')
OUT=$(launch "$DIR")
check "image by digest is pulled" "pull docker://ghcr.io/cmmr/gnoto@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
    "$(grep '^pull ' <<< "$OUT")"
check "and run from images/" "arg $DIR/data/images/gnoto-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.sif" \
    "$(grep -F "arg $DIR/data/images/gnoto-" <<< "$OUT")"
check "a second run doesn't pull again" "" "$(launch "$DIR" | grep '^pull ')"

DIR=$(install_case no-newline 'core:
  data_dir: ""')
printf 'gnoto-test.sif' > "$DIR/IMAGE"
check "IMAGE without a final newline, and stdin closed" "0" "$(launch "$DIR" <&- > /dev/null; echo $?)"

DIR=$(install_case path 'core:
  data_dir: ""' '../outside.sif')
check "IMAGE with a path refused" "1" "$(launch "$DIR" > /dev/null; echo $?)"

rm "$DIR/config.yaml"
check "missing config.yaml" "1" "$(launch "$DIR" > /dev/null; echo $?)"

exit $FAILED
