#
# versions.sh - The version cache: which commit the code runs at, resolving a
# version to a commit, fetching a commit into <data_dir>/versions/, handing a
# command to another version, and gnoto upgrade and gnoto prune.
#
# Sourced by:  lib/main.sh, before any command
# Defines:     code_version, install_commit, install_repository, current_commit,
#              current_repository, version_resolve, version_fetch, version_route,
#              version_reachable, latest_release, cache_lock, current_main,
#              upgrade_main, prune_main
# Requires:    git, tar, flock and du, from the image; the settings and helpers
#              from lib/env.sh, and args_parse from lib/args.sh
#
# Every version is a read-only copy of one commit, fetched with git from its
# repository into <data_dir>/repo.git, a bare repository shared by gnoto's
# group, and extracted into <data_dir>/versions/<commit>/ with a VERSION file
# naming the commit and repository. Its files are read-only and its directories
# group-writable, so any group member can delete a version. <data_dir>/current
# names the current version: its commit, then its repository, a line each.
#
# A command that calls for another version, such as a job naming
# ampliseq@<commit>, fetches it, writes "<commit>\nresolved" to the launcher's
# private directory as handover, and exits. The launcher then hands the same
# command to that version's launcher, which takes its version as resolved.
#
# COMPAT holds a number, 1 from the first commit with the version cache. A
# version runs only commits whose COMPAT is at least its own, so a commit
# without one, or from before a change that broke how versions hand over or
# read shared state, is refused.
#
# The cache lock, <data_dir>/versions/.lock, is taken shared by anything that
# fetches or is about to run a version, and exclusively by prune. A version
# used in the last hour is never pruned either, which covers a hand-over
# between one launcher and the next.

DEFAULT_REPOSITORY="https://github.com/cmmr/gnoto"

repo_git() {
    git -c safe.directory='*' -C "$DATA_DIR/repo.git" "$@"
}

# A field from a VERSION file
version_field() {
    sed -n "s/^$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *\$/\1/p" "$2" | head -1
}

# A git remote's URL as a repository gnoto records: https:// with any
# credentials taken out, or file:// for a repository on this machine. Prints
# nothing for anything else.
repository_url() {
    local url=$1
    case $url in
        git@*:*) url=$(sed -E 's#^git@([^:]+):#https://\1/#' <<< "$url") ;;
        /*) url=file://$url ;;
    esac
    case $url in
        https://*) sed -E -e 's#://[^/@]*@#://#' -e 's#\.git$##' <<< "$url" ;;
        file:///*) printf '%s' "$url" ;;
    esac
}

# The repository an install's own files came from: a git clone's origin, a
# release's VERSION, or gnoto's own
install_repository() {
    local dir=$1 url
    url=$(git -c safe.directory='*' -C "$dir" remote get-url origin 2> /dev/null) || url=""
    url=$(repository_url "$url")
    [[ -n $url || ! -r $dir/VERSION ]] || url=$(version_field repository "$dir/VERSION")
    printf '%s' "${url:-$DEFAULT_REPOSITORY}"
}

# The commit an install's own files are: a git clone's HEAD, or a release's
# VERSION. Prints nothing for neither. git runs without taking its index lock,
# because the install directory may belong to another user.
install_commit() {
    local dir=$1 top commit=""
    top=$(GIT_OPTIONAL_LOCKS=0 git -c safe.directory='*' -C "$dir" rev-parse --show-toplevel 2> /dev/null) || top=""
    if [[ -n $top && $(cd "$top" && pwd -P) == "$(cd "$dir" && pwd -P)" ]]; then
        commit=$(git -c safe.directory='*' -C "$dir" rev-parse HEAD 2> /dev/null) || commit=""
    elif [[ -r $dir/VERSION ]]; then
        commit=$(version_field commit "$dir/VERSION")
    fi
    [[ $commit =~ ^[0-9a-f]{40}$ ]] && printf '%s' "$commit"
    return 0
}

# Sets CODE_COMMIT, CODE_REPOSITORY and CODE_DEV for the code this runs from.
# Only a copy in the version cache has a commit. Anything else, such as the
# install directory under --dev, is dev.
code_version() {
    local commit=${CODE_DIR##*/}

    CODE_COMMIT=""
    CODE_REPOSITORY=$DEFAULT_REPOSITORY
    CODE_DEV=true
    if [[ ${CODE_DIR%/*} == */versions && $commit =~ ^[0-9a-f]{40}$ && -r $CODE_DIR/VERSION &&
        $(version_field commit "$CODE_DIR/VERSION") == "$commit" ]]; then
        CODE_COMMIT=$commit
        CODE_DEV=false
        CODE_REPOSITORY=$(version_field repository "$CODE_DIR/VERSION")
        CODE_REPOSITORY=${CODE_REPOSITORY:-$DEFAULT_REPOSITORY}
    else
        CODE_REPOSITORY=$(install_repository "$CODE_DIR")
    fi
}

# The current version's commit and repository, from <data_dir>/current
current_commit() {
    local commit=""
    [[ -r $DATA_DIR/current ]] && commit=$(sed -n 1p "$DATA_DIR/current")
    [[ $commit =~ ^[0-9a-f]{40}$ ]] && printf '%s' "$commit"
    return 0
}

current_repository() {
    local url=""
    [[ -r $DATA_DIR/current ]] && url=$(sed -n 2p "$DATA_DIR/current")
    printf '%s' "${url:-$DEFAULT_REPOSITORY}"
}

# Rewrites <data_dir>/current, by rename: current_write <commit> <repository>
current_write() {
    local tmp
    tmp=$(mktemp "$DATA_DIR/current.XXXXXX") && chmod 664 "$tmp" &&
        printf '%s\n%s\n' "$1" "$2" > "$tmp" && mv -f "$tmp" "$DATA_DIR/current" || {
        rm -f "$tmp"
        fail "Can't write $DATA_DIR/current."
    }
}

# Takes the cache lock on file descriptor 8: shared by default, or exclusive
# with "exclusive". Held until the process exits or closes 8.
cache_lock() {
    local how=-s
    [[ ${1:-} != exclusive ]] || how=-x
    mkdir -p "$DATA_DIR/versions" 2> /dev/null || :
    chmod 2775 "$DATA_DIR/versions" 2> /dev/null || :
    exec 8>> "$DATA_DIR/versions/.lock" || fail "Can't open $DATA_DIR/versions/.lock."
    flock "$how" -w 120 8 || {
        [[ $how == -x ]] && fail "Can't lock $DATA_DIR/versions: a command is fetching or starting a version. Try again in a minute."
        fail "Can't lock $DATA_DIR/versions: gnoto prune holds it. Try again in a minute."
    }
}

# A version's commit, from the part of pipeline@<version> after the @: a
# release such as 1.2.0 (the tag v1.2.0), a full commit, or a branch or tag
# name such as main. Prints the commit, or why not to stderr and returns 1.
version_resolve() {
    local repository=$1 ref=$2 refs out commit name

    if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s' "$ref"
        return 0
    fi
    if [[ $ref =~ ^[0-9a-f]{7,39}$ && ! $ref =~ ^[0-9]+$ ]]; then
        echo "a version needs the full 40-character commit, not $ref" >&2
        return 1
    fi
    # An annotated tag's commit is listed as <tag>^{}, which comes first.
    # ls-remote lists those only when it's given no pattern.
    if [[ $ref =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        refs=("refs/tags/v$ref")
    elif [[ $ref =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $ref != *..* && $ref != *.lock ]]; then
        refs=("refs/heads/$ref" "refs/tags/$ref")
    else
        echo "\"$ref\" isn't a version: give a release such as 1.2.0, a full commit, or a branch such as main" >&2
        return 1
    fi
    if ! out=$(git ls-remote --heads --tags "$repository" 2>&1); then
        echo "can't reach $repository to look up $ref: $(tail -1 <<< "$out")" >&2
        return 1
    fi
    for name in "${refs[@]}"; do
        commit=$(awk -v name="$name" '$2 == name "^{}" { print $1; exit } $2 == name { found = $1 }
            END { if (found != "") print found }' <<< "$out" | head -1)
        if [[ $commit =~ ^[0-9a-f]{40}$ ]]; then
            printf '%s' "$commit"
            return 0
        fi
    done
    echo "$repository has no release, branch or tag $ref" >&2
    return 1
}

# The newest release, as the tag v<major>.<minor>.<patch> with the highest
# number, or nothing when there's none
latest_release() {
    git ls-remote --tags --refs "$1" 2> /dev/null |
        sed -n 's#.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' | sort -V | tail -1
}

# The release tag that names a commit exactly, if any
release_of() {
    git ls-remote --tags "$1" 2> /dev/null | awk -v commit="$2" '
        $1 == commit && $2 ~ /^refs\/tags\/v[0-9]/ {
            name = $2; sub(/^refs\/tags\//, "", name); sub(/\^\{\}$/, "", name); print name; exit
        }'
}

# The cache's directories, made group-shared the first time
version_dirs() {
    mkdir -p "$DATA_DIR/versions" || return 1
    chmod 2775 "$DATA_DIR/versions" 2> /dev/null || :
    if [[ ! -d $DATA_DIR/repo.git ]]; then
        git init -q --bare --shared=group "$DATA_DIR/repo.git.tmp.$$" &&
            mv "$DATA_DIR/repo.git.tmp.$$" "$DATA_DIR/repo.git" 2> /dev/null ||
            rm -rf "$DATA_DIR/repo.git.tmp.$$"
        [[ -d $DATA_DIR/repo.git ]] || return 1
    fi
}

# Fails, saying why, when a commit's COMPAT is below this code's, or missing
version_compat_ok() {
    local commit=$1 theirs ours
    ours=$(head -1 "$CODE_DIR/COMPAT" 2> /dev/null)
    theirs=$(repo_git show "$commit:COMPAT" 2> /dev/null | head -1) || theirs=""
    if [[ ! $theirs =~ ^[0-9]+$ ]]; then
        echo "commit $commit is older than gnoto's version cache, so gnoto can't run it" >&2
        return 1
    fi
    if (( theirs < ${ours:-1} )); then
        echo "commit $commit is from before a change this version of gnoto can't run across: its COMPAT is $theirs, and this version's is $ours" >&2
        return 1
    fi
}

# Fetches a commit into <data_dir>/versions/<commit>, unless it's there
# already: version_fetch <repository> <commit>. git checks the content against
# the commit. Prints what it does to stderr, and why it failed.
version_fetch() {
    local repository=$1 commit=$2 dir=$DATA_DIR/versions/$2 status=0

    if [[ -x $dir/gnoto ]]; then
        touch -c "$dir" 2> /dev/null || :
        return 0
    fi
    version_dirs || { echo "can't create $DATA_DIR/versions and $DATA_DIR/repo.git" >&2; return 1; }
    (
        flock -w 900 9 || { echo "can't lock $DATA_DIR/versions to fetch $commit" >&2; exit 1; }
        [[ -x $dir/gnoto ]] && exit 0
        if repo_git cat-file -e "$commit^{commit}" 2> /dev/null; then
            repo_git update-ref "refs/gnoto/$commit" "$commit" || exit 1
        else
            echo "Fetching gnoto at $commit from $repository." >&2
            out=$(repo_git fetch -q --no-tags --no-write-fetch-head "$repository" "+$commit:refs/gnoto/$commit" 2>&1) || {
                echo "can't fetch commit $commit from $repository: $(tail -1 <<< "$out")" >&2
                exit 1
            }
        fi
        version_compat_ok "$commit" || exit 1
        tmp=$(mktemp -d "$DATA_DIR/versions/.tmp.XXXXXX") && chmod 2775 "$tmp" || exit 1
        if ! repo_git archive "$commit" | tar -x -C "$tmp" ||
            ! printf 'commit: "%s"\nrepository: "%s"\n' "$commit" "$repository" > "$tmp/VERSION"; then
            rm -rf "$tmp"
            echo "can't extract commit $commit into $DATA_DIR/versions" >&2
            exit 1
        fi
        find "$tmp" -type d -exec chmod 2775 {} + && find "$tmp" -type f -exec chmod a-w {} + &&
            mv "$tmp" "$dir" || { rm -rf "$tmp"; echo "can't move commit $commit into $dir" >&2; exit 1; }
    ) 9>> "$DATA_DIR/versions/.fetch.lock" || status=$?
    return $status
}

# Runs the command here when the commit is this code's own. Otherwise fetches
# it, leaves the hand-over for the launcher, and exits, so the launcher hands
# the command to that version: version_route <repository> <commit>
version_route() {
    local repository=$1 commit=$2
    [[ $commit != "$CODE_COMMIT" ]] || return 0
    [[ -n ${GNOTO_HELPER_DIR:-} && -d $GNOTO_HELPER_DIR ]] ||
        fail "Can't hand this command to gnoto at $commit: the launcher didn't pass its private directory."
    cache_lock
    version_fetch "$repository" "$commit" || fail "Can't run gnoto at $commit, which this command calls for."
    printf '%s\nresolved\n' "$commit" > "$GNOTO_HELPER_DIR/handover" ||
        fail "Can't hand this command to gnoto at $commit."
    exit 0
}

# The commit a job's version names, from the part after @: version_commit <ref>.
# Nothing names the current version. A command handed here with its version
# resolved runs as this version.
version_commit() {
    local ref=$1 commit
    if [[ -n $CODE_COMMIT && ${GNOTO_RESOLVED:-} == "$CODE_COMMIT" ]]; then
        printf '%s' "$CODE_COMMIT"
        return 0
    fi
    if [[ -z $ref ]]; then
        commit=$(current_commit)
        [[ -n $commit ]] || commit=$CODE_COMMIT
        printf '%s' "$commit"
        return 0
    fi
    version_resolve "$CODE_REPOSITORY" "$ref"
}

# Whether main or a release reaches a commit: GitHub serves a commit neither
# reaches for now, but doesn't promise to keep it. Prints yes or no, or nothing
# when it can't tell.
version_reachable() {
    local repository=$1 commit=$2 tips tip
    tips=$(git ls-remote --heads --tags "$repository" 2> /dev/null |
        awk '$2 == "refs/heads/main" || $2 ~ /^refs\/tags\/v[0-9]/ { print $1 }' | sort -u) || return 0
    [[ -n $tips ]] || { echo no; return 0; }
    grep -qx "$commit" <<< "$tips" && { echo yes; return 0; }
    version_dirs 2> /dev/null || return 0
    for tip in $tips; do
        repo_git cat-file -e "$tip^{commit}" 2> /dev/null ||
            repo_git fetch -q --no-tags --no-write-fetch-head "$repository" "+$tip:refs/gnoto/tips/$tip" 2> /dev/null ||
            return 0
        if repo_git merge-base --is-ancestor "$commit" "$tip" 2> /dev/null; then
            echo yes
            return 0
        fi
    done
    echo no
}

# _current: run from the install directory's own files when the current
# version has no copy. Makes this install's own commit current on its first
# command, or fetches the current version's copy again, then hands the command
# on to it.
current_main() {
    local commit repository changes hint=""
    commit=$(current_commit)
    if [[ -n $commit ]]; then
        repository=$(current_repository)
    else
        hint=" If this install's commit isn't on its repository yet, push it, or run its own files with --dev."
        commit=$(install_commit "$INSTALL_DIR")
        repository=$(install_repository "$INSTALL_DIR")
        [[ -n $commit ]] ||
            fail "This install has no current version yet, and isn't a release or a git clone with a commit to start from. Choose one with $(gnoto_command upgrade '<version>'), such as $(gnoto_command upgrade main), or run its own files with --dev."
        changes=$(GIT_OPTIONAL_LOCKS=0 git -c safe.directory='*' -C "$INSTALL_DIR" status --porcelain \
            --untracked-files=no 2> /dev/null) || changes=""
        echo "This install's first command: gnoto at $commit, its own commit, becomes the current version." >&2
        [[ -z $changes ]] || echo "Its changes since that commit run only with --dev." >&2
    fi
    cache_lock
    version_fetch "$repository" "$commit" || fail "Can't run gnoto at $commit, the current version.$hint"
    [[ -n $(current_commit) ]] || current_write "$commit" "$repository"
    printf '%s\ncurrent\n' "$commit" > "$GNOTO_HELPER_DIR/handover" ||
        fail "Can't hand the command to gnoto at $commit."
}

# What changed between two versions: the release notes in the new version's
# CHANGELOG.md above the old version's entry, or, until there's one, the
# commits between them
upgrade_notes() {
    local repository=$1 from=$2 to=$3 tag lines
    if [[ -r $DATA_DIR/versions/$to/CHANGELOG.md ]]; then
        tag=$(release_of "$repository" "$from")
        awk -v tag="$tag" '/^## / && tag != "" && index($0, tag) { exit } { print }' \
            "$DATA_DIR/versions/$to/CHANGELOG.md" | head -200
        return
    fi
    [[ -n $from ]] && repo_git cat-file -e "$from^{commit}" 2> /dev/null || return 0
    lines=$(repo_git log --oneline --no-decorate "$from..$to" 2> /dev/null | head -50)
    [[ -z $lines ]] || { echo "Commits it adds:"; sed 's/^/  /' <<< "$lines"; }
    lines=$(repo_git log --oneline --no-decorate "$to..$from" 2> /dev/null | head -50)
    [[ -z $lines ]] || { echo "Commits it leaves out:"; sed 's/^/  /' <<< "$lines"; }
}

# gnoto upgrade [--yes] [<version>]: makes a version current, and hands over
# to its gnoto lint
upgrade_main() {
    local usage="Usage: gnoto upgrade [--yes] [<version>]" ref commit current repository label answer

    args_parse "$usage" "yes" "$@"
    [[ ${#ARG_KEYS[@]} -eq 0 ]] || fail "gnoto upgrade takes --yes, not --${ARG_KEYS[0]}. $usage"
    [[ ${#ARG_WORDS[@]} -le 1 ]] || fail "$usage"
    [[ -n ${GNOTO_HELPER_DIR:-} && -d $GNOTO_HELPER_DIR ]] ||
        fail "gnoto upgrade needs the launcher's private directory, to run the new version's lint."
    code_version
    repository=$CODE_REPOSITORY
    current=$(current_commit)
    ref=${ARG_WORDS[0]:-}
    if [[ -z $ref ]]; then
        ref=$(latest_release "$repository")
        ref=${ref#v}
        [[ -n $ref ]] || ref=main
    fi
    commit=$(version_resolve "$repository" "$ref") || fail "Can't upgrade."
    label="$ref (commit $commit)"
    [[ $ref != "$commit" ]] || label="at $commit"
    if [[ $commit == "$current" && -x $DATA_DIR/versions/$commit/gnoto ]]; then
        echo "gnoto $label is current already."
        return 0
    fi
    cache_lock
    version_fetch "$repository" "$commit" || fail "Can't upgrade to $ref."

    echo "Upgrading gnoto to $label${current:+, from $current}."
    upgrade_notes "$repository" "$current" "$commit"
    if [[ -z ${ARG_FLAGS[yes]:-} ]]; then
        [[ -t 0 ]] || fail "No terminal to confirm on. Add --yes to upgrade."
        printf 'Make it the current version? Running and waiting jobs keep their own. [y/N] ' >&2
        read -r answer || answer=""
        [[ $answer == [yY]* ]] || fail "Not upgraded."
    fi
    current_write "$commit" "$repository"
    echo "gnoto $label is the current version. Jobs already running or waiting keep their own versions."
    echo "Running its gnoto lint."
    printf '%s\nlint\n' "$commit" > "$GNOTO_HELPER_DIR/handover" || fail "Can't run the new version's lint."
}

# A version's gnoto image file in <data_dir>/images, and whether it can be
# pulled again, as "<file>\t<pullable>"
version_image() {
    local image
    IFS= read -r image < "$1/IMAGE" 2> /dev/null || return 0
    case $image in
        docker://*@sha256:*)
            local name=${image#docker://}
            name=${name%%@*}
            printf '%s-%s.sif\tyes\n' "${name##*/}" "${image##*@sha256:}"
            ;;
        *.sif) printf '%s\tno\n' "$image" ;;
    esac
}

# Every image file a version's code names in <data_dir>/images, as
# "<file>\t<pullable>": its gnoto image; its step images, named as
# container_sif names them; and its Nextflow task images, from containers.config
# and its own modules, named as Nextflow names them in its cache. A version from
# before the lock files named its task images by tag, which isn't read here.
version_images() {
    local dir=$1 lock address
    version_image "$dir"
    for lock in "$dir"/pipelines/*/lock.yaml; do
        [[ -f $lock ]] || continue
        while IFS= read -r address; do
            if [[ $address =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*\.sif$ ]]; then
                printf '%s\tno\n' "$address"
            elif [[ $address == *@sha256:* ]]; then
                address=${address//\//-}
                printf '%s.sif\tyes\n' "${address/@sha256:/@sha256-}"
            fi
        done < <(yq -r '.step_images // {} | .[]' "$lock" 2> /dev/null)
    done
    cat "$dir"/pipelines/*/containers.config "$dir"/modules/*.nf "$dir"/workflows/*/*.nf 2> /dev/null |
        grep -oE "https://[a-z0-9.-]+/[^' ]*/blobs/sha256/[0-9a-f]{2}/[0-9a-f]{64}/data|[a-z0-9.-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}" |
        sort -u | while IFS= read -r address; do
            address=${address#https://}
            address=${address//\//-}
            printf '%s.img\tyes\n' "${address//:/-}"
        done
}

# gnoto prune [--yes]: removes the versions no running or waiting job uses,
# keeping the current one and any used in the last hour, and every image file
# no version it keeps names, except a local .sif a version names, which can't
# be pulled again, and any pulled in the last hour
prune_main() {
    local usage="Usage: gnoto prune [--yes]" dir commit status answer image pullable file bytes=0
    local -A keep=() why=() keep_image=()
    local remove=() images=() unpullable=0

    args_parse "$usage" "yes" "$@"
    [[ ${#ARG_KEYS[@]} -eq 0 && ${#ARG_WORDS[@]} -eq 0 ]] || fail "$usage"
    [[ -d $DATA_DIR/versions ]] || { echo "Nothing to prune: there's no $DATA_DIR/versions."; return 0; }
    cache_lock exclusive

    commit=$(current_commit)
    [[ -z $commit ]] || { keep[$commit]=1; why[$commit]="the current version"; }
    for dir in "$DATA_DIR"/runs/*/; do
        [[ -r $dir/run_state.json ]] || continue
        status=$(jq -r '.status // ""' "$dir/run_state.json" 2> /dev/null) || continue
        case $status in Completed | Failed | Cancelled | "Publish failed") continue ;; esac
        commit=$(jq -r '.commit // ""' "$dir/run_state.json")
        [[ $commit =~ ^[0-9a-f]{40}$ ]] || continue
        keep[$commit]=1
        why[$commit]+="${why[$commit]:+, }run ${dir%/}"
        why[$commit]=${why[$commit]//"$DATA_DIR/runs/"/}
    done
    while IFS= read -r dir; do
        commit=${dir##*/}
        [[ -n ${keep[$commit]:-} ]] || { keep[$commit]=1; why[$commit]="used in the last hour"; }
    done < <(find "$DATA_DIR/versions" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9a-f]{40}' -mmin -60)

    for dir in "$DATA_DIR"/versions/*/; do
        dir=${dir%/}
        commit=${dir##*/}
        [[ $commit =~ ^[0-9a-f]{40}$ ]] || continue
        if [[ -n ${keep[$commit]:-} ]]; then
            while IFS=$'\t' read -r image _; do
                keep_image[$image]=1
            done < <(version_images "$dir")
        else
            remove+=("$commit")
        fi
    done
    while IFS=$'\t' read -r image _; do
        keep_image[$image]=1
    done < <(version_images "$INSTALL_DIR")
    for commit in ${remove[@]+"${remove[@]}"}; do
        while IFS=$'\t' read -r image pullable; do
            [[ $pullable == no && -z ${keep_image[$image]:-} && -f $DATA_DIR/images/$image ]] || continue
            keep_image[$image]=1
            unpullable=$((unpullable + 1))
        done < <(version_images "$DATA_DIR/versions/$commit")
    done
    while IFS= read -r file; do
        [[ -n ${keep_image[$file]:-} ]] || images+=("$file")
    done < <(find "$DATA_DIR/images" -maxdepth 1 -type f \( -name '*.sif' -o -name '*.img' \) -mmin +60 \
        -printf '%f\n' 2> /dev/null | sort)

    for commit in "${!keep[@]}"; do
        [[ -d $DATA_DIR/versions/$commit ]] && echo "Keeping $commit: ${why[$commit]}."
    done
    if (( ${#remove[@]} == 0 && ${#images[@]} == 0 )); then
        echo "Nothing to prune."
        return 0
    fi
    for commit in ${remove[@]+"${remove[@]}"}; do
        echo "Removing version $commit"
    done
    for image in ${images[@]+"${images[@]}"}; do
        echo "Removing image $DATA_DIR/images/$image"
    done
    (( unpullable == 0 )) ||
        echo "Keeping $unpullable image file$( (( unpullable == 1 )) || echo s) only those versions named, because gnoto can't pull a local .sif again."
    if [[ -z ${ARG_FLAGS[yes]:-} ]]; then
        [[ -t 0 ]] || fail "No terminal to confirm on. Add --yes to prune."
        printf 'Remove them? [y/N] ' >&2
        read -r answer || answer=""
        [[ $answer == [yY]* ]] || fail "Nothing removed."
    fi
    for commit in ${remove[@]+"${remove[@]}"}; do
        # Renamed first, so a half-deleted version never looks whole
        file=$(mktemp -d "$DATA_DIR/versions/.tmp.prune.XXXXXX") &&
            mv "$DATA_DIR/versions/$commit" "$file/" && rm -rf "$file" ||
            warn "Couldn't remove $DATA_DIR/versions/$commit."
        repo_git update-ref -d "refs/gnoto/$commit" 2> /dev/null || :
    done
    for image in ${images[@]+"${images[@]}"}; do
        rm -f "$DATA_DIR/images/$image" "$DATA_DIR/images/$image.lock" ||
            warn "Couldn't remove $DATA_DIR/images/$image."
    done
    find "$DATA_DIR/versions" -mindepth 1 -maxdepth 1 -name '.tmp.*' -mmin +1440 -exec rm -rf {} + 2> /dev/null || :
    echo "Removed ${#remove[@]} version$( (( ${#remove[@]} == 1 )) || echo s) and ${#images[@]} image$( (( ${#images[@]} == 1 )) || echo s)."
}
