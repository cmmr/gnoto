#
# dashboard.sh - Builds the pages a run's results are read through.
#
# Sourced by:  present/ampliseq.sh, taxprofiler.sh and biobakery.sh, and
#              present/progress.sh and index_directories.sh for render_template
#              and dashboard_assets
# Defines:     render_template, dashboard_assets, dashboard_script_json,
#              dashboard_reset, dashboard_view,
#              dashboard_methods_view, dashboard_tab, dashboard_tab_end,
#              dashboard_button, dashboard_formats, dashboard_folder,
#              dashboard_bundle, dashboard_stat_group, dashboard_stat_row,
#              dashboard_stat_tiles, dashboard_stat_chips, dashboard_stat_bar,
#              dashboard_stat_detail, dashboard_stat_share,
#              dashboard_stat_share_of, dashboard_stat_share_detail,
#              dashboard_report_section, render_dashboard, dashboard_late_files,
#              PRESENT_DIR, DASHBOARD_PAGES, DOWNLOAD_EXTENSIONS
# Requires:    GNU find, jq; escape_html, escape_url, human_size, human_count,
#              group_count and warn from lib/utilities.sh
# Env:         CODE_DIR, from lib/env.sh
#
# Every pipeline gets the same pages in its results folder, and a fourth for a
# pipeline with methods data:
#
#   index.html         the navigation bar, and a frame the rest loads into
#   overview.html      what the run was, what it found, and what to take
#   deliverables.html  the annotated index of its outputs
#   methods.html       a methods paragraph for a manuscript, and its references
#
# The bar reads Overview, Deliverables, the views the Present script declared,
# QC Report when there's a MultiQC report (hidden until asked for, by ?qc or
# #quality in the address), and File Explorer, the results folder's listing.
#
# A Present script declares what its run produced, then renders:
#
#   dashboard_reset        <results_dir> <catalog>
#   dashboard_view         <id> <label> <path>    a link in the bar, if the
#                                                 page exists
#   dashboard_methods_view <data> [label]         the Methods page, from the
#                                                 data a methods script wrote
#   dashboard_tab          <id> <label>           opens a tab of the Feature
#                                                 Table card; a tab left empty
#                                                 isn't drawn
#   dashboard_tab_end                             closes it
#   dashboard_button       <glob> [label]         a file the card offers; false
#                                                 when the glob named nothing
#   dashboard_formats      <heading> <[title|]label|path> ...
#                                                 one file in several formats,
#                                                 as a row of boxes
#   dashboard_folder       <folder/> [label]      a folder's listing; false when
#                                                 there's no such folder
#   dashboard_bundle       <href> [bytes] [folder...]
#                                                 the deliverables zip, its
#                                                 size, and the folders of reads
#                                                 zipped beside the results
#   dashboard_stat_group   <heading> [note]       opens a block of statistics
#   dashboard_stat_row     <label> <value>
#   dashboard_stat_tiles   <value|label|tone> ... a row of counts
#   dashboard_stat_chips   <value|label> ...      the same, set small
#   dashboard_stat_bar     <label> <reading> <percent> [tone] [details] [note] [info]
#   dashboard_stat_detail  <group> <label> <reading> <percent> [href]
#   dashboard_stat_share, dashboard_stat_share_of, dashboard_stat_share_detail
#                          the bars above, from a count and its total; nothing
#                          when either isn't a count
#   dashboard_report_section <report> <href> <anchors>
#                          a link to a section of a published report, if it has
#                          one of those anchors
#   render_dashboard       <run_id> <title> <subtitle> <version> <completed>
#                          <sample_count> <expires> [plot_data]
#
# Each skips what the run didn't produce, so the pages describe the run rather
# than the pipeline. Every value written into a page goes through escape_html,
# and every path into an href through escape_url.
#
# Icons are Material Symbols names. present/build-assets.sh subsets the font to
# the names it lists, so a new icon goes there too.

PRESENT_DIR=$CODE_DIR/present

# Extensions that download when clicked. Everything else opens in a new tab.
DOWNLOAD_EXTENSIONS=(zip gz bz2 xz tar tgz qza qzv biom rds rda parquet)

# The two states of a link in the bar, and of a tab in the Feature Table card,
# spelled as the pages' own scripts spell them
DASHBOARD_NAV_ON="text-on-primary border-b-2 border-secondary-fixed font-bold pb-1 px-2 py-1 rounded text-[13px] tracking-[0.02em] hover:bg-primary-container transition-colors"
DASHBOARD_NAV_OFF="text-primary-fixed/80 hover:text-on-primary hover:bg-primary-container transition-colors px-2 py-1 rounded text-[13px] tracking-[0.02em] font-medium"
DASHBOARD_TAB_ON="font-label-caps text-label-caps font-bold text-primary border-b-2 border-primary pb-0.5"
DASHBOARD_TAB_OFF="font-label-caps text-label-caps font-bold text-on-surface-variant opacity-60 hover:opacity-100 transition-opacity pb-0.5"

DASHBOARD_PAGES=(overview.html deliverables.html methods.html index.html)
DASHBOARD_QC_REPORT="multiqc/multiqc_report.html"
DASHBOARD_LISTING="directory_listing.html"

# Fills in a page template and prints it. Each __NAME__ in the template is
# replaced in one pass, so a value is never searched for another placeholder.
# COMMON_HEAD and COMMON_CSS are templates/head.html and templates/common.css,
# and the name and value pairs after the template fill in the rest. A
# placeholder with no value is left as it is.
render_template() {
    local file=$1 page out="" name pattern='__([A-Z][A-Z_]*[A-Z])__'
    local -A values=()
    shift

    if [[ ! -r $file || ! -r $PRESENT_DIR/templates/head.html || ! -r $PRESENT_DIR/templates/common.css ]]; then
        warn "Can't read the page template $file, or head.html and common.css beside it."
        return 1
    fi
    page=$(< "$file")
    values[COMMON_HEAD]=$(< "$PRESENT_DIR/templates/head.html")
    values[COMMON_CSS]=$(< "$PRESENT_DIR/templates/common.css")
    while (( $# >= 2 )); do
        values[$1]=$2
        shift 2
    done

    while [[ $page =~ $pattern ]]; do
        name=${BASH_REMATCH[1]}
        out+=${page%%"${BASH_REMATCH[0]}"*}
        if [[ -n ${values[$name]+set} ]]; then
            out+=${values[$name]}
        else
            out+=${BASH_REMATCH[0]}
        fi
        page=${page#*"${BASH_REMATCH[0]}"}
    done
    printf '%s\n' "$out$page"
}

# Copies the stylesheet and fonts the pages link into <results_dir>/assets/
dashboard_assets() {
    mkdir -p "$1/assets" && cp -R "$PRESENT_DIR/assets/." "$1/assets/"
}

# JSON from a file, for a page to read inside a script element: compact, and
# with every < escaped, so nothing in it can close the element. null when the
# file is missing, empty or isn't JSON.
dashboard_script_json() {
    local json
    if [[ -n ${1:-} && -s $1 ]] && json=$(jq -c . "$1" 2> /dev/null) && [[ -n $json ]]; then
        printf '%s' "${json//</\\u003c}"
    else
        printf 'null'
    fi
}

dashboard_reset() {
    DASHBOARD_RESULTS_DIR=${1%/}
    DASHBOARD_CATALOG=$2
    DASHBOARD_VIEWS=()
    DASHBOARD_DOWNLOADS=""
    DASHBOARD_STATS=""
    DASHBOARD_STAT_GROUP_OPEN=""
    DASHBOARD_METHODS=""
    # The card's tabs, in the order declared, and the one open now. While a tab
    # is open, DASHBOARD_DOWNLOADS and DASHBOARD_STATS are its own, and the
    # card's are kept aside.
    DASHBOARD_TAB=""
    DASHBOARD_TAB_IDS=()
    DASHBOARD_TAB_LABELS=()
    DASHBOARD_TAB_BODIES=()
    DASHBOARD_CARD_DOWNLOADS=""
    DASHBOARD_CARD_STATS=""
    DASHBOARD_BUNDLE_URL=""
    DASHBOARD_BUNDLE_SIZE=""
    DASHBOARD_BUNDLE_FOLDERS=()
}

# True when a path is one a browser should be told to save
dashboard_is_download() {
    local extension=${1##*.} candidate
    extension=${extension,,}
    for candidate in "${DOWNLOAD_EXTENSIONS[@]}"; do
        [[ $extension == "$candidate" ]] && return 0
    done
    return 1
}

# A link to an output, read inside the landing page's frame, opens outside it
# unless it downloads
dashboard_link_attributes() {
    if dashboard_is_download "$1"; then
        printf ' download'
    else
        printf ' target="_blank" rel="noopener"'
    fi
}

# The icon for what a file is, by its extension
dashboard_file_icon() {
    local extension=${1##*.}
    case ${extension,,} in
        zip | gz | bz2 | xz | tar | tgz) printf 'folder_zip' ;;
        biom | qza | qzv | rds | rda | parquet | json) printf 'data_object' ;;
        tsv | csv) printf 'table_view' ;;
        html | htm | svg | pdf | png) printf 'monitoring' ;;
        *) printf 'description' ;;
    esac
}

# A link in the bar, between Deliverables and QC Report, if the run wrote the
# page. The id is the fragment the bar records the view as.
dashboard_view() {
    local id=$1 label=$2 path=$3
    [[ -n $path && -f $DASHBOARD_RESULTS_DIR/$path ]] || return 0
    DASHBOARD_VIEWS+=("$id|$label|$path")
}

# The Methods page's link, for a run whose methods script wrote its data:
# paragraphs citing [@id], and the references those ids name
dashboard_methods_view() {
    local data=$1 label=${2:-Methods}
    [[ -s $data ]] || return 0
    DASHBOARD_METHODS=$data
    DASHBOARD_VIEWS+=("methods|$label|methods.html")
}

dashboard_drop_view() {
    local entry kept=()
    for entry in ${DASHBOARD_VIEWS[@]+"${DASHBOARD_VIEWS[@]}"}; do
        [[ ${entry%%|*} == "$1" ]] || kept+=("$entry")
    done
    DASHBOARD_VIEWS=(${kept[@]+"${kept[@]}"})
}

# The pill beside the statistics heading: how many samples every count in the
# card is over
dashboard_sample_pill() {
    local count=$1 noun=samples
    [[ $count =~ ^[0-9]+$ && $count -gt 0 ]] || return 0
    (( count == 1 )) && noun=sample
    printf '<span class="inline-flex items-center gap-1.5 shrink-0 rounded-full border border-outline-variant bg-surface-container px-2.5 py-1 font-label-caps text-label-caps text-on-surface-variant">'
    printf '<span class="material-symbols-outlined text-[14px]">science</span>%s %s</span>' "$count" "$noun"
}

# One link per file a glob matches, under the file's name or the label. A
# label belongs to a glob that names one file. False when it named nothing.
dashboard_button() {
    local pattern=$1 label=${2:-} path name offered=1
    for path in "$DASHBOARD_RESULTS_DIR"/$pattern; do
        [[ -r $path ]] || continue
        name=${path#"$DASHBOARD_RESULTS_DIR/"}
        dashboard_link_row "$(escape_url "$name")" "${label:-${name##*/}}" "$name" \
            "$(dashboard_file_icon "$name")" file_download "$(dashboard_link_attributes "$name")"
        offered=0
    done
    return $offered
}

# A link to the listing written for a folder
dashboard_folder() {
    local folder=${1%/} label=${2:-}
    [[ -d $DASHBOARD_RESULTS_DIR/$folder ]] || return 1
    dashboard_link_row "$(escape_url "$folder")/$DASHBOARD_LISTING" "${label:-$folder/}" "$folder/" \
        folder_open open_in_new "$(dashboard_link_attributes "$DASHBOARD_LISTING")"
}

# One row of the Feature Table card: an icon for what it leads to, its text,
# and an icon for what following it does. The href comes escaped.
dashboard_link_row() {
    local href=$1 text=$2 title=$3 icon=$4 action=$5 attributes=$6
    DASHBOARD_DOWNLOADS+="<a class=\"flex items-center justify-between gap-2 px-2 py-1.5 rounded hover:bg-surface-container transition-colors group\""
    DASHBOARD_DOWNLOADS+=" href=\"$href\"$attributes>"
    DASHBOARD_DOWNLOADS+="<span class=\"flex items-center gap-2 min-w-0\">"
    DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[20px] text-on-surface-variant group-hover:text-primary transition-colors\">"
    DASHBOARD_DOWNLOADS+="$icon</span>"
    DASHBOARD_DOWNLOADS+="<span class=\"text-[13px] leading-5 text-on-surface truncate\""
    DASHBOARD_DOWNLOADS+=" title=\"$(escape_html "$title")\">$(escape_html "$text")</span></span>"
    DASHBOARD_DOWNLOADS+="<span class=\"material-symbols-outlined text-[18px] shrink-0 text-on-surface-variant opacity-0 group-hover:opacity-100 transition-opacity\">"
    DASHBOARD_DOWNLOADS+="$action</span></a>"
}

# One file in several formats, as a row of boxes under a heading, each naming
# its format: the thing set large and the encoding under it. Every box
# downloads, because each is the whole table. A format the run didn't write is
# left out, and a heading with none isn't drawn. An entry is "label|path", set
# large as BIOM, or "title|label|path".
dashboard_formats() {
    local heading=$1 entry title label name boxes=""
    shift
    for entry in "$@"; do
        title=BIOM
        name=${entry##*|}
        label=${entry%|*}
        if [[ $label == *"|"* ]]; then
            title=${label%%|*}
            label=${label#*|}
        fi
        [[ -r $DASHBOARD_RESULTS_DIR/$name ]] || continue
        boxes+="<a class=\"flex flex-col items-center justify-center gap-0.5 py-2 px-1 rounded-lg"
        boxes+=" border border-outline-variant bg-surface-container-lowest"
        boxes+=" hover:border-primary hover:bg-surface-container transition-colors group\""
        boxes+=" href=\"$(escape_url "$name")\" download"
        boxes+=" title=\"$(escape_html "$name")\">"
        boxes+="<span class=\"font-bold text-body-md leading-5 text-primary\">$(escape_html "$title")</span>"
        boxes+="<span class=\"font-label-caps text-[10px] leading-3 tracking-[0.06em]"
        boxes+=" text-secondary group-hover:text-primary transition-colors\">"
        boxes+="$(escape_html "$label")</span></a>"
    done
    [[ -n $boxes ]] || return 1

    DASHBOARD_DOWNLOADS+="<div class=\"px-2 pt-2 pb-1\">"
    if [[ -n $heading ]]; then
        DASHBOARD_DOWNLOADS+="<span class=\"block font-label-caps text-label-caps text-on-surface-variant mb-1.5\">"
        DASHBOARD_DOWNLOADS+="$(escape_html "$heading")</span>"
    fi
    DASHBOARD_DOWNLOADS+="<div class=\"grid grid-cols-3 gap-1.5\">$boxes</div>"
    DASHBOARD_DOWNLOADS+="</div>"
}

# Opens a tab of the Feature Table card. Downloads and stat groups go into it
# until the next dashboard_tab or dashboard_tab_end.
dashboard_tab() {
    dashboard_tab_end
    dashboard_end_stat_group
    DASHBOARD_CARD_DOWNLOADS=$DASHBOARD_DOWNLOADS
    DASHBOARD_CARD_STATS=$DASHBOARD_STATS
    DASHBOARD_DOWNLOADS=""
    DASHBOARD_STATS=""
    DASHBOARD_TAB="$1|$2"
}

# Closes the open tab, dropping it when nothing went into it. A tab's downloads
# come first and its stat groups under them.
dashboard_tab_end() {
    local body="" gap
    [[ -n $DASHBOARD_TAB ]] || return 0
    dashboard_end_stat_group

    if [[ -n $DASHBOARD_DOWNLOADS ]]; then
        body+="<div class=\"flex flex-col gap-0.5\">$DASHBOARD_DOWNLOADS</div>"
    fi
    if [[ -n $DASHBOARD_STATS ]]; then
        # A block with no heading sits closer under the downloads
        gap="mt-4"
        [[ $DASHBOARD_STATS == "<div><h4"* ]] || gap="mt-3"
        body+="<div class=\"flex flex-col gap-5 px-2${DASHBOARD_DOWNLOADS:+ $gap}\">$DASHBOARD_STATS</div>"
    fi
    if [[ -n $body ]]; then
        DASHBOARD_TAB_IDS+=("${DASHBOARD_TAB%%|*}")
        DASHBOARD_TAB_LABELS+=("${DASHBOARD_TAB#*|}")
        DASHBOARD_TAB_BODIES+=("$body")
    fi
    DASHBOARD_DOWNLOADS=$DASHBOARD_CARD_DOWNLOADS
    DASHBOARD_STATS=$DASHBOARD_CARD_STATS
    DASHBOARD_TAB=""
}

# The deliverables zip: its href, its size in bytes, and the folders of reads
# zipped beside the results, which the index lists held and draws as a tree.
# Declared before the pages are rendered, since both the button and the index
# read it.
dashboard_bundle() {
    local href=$1 bytes=${2:-}
    [[ -n $href ]] || return 0
    DASHBOARD_BUNDLE_URL=$href
    DASHBOARD_BUNDLE_FOLDERS=("${@:3}")
    [[ $bytes =~ ^[0-9]+$ ]] && DASHBOARD_BUNDLE_SIZE=$bytes
    return 0
}

# An href as it goes into a page: an absolute address as it is, and a relative
# path URL-encoded
dashboard_href() {
    if [[ $1 == http://* || $1 == https://* ]]; then
        escape_html "$1"
    else
        escape_url "$1"
    fi
}

# The button that takes the zip, under the expiry date in the bar, so the reader
# just told the results go away is looking at the way to keep them. A plain
# link, so a middle-click or a shared address works without scripting.
dashboard_zip_button() {
    [[ -n $DASHBOARD_BUNDLE_URL ]] || return 0
    printf '<a class="shrink-0 bg-primary text-on-primary px-3.5 py-2 rounded-lg text-[13px] font-semibold hover:bg-primary-container transition-colors flex items-center justify-center gap-1.5 whitespace-nowrap"'
    printf ' id="download-all" href="%s" download target="_top"' "$(dashboard_href "$DASHBOARD_BUNDLE_URL")"
    printf '><span class="material-symbols-outlined text-[18px]">archive</span>Download everything'
    if [[ -n $DASHBOARD_BUNDLE_SIZE ]]; then
        printf '<span class="font-normal text-[12px] opacity-80">(%s)</span>' \
            "$(escape_html "$(human_size "$DASHBOARD_BUNDLE_SIZE")")"
    fi
    printf '</a>'
}

# Text as HTML, each count human_count shortened written as a span whose
# tooltip is the exact figure: 4.4M over "4,404,860"
dashboard_count_html() {
    local text out="" pattern=$'\034([0-9]+)\035([^\036]*)\036'
    text=$(escape_html "$1")
    while [[ $text =~ $pattern ]]; do
        out+=${text%%"${BASH_REMATCH[0]}"*}
        out+="<span title=\"$(group_count "${BASH_REMATCH[1]}")\">${BASH_REMATCH[2]}</span>"
        text=${text#*"${BASH_REMATCH[0]}"}
    done
    printf '%s' "$out$text"
}

dashboard_end_stat_group() {
    if [[ -n $DASHBOARD_STAT_GROUP_OPEN ]]; then
        DASHBOARD_STATS+="</div>"
        DASHBOARD_STAT_GROUP_OPEN=""
    fi
}

# One block of statistics. The note is the setting the block's numbers came
# from, such as the reference database over the classification. With neither a
# heading nor a note, the block has no heading line.
dashboard_stat_group() {
    local heading=${1:-} note=${2:-}
    dashboard_end_stat_group
    if [[ -z $heading$note ]]; then
        DASHBOARD_STATS+="<div>"
        DASHBOARD_STAT_GROUP_OPEN=1
        return 0
    fi
    DASHBOARD_STATS+="<div><h4 class=\"flex items-baseline justify-between gap-2 font-label-caps text-label-caps text-on-surface-variant mb-2.5\">"
    DASHBOARD_STATS+="<span class=\"shrink-0\">$(escape_html "$heading")</span>"
    if [[ -n $note ]]; then
        DASHBOARD_STATS+="<span class=\"min-w-0 truncate text-right text-[11px] font-normal tracking-normal normal-case text-outline\""
        DASHBOARD_STATS+=" title=\"$(escape_html "$note")\">$(escape_html "$note")</span>"
    fi
    DASHBOARD_STATS+="</h4>"
    DASHBOARD_STAT_GROUP_OPEN=1
}

# A reading with no bar under it
dashboard_stat_row() {
    local label=$1 value=$2
    [[ -n $value ]] || return 0
    DASHBOARD_STATS+="<div class=\"flex justify-between items-baseline gap-2 mb-1.5 last:mb-0\">"
    DASHBOARD_STATS+="<span class=\"font-body-sm text-body-sm font-medium text-on-surface shrink-0\">"
    DASHBOARD_STATS+="$(escape_html "$label")</span>"
    DASHBOARD_STATS+="<span class=\"font-body-sm text-body-sm text-on-surface-variant text-right\">"
    DASHBOARD_STATS+="$(escape_html "$value")</span></div>"
}

# A row of counts, each value|label|tone. The tone is growth for the biological
# readings, plain, or empty for the institutional blue.
dashboard_tiles() {
    local box=$1 columns=$2 value_class=$3 label_class=$4 entry value label tone grid
    shift 4
    # Spelled out, so the stylesheet build finds both
    grid="grid-cols-2"
    [[ $columns == 3 ]] && grid="grid-cols-3"
    DASHBOARD_STATS+="<div class=\"grid $grid gap-2\">"
    for entry in "$@"; do
        IFS='|' read -r value label tone <<< "$entry"
        case $tone in
            growth) tone="text-secondary" ;;
            plain) tone="text-on-surface" ;;
            *) tone="text-primary" ;;
        esac
        DASHBOARD_STATS+="<div class=\"$box\"><span class=\"$value_class $tone\">"
        DASHBOARD_STATS+="$(dashboard_count_html "$value")</span>"
        DASHBOARD_STATS+="<span class=\"$label_class\">$(escape_html "$label")</span></div>"
    done
    DASHBOARD_STATS+='</div>'
}

dashboard_stat_tiles() {
    dashboard_tiles \
        "bg-surface-container p-2.5 rounded-lg border border-outline-variant/30 flex flex-col items-center justify-center text-center" \
        2 "font-headline-lg text-headline-lg leading-7" \
        "font-body-sm text-body-sm text-on-surface-variant" "$@"
}

dashboard_stat_chips() {
    dashboard_tiles \
        "bg-surface-container p-2 rounded-lg border border-outline-variant/30 flex flex-col items-center justify-center text-center" \
        3 "font-bold text-body-md leading-5" \
        "text-[10px] leading-3 font-label-caps text-on-surface-variant" "$@"
}

# How far a bar is filled, as a number from 0 to 100
dashboard_bar_fill() {
    local percent=$1
    [[ $percent =~ ^[0-9]+(\.[0-9]+)?$ ]] || percent=0
    if awk -v p="$percent" 'BEGIN { exit !(p > 100) }'; then
        percent=100
    fi
    printf '%s' "$percent"
}

# One measurement as a labelled bar. The reading is written for a reader, and
# the percentage only fills the bar. A details group puts a "details" link
# beside the label that shows and hides that group's dashboard_stat_detail
# bars; it's written hidden, and the page's script reveals it, so a reader
# without scripting isn't offered a control that does nothing. A note goes
# small under the bar, and an explanation behind an icon beside the label.
dashboard_stat_bar() {
    local label=$1 reading=$2 percent=$3 tone=${4:-} details=${5:-} note=${6:-} info=${7:-}
    case $tone in
        growth) tone="bg-bio-growth" ;;
        *) tone="bg-primary-container" ;;
    esac
    percent=$(dashboard_bar_fill "$percent")

    DASHBOARD_STATS+="<div class=\"mb-2.5 last:mb-0\"><div class=\"flex justify-between items-baseline gap-2 mb-1\">"
    DASHBOARD_STATS+="<span class=\"font-body-sm text-body-sm font-medium text-on-surface\">$(escape_html "$label")"
    if [[ -n $info ]]; then
        DASHBOARD_STATS+="<span class=\"material-symbols-outlined ml-0.5 align-[-2px] text-[13px] leading-none"
        DASHBOARD_STATS+=" text-outline/70 hover:text-on-surface-variant cursor-help select-none\""
        DASHBOARD_STATS+=" title=\"$(escape_html "$info")\" aria-label=\"$(escape_html "$info")\""
        DASHBOARD_STATS+=" role=\"img\">info</span>"
    fi
    if [[ -n $details ]]; then
        DASHBOARD_STATS+="<button type=\"button\" data-stat-details=\"$(escape_html "$details")\""
        DASHBOARD_STATS+=" aria-expanded=\"false\" style=\"display: none\""
        DASHBOARD_STATS+=" class=\"ml-1.5 font-body-sm text-body-sm font-normal text-primary underline"
        DASHBOARD_STATS+=" decoration-dotted underline-offset-2 hover:no-underline\">details</button>"
    fi
    DASHBOARD_STATS+="</span>"
    DASHBOARD_STATS+="<span class=\"font-code-sm text-code-sm text-on-surface-variant\">$(dashboard_count_html "$reading")</span></div>"

    # A sliver of a bar reads as an empty one, so under a tenth there's only
    # the reading
    if awk -v p="$percent" 'BEGIN { exit !(p >= 10) }'; then
        DASHBOARD_STATS+="<div class=\"h-1.5 w-full bg-surface-variant rounded-full overflow-hidden\">"
        DASHBOARD_STATS+="<div class=\"h-full $tone rounded-full\" style=\"width: $percent%;\"></div></div>"
    fi
    if [[ -n $note ]]; then
        DASHBOARD_STATS+="<div class=\"mt-1 truncate font-body-sm text-[11px] leading-4 text-outline\""
        DASHBOARD_STATS+=" title=\"$(escape_html "$note")\">$(escape_html "$note")</div>"
    fi
    DASHBOARD_STATS+="</div>"
}

# One step behind a bar's "details" link, set smaller and indented. With an
# href, the label links to where the pipeline's own report accounts for the
# step, opening in the frame the reader is in.
dashboard_stat_detail() {
    local group=$1 label=$2 reading=$3 percent=$4 href=${5:-}
    local style="font-body-sm text-[11px] leading-4 text-on-surface-variant"
    local open="<span class=\"$style\">" close="</span>"

    percent=$(dashboard_bar_fill "$percent")
    if [[ -n $href ]]; then
        style+=" underline decoration-dotted underline-offset-2 hover:text-on-surface hover:decoration-solid"
        # Not escape_url: the href carries a fragment, and is built from a
        # fixed path and an anchor the report declared
        open="<a class=\"$style\" href=\"$(escape_html "$href")\">"
        close="</a>"
    fi
    DASHBOARD_STATS+="<div class=\"mb-2 last:mb-0 pl-3 border-l-2 border-outline-variant/40\""
    DASHBOARD_STATS+=" data-stat-detail=\"$(escape_html "$group")\" style=\"display: none\">"
    DASHBOARD_STATS+="<div class=\"flex justify-between items-baseline gap-2 mb-1\">"
    DASHBOARD_STATS+="$open$(escape_html "$label")$close"
    DASHBOARD_STATS+="<span class=\"font-code-sm text-code-sm text-outline shrink-0\">"
    DASHBOARD_STATS+="$(dashboard_count_html "$reading")</span></div>"
    DASHBOARD_STATS+="<div class=\"h-1 w-full bg-surface-variant rounded-full overflow-hidden\">"
    DASHBOARD_STATS+="<div class=\"h-full bg-primary-container/60 rounded-full\" style=\"width: $percent%;\"></div>"
    DASHBOARD_STATS+="</div></div>"
}

# A count as a share of its total: the bar's fill, then the reading. Whole
# percent, except at either end, where rounding would say nothing happened when
# something did: 99.5% kept isn't 100%, and a few hundredths of a percent isn't
# 0%. Those get a decimal, and less than that is "<0.1". Fails when either
# isn't a count, which is how a step the run didn't take leaves out its bar.
dashboard_share_reading() {
    local count=$1 total=$2
    [[ $count =~ ^[0-9]+$ && $total =~ ^[0-9]+$ ]] || return 1
    (( total > 0 )) || return 1
    LC_ALL=C awk -v c="$count" -v t="$total" 'BEGIN {
        share = c * 100 / t
        text = sprintf("%.0f", share)
        if (text == "100" && c < t) {
            text = sprintf("%.1f", share)
            if (text == "100.0") text = "99.9"
        } else if (text == "0" && c > 0) {
            text = sprintf("%.1f", share)
            if (text == "0.0") text = "<0.1"
        }
        printf "%.4f %s\n", share, text
    }'
}

# A reading as a bar: what share of the total, and how many reads. Green is for
# what came through, navy for totals.
dashboard_stat_share() {
    local label=$1 count=$2 total=$3 tone=${4:-growth} details=${5:-} percent reading
    read -r percent reading < <(dashboard_share_reading "$count" "$total") || return 0
    dashboard_stat_bar "$label" "$reading% · $(human_count "$count")" "$percent" "$tone" "$details"
}

# The same with the total beside the count, "19% · 764k / 4.0M", a note and an
# explanation
dashboard_stat_share_of() {
    local label=$1 count=$2 total=$3 note=${4:-} info=${5:-} percent reading
    read -r percent reading < <(dashboard_share_reading "$count" "$total") || return 0
    dashboard_stat_bar "$label" "$reading% · $(human_count "$count") / $(human_count "$total")" \
        "$percent" growth "" "$note" "$info"
}

# The same as one of the steps behind a bar's "details" link
dashboard_stat_share_detail() {
    local group=$1 label=$2 count=$3 total=$4 href=${5:-} percent reading
    read -r percent reading < <(dashboard_share_reading "$count" "$total") || return 0
    dashboard_stat_detail "$group" "$label" "$reading% · $(human_count "$count")" "$percent" "$href"
}

# The address of a section of a report the run published, given the anchors
# that could carry it, most specific first. Nothing when the report has none of
# them, which leaves the label as text rather than a link that lands nowhere.
dashboard_report_section() {
    local report=$1 href=$2 anchor
    [[ -r $report ]] || return 0
    for anchor in $3; do
        if grep -qF "id=\"$anchor\"" "$report"; then
            printf '%s#%s' "$href" "$anchor"
            return 0
        fi
    done
}

# The statistics card, or nothing when there's nothing in it
dashboard_stats_card() {
    local sample_count=${1:-}
    dashboard_end_stat_group
    [[ -n $DASHBOARD_STATS ]] || return 0
    printf '<div class="bg-surface-container-lowest rounded-xl border border-outline-variant p-padding-card shadow-sm lg:flex-1 lg:min-h-0 lg:overflow-y-auto">'
    printf '<h3 class="text-base font-semibold text-primary mb-4 flex items-center justify-between gap-2">'
    printf '<span class="flex items-center gap-2"><span class="material-symbols-outlined text-[20px]">analytics</span>Run Statistics</span>'
    printf '%s</h3>' "$(dashboard_sample_pill "$sample_count")"
    printf '<div class="flex flex-col gap-5">%s</div></div>' "$DASHBOARD_STATS"
}

dashboard_downloads_title() {
    if (( ${#DASHBOARD_TAB_IDS[@]} > 1 )); then
        printf 'Feature Tables'
    else
        printf 'Feature Table'
    fi
}

# What the Feature Table card offers: tab links over a panel per tab, the first
# showing, or a line saying the run named nothing
dashboard_downloads() {
    local count=${#DASHBOARD_TAB_IDS[@]} i class selected style

    if [[ -z $DASHBOARD_DOWNLOADS ]] && (( count == 0 )); then
        printf '<p class="font-body-sm text-body-sm text-on-surface-variant p-2">'
        printf 'This run names no single files; take all of it with the button above.</p>'
        return 0
    fi
    if [[ -n $DASHBOARD_DOWNLOADS ]]; then
        printf '<div class="flex flex-col gap-0.5">%s</div>' "$DASHBOARD_DOWNLOADS"
    fi
    (( count > 0 )) || return 0

    printf '<div class="flex flex-wrap items-center gap-x-4 gap-y-1 ml-1 mb-3" role="tablist">'
    for (( i = 0; i < count; i++ )); do
        class=$DASHBOARD_TAB_OFF
        selected=false
        if (( i == 0 )); then
            class=$DASHBOARD_TAB_ON
            selected=true
        fi
        printf '<button type="button" role="tab" aria-selected="%s" class="%s" data-feature-tab="%s">%s</button>' \
            "$selected" "$class" "$(escape_html "${DASHBOARD_TAB_IDS[i]}")" \
            "$(escape_html "${DASHBOARD_TAB_LABELS[i]}")"
    done
    printf '</div>'
    for (( i = 0; i < count; i++ )); do
        style=""
        (( i > 0 )) && style=' style="display: none"'
        printf '<div role="tabpanel" data-feature-panel="%s"%s>%s</div>' \
            "$(escape_html "${DASHBOARD_TAB_IDS[i]}")" "$style" "${DASHBOARD_TAB_BODIES[i]}"
    done
}

# A group heading as a fragment: "Start here" is start-here
dashboard_slug() {
    local slug=${1,,}
    slug=${slug//[^a-z0-9]/-}
    while [[ $slug == *--* ]]; do
        slug=${slug//--/-}
    done
    slug=${slug#-}
    printf '%s' "${slug%-}"
}

# The navigation bar
dashboard_nav() {
    local entry id label path hidden views=("deliverables|Deliverables|deliverables.html")

    views+=(${DASHBOARD_VIEWS[@]+"${DASHBOARD_VIEWS[@]}"})
    if [[ -f $DASHBOARD_RESULTS_DIR/$DASHBOARD_QC_REPORT ]]; then
        views+=("quality|QC Report|$DASHBOARD_QC_REPORT")
    fi
    views+=("listing|File Explorer|$DASHBOARD_LISTING")

    printf '<a class="%s" data-view="overview" href="overview.html" target="view">Overview</a>' \
        "$DASHBOARD_NAV_ON"
    for entry in "${views[@]}"; do
        id=${entry%%|*}
        label=${entry#*|}
        label=${label%%|*}
        path=${entry##*|}
        hidden=""
        [[ $id == quality ]] && hidden=" hidden"
        printf '<a class="%s" data-view="%s" href="%s" target="view"%s>%s</a>' \
            "$DASHBOARD_NAV_OFF" "$(escape_html "$id")" "$(escape_url "$path")" "$hidden" \
            "$(escape_html "$label")"
    done
}

# The note at the end of the bar saying when the results are deleted. How far
# off that is, the page works out when it's read.
dashboard_expiry() {
    local expires=$1

    if [[ ! $expires =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        printf '<div class="flex items-center gap-2 text-on-surface-variant bg-surface-container px-3 py-1.5 rounded-full border border-outline-variant font-label-caps text-label-caps font-bold"'
        printf ' title="These results stay online until whoever ran this analysis removes them.">'
        printf '<span class="material-symbols-outlined text-sm">timer</span>'
        printf '<span>No expiration date</span></div>'
        return 0
    fi
    printf '<div class="flex items-center gap-2 text-warning-amber bg-warning-amber/10 px-3 py-1.5 rounded-full border border-warning-amber/20 font-label-caps text-label-caps font-bold"'
    printf ' data-expires="%s" title="This page and every file it links to are deleted after' "$expires"
    printf ' that date. Save anything you want to keep, or ask whoever ran this analysis to keep'
    printf ' them online for longer.">'
    printf '<span class="material-symbols-outlined text-sm">timer</span><span>'
    printf '<span class="label">Expires </span><span class="date">%s</span>' \
        "$(escape_html "$(date -u -d "$expires" '+%b %-d, %Y')")"
    printf '<span class="countdown"></span></span></div>'
}

# The foot of every page: when the run finished, what ran it, and its uid
dashboard_footer_note() {
    local note="" part
    for part in "${1:+Completed $1}" "$2" "$3"; do
        [[ -n $part ]] && note+="${note:+ · }$(escape_html "$part")"
    done
    printf '%s' "$note"
}

dashboard_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# The folders under a directory, a line each, drawn under the line naming it
dashboard_tree_lines() {
    local dir=$1 prefix=$2 children=() i last branch next
    mapfile -t children < <(find -L "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
    last=$(( ${#children[@]} - 1 ))
    for (( i = 0; i <= last; i++ )); do
        branch="├── "
        next="│   "
        if (( i == last )); then
            branch="└── "
            next="    "
        fi
        printf '%s%s%s/\n' "$prefix" "$branch" "$(escape_html "${children[i]}")"
        dashboard_tree_lines "$dir/${children[i]}" "$prefix$next"
    done
}

# What the zip unpacks into: the folders of reads, results/ and every folder
# under them, inside the folder named after the zip. Files are left out, so the
# tree is a map of where things are.
dashboard_bundle_tree() {
    local folder name last i folders=()
    for folder in ${DASHBOARD_BUNDLE_FOLDERS[@]+"${DASHBOARD_BUNDLE_FOLDERS[@]}"}; do
        [[ -d $folder ]] && folders+=("${folder%/}")
    done
    last=$(( ${#folders[@]} - 1 ))
    (( last >= 0 )) || return 0
    name=${DASHBOARD_BUNDLE_URL%%\?*}
    name=${name##*/}
    name=${name%.zip}

    printf '<pre class="tree">%s/\n' "$(escape_html "$name")"
    for (( i = 0; i <= last; i++ )); do
        if (( i == last )); then
            printf '└── %s/\n' "$(escape_html "${folders[i]}")"
            dashboard_tree_lines "${folders[i]}" "    "
        else
            printf '├── %s/\n' "$(escape_html "${folders[i]}")"
            dashboard_tree_lines "${folders[i]}" "│   "
        fi
    done
    printf '</pre>'
}

# One row of the file index: its name, its size, and on the last row of its
# entry, what it holds. A held row is a folder of reads published only in the
# zip, greyed with a note, which the page turns back into a link off disk.
dashboard_row() {
    local href=$1 label=$2 description=$3 size=$4 tag=$5 held=${6:-} row="<tr>" attributes

    if [[ $href == "$DASHBOARD_BUNDLE_URL" ]]; then
        attributes=' download target="_top"'
    else
        attributes=$(dashboard_link_attributes "$href")
    fi
    [[ -n $held ]] && row="<tr class=\"held\">"
    printf '%s<td class="name"><a href="%s"%s>%s</a>' \
        "$row" "$(dashboard_href "$href")" "$attributes" "$(escape_html "$label")"
    [[ -n $tag ]] && printf '<span class="tag">%s</span>' "$(escape_html "$tag")"
    [[ -n $description ]] && printf '<span class="desc">%s</span>' "$(escape_html "$description")"
    [[ $href == "$DASHBOARD_BUNDLE_URL" ]] && dashboard_bundle_tree
    [[ -n $held ]] && printf '<span class="held-note">%s</span>' \
        'Not published here — take these with the “Download everything” button on the Overview.'
    printf '</td><td class="size">%s</td></tr>\n' "$(escape_html "$size")"
}

# One file of a catalog entry, into the arrays dashboard_entry declared
dashboard_add_file() {
    hrefs+=("$1")
    labels+=("$2")
    sizes+=("$3")
    tags+=("$4")
    helds+=("${5:-}")
}

# The files one path of a catalog entry names: the zip, a held folder of reads
# (relative to the run directory, and only when the zip holds it), a folder of
# the results as its listing, or a glob, one per match in name order
dashboard_entry_files() {
    local path=$1 label=$2 full name size count folder bundled=""

    if [[ $path == "$DASHBOARD_BUNDLE_URL" ]]; then
        size=""
        [[ -n $DASHBOARD_BUNDLE_SIZE ]] && size=$(human_size "$DASHBOARD_BUNDLE_SIZE")
        dashboard_add_file "$path" "${label:-${path##*/}}" "$size" ""
        return 0
    fi

    if [[ $path == HELD:* ]]; then
        path=${path#HELD:}
        full=${path%/}
        [[ -d $full ]] || return 0
        for folder in ${DASHBOARD_BUNDLE_FOLDERS[@]+"${DASHBOARD_BUNDLE_FOLDERS[@]}"}; do
            [[ ${folder%/} == "$full" ]] && bundled=1
        done
        [[ -n $bundled ]] || return 0
        count=$(find -L "$full" -type f ! -name "$DASHBOARD_LISTING" | wc -l)
        (( count > 0 )) || return 0
        dashboard_add_file "$path$DASHBOARD_LISTING" "${label:-$path}" "$count files" folder held
        return 0
    fi

    if [[ $path == */ ]]; then
        full=$DASHBOARD_RESULTS_DIR/${path%/}
        [[ -d $full ]] || return 0
        count=$(find -L "$full" -type f ! -name "$DASHBOARD_LISTING" | wc -l)
        (( count > 0 )) || return 0
        dashboard_add_file "$path$DASHBOARD_LISTING" "${label:-$path}" "$count files" folder
        return 0
    fi

    # A labelled entry names a thing rather than a file, so it has no size
    for full in "$DASHBOARD_RESULTS_DIR"/$path; do
        [[ -f $full ]] || continue
        name=${full#"$DASHBOARD_RESULTS_DIR/"}
        [[ ${name##*/} == "$DASHBOARD_LISTING" ]] && continue
        size=""
        [[ -z $label ]] && size=$(human_size "$(stat -L -c %s "$full")")
        dashboard_add_file "$name" "${label:-$name}" "$size" ""
    done
}

# One catalog entry as one block of the index: a row per file its paths name,
# and the description once, under the last
dashboard_entry() {
    local paths=$1 label=$2 description=$3 path i last text
    local list=() hrefs=() labels=() sizes=() tags=() helds=()

    read -ra list <<< "$paths"
    for path in "${list[@]}"; do
        dashboard_entry_files "$path" "$label"
    done
    last=$(( ${#hrefs[@]} - 1 ))
    (( last >= 0 )) || return 0

    printf '<tbody>'
    for (( i = 0; i <= last; i++ )); do
        text=""
        (( i == last )) && text=$description
        dashboard_row "${hrefs[i]}" "${labels[i]}" "$text" "${sizes[i]}" "${tags[i]}" "${helds[i]}"
    done
    printf '</tbody>'
}

# One group of the index, kept only when it has rows, into the GROUP_NAV and
# SECTIONS its caller declared
dashboard_end_group() {
    local group=$1 about=$2 rows=$3 slug
    [[ -n $group && -n $rows ]] || return 0
    slug=$(dashboard_slug "$group")
    GROUP_NAV+="<a href=\"#$slug\">$(escape_html "$group")</a>"
    SECTIONS+="<section class=\"group\" id=\"$slug\">"
    SECTIONS+="<h2>$(escape_html "$group")</h2>"
    [[ -n $about ]] && SECTIONS+="<div class=\"about\">$about</div>"
    SECTIONS+="<table>$rows</table></section>"
}

# The index and the menu beside it, in one pass over the catalog, so a group
# with no rows is in neither
dashboard_index() {
    local line group path label description current="" group_about="" group_rows=""

    GROUP_NAV=""
    SECTIONS=""
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line//$'\r'/}
        line=$(dashboard_trim "$line")
        [[ -z $line || $line == \#* ]] && continue
        IFS='|' read -r group path label description <<< "$line"
        group=$(dashboard_trim "$group")
        path=$(dashboard_trim "$path")
        label=$(dashboard_trim "$label")
        description=$(dashboard_trim "$description")
        [[ -n $group ]] || continue

        if [[ $group != "$current" ]]; then
            dashboard_end_group "$current" "$group_about" "$group_rows"
            current=$group
            group_about=""
            group_rows=""
        fi

        # A line with no path and no label describes the group. Judged before
        # the zip's href goes in, so a run without one drops that row instead.
        if [[ -z $path && -z $label ]]; then
            [[ -n $description ]] && group_about+="<p>$(escape_html "$description")</p>"
            continue
        fi
        path=${path//__BUNDLE_URL__/"$DASHBOARD_BUNDLE_URL"}
        [[ -n $path ]] || continue
        group_rows+=$(dashboard_entry "$path" "$label" "$description")
    done < "$DASHBOARD_CATALOG"
    dashboard_end_group "$current" "$group_about" "$group_rows"
}

render_shell() {
    local title=$1 expires=$2
    render_template "$PRESENT_DIR/templates/dashboard.html" \
        TASK_NAME "$(escape_html "$title")" \
        NAV "$(dashboard_nav)" \
        EXPIRY "$(dashboard_expiry "$expires")" \
        FIRST_VIEW overview.html
}

render_overview() {
    local title=$1 subtitle=$2 sample_count=$3 plot_data=$4 footer=$5
    # A tab left open would count its stat groups as the statistics card's
    dashboard_tab_end
    render_template "$PRESENT_DIR/templates/overview.html" \
        TASK_NAME "$(escape_html "$title")" \
        SUBTITLE "$(escape_html "$subtitle")" \
        PLOT_DATA "$(dashboard_script_json "$plot_data")" \
        DOWNLOADS_TITLE "$(dashboard_downloads_title)" \
        DOWNLOADS "$(dashboard_downloads)" \
        ZIP_BUTTON "$(dashboard_zip_button)" \
        STATS "$(dashboard_stats_card "$sample_count")" \
        FOOTER_NOTE "$footer"
}

# One part of the Methods page as markup: "text", the paragraphs with their
# [@id] citations written author-year; "references", the cited references in
# alphabetical order, each linked to its DOI or address; or "bibtex". A
# reference is an entry of conf/references.yaml, and its citation, formatted
# form and BibTeX are derived here.
dashboard_methods_html() {
    jq -r --arg part "$1" '
        def ids: [scan("@([A-Za-z0-9_]+)") | .[0]];
        def cited: [scan("\\[@[^\\]]*\\]") | ids[]];
        def firsts: reduce .[] as $id ([]; if any(.[]; . == $id) then . else . + [$id] end);

        def person: contains(", ");
        def family: if person then split(", ")[0] else . end;
        def initials: split(", ")[1] // "";
        def stop: if test("[.?!]$") then . else . + "." end;
        def link: if .doi then "https://doi.org/" + .doi else (.url // "") end;

        def citation:
            .cite // (
                (.author | map(family)) as $names
                | (if (.et_al // false) or ($names | length) > 2 then $names[0] + " et al."
                   elif ($names | length) == 2 then $names[0] + " and " + $names[1]
                   else $names[0] end)
                + ", " + (.year | tostring));

        def formatted:
            ((.author | map(if person then family + " " + initials else . end) | join(", "))
             + (if .et_al then ", et al" else "" end) | stop)
            + " " + (.title | stop) + " "
            + if .type == "article" then
                (.journal_abbrev // .journal) + ". " + (.year | tostring)
                + (if .volume then ";" + (.volume | tostring) else "" end)
                + (if .number then "(" + (.number | tostring) + ")" else "" end)
                + (if .pages then ":" + (.pages | tostring) else "" end) + "."
              else
                (if .publisher then .publisher + "; " else "" end) + (.year | tostring) + "."
              end;

        def latex: gsub("(?<c>[&%$#_])"; "\\" + .c);
        def bibname:
            if person
            then family + ", " + (initials | explode | map([.] | implode + ".") | join(" "))
            else "{" + . + "}" end;

        def bibtex($id):
            "@" + (if .type == "article" then "article" else "misc" end) + "{" + $id + ",\n"
            + ([["author", ((.author | map(bibname)) + (if .et_al then ["others"] else [] end)
                            | join(" and "))],
                ["title", "{" + (.title | latex) + "}"],
                ["journal", (.journal // null | if . then latex else . end)],
                ["publisher", (.publisher // null | if . then latex else . end)],
                ["year", (.year | tostring)],
                ["volume", .volume],
                ["number", .number],
                ["pages", (.pages // null | if . then tostring | gsub("–"; "--") else . end)],
                ["doi", .doi],
                ["url", (if .doi then null else .url end)]]
               | map(select(.[1] != null) | "  " + .[0] + " = {" + (.[1] | tostring) + "}")
               | join(",\n"))
            + "\n}";

        . as $data
        | ([$data.paragraphs[] | cited[]] | firsts) as $order
        | ($data.references // {}) as $refs
        | [$order[] | . as $id | {id: $id, ref: ($refs[$id] // {author: [$id], title: $id, year: ""})}]
          as $cited

        | if $part == "text" then
            [$data.paragraphs[]
             | gsub("\\[(?<group>@[^\\]]*)\\]";
                    "(" + (.group | ids | map(($refs[.] // null) as $ref
                                              | if $ref then $ref | citation else . end)
                           | join("; ")) + ")")
             | "<p>" + @html + "</p>"]
            | join("")
          elif $part == "references" then
            $cited
            | map(.ref | {text: formatted, link: link})
            | sort_by(.text | ascii_downcase)
            | map("<li>" + (.text | @html)
                  + (.link | if . == "" then ""
                             else " <a href=\"" + @html + "\" target=\"_blank\" rel=\"noopener\">"
                                  + @html + "</a>" end)
                  + "</li>")
            | "<ul class=\"methods-refs\">" + join("") + "</ul>"
          else
            $cited
            | sort_by(.id)
            | map(.id as $id | .ref | bibtex($id))
            | "<pre class=\"methods-bibtex\">" + (join("\n\n") | @html) + "</pre>"
          end
    ' "$DASHBOARD_METHODS"
}

render_methods() {
    local title=$1 footer=$2 text references bibtex
    text=$(dashboard_methods_html text) || return 1
    references=$(dashboard_methods_html references) || return 1
    bibtex=$(dashboard_methods_html bibtex) || return 1
    render_template "$PRESENT_DIR/templates/methods.html" \
        TASK_NAME "$(escape_html "$title")" \
        TEXT "$text" \
        REFERENCES "$references" \
        BIBTEX "$bibtex" \
        FOOTER_NOTE "$footer"
}

render_deliverables() {
    local title=$1 footer=$2 GROUP_NAV SECTIONS
    if [[ ! -r $DASHBOARD_CATALOG ]]; then
        warn "There's no output catalog at $DASHBOARD_CATALOG, so the file index is empty."
        GROUP_NAV=""
        SECTIONS="<p class=\"empty\">No file index was built for this run.</p>"
    else
        dashboard_index
    fi
    render_template "$PRESENT_DIR/templates/deliverables.html" \
        TASK_NAME "$(escape_html "$title")" \
        GROUP_NAV "$GROUP_NAV" \
        SECTIONS "$SECTIONS" \
        FOOTER_NOTE "$footer"
}

# Writes the pages into the results folder, from what the run produced and what
# the Present script declared, and prints whatever failed. The subtitle names
# the analysis, completed is the date written for a reader, sample_count is a
# number or empty, expires is YYYY-MM-DD or empty, and plot_data is the file the
# composition step wrote, or empty. The Methods page is left out, with its
# link, rather than costing the run its dashboard.
render_dashboard() {
    local run_id=$1 title=$2 subtitle=$3 version=$4 completed=$5 sample_count=$6
    local expires=$7 plot_data=${8:-} footer name page

    footer=$(dashboard_footer_note "$completed" "$version" "$run_id")
    for name in overview deliverables methods index; do
        case $name in
            overview) page=$(render_overview "$title" "$subtitle" "$sample_count" "$plot_data" "$footer") ;;
            deliverables) page=$(render_deliverables "$title" "$footer") ;;
            methods)
                [[ -n $DASHBOARD_METHODS ]] || continue
                if ! page=$(render_methods "$title" "$footer") || [[ -z $page ]]; then
                    warn "The Methods page couldn't be built from $DASHBOARD_METHODS, so it's left out."
                    dashboard_drop_view methods
                    rm -f "$DASHBOARD_RESULTS_DIR/methods.html"
                    continue
                fi
                ;;
            index) page=$(render_shell "$title" "$expires") ;;
        esac
        if [[ -z $page ]]; then
            printf "The %s page couldn't be built from its template." "$name"
            return 1
        fi
        if ! printf '%s\n' "$page" > "$DASHBOARD_RESULTS_DIR/$name.html"; then
            printf "The %s page couldn't be written into %s." "$name" "$DASHBOARD_RESULTS_DIR"
            return 1
        fi
    done
}

# What's written into the results after the zip is first built, a path per
# line: the pages, progress.json and every folder listing
dashboard_late_files() {
    local name
    for name in "${DASHBOARD_PAGES[@]}" progress.json; do
        [[ -f $DASHBOARD_RESULTS_DIR/$name ]] && printf '%s\n' "$DASHBOARD_RESULTS_DIR/$name"
    done
    find "$DASHBOARD_RESULTS_DIR" -name "$DASHBOARD_LISTING" -type f
}
