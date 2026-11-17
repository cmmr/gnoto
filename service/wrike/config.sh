#
# config.sh - gnoto config wrike: sets up gnoto's part of Wrike, and lint's
# checks of it.
#
# Sourced by:  lib/config.sh and lib/lint.sh
# Defines:     config_wrike_step, wrike_questions_spec, wrike_fields_spec,
#              wrike_webhook_secret, lint_wrike, WRIKE_WEBHOOK_EVENTS
# Requires:    wrike_call from service/wrike/api.sh; generated_set,
#              config_confirm and run_id_salt from lib/config.sh; options_json
#              and pipeline_names from lib/jobfile.sh; lint_ok, lint_warn and
#              lint_fail from lib/lint.sh
#
# Each object is found by its name and adopted when it exists, or else is
# created after the plan is shown and accepted, and its ID goes to
# generated.yaml. So the step is safe to repeat, and --dry-run stops after the
# plan. A bot that isn't an account admin can't make a workflow or change its
# statuses, and often not a space, so then this lists what a person must make
# first, the space, with the bot its admin, and the space's own workflow, and
# stops:
#
#   space      "gnoto", whose tasks take the gnoto workflow by default
#   workflow   "gnoto", with the statuses Submitted, Running, Completed,
#              Failed, Cancelled and Expired: the space's own, or else the
#              account's, which only an admin bot makes
#   folder     "gnoto Jobs", in the space, where requests arrive
#   fields     in the space: Pipeline, which the form fills, and Results and
#              Expiration, which gnoto fills. Pipeline's answers are kept to
#              the pipelines and the repeat, with no others allowed.
#   webhook    on "gnoto Jobs", to aws.sqs.webhook_url, when SQS is set up, for
#              WRIKE_WEBHOOK_EVENTS. Webhooks can't be edited, so one with other
#              events is deleted before its replacement is made, so no event
#              arrives twice.
#
# Every other question on the request form, one for each in the pipelines'
# options.yaml but Title and Samplesheet, which are the task's title and
# attachment, writes its answer into the task's description, where gnoto reads
# it. A question several pipelines ask is asked once. Wrike's API can't make a
# request form, so this prints a checklist for one, then looks for it by name,
# records it, and compares its questions with the checklist. lint repeats the
# comparison. Wrike's API can't delete a custom field either, so a field the
# space still has for a question is named, to delete by hand.

# Keep in step with the case statement in service/wrike/listener.sh: an event
# the webhook doesn't subscribe to never arrives, with nothing in any log
WRIKE_WEBHOOK_EVENTS="TaskCreated,TaskDeleted,TaskCustomFieldChanged"
WRIKE_SPACE_TITLE="gnoto"
WRIKE_WORKFLOW_NAME="gnoto"
WRIKE_FOLDER_TITLE="gnoto Jobs"
WRIKE_FORM_TITLE="gnoto Request"
# name, group and color of each status, in order
WRIKE_STATUSES=("Submitted Active Blue" "Running Active Turquoise" "Completed Completed Green"
    "Failed Cancelled Red" "Cancelled Cancelled Gray" "Expired Completed Brown")

# The request form's questions after Title and Samplesheet, in order, as a
# JSON array of {key, title, type, values, help, pipelines, rank, required,
# default, field}. pipelines are the Pipeline answers the form shows a
# question for, and rank its place in each pipeline's options.yaml.
# An option with a default is required, starting at that answer, and so is
# always in the description of a request that names its pipeline. Only
# Pipeline maps to a custom field. Fails when two pipelines ask one question
# with different titles, answers or defaults.
wrike_questions_spec() {
    local pipeline all="[]" options
    for pipeline in $(pipeline_names); do
        options=$(options_json "$pipeline")
        all=$(jq -c --arg pipeline "$pipeline" --argjson options "$options" '. + [$options | to_entries[]
            | .key as $rank | .value
            | select(.key != "title" and .key != "samplesheet")
            | ((.labels // {}) | with_entries(.key |= tostring)) as $labels
            | {key, title: .question, type: (if .multiple then "Multiple" else "DropDown" end),
               values: [(.values // [])[] | tostring | ($labels[.] // .)], help: (.help // ""),
               required: (.default != null and .default != ""),
               default: (if .default == null then "" else (.default | tostring | ($labels[.] // .)) end),
               pipelines: [$pipeline], rank: {($pipeline): $rank}, field: false}]' <<< "$all")
    done
    jq -c --argjson pipelines "$(pipeline_names | jq -R . | jq -sc .)" --arg repeat "$WRIKE_REPEAT_ANSWER" \
        --arg pipeline "$WRIKE_PIPELINE_QUESTION" --arg previous "$WRIKE_PREVIOUS_QUESTION" '
        group_by(.key) | map(
            if (map([.title, .values, .type, .default]) | unique | length) > 1
            then error("The option \(.[0].key) is asked differently by \(map(.pipelines[0]) | join(" and ")): one question must have one title, one set of answers and one default")
            else .[0] + {pipelines: map(.pipelines[0]), rank: (map(.rank) | add)} end)
        # A repeat keeps the answers of its earlier run, but for how long its results are kept
        | map(if .key == "retention" then .pipelines += [$repeat] else . end)
        | [{key: "pipeline", title: $pipeline, type: "DropDown", values: ($pipelines + [$repeat]),
            help: "Which analysis to run, or to repeat an earlier run on new samples", pipelines: [],
            rank: {}, required: true, default: "", field: true},
           {key: "previous_run", title: $previous, type: "Text", values: [],
            help: "The earlier run to repeat: its eight-character ID, or its results address", pipelines: [$repeat],
            rank: {}, required: true, default: "", field: false}]
          + sort_by([(.pipelines | length) != ($pipelines | length) + 1, .title])' <<< "$all"
}

# The custom fields gnoto reads or writes, as a JSON array of {key, title,
# type, values}: the questions that map to one, then Results and Expiration,
# which gnoto fills and no question asks
wrike_fields_spec() {
    local questions
    questions=$(wrike_questions_spec) || return 1
    jq -c '[.[] | select(.field) | {key, title, type, values}]
        + [{key: "results", title: "Results", type: "Text", values: []},
           {key: "expiration", title: "Expiration", type: "Date", values: []}]' <<< "$questions"
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

# A user's type in the account, such as Regular User or Admin, or nothing
wrike_user_type() {
    local type
    type=$(wrike_call GET "users/$1" 2> /dev/null | jq -r '.data[0].userTypeId // empty')
    [[ -n $type ]] || return 0
    wrike_call GET "user_types" 2> /dev/null | jq -r --arg id "$type" 'first(.data[]? | select(.id == $id) | .title) // empty'
}

# Whether a user is an admin of a space: wrike_space_admin <space> <user>
wrike_space_admin() {
    wrike_call GET "spaces/$1" -G --data-urlencode 'fields=["members"]' 2> /dev/null |
        jq -e --arg user "$2" 'any(.data[0].members[]?; .id == $user and .isManager)' > /dev/null
}

# Statuses as the checklist names them: "Submitted (Active, Blue), ..."
wrike_status_text() {
    local status name group color text=""
    for status in "$@"; do
        read -r name group color <<< "$status"
        text+="${text:+, }$name ($group, $color)"
    done
    printf '%s' "$text"
}

# The space's ID, by title, or nothing
wrike_find_space() {
    wrike_call GET "spaces" | jq -r --arg title "$WRIKE_SPACE_TITLE" 'first(.data[]? | select(.title == $title) | .id) // empty'
}

# The workflow, by name, as compact JSON, or nothing: wrike_find_workflow
# [space]. A space's own workflows, which a person makes, list apart from the
# account's, which an admin bot makes.
wrike_find_workflow() {
    local found=""
    if [[ -n ${1:-} ]]; then
        found=$(wrike_call GET "spaces/$1/workflows" |
            jq -c --arg name "$WRIKE_WORKFLOW_NAME" 'first(.data[]? | select(.name == $name)) // empty') || return 1
    fi
    [[ -n $found ]] ||
        found=$(wrike_call GET "workflows" | jq -c --arg name "$WRIKE_WORKFLOW_NAME" 'first(.data[]? | select(.name == $name)) // empty') ||
        return 1
    printf '%s' "$found"
}

wrike_find_folder() {
    wrike_call GET "spaces/$1/folders" |
        jq -r --arg title "$WRIKE_FOLDER_TITLE" 'first(.data[]? | select(.title == $title and (.scope // "WsFolder") != "RbFolder") | .id) // empty'
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

# The checklist for building the request form by hand, from the questions, in
# the words of Wrike's form builder: one page, with Pipeline's options each
# followed by the questions only it asks, as its follow-up questions, in its
# options.yaml's order. A question several pipelines ask follows each of
# their options. The questions every request asks come last.
wrike_form_checklist() {
    local questions=$1
    cat << EOF

Build the request form in Wrike by hand: gnoto can read forms, but not make them.
In the "$WRIKE_SPACE_TITLE" space, create a request form named "$WRIKE_FORM_TITLE".

Response settings
  Create task
  Set status to: Submitted
  Save to: $WRIKE_FOLDER_TITLE

Questions, each titled exactly as written, with exactly the options listed, and
"Add answer to" at Description, where gnoto reads the answer, unless it says otherwise:
EOF
    jq -r '
        def kind: {DropDown: "Single answer", Multiple: "Multiple answers", Text: "Single line text"}[.type];
        def detail: (if .help != "" then "Description: \"\(.help)\"" else empty end),
            (.default as $default | if .values != [] then
                "Options: " + ([.values[] | if . == $default then "\(.) (preselected)" else . end] | join(", "))
             else empty end),
            "Answer required: " + (if .required then "on" else "off" end),
            (if .field then "Add answer to: \(.title), the custom field" else empty end);
        def block($first; $pad): "\($first)\(.title): \(kind)", (detail | $pad + .);
        first(.[] | select(.key == "pipeline")) as $pipeline
        | ($pipeline.values | length) as $all
        | [.[] | select(.key != "pipeline" and (.pipelines | length) >= $all)] as $always
        | [$pipeline.values[] as $answer | {answer: $answer,
            questions: ([.[] | select(.key != "pipeline" and (.pipelines | length) < $all and any(.pipelines[]; . == $answer))]
                | sort_by(.rank[$answer] // 0))}]
        | "  1. Title: Single line text", "     Description: \"Names the results.\"", "     Answer required: on",
          "     Add answer to: Title",
          ($pipeline | block("  2. "; "     ")),
          "     Follow-up questions:",
          (.[] | "       \(.answer)" + (if .questions == [] then ": none" else "" end),
              (.questions | to_entries[] | ([.key + 97] | implode) as $letter | .value
                  | block("         \($letter). "; "            "))),
          "  3. Samplesheet: Attachment",
          "     Description: \"Tab-separated, no header: sample, fastq1, fastq2. Omit fastq2 for single-end.\"",
          "     Answer required: on",
          ($always | to_entries[] | (.key + 4) as $n | .value | block("  \($n). "; "     "))' <<< "$questions"
    echo
    echo "Then run $(gnoto_command config wrike) again, which finds the form and checks its questions."
}

# What differs between the form and the questions: a line each. A question
# asked under several answers is checked each time. Wrike's API doesn't say
# where a question's answer goes, so that isn't compared.
wrike_form_drift() {
    local form=$1 questions=$2
    jq -r --argjson spec "$questions" '
        {DropDown: "ComboBox", Multiple: "CheckBox", Text: "TextField"} as $types
        | {ComboBox: "Single answer", CheckBox: "Multiple answers", TextField: "Single line text", TextArea: "Paragraph"} as $names
        | [.data[0].pages[]?.fields[]? | {title, type, mandatory: (.mandatory // false),
            items: [.items[]?.title], chosen: [.items[]? | select(.selectedByDefault) | .title]}] as $form
        | [$spec[] | . as $want
           | [$form[] | select(.title == $want.title)] as $asked
           | if $asked == [] then "the form has no question \"\($want.title)\""
             else $asked[] as $q
               | (if $q.type != $types[$want.type] and ($want.type != "Text" or $q.type != "TextArea") then
                     "the form asks \"\($want.title)\" as \($names[$q.type] // $q.type), not \($names[$types[$want.type]])" else empty end),
                 (if $want.values != [] and ($q.items | sort) != ($want.values | sort) then
                     "the form offers \"\($want.title)\" the answers \($q.items | join(", ")), not \($want.values | join(", "))" else empty end),
                 (if $want.required and ($q.mandatory | not) then "the form should require \"\($want.title)\"" else empty end),
                 (if $want.default != "" and $q.chosen != [$want.default] then
                     "the form should select \($want.default) by default in \"\($want.title)\"" else empty end)
             end]
        | unique[]' <<< "$form"
}

# The space's custom fields that a question has the title of, and gnoto
# doesn't use: the old way of carrying an answer, which the form may still
# map that question to. A line each.
wrike_leftover_fields() {
    local existing=$1 questions=$2 fields=$3
    jq -r --argjson questions "$questions" --argjson fields "$fields" '
        .[] | .title as $title
        | select(any($questions[]; .title == $title) and (any($fields[]; .title == $title) | not)) | $title' <<< "$existing"
}

# gnoto config wrike, once its settings are written
config_wrike_step() {
    local me bot bot_name role admin kind name space workflow folder fields spec plan=() status group color have id field
    local existing questions leftover webhooks hook form forms drift missing=() steps=() i
    [[ ${WRIKE_ENABLED:-false} == true ]] || return 0
    [[ -n ${WRIKE_API_TOKEN:-} ]] || fail "Set wrike.api_token first, the bot account's API token."
    run_id_salt
    me=$(wrike_me) || fail "Wrike refused the token, as above."
    IFS=$'\t' read -r bot bot_name role admin <<< "$me"
    [[ $role != Collaborator ]] || fail "The bot account, $bot_name, is a Collaborator, and those can't create tasks. Give it a full license."
    generated_set wrike.bot_id "$bot"
    kind=$(wrike_user_type "$bot")
    if [[ -n $kind ]]; then
        kind="$([[ $kind == [AEIOUaeiou]* ]] && echo an || echo a) $kind"
    elif [[ $admin == true ]]; then
        kind="an account admin"
    fi
    echo "Wrike's bot account is $bot_name${kind:+, $kind}." >&2

    space=$(wrike_find_space) || fail "Can't list Wrike's spaces."
    workflow=$(wrike_find_workflow "$space") || fail "Can't list Wrike's workflows."
    [[ -n $space ]] || plan+=("Create the space \"$WRIKE_SPACE_TITLE\"")
    [[ -n $workflow ]] || plan+=("Create the workflow \"$WRIKE_WORKFLOW_NAME\"")
    for status in "${WRIKE_STATUSES[@]}"; do
        read -r name group color <<< "$status"
        if [[ -z $workflow ]] || ! jq -e --arg name "$name" 'any(.customStatuses[]?; .name == $name)' <<< "$workflow" > /dev/null; then
            plan+=("Add the status $name, in the group $group, to the workflow")
            missing+=("$status")
        fi
    done

    # A bot that isn't an account admin can't make a workflow or change its
    # statuses, and many accounts keep it from making spaces. As the space's
    # admin it can make the rest, so a person makes the space and its own
    # workflow first.
    if [[ $admin != true ]]; then
        if [[ -z $space ]] || ! wrike_space_admin "$space" "$bot"; then
            steps+=("Create the space \"$WRIKE_SPACE_TITLE\", unless it exists, and add $bot_name to it as a space admin.")
        fi
        if [[ -z $workflow ]]; then
            steps+=("In the space's settings, under Workflows, create the workflow \"$WRIKE_WORKFLOW_NAME\" with these statuses, named exactly so, with their groups: $(wrike_status_text "${WRIKE_STATUSES[@]}").")
        elif (( ${#missing[@]} > 0 )); then
            steps+=("In the space's settings, under Workflows, give the workflow \"$WRIKE_WORKFLOW_NAME\" these statuses, named exactly so, with their groups: $(wrike_status_text "${missing[@]}").")
        fi
        if (( ${#steps[@]} > 0 )); then
            echo "$bot_name is${kind:+ $kind,} not an account admin, so it can't make a workflow or change one, or"
            echo "in many accounts a space. With your own Wrike account, do this:"
            for i in "${!steps[@]}"; do
                printf '  %d. %s\n' $((i + 1)) "${steps[i]}"
            done
            fail "Wrike needs those first. Then run $(gnoto_command config wrike) again, which makes the rest as $bot_name."
        fi
    fi
    if [[ -n $space ]]; then
        folder=$(wrike_find_folder "$space") || fail "Can't list the space's folders."
        existing=$(wrike_space_fields "$space") || fail "Can't list the space's custom fields."
    else
        folder="" existing="[]"
    fi
    [[ -n $folder ]] || plan+=("Create the folder \"$WRIKE_FOLDER_TITLE\" in the space")
    questions=$(wrike_questions_spec) && spec=$(wrike_fields_spec) ||
        fail "The pipelines' options.yaml can't be made into the request form's questions, as above."
    while IFS= read -r field; do
        have=$(jq -c --arg title "$(jq -r .title <<< "$field")" 'first(.[] | select(.title == $title)) // empty' <<< "$existing")
        if [[ -z $have ]]; then
            plan+=("Create the custom field \"$(jq -r .title <<< "$field")\", $(jq -r '.type + (if .values != [] then " of " + (.values | join(", ")) else "" end)' <<< "$field")")
        elif [[ $(jq -r .type <<< "$have") != "$(jq -r .type <<< "$field")" ]]; then
            fail "The space has a field \"$(jq -r .title <<< "$field")\" of type $(jq -r .type <<< "$have"), and gnoto needs one of type $(jq -r .type <<< "$field"). Rename or remove it in Wrike."
        elif [[ $(jq -c '.values | sort' <<< "$have") != "$(jq -c '.values | sort' <<< "$field")" ]]; then
            plan+=("Change the answers of the field \"$(jq -r .title <<< "$field")\" to $(jq -r '.values | join(", ")' <<< "$field")")
        fi
    done < <(jq -c '.[]' <<< "$spec")
    if sqs_on && [[ -n ${AWS_SQS_WEBHOOK_URL:-} ]]; then
        if [[ -n $folder ]]; then
            webhooks=$(wrike_find_webhooks "$folder" "$AWS_SQS_WEBHOOK_URL") || fail "Can't list Wrike's webhooks."
        else
            webhooks=""
        fi
        if [[ -z $webhooks ]]; then
            plan+=("Create the webhook on \"$WRIKE_FOLDER_TITLE\" to $AWS_SQS_WEBHOOK_URL, for $WRIKE_WEBHOOK_EVENTS")
        elif [[ $(jq -sc 'map(.events | sort | join(",")) | unique' <<< "$webhooks") != "$(jq -cn --arg e "$WRIKE_WEBHOOK_EVENTS" '[$e | split(",") | sort | join(",")]')" ||
            $(grep -c . <<< "$webhooks") -gt 1 ]]; then
            plan+=("Replace the webhook on \"$WRIKE_FOLDER_TITLE\", deleting the old one first, for $WRIKE_WEBHOOK_EVENTS")
        fi
    fi

    if (( ${#plan[@]} > 0 )); then
        config_confirm "in Wrike, as $bot_name" "${plan[@]}" || exit 0
    fi

    # The workflow and its statuses
    if [[ -z $workflow ]]; then
        workflow=$(wrike_call POST "workflows" --data-urlencode "name=$WRIKE_WORKFLOW_NAME" | jq -c '.data[0]') ||
            fail "Wrike didn't create the workflow. If the bot isn't an admin, have an admin create a workflow named \"$WRIKE_WORKFLOW_NAME\", and run this again."
    fi
    generated_set wrike.workflow_id "$(jq -r .id <<< "$workflow")"
    for status in "${WRIKE_STATUSES[@]}"; do
        read -r name group color <<< "$status"
        id=$(jq -r --arg name "$name" 'first(.customStatuses[]? | select(.name == $name) | .id) // empty' <<< "$workflow")
        if [[ -z $id ]]; then
            workflow=$(wrike_call PUT "workflows/$WRIKE_WORKFLOW_ID" --data-urlencode \
                "customStatus=$(jq -cn --arg name "$name" --arg group "$group" --arg color "$color" \
                '{name: $name, group: $group, color: $color, hidden: false}')" | jq -c '.data[0]') ||
                fail "Wrike didn't add the status $name to the workflow."
            id=$(jq -r --arg name "$name" 'first(.customStatuses[]? | select(.name == $name) | .id) // empty' <<< "$workflow")
            [[ -n $id ]] || fail "Wrike didn't add the status $name to the workflow."
        fi
        generated_set "wrike.statuses.${name,,}" "$id"
    done

    # The space, whose tasks take the workflow, and the folder
    if [[ -z $space ]]; then
        space=$(wrike_call POST "spaces" --data-urlencode "title=$WRIKE_SPACE_TITLE" --data-urlencode "accessType=Public" \
            --data-urlencode "defaultTaskWorkflowId=$WRIKE_WORKFLOW_ID" | jq -r '.data[0].id // empty') ||
            fail "Wrike didn't create the space."
        [[ -n $space ]] || fail "Wrike didn't create the space."
    elif [[ $(wrike_call GET "spaces/$space" | jq -r '.data[0].defaultTaskWorkflowId // ""') != "$WRIKE_WORKFLOW_ID" ]]; then
        wrike_call PUT "spaces/$space" --data-urlencode "defaultTaskWorkflowId=$WRIKE_WORKFLOW_ID" > /dev/null ||
            warn "The space's tasks don't take the gnoto workflow by default. The form must still set the status Submitted."
    fi
    generated_set wrike.space_id "$space"
    if [[ -z $folder ]]; then
        folder=$(wrike_call POST "folders/$space/folders" --data-urlencode "title=$WRIKE_FOLDER_TITLE" |
            jq -r '.data[0].id // empty') || fail "Wrike didn't create the folder."
        [[ -n $folder ]] || fail "Wrike didn't create the folder."
    fi
    generated_set wrike.folder_id "$folder"

    # The fields
    existing=$(wrike_space_fields "$space") || fail "Can't list the space's custom fields."
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
    done < <(jq -c '.[]' <<< "$spec")
    # Fields gnoto once made for questions whose answers now go to the description
    while IFS= read -r field; do
        [[ -z $field ]] || generated_set "wrike.fields.$field" ""
    done < <({ yq -o=json '.wrike.fields // {}' "$DATA_DIR/generated.yaml" 2> /dev/null || echo "{}"; } |
        jq -r --argjson spec "$spec" 'keys[] | select(. as $key | all($spec[]; .key != $key))')
    leftover=$(wrike_leftover_fields "$existing" "$questions" "$spec")
    if [[ -n $leftover ]]; then
        echo "The space has custom fields for questions whose answers go to the task's description now:"
        sed 's/^/  /' <<< "$leftover"
        echo "A question the form maps to one of them is read as unanswered. Wrike's API can't delete a"
        echo "field, so delete them by hand in Wrike, which also takes them off the form."
    fi

    # The webhook
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

    # The form, made by hand
    forms=$(wrike_call GET "spaces/$space/request_forms") || fail "Can't list the space's request forms."
    form=$(jq -r --arg title "$WRIKE_FORM_TITLE" 'first(.data[]? | select(.title == $title) | .id) // empty' <<< "$forms")
    if [[ -z $form ]]; then
        wrike_form_checklist "$questions"
        return 0
    fi
    generated_set wrike.form_id "$form"
    drift=$(wrike_form_drift "$(wrike_call GET "request_forms/$form")" "$questions") || drift=""
    if [[ -n $drift ]]; then
        echo "The form \"$WRIKE_FORM_TITLE\" differs from gnoto's questions:"
        sed 's/^/  /' <<< "$drift"
        wrike_form_checklist "$questions"
        return 0
    fi
    echo "Wrike is ready: the form \"$WRIKE_FORM_TITLE\" matches gnoto's questions."
}

# lint's Wrike checks
lint_wrike() {
    local me bot name role admin kind questions spec leftover drift json status field missing=()
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
        kind=$(wrike_user_type "$bot")
        [[ -n $kind || $admin != true ]] || kind="account admin"
        lint_ok "wrike: the bot account is $name${kind:+, $([[ $kind == [AEIOUaeiou]* ]] && echo an || echo a) $kind}"
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
    questions=$(wrike_questions_spec 2> /dev/null) || questions="[]"
    spec=$(wrike_fields_spec 2> /dev/null) || spec="[]"
    while IFS= read -r field; do
        [[ -z $field || -n $(wrike_field_id "$field") ]] || missing+=("field $field")
    done < <(jq -r '.[].key' <<< "$spec")
    if (( ${#missing[@]} > 0 )); then
        lint_fail "wrike: generated.yaml lacks the $(lint_list "${missing[@]}"). Run: $(gnoto_command config wrike)"
    fi
    if [[ -n ${WRIKE_SPACE_ID:-} ]] && json=$(wrike_space_fields "$WRIKE_SPACE_ID" 2> /dev/null); then
        leftover=$(wrike_leftover_fields "$json" "$questions" "$spec")
        [[ -z $leftover ]] ||
            lint_warn "wrike: the space has custom fields for questions whose answers go to the description now, and a question the form maps to one is read as unanswered. Delete them in Wrike: $(paste -sd ';' <<< "$leftover" | sed 's/;/, /g')"
    fi
    if [[ -z ${WRIKE_FORM_ID:-} ]]; then
        lint_warn "wrike: no request form \"$WRIKE_FORM_TITLE\" found yet. $(gnoto_command config wrike) prints its checklist"
    elif json=$(wrike_call GET "request_forms/$WRIKE_FORM_ID" 2> /dev/null); then
        drift=$(wrike_form_drift "$json" "$questions")
        if [[ -n $drift ]]; then
            lint_warn "wrike: the request form differs from options.yaml: $(paste -sd ';' <<< "$drift" | sed 's/;/; /g')"
        else
            lint_ok "wrike: the request form matches options.yaml"
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
