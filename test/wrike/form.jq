#
# form.jq - gnoto's request form, as the Wrike stub holds one, built as the
# checklist config wrike prints says: Title to the task's title, Samplesheet
# an attachment, each question that maps to a custom field mapped to it, and
# every other answer left in the description.
#
# Used by:  test/lib/integrations-test.sh and
#           test/testbed/checks/integrations.sh, for the stub's /_test/form
# Input:    the questions, as wrike_questions_spec prints them
# Args:     $space, $folder and $status, Submitted's ID; $fields, a JSON
#           object of each field's key to its ID
#
#   jq -c --arg space ... --arg folder ... --arg status ... \
#       --argjson fields '{"pipeline": "..."}' -f test/wrike/form.jq

{DropDown: "ComboBox", Multiple: "CheckBox", Text: "TextField"} as $types
| {title: "gnoto Request", spaceId: $space, _folderId: $folder, _status: $status,
   pages: [{title: "", fields: (
       [{title: "Title", type: "TextField", mandatory: true, _map: "title"},
        {title: "Samplesheet", type: "Attachment", mandatory: true}]
       + [.[] | .default as $default
          | {title, type: $types[.type], mandatory: .required,
             items: [.values[] | {title: ., selectedByDefault: (. == $default)}]}
            + (if .field then {_map: {customField: $fields[.key]}} else {} end)])}]}
