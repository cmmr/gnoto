#!/bin/bash
#
# build-assets.sh - Rebuilds present/assets/: the stylesheet every dashboard
# page links, and the fonts it sets text and icons in.
#
# Run by:    a developer, after changing a class or an icon in present/
# Usage:     present/build-assets.sh          rebuild present/assets/
#            present/build-assets.sh --check  rebuild into a scratch folder and
#                                             compare, changing nothing
# Requires:  docker and bash. Works from Git Bash on Windows.
#
# Everything runs in one pinned python:3.12-slim container, never on the host.
# Each download is checked against its SHA-256 below. The Tailwind CSS
# standalone CLI builds gnoto.css from present/tailwind.css and the classes in
# present/templates/ and present/*.sh, and fontTools, the library pyftsubset
# runs, cuts Material Symbols Outlined down to the icons in ICONS, fixed at
# optical size 24 and grade 0 as Google's stylesheet served it. Inter and
# JetBrains Mono ship as released. Each font's licence goes beside it, and
# Tailwind's beside the stylesheet.
#
# The sources go into the container as a tar on stdin and the assets come back
# as one on stdout, so nothing is written through a bind mount. The same pins
# and sources give the same bytes, which --check confirms.
#
# A new icon goes in ICONS, a class written only at run time in tailwind.css's
# inline source, and a new version here with its checksum. A checksum left
# empty is printed by the build, which then stops.

set -euo pipefail

export MSYS_NO_PATHCONV=1

IMAGE=python:3.12-slim@sha256:4840d514c583a4d3d8cad3940e68dee6f0f6f3635c12fcd0a3d74c21a5b93a54

TAILWIND_VERSION=4.3.5
TAILWIND_SHA256=e47695cee3f0d90623a91f3939b08bdee610eb5ad99340adff9d4145b284d6cc
TAILWIND_LICENSE_SHA256=60e0b68c0f35c078eef3a5d29419d0b03ff84ec1df9c3f9d6e39a519a5ae7985
INTER_VERSION=4.1
INTER_SHA256=9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e
JETBRAINS_VERSION=2.304
JETBRAINS_SHA256=6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf
# google/material-design-icons has no releases for Material Symbols, so it's
# pinned to the newest commit that changed the font
SYMBOLS_COMMIT=10ecc14790612ca8fd164e3f4ffe9c16fc50d5b7
SYMBOLS_SHA256=3ae08513a06396b0258cf1d1a1091c2d336977518fb755ea5b4a13aacdbdc6ef
SYMBOLS_CODEPOINTS_SHA256=a7404d9e5a1b63f496cf05ace45d386075886b5a7f123fba9f29527cb6006fde
SYMBOLS_LICENSE_SHA256=58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd
FONTTOOLS_REQUIREMENTS="fonttools==4.68.0 --hash=sha256:3edce69ecdefa73ab1041901ca22eefed6ebb93a77bc77e889d940479f25bf7d --hash=sha256:d76f8fdcb6936f5e1045a0c9dd721a4bf11112e60d1e243bfa1d39f06a8b3104
brotli==1.2.1 --hash=sha256:4b9dd0173ca5e01d1eb307d3c184fe8c09bdc168ede560889b1018d216d38c61"

# Every icon a page or script names
ICONS=(analytics archive bar_chart content_copy data_object description file_download
    folder_open folder_zip info menu_book monitoring open_in_new science table_view timer
    timer_off)

# The build, inside the container, from the sources in /build/src. Writes the
# assets as a tar to stdout, and everything else to stderr.
in_container() {
    local symbols_url=https://raw.githubusercontent.com/google/material-design-icons/$SYMBOLS_COMMIT
    cd /build
    mkdir -p dl out/fonts

    {
        printf 'tailwindcss\t%s\t%s\n' \
            "https://github.com/tailwindlabs/tailwindcss/releases/download/v$TAILWIND_VERSION/tailwindcss-linux-x64" \
            "$TAILWIND_SHA256"
        printf 'tailwind-LICENSE\t%s\t%s\n' \
            "https://raw.githubusercontent.com/tailwindlabs/tailwindcss/v$TAILWIND_VERSION/LICENSE" \
            "$TAILWIND_LICENSE_SHA256"
        printf 'inter.zip\t%s\t%s\n' \
            "https://github.com/rsms/inter/releases/download/v$INTER_VERSION/Inter-$INTER_VERSION.zip" \
            "$INTER_SHA256"
        printf 'jetbrains.zip\t%s\t%s\n' \
            "https://github.com/JetBrains/JetBrainsMono/releases/download/v$JETBRAINS_VERSION/JetBrainsMono-$JETBRAINS_VERSION.zip" \
            "$JETBRAINS_SHA256"
        printf 'symbols.woff2\t%s\t%s\n' \
            "$symbols_url/variablefont/MaterialSymbolsOutlined%5BFILL,GRAD,opsz,wght%5D.woff2" \
            "$SYMBOLS_SHA256"
        printf 'symbols.codepoints\t%s\t%s\n' \
            "$symbols_url/variablefont/MaterialSymbolsOutlined%5BFILL,GRAD,opsz,wght%5D.codepoints" \
            "$SYMBOLS_CODEPOINTS_SHA256"
        printf 'symbols-LICENSE\t%s\t%s\n' "$symbols_url/LICENSE" "$SYMBOLS_LICENSE_SHA256"
    } > dl/pins.tsv

    python3 -I - dl/pins.tsv dl >&2 << 'PY'
import hashlib, sys, urllib.request

pins, folder = sys.argv[1], sys.argv[2]
unpinned = []
for line in open(pins):
    name, url, want = (line.rstrip("\n").split("\t") + [""])[:3]
    try:
        with urllib.request.urlopen(url, timeout=300) as response:
            data = response.read()
    except Exception as error:
        sys.exit("Couldn't download %s: %s" % (url, error))
    got = hashlib.sha256(data).hexdigest()
    if not want:
        unpinned.append("%s %s" % (name, got))
    elif got != want:
        sys.exit("%s has SHA-256 %s, not the pinned %s" % (url, got, want))
    with open("%s/%s" % (folder, name), "wb") as out:
        out.write(data)
if unpinned:
    sys.exit("Pin these checksums in build-assets.sh:\n" + "\n".join(unpinned))
PY

    printf '%s\n' "$FONTTOOLS_REQUIREMENTS" > dl/requirements.txt
    PIP_DISABLE_PIP_VERSION_CHECK=1 pip install --quiet --no-deps --require-hashes --root-user-action=ignore \
        -r dl/requirements.txt >&2 || { echo "Couldn't install fontTools from PyPI." >&2; exit 1; }

    chmod +x dl/tailwindcss
    (cd src && /build/dl/tailwindcss --input tailwind.css --output /build/out/gnoto.css --minify) >&2
    cp dl/tailwind-LICENSE out/LICENSE-tailwindcss.txt

    python3 -I - dl out/fonts "${ICONS[@]}" >&2 << 'PY'
import sys, zipfile
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

dl, fonts, icons = sys.argv[1], sys.argv[2], sys.argv[3:]

def extract(archive, member, target):
    with zipfile.ZipFile(archive) as z:
        with open(target, "wb") as out:
            out.write(z.read(member))

extract(dl + "/inter.zip", "web/InterVariable.woff2", fonts + "/InterVariable.woff2")
extract(dl + "/inter.zip", "LICENSE.txt", fonts + "/LICENSE-Inter.txt")
extract(dl + "/jetbrains.zip", "fonts/webfonts/JetBrainsMono-Regular.woff2", fonts + "/JetBrainsMono-Regular.woff2")
extract(dl + "/jetbrains.zip", "fonts/webfonts/JetBrainsMono-Medium.woff2", fonts + "/JetBrainsMono-Medium.woff2")
extract(dl + "/jetbrains.zip", "OFL.txt", fonts + "/LICENSE-JetBrainsMono.txt")
with open(dl + "/symbols-LICENSE", "rb") as source, open(fonts + "/LICENSE-MaterialSymbols.txt", "wb") as out:
    out.write(source.read())

codepoints = {}
for line in open(dl + "/symbols.codepoints"):
    name, code = line.split()
    codepoints[name] = int(code, 16)
missing = [icon for icon in icons if icon not in codepoints]
if missing:
    sys.exit("Material Symbols has no " + ", ".join(missing))

# Each icon is reached by its name as a ligature, so the subset keeps the
# letters, and the glyphs by their codepoints. Without layout closure, the
# ligatures for every other name made of those letters go.
font = TTFont(dl + "/symbols.woff2", recalcTimestamp=False)
options = subset.Options()
options.layout_closure = False
options.layout_features = ["*"]
options.name_IDs = ["*"]
options.notdef_outline = True
subsetter = subset.Subsetter(options)
subsetter.populate(unicodes=[codepoints[icon] for icon in icons],
                   text="abcdefghijklmnopqrstuvwxyz0123456789_")
subsetter.subset(font)

font = instantiateVariableFont(font, {"opsz": 24, "GRAD": 0})

# Every icon still spells out as a ligature
cmap = font.getBestCmap()
ligatures = {}
for lookup in font["GSUB"].table.LookupList.Lookup:
    for table in lookup.SubTable:
        if table.LookupType == 7:
            table = table.ExtSubTable
        if getattr(table, "LookupType", 0) == 4:
            for first, entries in table.ligatures.items():
                for entry in entries:
                    ligatures[(first,) + tuple(entry.Component)] = entry.LigGlyph
for icon in icons:
    if tuple(cmap[ord(c)] for c in icon) not in ligatures:
        sys.exit("The subset lost the ligature for " + icon)

font.flavor = "woff2"
font.save(fonts + "/MaterialSymbolsOutlined.woff2")
print("Kept %d glyphs for %d icons" % (len(font.getGlyphOrder()), len(icons)))
PY

    tar -C out --owner=0 --group=0 --numeric-owner --mtime=@0 --sort=name -cf - .
}

if [[ ${1:-} == --in-container ]]; then
    in_container
    exit 0
fi

PRESENT=$(cd "$(dirname "$0")" && pwd)
CHECK=""
case ${1:-} in
    --check) CHECK=1 ;;
    "") ;;
    *)
        sed -n '7,9p' "$0" >&2
        exit 1
        ;;
esac
command -v docker > /dev/null || { echo "build-assets.sh needs docker." >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir "$SCRATCH/assets"

(cd "$PRESENT" && tar -cf - tailwind.css templates ./*.sh) |
    docker run --rm -i "$IMAGE" bash -c \
        'mkdir -p /build/src && tar -xf - -C /build/src && bash /build/src/build-assets.sh --in-container' \
        > "$SCRATCH/assets.tar"
tar -xf "$SCRATCH/assets.tar" -C "$SCRATCH/assets"

if [[ -n $CHECK ]]; then
    if diff -r "$PRESENT/assets" "$SCRATCH/assets" > /dev/null; then
        echo "present/assets/ matches a fresh build."
        exit 0
    fi
    echo "present/assets/ differs from a fresh build:" >&2
    diff -rq "$PRESENT/assets" "$SCRATCH/assets" >&2 || :
    exit 1
fi

rm -rf "$PRESENT/assets"
mkdir "$PRESENT/assets"
tar -xmf "$SCRATCH/assets.tar" -C "$PRESENT/assets"
(cd "$PRESENT/assets" && find . -type f | LC_ALL=C sort | xargs sha256sum)
echo "Rebuilt present/assets/."
