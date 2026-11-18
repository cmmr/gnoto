#
# form.jq - The example request form from docs/wrike.md, as the Wrike stub
# holds one: each question that gnoto reads names its gnoto start option in
# brackets, and its answer goes to the task's description, but Title's, which
# is the task's title. The form's follow-up questions are listed with the
# rest, once each, and Settings, which names no option, is there as the guide
# has it.
#
# Used by:  test/lib/integrations-test.sh and
#           test/testbed/checks/integrations.sh, for the stub's /_test/form
# Args:     $space, $folder and $status, Submitted's ID, where the form saves
#
#   jq -n -c --arg space ... --arg folder ... --arg status ... -f test/wrike/form.jq

def single($title; $options; $default): {title: $title, type: "ComboBox", mandatory: ($default != null),
    items: [$options[] | {title: ., selectedByDefault: (. == $default)}]};
def multiple($title; $options): {title: $title, type: "CheckBox", mandatory: false,
    items: [$options[] | {title: ., selectedByDefault: false}]};
def text($title): {title: $title, type: "TextField", mandatory: true};

{title: "gnoto Request", spaceId: $space, _folderId: $folder, _status: $status,
 pages: [{title: "", fields: [
    single("Pipeline [pipeline]"; [
        "ampliseq: 16S rRNA amplicons, full length or a variable region",
        "biobakery: shotgun metagenomes, taxa with MetaPhlAn and functions with HUMAnN",
        "taxprofiler: shotgun metagenomes, taxa with several profilers",
        "repeat: new samples, with an earlier run's settings and software"]; null) + {mandatory: true},
    single("Settings"; ["Default", "Custom"]; "Default"),
    single("Taxonomy reference [--ampliseq.dada_ref_taxonomy]"; ["silva=138.2"]; null),
    multiple("Taxa to exclude [--ampliseq.exclude_taxa]"; ["mitochondria", "chloroplast", "Francisella"]),
    single("Read pair joining [--ampliseq.mergepairs_strategy]"; ["merge", "concatenate", "consensus"]; null),
    single("PICRUSt2 functions [--ampliseq.picrust]"; ["No", "Yes"]; null),
    multiple("Reads to deliver [--delivered_reads]"; ["Raw", "Host Depleted", "Cleaned"]),
    single("Host removal [--hostremoval_reference]"; ["None", "PhiX", "Human + PhiX", "Mouse + PhiX"]; "PhiX"),
    single("Instrument platform [--taxprofiler.instrument_platform]"; ["ILLUMINA", "OXFORD_NANOPORE", "PACBIO_SMRT"]; null),
    text("Previous run [--previous_run]"),
    text("Title [--title]") + {_map: "title"},
    single("Dashboard retention [--retention]"; ["1 Month", "3 Months", "6 Months", "12 Months", "24 Months", "Unlimited"]; "3 Months"),
    {title: "Samplesheet [--samplesheet]", type: "Attachment", mandatory: true}]}]}
