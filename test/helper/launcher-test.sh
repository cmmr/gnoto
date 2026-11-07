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
echo "host PATH=$PATH"
echo "host SLURM_CONF=${SLURM_CONF-}"
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
    nested: "/ignored"
apptainer:
  enabled: true
  binds: "/a,/b"
slurm:
  enabled: true    # with a comment
  bin_dir: "/opt/slurm/bin"
  conf: "/etc/site/slurm.conf"
aws:
  region: ""')
mkdir -p "$WORK/elsewhere/images"
: > "$WORK/elsewhere/images/gnoto-test.sif"
OUT=$(launch "$DIR")
PRIVATE=$(sed -n 's/^env APPTAINERENV_GNOTO_HELPER_DIR=//p' <<< "$OUT")
check "settings: binds" "$DIR $WORK/elsewhere $WORK/db dir $PRIVATE /a,/b" "$(binds <<< "$OUT")"
check "settings: data directory passed in" "env APPTAINERENV_GNOTO_DATA_DIR=$WORK/elsewhere" \
    "$(grep '^env APPTAINERENV_GNOTO_DATA_DIR=' <<< "$OUT")"
check "settings: slurm.bin_dir first on the host PATH" "host PATH=/opt/slurm/bin:$WORK/stub/bin:/usr/bin:/bin" \
    "$(grep '^host PATH=' <<< "$OUT")"
check "settings: slurm.conf becomes SLURM_CONF" "host SLURM_CONF=/etc/site/slurm.conf" \
    "$(grep '^host SLURM_CONF=' <<< "$OUT")"

sed -i 's/^  enabled: true    # with a comment$/  enabled: false/' "$DIR/config.yaml"
OUT=$(launch "$DIR")
check "slurm off: its bin_dir and conf don't count" "host PATH=$WORK/stub/bin:/usr/bin:/bin host SLURM_CONF=" \
    "$(grep '^host ' <<< "$OUT" | tr '\n' ' ' | sed 's/ $//')"
sed -i '/^apptainer:$/,/^slurm:$/s/^  enabled: true$/  enabled: false/' "$DIR/config.yaml"
check "apptainer off" "gnoto: apptainer.enabled is false in $DIR/config.yaml, and gnoto has no other container engine yet. Set it to true." \
    "$(launch "$DIR")"
sed -i 's/^  enabled: false$/  enabled: yes/' "$DIR/config.yaml"
check "enabled that isn't true or false" "1" "$(launch "$DIR" > /dev/null; echo $?)"

DIR=$(install_case unquoted 'core:
  data_dir: /unquoted')
check "unquoted value refused" "gnoto: config.yaml: write core.data_dir as   data_dir: \"value\"   under core:, with the value in double quotes, or true or false" \
    "$(launch "$DIR")"

DIR=$(install_case trailing 'core:
  data_dir: "/x" trailing')
check "trailing text refused" "1" "$(launch "$DIR" > /dev/null; echo $?)"

DIR=$(install_case caller-env 'core:
  data_dir: ""')
OUT=$(launch "$DIR" APPTAINERENV_LEAK=1 SINGULARITYENV_LEAK=1)
check "caller's APPTAINERENV_ variables dropped" "" "$(grep -E 'LEAK' <<< "$OUT")"
check "image environment" "APPTAINERENV_GNOTO_BOOTSTRAP APPTAINERENV_GNOTO_CODE_DIR APPTAINERENV_GNOTO_DATA_DIR APPTAINERENV_GNOTO_DB_DIR APPTAINERENV_GNOTO_FOUND_APPTAINER_BIN_DIR APPTAINERENV_GNOTO_HELPER_DIR APPTAINERENV_GNOTO_INSTALL_DIR APPTAINERENV_PREPEND_PATH APPTAINERENV_USER" \
    "$(sed -n 's/^env \(APPTAINERENV_[A-Z_]*\)=.*/\1/p' <<< "$OUT" | tr '\n' ' ' | sed 's/ $//')"

DIR=$(install_case home "apptainer:
  bin_dir: \"$WORK/stub/bin\"")
check "apptainer.bin_dir puts apptainer on PATH" "0" \
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

# Without config.yaml, everything is at its default, with Apptainer from PATH
DIR=$(install_case no-config 'unused')
rm "$DIR/config.yaml"
OUT=$(launch "$DIR")
PRIVATE=$(sed -n 's/^env APPTAINERENV_GNOTO_HELPER_DIR=//p' <<< "$OUT")
check "no config.yaml: defaults" "$DIR $DIR/data $DIR/data/db $PRIVATE" "$(binds <<< "$OUT")"
check "no config.yaml: runs main.sh" "yes" "$(grep -qx "arg $DIR/lib/main.sh" <<< "$OUT" && echo yes || echo no)"
check "and writes none" "no" "$([[ -e $DIR/config.yaml ]] && echo yes || echo no)"
check "where apptainer was found is passed in" "env APPTAINERENV_GNOTO_FOUND_APPTAINER_BIN_DIR=$WORK/stub/bin" \
    "$(grep '^env APPTAINERENV_GNOTO_FOUND_APPTAINER' <<< "$OUT")"
check "no config.yaml and no apptainer" \
    "gnoto: can't find apptainer. Put its directory on PATH, or run: gnoto init --apptainer=/path/to/apptainer" \
    "$(env -i PATH=/usr/bin:/bin HOME="$WORK" TMPDIR="$WORK" dash "$DIR/gnoto" exec true 2>&1)"

mkdir -p "$WORK/slurm/bin"
printf '#!/bin/sh\n' > "$WORK/slurm/bin/sbatch"
chmod +x "$WORK/slurm/bin/sbatch"
OUT=$(env -i PATH="$WORK/stub/bin:$WORK/slurm/bin:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK" \
    SLURM_CONF=/etc/site/slurm.conf dash "$DIR/gnoto" exec true 2>&1)
check "where sbatch was found, and SLURM_CONF, are passed in" \
    $'env APPTAINERENV_GNOTO_FOUND_SLURM_BIN_DIR='"$WORK"$'/slurm/bin\nenv APPTAINERENV_GNOTO_FOUND_SLURM_CONF=/etc/site/slurm.conf' \
    "$(grep '^env APPTAINERENV_GNOTO_FOUND_SLURM' <<< "$OUT")"

# gnoto init, with no apptainer on PATH: it writes only the apptainer section
init_with() {
    (cd "$WORK" && env -i PATH=/usr/bin:/bin HOME="$WORK" TMPDIR="$WORK" dash "$DIR/gnoto" init "$@" 2>&1)
}
OUT=$(init_with --apptainer="$WORK/stub/bin/apptainer")
check "init: says what it wrote" \
    "Wrote $DIR/config.yaml, with apptainer.bin_dir \"$WORK/stub/bin\". gnoto config lists the other sections." "$OUT"
check "init: the apptainer section and nothing else" \
    $'# This install\'s settings. gnoto config lists the sections, and adds or changes one.\n\napptainer:\n  enabled: true\n  bin_dir: "'"$WORK"'/stub/bin"' \
    "$(cat "$DIR/config.yaml")"
check "init: mode 660, the user's group" "660 $(id -gn)" "$(stat -c '%a %G' "$DIR/config.yaml")"
OUT=$(env -i PATH=/usr/bin:/bin HOME="$WORK" TMPDIR="$WORK" dash "$DIR/gnoto" exec true 2>&1)
check "init: then gnoto runs without apptainer on PATH" "host PATH=$WORK/stub/bin:/usr/bin:/bin" \
    "$(grep '^host PATH=' <<< "$OUT")"
check "init: refused when config.yaml exists" \
    "gnoto: $DIR/config.yaml already exists. Edit it by hand, or run gnoto config." \
    "$(init_with --apptainer="$WORK/stub/bin/apptainer")"
rm "$DIR/config.yaml"
init_with --apptainer=stub/bin/ > /dev/null
check "init: a relative directory" "  bin_dir: \"$WORK/stub/bin\"" "$(grep bin_dir "$DIR/config.yaml")"
rm "$DIR/config.yaml"
init_with --apptainer stub/bin/apptainer > /dev/null
check "init: the space form" "  bin_dir: \"$WORK/stub/bin\"" "$(grep bin_dir "$DIR/config.yaml")"
rm "$DIR/config.yaml"
check "init: no option" "gnoto: Usage: gnoto init --apptainer=/path/to/apptainer" "$(init_with)"
check "init: no value" "gnoto: --apptainer needs a value, as --apptainer=/path/to/apptainer" \
    "$(init_with --apptainer)"
check "init: an empty value" "gnoto: --apptainer needs a value, as --apptainer=/path/to/apptainer" \
    "$(init_with --apptainer=)"
check "init: a value after a space can't start with --" \
    "gnoto: --apptainer needs a value, as --apptainer=/path/to/apptainer" "$(init_with --apptainer --x)"
check "init: given twice" "gnoto: --apptainer is given twice" \
    "$(init_with --apptainer="$WORK/stub/bin/apptainer" --apptainer "$WORK/stub/bin/apptainer")"
check "init: another option" "gnoto: gnoto init takes --apptainer=/path/to/apptainer, not --podman=/x" \
    "$(init_with --podman=/x)"
check "init: no apptainer there" "gnoto: there's no apptainer command at /usr/bin/apptainer" \
    "$(init_with --apptainer=/usr/bin/apptainer)"
check "init: and writes nothing" "no" "$([[ -e $DIR/config.yaml ]] && echo yes || echo no)"

exit $FAILED
