#
# config.sh - gnoto config wrike: sets up gnoto's part of Wrike, and lint's
# checks of it.
#
# Sourced by:  lib/config.sh and lib/lint.sh
# Defines:     config_wrike_step, wrike_fields_spec, wrike_webhook_secret,
#              lint_wrike, WRIKE_WEBHOOK_EVENTS
# Requires:    wrike_call from service/wrike/api.sh; generated_set,
#              config_confirm and run_id_salt from lib/config.sh; options_json
#              and pipeline_names from lib/jobfile.sh; lint_ok, lint_warn and
#              lint_fail from lib/lint.sh
#
# Each object is found by its name and adopted when it exists, or else is
# created after the plan is shown and accepted, and its ID goes to
# generated.yaml. So the step is safe to repeat, and --dry-run stops after the
# plan:
#
#   space      "gnoto", whose tasks take the gnoto workflow by default
#   workflow   "gnoto", with the statuses Submitted, Running, Completed,
#              Failed, Cancelled and Expired
#   folder     "gnoto Jobs", in the space, where requests arrive
#   fields     in the space: Pipeline, Previous Run, Results, Expiration, and
#              one for each question in the pipelines' options.yaml but Title
#              and Samplesheet, which are the task's title and attachment. A
#              question several pipelines ask is one field. A dropdown's
#              answers are kept to options.yaml's, with no others allowed.
#   webhook    on "gnoto Jobs", to aws.webhook_url, when SQS is set up, for
#              WRIKE_WEBHOOK_EVENTS. Webhooks can't be edited, so one with other
#              events is deleted before its replacement is made, so no event
#              arrives twice.
#
# Wrike's API can't make a request form, so this prints a checklist for one,
# then looks for it by name, records it, and compares its questions with the
# fields. lint repeats the comparison.

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

# Every field gnoto reads or writes, as a JSON array of {key, title, type,
# values, help, pipelines}. Fails when two pipelines ask one question with
# different titles or answers.
wrike_fields_spec() {
    local pipeline all="[]" options
    for pipeline in $(pipeline_names); do
        options=$(options_json "$pipeline")
        all=$(jq -c --arg pipeline "$pipeline" --argjson options "$options" '. + [$options[]
            | select(.key != "title" and .key != "samplesheet")
            | ((.labels // {}) | with_entries(.key |= tostring)) as $labels
            | {key, title: .question, type: (if .multiple then "Multiple" else "DropDown" end),
               values: [(.values // [])[] | tostring | ($labels[.] // .)], help: (.help // ""),
               pipelines: [$pipeline]}]' <<< "$all")
    done
    jq -c --argjson pipelines "$(pipeline_names | jq -R . | jq -sc .)" --arg repeat "$WRIKE_REPEAT_ANSWER" '
        group_by(.key) | map(
            if (map(.title) | unique | length) > 1 or (map(.values) | unique | length) > 1 or (map(.type) | unique | length) > 1
            then error("The option \(.[0].key) is asked differently by \(map(.pipelines[0]) | join(" and ")): one question must have one title and one set of answers")
            else .[0] + {pipelines: map(.pipelines[0])} end)
        | [{key: "pipeline", title: "Pipeline", type: "DropDown", values: ($pipelines + [$repeat]),
            help: "Which analysis to run, or to repeat an earlier run on new samples", pipelines: $pipelines},
           {key: "previous_run", title: "Previous Run", type: "Text", values: [],
            help: "The earlier run to repeat: its eight-character ID, or its results address", pipelines: []},
           {key: "results", title: "Results", type: "Text", values: [], help: "", pipelines: [], gnoto: true},
           {key: "expiration", title: "Expiration", type: "Date", values: [], help: "", pipelines: [], gnoto: true}]
          + .' <<< "$all"
}

# The secret Wrike signs the webhook's deliveries with, which the SQS stack's
# Lambda checks: wrike.webhook_secret, or else a random one, made in
# generated.yaml the first time config sqs --deploy or config wrike needs it
wrike_webhook_secret() {
    [[ -z ${WRIKE_WEBHOOK_SECRET:-} ]] || return 0
    generated_set --keep wrike.webhook_secret "$(openssl rand -hex 32)"
}

# The bot account: its ID, name and role, as "id<tab>name<tab>role"
wrike_me() {
    wrike_call GET "contacts" -G --data-urlencode "me=true" |
        jq -r '.data[0] | [.id, "\(.firstName // "") \(.lastName // "")", ((.profiles // [])[0].role // "")] | @tsv'
}

# The space's ID, by title, or nothing
wrike_find_space() {
    wrike_call GET "spaces" | jq -r --arg title "$WRIKE_SPACE_TITLE" 'first(.data[]? | select(.title == $title) | .id) // empty'
}

# The workflow, by name, as compact JSON, or nothing
wrike_find_workflow() {
    wrike_call GET "workflows" | jq -c --arg name "$WRIKE_WORKFLOW_NAME" 'first(.data[]? | select(.name == $name)) // empty'
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

# The checklist for building the request form by hand
wrike_form_checklist() {
    local spec=$1
    cat << EOF

Build the request form in Wrike by hand: its API can read forms, and can't make them.
In the "$WRIKE_SPACE_TITLE" space, create a request form named "$WRIKE_FORM_TITLE" that creates a task in
"$WRIKE_FOLDER_TITLE" with the status Submitted. Map each question to the custom field of
the same name, and offer exactly the answers listed:

  1. Title: the task's title, required. "Names the results."
  2. Samplesheet: an attachment, required. "Tab-separated, no header: sample, fastq1,
     fastq2. Omit fastq2 for single-end."
EOF
    jq -r '[.[] | select(.gnoto | not)] | to_entries[] | .key as $i | .value
        | "  \($i + 3). \(.title): " + (if .type == "Text" then "text" elif .type == "Multiple" then "checkboxes" else "a dropdown" end)
          + (if .values != [] then ", answers: " + (.values | join(", ")) else "" end)
          + (if .key == "pipeline" then ". Required"
             elif .key == "previous_run" then ". Shown when Pipeline is Repeat an earlier run"
             elif (.pipelines | length) > 0 then ". Shown when Pipeline is " + (.pipelines | join(" or "))
             else "" end)
          + (if .help != "" then ". \"\(.help)\"" else "" end)' <<< "$spec"
    echo
    echo "Then run $(gnoto_command config wrike) again, which finds the form and checks its questions."
}

# What differs between the form and the fields: a line each
wrike_form_drift() {
    local form=$1 spec=$2
    jq -r --argjson spec "$spec" '
        [.data[0].pages[]?.fields[]? | {title, items: [.items[]?.title]}] as $questions
        | $spec[] | select(.gnoto | not) | . as $field
        | ([$questions[] | select(.title == $field.title)] | .[0]) as $q
        | if $q == null then "the form has no question \"\($field.title)\""
          elif $field.values != [] and ($q.items | sort) != ($field.values | sort) then
              "the form offers \"\($field.title)\" the answers \($q.items | join(", ")), not \($field.values | join(", "))"
          else empty end' <<< "$form"
}

# gnoto config wrike, once its settings are written
config_wrike_step() {
    local me bot name role space workflow folder fields spec plan=() status group color have id field
    local existing missing_fields=() update_fields=() webhooks hook form forms drift
    [[ ${WRIKE_ENABLED:-false} == true ]] || return 0
    [[ -n ${WRIKE_API_TOKEN:-} ]] || fail "Set wrike.api_token first, the bot account's API token."
    run_id_salt
    me=$(wrike_me) || fail "Wrike refused the token, as above."
    IFS=$'\t' read -r bot name role <<< "$me"
    [[ $role != Collaborator ]] || fail "The bot account, $name, is a Collaborator, and those can't create tasks. Give it a full license."
    generated_set wrike.bot_id "$bot"
    echo "Wrike's bot account is $name." >&2

    space=$(wrike_find_space) || fail "Can't list Wrike's spaces."
    workflow=$(wrike_find_workflow) || fail "Can't list Wrike's workflows."
    [[ -n $space ]] || plan+=("Create the space \"$WRIKE_SPACE_TITLE\"")
    [[ -n $workflow ]] || plan+=("Create the workflow \"$WRIKE_WORKFLOW_NAME\"")
    for status in "${WRIKE_STATUSES[@]}"; do
        read -r name group color <<< "$status"
        [[ -n $workflow ]] && jq -e --arg name "$name" 'any(.customStatuses[]?; .name == $name)' <<< "$workflow" > /dev/null ||
            plan+=("Add the status $name, in the group $group, to the workflow")
    done
    if [[ -n $space ]]; then
        folder=$(wrike_find_folder "$space") || fail "Can't list the space's folders."
        existing=$(wrike_space_fields "$space") || fail "Can't list the space's custom fields."
    else
        folder="" existing="[]"
    fi
    [[ -n $folder ]] || plan+=("Create the folder \"$WRIKE_FOLDER_TITLE\" in the space")
    spec=$(wrike_fields_spec) || fail "The pipelines' options.yaml can't be made into Wrike's fields, as above."
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
    if sqs_on && [[ -n ${AWS_WEBHOOK_URL:-} ]]; then
        if [[ -n $folder ]]; then
            webhooks=$(wrike_find_webhooks "$folder" "$AWS_WEBHOOK_URL") || fail "Can't list Wrike's webhooks."
        else
            webhooks=""
        fi
        if [[ -z $webhooks ]]; then
            plan+=("Create the webhook on \"$WRIKE_FOLDER_TITLE\" to $AWS_WEBHOOK_URL, for $WRIKE_WEBHOOK_EVENTS")
        elif [[ $(jq -sc 'map(.events | sort | join(",")) | unique' <<< "$webhooks") != "$(jq -cn --arg e "$WRIKE_WEBHOOK_EVENTS" '[$e | split(",") | sort | join(",")]')" ||
            $(grep -c . <<< "$webhooks") -gt 1 ]]; then
            plan+=("Replace the webhook on \"$WRIKE_FOLDER_TITLE\", deleting the old one first, for $WRIKE_WEBHOOK_EVENTS")
        fi
    fi

    if (( ${#plan[@]} > 0 )); then
        config_confirm "in Wrike, as $name" "${plan[@]}" || exit 0
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

    # The webhook
    if sqs_on && [[ -n ${AWS_WEBHOOK_URL:-} ]]; then
        webhooks=$(wrike_find_webhooks "$folder" "$AWS_WEBHOOK_URL") || fail "Can't list Wrike's webhooks."
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
            hook=$(wrike_call POST "folders/$folder/webhooks" --data-urlencode "hookUrl=$AWS_WEBHOOK_URL" \
                --data-urlencode "secret=$WRIKE_WEBHOOK_SECRET" --data-urlencode "events=[$WRIKE_WEBHOOK_EVENTS]" |
                jq -r '.data[0].id // empty') ||
                fail "Wrike didn't create the webhook. Its handshake with $AWS_WEBHOOK_URL may have failed: the SQS stack's Lambda checks it with wrike.webhook_secret as the stack was deployed, so if that changed since, deploy it again: $(gnoto_command config sqs --deploy)"
        fi
        generated_set wrike.webhook_id "$hook"
    fi

    # The form, made by hand
    forms=$(wrike_call GET "spaces/$space/request_forms") || fail "Can't list the space's request forms."
    form=$(jq -r --arg title "$WRIKE_FORM_TITLE" 'first(.data[]? | select(.title == $title) | .id) // empty' <<< "$forms")
    if [[ -z $form ]]; then
        wrike_form_checklist "$spec"
        return 0
    fi
    generated_set wrike.form_id "$form"
    drift=$(wrike_form_drift "$(wrike_call GET "request_forms/$form")" "$spec") || drift=""
    if [[ -n $drift ]]; then
        echo "The form \"$WRIKE_FORM_TITLE\" differs from gnoto's questions:"
        sed 's/^/  /' <<< "$drift"
        wrike_form_checklist "$spec"
        return 0
    fi
    echo "Wrike is ready: the form \"$WRIKE_FORM_TITLE\" matches gnoto's questions."
}

# lint's Wrike checks
lint_wrike() {
    local me bot name role spec drift json status field missing=()
    [[ ${WRIKE_ENABLED:-false} == true ]] || return 0
    if [[ -z ${WRIKE_API_TOKEN:-} ]]; then
        lint_fail "wrike: is on, and wrike.api_token isn't set. $(gnoto_command config wrike) asks for it"
        return 0
    fi
    if ! me=$(wrike_me 2> /dev/null) || [[ -z $me ]]; then
        lint_fail "wrike: the token doesn't work, or Wrike can't be reached at ${WRIKE_API_URL:-}"
        return 0
    fi
    IFS=$'\t' read -r bot name role <<< "$me"
    if [[ $role == Collaborator ]]; then
        lint_fail "wrike: the bot account, $name, is a Collaborator, and those can't create tasks"
    else
        lint_ok "wrike: the bot account is $name"
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
    spec=$(wrike_fields_spec 2> /dev/null) || spec="[]"
    while IFS= read -r field; do
        [[ -z $field || -n $(wrike_field_id "$field") ]] || missing+=("field $field")
    done < <(jq -r '.[].key' <<< "$spec")
    if (( ${#missing[@]} > 0 )); then
        lint_fail "wrike: generated.yaml lacks the $(lint_list "${missing[@]}"). Run: $(gnoto_command config wrike)"
    fi
    if [[ -z ${WRIKE_FORM_ID:-} ]]; then
        lint_warn "wrike: no request form \"$WRIKE_FORM_TITLE\" found yet. $(gnoto_command config wrike) prints its checklist"
    elif json=$(wrike_call GET "request_forms/$WRIKE_FORM_ID" 2> /dev/null); then
        drift=$(wrike_form_drift "$json" "$spec")
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
