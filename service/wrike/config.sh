#
# config.sh - gnoto config wrike: takes up the Wrike objects a person set up
# for gnoto, checks the bot can work in them, and lint's checks of them.
#
# Sourced by:  lib/config.sh and lib/lint.sh
# Defines:     config_wrike_step, config_wrike_suggest, wrike_form_keys,
#              wrike_fields_spec, wrike_form_problems, wrike_webhook_secret,
#              lint_wrike, WRIKE_WEBHOOK_EVENTS, WRIKE_GUIDE
# Requires:    wrike_call from service/wrike/api.sh; generated_set,
#              config_confirm and run_id_salt from lib/config.sh; options_json
#              and pipeline_names from lib/jobfile.sh; lint_ok, lint_warn and
#              lint_fail from lib/lint.sh
#
# A person sets up Wrike first, as the guide at WRIKE_GUIDE says: a space, or
# any space gnoto may share, with the bot its admin; a folder in it where
# gnoto's tasks go; a workflow with gnoto's six statuses; a request form, built
# however they like, whose questions name the gnoto start option each answers
# in brackets, such as [--retention], and which saves its tasks to the folder
# as Submitted; and a test request made with the form. wrike.folder names the
# folder, by its name or its Wrike link, and this finds the rest from it:
#
#   space      the one whose folders include it
#   request    the folder's newest task whose description names an option in
#              brackets: the test request
#   workflow   the one the test request's status is in, or without one, the
#              one with gnoto's six statuses, the space's own first
#   form       the one whose questions the test request answers
#
# and records their IDs in generated.yaml. Then, once the plan is shown and
# accepted:
#
#   fields     creates the custom fields Pipeline, Results and Expiration in
#              the space, or takes up those it has. gnoto fills all three.
#   test       creates a task in the folder with a gnoto status, sets its
#              fields, comments on it and attaches a file to it, then deletes
#              it, which shows the bot can do all gnoto does there
#   webhook    on the folder, to aws.sqs.webhook_url, when SQS is set up, for
#              WRIKE_WEBHOOK_EVENTS. Webhooks can't be edited, so one with other
#              events is deleted before its replacement is made, so no event
#              arrives twice.
#   request    says what gnoto read from the test request, in a comment on it
#              and here, and moves it to Cancelled, so it never runs
#
# Then it reads the form for problems: a key gnoto start doesn't take, a type
# that doesn't fit, or an answer gnoto doesn't know. lint repeats that check.

# Keep in step with the case statement in service/wrike/listener.sh: an event
# the webhook doesn't subscribe to never arrives, with nothing in any log
WRIKE_WEBHOOK_EVENTS="TaskCreated,TaskDeleted,TaskCustomFieldChanged"
WRIKE_GUIDE="https://cmmr.github.io/gnoto/wrike/"
# name, group and color of each status, in order
WRIKE_STATUSES=("Submitted Active Blue" "Running Active Turquoise" "Completed Completed Green"
    "Failed Cancelled Red" "Cancelled Cancelled Gray" "Expired Completed Brown")

# Every bracketed key gnoto reads from a request, as a JSON object of each key
# to {type, values, pipelines}: [pipeline], whose answers start with a
# pipeline's name or repeat, [--previous_run], [--title] and [--samplesheet],
# and each option in the pipelines' options.yaml as gnoto start takes it,
# --<key> for one in: top and --<pipeline>.<key> for one in its section.
# values are the answers gnoto knows, an option's labels where it has them.
# Fails when two pipelines take one top option with different answers.
wrike_form_keys() {
    local pipeline all="[]" options
    for pipeline in $(pipeline_names); do
        options=$(options_json "$pipeline")
        all=$(jq -c --arg pipeline "$pipeline" --argjson options "$options" '. + [$options[]
            | select(.key != "title" and .key != "samplesheet")
            | ((.labels // {}) | with_entries(.key |= tostring)) as $labels
            | {key: (if .in == "top" then "--\(.key)" else "--\($pipeline).\(.key)" end),
               type: (if .values == null then "Text" elif .multiple then "Multiple" else "DropDown" end),
               values: [(.values // [])[] | tostring | ($labels[.] // .)], pipelines: [$pipeline]}]' <<< "$all")
    done
    jq -c --argjson pipelines "$(pipeline_names | jq -R . | jq -sc .)" --arg repeat "$WRIKE_REPEAT_ANSWER" '
        group_by(.key) | map(
            if (map([.type, .values]) | unique | length) > 1
            then error("The option \(.[0].key) is taken differently by \(map(.pipelines[0]) | join(" and ")): one key must have one set of answers")
            else {(.[0].key): (.[0] + {pipelines: map(.pipelines[0])} | del(.key))} end)
        | add + {
            pipeline: {type: "DropDown", values: ($pipelines + [$repeat]), pipelines: $pipelines},
            "--previous_run": {type: "Text", values: [], pipelines: [$repeat]},
            "--title": {type: "Text", values: [], pipelines: $pipelines},
            "--samplesheet": {type: "Attachment", values: [], pipelines: $pipelines}}' <<< "$all"
}

# The custom fields gnoto fills, as a JSON array of {key, title, type, values}
wrike_fields_spec() {
    jq -cn --argjson pipelines "$(pipeline_names | jq -R . | jq -sc .)" '
        [{key: "pipeline", title: "Pipeline", type: "DropDown", values: $pipelines},
         {key: "results", title: "Results", type: "Text", values: []},
         {key: "expiration", title: "Expiration", type: "Date", values: []}]'
}

# What gnoto can't read past in a request form: a line each. A question is
# read by the key in its title's brackets, and one without is left alone. An
# answer to [pipeline] is read by its first word, so it can say more after it.
wrike_form_problems() {
    local form=$1 keys=$2
    jq -r --argjson keys "$keys" '
        {ComboBox: "DropDown", CheckBox: "Multiple", TextField: "Text", TextArea: "Text", Attachment: "Attachment"} as $kinds
        | {DropDown: "Single answer", Multiple: "Multiple answers", Text: "Single line text", Attachment: "Attachment"} as $names
        | [.data[0].pages[]?.fields[]? | {title, type, items: [.items[]?.title],
            key: ((.title // "") | capture("\\[(?<k>[^\\]]+)\\]").k? // null)}] as $form
        | [($form[] | select(.key != null) | . as $q | $keys[$q.key] as $want
            | ($kinds[$q.type] // "") as $kind
            | if $want == null then "\"\($q.title)\": gnoto start has no \($q.key)"
              else
                (if $kind != $want.type then
                    "\"\($q.title)\" is \($names[$kind] // $q.type), and gnoto reads it as \($names[$want.type])" else empty end),
                (if $want.values != [] then
                    ($q.items[] | . as $item
                     | (if $q.key == "pipeline" then (ascii_downcase | capture("^(?<w>[a-z0-9_]+)").w? // "") else . end) as $answer
                     | select(all($want.values[]; . != $answer))
                     | "\"\($q.title)\" offers \"\($item)\", and gnoto takes " + ($want.values | join(", ")))
                 else empty end)
              end),
           (if any($form[]; .key == "pipeline") then empty
            else "the form has no question with [pipeline] in its title, so gnoto finds no pipeline in its requests" end)]
        | unique[]' <<< "$form"
}

# The secret Wrike signs the webhook's deliveries with, which the SQS stack's
# Lambda checks: wrike.webhook_secret, or else a random one, made in
# generated.yaml the first time config sqs --deploy or config wrike needs it
wrike_webhook_secret() {
    [[ -z ${WRIKE_WEBHOOK_SECRET:-} ]] || return 0
    generated_set --keep wrike.webhook_secret "$(openssl rand -hex 32)"
}

# The bot account: its ID, name, role, and whether it's an account admin or
# the owner, as "id<tab>name<tab>role<tab>true|false"
wrike_me() {
    wrike_call GET "contacts" -G --data-urlencode "me=true" |
        jq -r '.data[0] | ((.profiles // [])[0] // {}) as $p
            | [.id, "\(.firstName // "") \(.lastName // "")", ($p.role // ""), (($p.admin // false) or ($p.owner // false))] | @tsv'
}

# A user's type in the account, such as Regular User or Admin, with its
# article, or nothing: wrike_user_type <user> <admin true|false>
wrike_user_type() {
    local type title=""
    type=$(wrike_call GET "users/$1" 2> /dev/null | jq -r '.data[0].userTypeId // empty')
    [[ -z $type ]] ||
        title=$(wrike_call GET "user_types" 2> /dev/null | jq -r --arg id "$type" 'first(.data[]? | select(.id == $id) | .title) // empty')
    [[ -n $title || $2 != true ]] || title="account admin"
    [[ -z $title ]] || printf '%s %s' "$([[ $title == [AEIOUaeiou]* ]] && echo an || echo a)" "$title"
}

# Whether a user is an admin of a space: wrike_space_admin <space> <user>
wrike_space_admin() {
    wrike_call GET "spaces/$1" -G --data-urlencode 'fields=["members"]' 2> /dev/null |
        jq -e --arg user "$2" 'any(.data[0].members[]?; .id == $user and .isManager)' > /dev/null
}

# The spaces the bot can see, as compact JSON of {id, title}
wrike_spaces() {
    wrike_call GET "spaces" | jq -c '[.data[]? | {id, title}]'
}

# A space's folders, as compact JSON of {id, title}, without its own root
# folder, which has its title, or what's in the recycle bin
wrike_folders() {
    wrike_call GET "spaces/$1/folders" | jq -c '[.data[]? | select((.scope // "WsFolder") == "WsFolder") | {id, title}]'
}

# The workflows a space's tasks can take, as compact JSON: its own, which only
# its own list shows, then the account's
wrike_workflows() {
    local own account
    own=$(wrike_call GET "spaces/$1/workflows" | jq -c '[.data[]?]') || return 1
    account=$(wrike_call GET "workflows" | jq -c '[.data[]?]') || return 1
    jq -cn --argjson own "$own" --argjson account "$account" '$own + $account'
}

# The request forms a space has, then those of the account, as compact JSON
# of {id, title}
wrike_forms() {
    local own account
    own=$(wrike_call GET "spaces/$1/request_forms" | jq -c '[.data[]? | {id, title}]') || return 1
    account=$(wrike_call GET "request_forms" 2> /dev/null | jq -c '[.data[]? | {id, title}]') || account="[]"
    jq -cn --argjson own "$own" --argjson account "$account" '$own + $account | unique_by(.id)'
}

# The space's custom fields as compact JSON
wrike_space_fields() {
    wrike_call GET "spaces/$1/customfields" | jq -c '[.data[]? | {id, title, type,
        values: ((.settings.values // [.settings.options[]?.value]) // [])}]'
}

# The webhooks on the folder to the address, as compact JSON a line
wrike_find_webhooks() {
    wrike_call GET "webhooks" | jq -c --arg folder "$1" --arg url "$2" \
        '.data[]? | select(.folderId == $folder and .hookUrl == $url)'
}

# The titles in a list, quoted and comma-separated, for a message
wrike_titles() {
    jq -r '[.[] | "\"\(.title // .name)\""] | if . == [] then "none" else join(", ") end' <<< "$1"
}

# Every folder the bot can see, in every space, as compact JSON of {id, title,
# space, spaceTitle, createdDate}. Only a folder read by its ID says when it
# was made, so they're read a hundred at a time.
wrike_all_folders() {
    local spaces=$1 space title folders all="[]" ids dated="[]" i
    while IFS=$'\t' read -r space title; do
        [[ -n $space ]] || continue
        folders=$(wrike_folders "$space") || return 1
        all=$(jq -c --argjson more "$folders" --arg space "$space" --arg title "$title" \
            '. + [$more[] | . + {space: $space, spaceTitle: $title}]' <<< "$all")
    done < <(jq -r '.[] | [.id, .title] | @tsv' <<< "$spaces")
    for (( i = 0; i < $(jq length <<< "$all"); i += 100 )); do
        ids=$(jq -r --argjson i "$i" '[.[$i:$i + 100][].id] | join(",")' <<< "$all")
        dated=$(jq -c --argjson more "$(wrike_call GET "folders/$ids" | jq -c '[.data[]? | {id, createdDate}]')" \
            '. + $more' <<< "$dated") || return 1
    done
    jq -c --argjson dated "$dated" '($dated | map({(.id): .createdDate}) | add // {}) as $when
        | map(. + {createdDate: ($when[.id] // "")})' <<< "$all"
}

# The folders a setting names, as compact JSON: by its name, or by its Wrike
# link, whose number Wrike turns into its ID. A link names one folder, and a
# name may name several, in different spaces.
wrike_named_folders() {
    local wanted=$1 folders=$2 legacy id="" link='(/folder/|[?&#]id=)([0-9]+)'
    if [[ $wanted =~ $link ]]; then
        legacy=${BASH_REMATCH[2]}
        id=$(wrike_call GET "ids" -G --data-urlencode "ids=[\"$legacy\"]" --data-urlencode "type=ApiV2Folder" |
            jq -r '.data[0].id // empty') || return 1
    fi
    jq -c --arg id "$id" --arg title "$wanted" \
        'map(select(if $id != "" then .id == $id else .title == $title end))' <<< "$folders"
}

# What config wrike suggests for the folder: the one named, when the bot can
# see it, or else the newest it can see, with what else there is listed above
# the question
config_wrike_suggest() {
    local current folders
    [[ $1 == folder ]] || return 1
    local WRIKE_API_TOKEN=${CONFIG_NEW[api_token]:-${WRIKE_API_TOKEN:-}}
    local WRIKE_API_URL=${CONFIG_NEW[api_url]:-${WRIKE_API_URL:-}}
    current=${CONFIG_NEW[folder]:-${WRIKE_FOLDER:-}}
    [[ -n $WRIKE_API_TOKEN && -n $WRIKE_API_URL ]] || { printf '%s' "$current"; return 0; }
    folders=$(wrike_all_folders "$(wrike_spaces 2> /dev/null)" 2> /dev/null) || { printf '%s' "$current"; return 0; }
    echo "  The bot sees these folders, the newest last: $(wrike_titles \
        "$(jq -c 'sort_by(.createdDate) | map({title: "\(.title) (in \(.spaceTitle))"})' <<< "$folders")")" >&2
    if [[ -n $current && $(wrike_named_folders "$current" "$folders" 2> /dev/null | jq length) -eq 1 ]]; then
        printf '%s' "$current"
    else
        jq -r 'sort_by(.createdDate) | last | .title // empty' <<< "$folders"
    fi
}

# The folder's newest task that a request form made, as compact JSON with its
# description: one whose description names an option in brackets
wrike_test_request() {
    wrike_call GET "folders/$1/tasks" -G --data-urlencode 'fields=["description"]' --data-urlencode "pageSize=1000" |
        jq -c '[.data[]? | select((.description // "") | test("\\[(--)?[a-z][a-z0-9_.]*\\]"))] | sort_by(.createdDate) | last // empty'
}

# The form a request came from, out of the forms the bot can see, as
# {id, title}: the one with the most of the questions its description answers
wrike_request_form() {
    local request=$1 forms=$2 titles form questions best="" most=0 count
    titles=$(wrike_task_answers "$request" titles)
    while IFS= read -r form; do
        [[ -n $form ]] || continue
        questions=$(wrike_call GET "request_forms/$(jq -r .id <<< "$form")" 2> /dev/null |
            jq -c '[.data[0].pages[]?.fields[]?.title]') || continue
        count=$(jq --argjson questions "$questions" '[.[] | select(. as $t | $questions | index($t))] | length' <<< "$titles")
        if (( count > most )); then
            most=$count
            best=$form
        fi
    done < <(jq -c '.[]' <<< "$forms")
    printf '%s' "$best"
}

# Creates a task in the folder, as gnoto does a command-line job's, sets its
# fields, comments on it and attaches a file to it, then deletes it. Prints
# what the bot couldn't do, and returns 1.
wrike_write_test() {
    local folder=$1 json task why=""
    json=$(wrike_call POST "folders/$folder/tasks" --data-urlencode "title=gnoto config wrike's test, safe to delete" \
        --data-urlencode "description=A test of what gnoto does in this folder." \
        --data-urlencode "customStatus=$(wrike_status_id running)" \
        --data-urlencode "customFields=$(jq -cn --arg p "$(wrike_field_id pipeline)" --arg r "$(wrike_field_id results)" \
            --arg e "$(wrike_field_id expiration)" --arg pipeline "$(pipeline_names | head -n 1)" --arg date "$(date -u +%F)" \
            '[{id: $p, value: $pipeline}, {id: $r, value: "https://example.invalid/gnoto-test/"}, {id: $e, value: $date}]')") ||
        { echo "create a task there with a gnoto status and its fields, as above"; return 1; }
    task=$(jq -r '.data[0].id // empty' <<< "$json")
    is_valid_wrike_id "$task" || { echo "create a task there: Wrike named none"; return 1; }
    wrike_call POST "tasks/$task/comments" --data-urlencode "plainText=true" \
        --data-urlencode "text=gnoto config wrike's test comment." > /dev/null 2>&1 || why="comment on a task there"
    [[ -n $why ]] || printf 'gnoto config wrike test\n' | wrike_call POST "tasks/$task/attachments" -H "X-File-Name: gnoto-test.txt" \
        -H "Content-Type: application/octet-stream" --data-binary @- > /dev/null 2>&1 || why="attach a file to a task there"
    wrike_call DELETE "tasks/$task" > /dev/null 2>&1 ||
        warn "The test task couldn't be deleted. Delete \"gnoto config wrike's test, safe to delete\" in Wrike by hand."
    [[ -z $why ]] || { echo "$why"; return 1; }
}

# gnoto config wrike, once its settings are written
config_wrike_step() {
    local me bot bot_name role admin kind name group color status spaces folders matches folder space space_title
    local request="" workflows workflow forms form="" form_title="" fields existing have id field plan=() missing=()
    local webhooks hook problems why answers heard submitted uid test_request=""
    [[ ${WRIKE_ENABLED:-false} == true ]] || return 0
    [[ -n ${WRIKE_API_TOKEN:-} ]] || fail "Set wrike.api_token first, the bot account's API token."
    [[ -n ${WRIKE_FOLDER:-} ]] || fail "Set wrike.folder first, the folder gnoto's tasks go in, by its name or its Wrike link."
    run_id_salt
    me=$(wrike_me) || fail "Wrike refused the token, as above."
    IFS=$'\t' read -r bot bot_name role admin <<< "$me"
    [[ $role != Collaborator ]] || fail "The bot account, $bot_name, is a Collaborator, and those can't create tasks. Give it a full license."
    generated_set wrike.bot_id "$bot"
    kind=$(wrike_user_type "$bot" "$admin")
    echo "Wrike's bot account is $bot_name${kind:+, $kind}." >&2

    # The folder, and its space
    spaces=$(wrike_spaces) || fail "Can't list Wrike's spaces."
    folders=$(wrike_all_folders "$spaces") || fail "Can't list the spaces' folders."
    matches=$(wrike_named_folders "$WRIKE_FOLDER" "$folders") || fail "Wrike can't say which folder the link \"$WRIKE_FOLDER\" is."
    case $(jq length <<< "$matches") in
        0) fail "$bot_name can't see a folder \"$WRIKE_FOLDER\". It sees $(wrike_titles "$folders"). Set up Wrike as $WRIKE_GUIDE says, with $bot_name in the space, and give the folder's name or link with $(gnoto_command config wrike --folder=\"name\")." ;;
        1) ;;
        *) fail "More than one folder is named \"$WRIKE_FOLDER\", in $(wrike_titles "$(jq -c 'map({title: .spaceTitle})' <<< "$matches")"). Give the one gnoto should use by its Wrike link, with $(gnoto_command config wrike --folder=\"link\")." ;;
    esac
    folder=$(jq -r '.[0].id' <<< "$matches")
    space=$(jq -r '.[0].space' <<< "$matches")
    space_title=$(jq -r '.[0].spaceTitle' <<< "$matches")

    # The test request, and from it the workflow and form
    request=$(wrike_test_request "$folder") || fail "Can't list the tasks in \"$WRIKE_FOLDER\"."
    workflows=$(wrike_workflows "$space") || fail "Can't list Wrike's workflows."
    if [[ -n $request ]]; then
        workflow=$(jq -c --arg status "$(jq -r '.customStatusId // ""' <<< "$request")" \
            'first(.[] | select(any(.customStatuses[]?; .id == $status))) // empty' <<< "$workflows")
        [[ -n $workflow ]] ||
            fail "The test request \"$(jq -r .title <<< "$request")\" has a status in no workflow $bot_name can see. The form must set its requests to the status Submitted, in the workflow with gnoto's statuses."
        forms=$(wrike_forms "$space") || fail "Can't list the space's request forms."
        form=$(wrike_request_form "$request" "$forms")
        form_title=$(jq -r '.title // empty' <<< "${form:-null}")
        form=$(jq -r '.id // empty' <<< "${form:-null}")
    else
        # Without a request, the workflow with gnoto's statuses: the space's
        # own first, as its default for tasks if it has several
        workflow=$(jq -c --arg default "$(wrike_call GET "spaces/$space" | jq -r '.data[0].defaultTaskWorkflowId // ""')" \
            --argjson names "$(printf '%s\n' "${WRIKE_STATUSES[@]%% *}" | jq -R . | jq -sc .)" '
            [.[] | select([.customStatuses[]?.name] as $have | all($names[]; . as $n | $have | index($n)))]
            | (first(.[] | select(.id == $default)) // first(.[])) // empty' <<< "$workflows")
        [[ -n $workflow ]] ||
            fail "No request is in \"$WRIKE_FOLDER\" yet, and no workflow $bot_name can see has gnoto's six statuses. Set up the workflow and form, and submit a test request with the form, as $WRIKE_GUIDE says."
    fi
    for status in "${WRIKE_STATUSES[@]}"; do
        read -r name group color <<< "$status"
        jq -e --arg name "$name" 'any(.customStatuses[]?; .name == $name)' <<< "$workflow" > /dev/null ||
            missing+=("$name ($group)")
    done
    (( ${#missing[@]} == 0 )) ||
        fail "The workflow \"$(jq -r .name <<< "$workflow")\", which the test request is in, lacks gnoto's $(lint_list "${missing[@]}"). Give it those, named exactly so, in Wrike, as $WRIKE_GUIDE says."
    if [[ -n $request ]]; then
        [[ -n $form ]] ||
            fail "None of the request forms $bot_name can see asks the questions the request \"$(jq -r .title <<< "$request")\" answers. The form must be in the space \"$space_title\", or the account's."
        # A request gnoto hasn't run, still Submitted, is the test request. One
        # it ran or that moved on, after an earlier run of this, only shows
        # the workflow and form.
        submitted=$(jq -r 'first(.customStatuses[] | select(.name == "Submitted") | .id)' <<< "$workflow")
        uid=$(derive_uid "$(jq -r .id <<< "$request")") || fail "There's no uid for a request: RUN_ID_SALT isn't set."
        if [[ -e $DATA_DIR/runs/$uid || -e $DATA_DIR/history/$uid ]]; then
            test_request=""
        elif [[ $(jq -r .customStatusId <<< "$request") == "$submitted" ]]; then
            test_request=$request
        elif [[ -z ${WRIKE_FORM_ID:-} ]]; then
            fail "The request \"$(jq -r .title <<< "$request")\" isn't Submitted, and gnoto starts only Submitted requests. Set the form's status for its tasks to Submitted, and submit a test request with it."
        fi
    fi
    echo "gnoto's folder is \"$WRIKE_FOLDER\", in the space \"$space_title\". Its workflow is \"$(jq -r .name <<< "$workflow")\"${form_title:+, and its request form \"$form_title\"}." >&2

    # The fields gnoto fills
    fields=$(wrike_fields_spec)
    existing=$(wrike_space_fields "$space") || fail "Can't list the space's custom fields."
    while IFS= read -r field; do
        have=$(jq -c --arg title "$(jq -r .title <<< "$field")" 'first(.[] | select(.title == $title)) // empty' <<< "$existing")
        if [[ -z $have ]]; then
            plan+=("Create the custom field \"$(jq -r .title <<< "$field")\", $(jq -r '.type + (if .values != [] then " of " + (.values | join(", ")) else "" end)' <<< "$field"), in the space")
        elif [[ $(jq -r .type <<< "$have") != "$(jq -r .type <<< "$field")" ]]; then
            fail "The space has a field \"$(jq -r .title <<< "$field")\" of type $(jq -r .type <<< "$have"), and gnoto needs one of type $(jq -r .type <<< "$field"). Rename or remove it in Wrike."
        elif [[ $(jq -c '.values | sort' <<< "$have") != "$(jq -c '.values | sort' <<< "$field")" ]]; then
            plan+=("Change the answers of the field \"$(jq -r .title <<< "$field")\" to $(jq -r '.values | join(", ")' <<< "$field")")
        fi
    done < <(jq -c '.[]' <<< "$fields")
    if (( ${#plan[@]} > 0 )) && [[ $admin != true ]] && ! wrike_space_admin "$space" "$bot"; then
        fail "$bot_name makes gnoto's custom fields as the space's admin, and it isn't one. Make it an admin of \"$space_title\", as $WRIKE_GUIDE says, and run this again."
    fi
    plan+=("Test, in \"$WRIKE_FOLDER\", that $bot_name can create a task with a gnoto status, set its fields, comment and attach a file, then delete it")
    if sqs_on && [[ -n ${AWS_SQS_WEBHOOK_URL:-} ]]; then
        webhooks=$(wrike_find_webhooks "$folder" "$AWS_SQS_WEBHOOK_URL") || fail "Can't list Wrike's webhooks."
        if [[ -z $webhooks ]]; then
            plan+=("Create the webhook on \"$WRIKE_FOLDER\" to $AWS_SQS_WEBHOOK_URL, for $WRIKE_WEBHOOK_EVENTS")
        elif [[ $(jq -sc 'map(.events | sort | join(",")) | unique' <<< "$webhooks") != "$(jq -cn --arg e "$WRIKE_WEBHOOK_EVENTS" '[$e | split(",") | sort | join(",")]')" ||
            $(grep -c . <<< "$webhooks") -gt 1 ]]; then
            plan+=("Replace the webhook on \"$WRIKE_FOLDER\", deleting the old one first, for $WRIKE_WEBHOOK_EVENTS")
        fi
    fi
    [[ -z $test_request ]] ||
        plan+=("Comment on the test request \"$(jq -r .title <<< "$test_request")\" with what gnoto read from it, and move it to Cancelled, so it never runs")
    config_confirm "in Wrike, as $bot_name" "${plan[@]}" || exit 0

    generated_set wrike.space_id "$space"
    generated_set wrike.folder_id "$folder"
    generated_set wrike.workflow_id "$(jq -r .id <<< "$workflow")"
    for status in "${WRIKE_STATUSES[@]}"; do
        name=${status%% *}
        generated_set "wrike.statuses.${name,,}" "$(jq -r --arg name "$name" 'first(.customStatuses[] | select(.name == $name) | .id)' <<< "$workflow")"
    done
    generated_set wrike.form_id "$form"

    while IFS= read -r field; do
        have=$(jq -c --arg title "$(jq -r .title <<< "$field")" 'first(.[] | select(.title == $title)) // empty' <<< "$existing")
        if [[ -z $have ]]; then
            id=$(wrike_call POST "customfields" --data-urlencode "title=$(jq -r .title <<< "$field")" \
                --data-urlencode "type=$(jq -r .type <<< "$field")" --data-urlencode "spaceId=$space" \
                --data-urlencode "settings=$(jq -c 'if .values != [] then {values, allowOtherValues: false} else {} end' <<< "$field")" |
                jq -r '.data[0].id // empty') || fail "Wrike didn't create the field \"$(jq -r .title <<< "$field")\"."
        else
            id=$(jq -r .id <<< "$have")
            if [[ $(jq -c '.values | sort' <<< "$have") != "$(jq -c '.values | sort' <<< "$field")" ]]; then
                wrike_call PUT "customfields/$id" \
                    --data-urlencode "settings=$(jq -c '{values, allowOtherValues: false}' <<< "$field")" > /dev/null ||
                    fail "Wrike didn't change the answers of the field \"$(jq -r .title <<< "$field")\"."
            fi
        fi
        [[ -n $id ]] || fail "Wrike didn't create the field \"$(jq -r .title <<< "$field")\"."
        generated_set "wrike.fields.$(jq -r .key <<< "$field")" "$id"
    done < <(jq -c '.[]' <<< "$fields")
    source "$CODE_DIR/lib/env.sh"

    why=$(wrike_write_test "$folder") ||
        fail "$bot_name couldn't $why. It needs to edit tasks in \"$WRIKE_FOLDER\": share the folder with it, with a role that can, and run this again."
    echo "$bot_name can create, change, comment on and attach to tasks in \"$WRIKE_FOLDER\"." >&2

    if sqs_on && [[ -n ${AWS_SQS_WEBHOOK_URL:-} ]]; then
        webhooks=$(wrike_find_webhooks "$folder" "$AWS_SQS_WEBHOOK_URL") || fail "Can't list Wrike's webhooks."
        hook=""
        while IFS= read -r field; do
            [[ -n $field ]] || continue
            if [[ -z $hook && $(jq -r '.events | sort | join(",")' <<< "$field") == "$(tr ',' '\n' <<< "$WRIKE_WEBHOOK_EVENTS" | sort | paste -sd ,)" ]]; then
                hook=$(jq -r .id <<< "$field")
            else
                wrike_call DELETE "webhooks/$(jq -r .id <<< "$field")" > /dev/null || fail "Wrike didn't delete an old webhook."
            fi
        done <<< "$webhooks"
        if [[ -z $hook ]]; then
            wrike_webhook_secret
            hook=$(wrike_call POST "folders/$folder/webhooks" --data-urlencode "hookUrl=$AWS_SQS_WEBHOOK_URL" \
                --data-urlencode "secret=$WRIKE_WEBHOOK_SECRET" --data-urlencode "events=[$WRIKE_WEBHOOK_EVENTS]" |
                jq -r '.data[0].id // empty') ||
                fail "Wrike didn't create the webhook. Its handshake with $AWS_SQS_WEBHOOK_URL may have failed: the SQS stack's Lambda checks it with wrike.webhook_secret as the stack was deployed, so if that changed since, deploy it again: $(gnoto_command config sqs --deploy)"
        fi
        generated_set wrike.webhook_id "$hook"
    fi

    if [[ -z $request ]]; then
        echo "Wrike is ready for jobs from the command line. Requests from a form need one, saving to \"$WRIKE_FOLDER\" as Submitted, and a test request made with it, as $WRIKE_GUIDE says. Then run this again."
        return 0
    fi
    # What gnoto read from the test request, on it and here
    if [[ -n $test_request ]]; then
        answers=$(wrike_task_answers "$test_request")
        heard=$(jq -r 'to_entries[] | "  \(.key): \(.value)"' <<< "$answers")
        echo "From the test request \"$(jq -r .title <<< "$test_request")\", gnoto read:"
        printf '%s\n' "${heard:-  nothing}"
        wrike_comment "$(jq -r .id <<< "$test_request")" "gnoto config wrike read this test request, and moved it to Cancelled so it never runs. It read:
${heard:-  nothing}"
        wrike_set_status "$(jq -r .id <<< "$test_request")" Cancelled
    fi
    problems=$(wrike_form_problems "$(wrike_call GET "request_forms/$form")" "$(wrike_form_keys)") || problems=""
    if [[ -n $problems ]]; then
        echo "Wrike is ready, but gnoto can't read all of the form \"$form_title\":"
        sed 's/^/  /' <<< "$problems"
        echo "$WRIKE_GUIDE says how a form's questions name what they answer."
        return 0
    fi
    echo "Wrike is ready: gnoto can read the form \"$form_title\"."
}

# lint's Wrike checks
lint_wrike() {
    local me bot name role admin kind problems json status field missing=()
    [[ ${WRIKE_ENABLED:-false} == true ]] || return 0
    if [[ -z ${WRIKE_API_TOKEN:-} ]]; then
        lint_fail "wrike: is on, and wrike.api_token isn't set. $(gnoto_command config wrike) asks for it"
        return 0
    fi
    if ! me=$(wrike_me 2> /dev/null) || [[ -z $me ]]; then
        lint_fail "wrike: the token doesn't work, or Wrike can't be reached at ${WRIKE_API_URL:-}"
        return 0
    fi
    IFS=$'\t' read -r bot name role admin <<< "$me"
    if [[ $role == Collaborator ]]; then
        lint_fail "wrike: the bot account, $name, is a Collaborator, and those can't create tasks"
    else
        kind=$(wrike_user_type "$bot" "$admin")
        lint_ok "wrike: the bot account is $name${kind:+, $kind}"
    fi
    [[ -n ${INPUT_ROOTS:-} ]] ||
        lint_fail "wrike: core.input_roots isn't set, and form requests may read FASTQs only under it. $(gnoto_command config core --input_roots=/path)"
    if [[ -z ${WRIKE_FOLDER_ID:-} ]]; then
        lint_fail "wrike: isn't set up yet. Run: $(gnoto_command config wrike)"
        return 0
    fi
    for status in "${WRIKE_STATUSES[@]}"; do
        [[ -n $(wrike_status_id "${status%% *}") ]] || missing+=("status ${status%% *}")
    done
    while IFS= read -r field; do
        [[ -z $field || -n $(wrike_field_id "$field") ]] || missing+=("field $field")
    done < <(wrike_fields_spec | jq -r '.[].key')
    if (( ${#missing[@]} > 0 )); then
        lint_fail "wrike: generated.yaml lacks the $(lint_list "${missing[@]}"). Run: $(gnoto_command config wrike)"
    fi
    if [[ -z ${WRIKE_FORM_ID:-} ]]; then
        lint_warn "wrike: no request form is set up, so requests come only from the command line. $WRIKE_GUIDE says how to build one"
    elif json=$(wrike_call GET "request_forms/$WRIKE_FORM_ID" 2> /dev/null); then
        problems=$(wrike_form_problems "$json" "$(wrike_form_keys 2> /dev/null || echo "{}")")
        if [[ -n $problems ]]; then
            lint_warn "wrike: gnoto can't read all of the request form: $(paste -sd ';' <<< "$problems" | sed 's/;/; /g')"
        else
            lint_ok "wrike: gnoto can read the request form"
        fi
    else
        lint_warn "wrike: the request form recorded in generated.yaml can't be read"
    fi
    if sqs_on; then
        if [[ -z ${WRIKE_WEBHOOK_ID:-} ]]; then
            lint_fail "wrike: SQS is set up, and there's no webhook. Run: $(gnoto_command config wrike)"
        elif json=$(wrike_call GET "webhooks/$WRIKE_WEBHOOK_ID" 2> /dev/null); then
            status=$(jq -r '.data[0].status // ""' <<< "$json")
            if [[ $status == Active ]]; then
                lint_ok "wrike: webhook $status"
            else
                lint_warn "wrike: webhook ${status:-unknown}. The poll timer's scan reactivates it"
            fi
        else
            lint_fail "wrike: the webhook recorded in generated.yaml is gone. Run: $(gnoto_command config wrike)"
        fi
    fi
}
