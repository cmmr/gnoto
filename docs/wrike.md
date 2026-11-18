# Setting up Wrike

With Wrike, every gnoto job has a task. gnoto moves the task through its statuses as the
job runs, links its results there, and keeps on it the date the results are removed,
which people can change. A Wrike request form can start jobs too, so someone who never
logs in to the cluster can ask for one.

gnoto works in Wrike through a bot account, and Wrike's API can't make request forms. It
makes workflows, and in many accounts spaces, only for an account admin, which a bot
shouldn't be. So a person sets Wrike up first, with their own account, as this page says,
and `gnoto config wrike` takes it up from there.

## What gnoto needs

| What | Why |
| --- | --- |
| A bot account | A Wrike user for gnoto, with a full license, since a Collaborator can't create tasks, and its API token. It needn't be an account admin. |
| A space, with the bot as its admin | gnoto makes its custom fields there: Pipeline, Results and Expiration. A space of gnoto's own is best. A space's custom fields show on every task in it, and its workflow and form then sit apart from other teams'. |
| A folder in the space | Every job's task goes there, and the request form saves to it. |
| A workflow with gnoto's statuses | gnoto moves each task through them. The space's own workflow keeps it out of the account's list. |
| A request form | For people to ask for jobs. Without one, gnoto still makes a task for each job started on the cluster. |
| A test request | Made with the form, it shows gnoto which form and workflow to use, and what it reads from a request. |

## The workflow's statuses

gnoto needs these six, named exactly so, in these groups. The colors are yours, and the
workflow can have other statuses as well.

| Status | Group | Set when |
| --- | --- | --- |
| Submitted | Active | the request form makes a request |
| Running | Active | a job starts |
| Completed | Completed | a job ends with its results |
| Failed | Cancelled | a job fails, or a request can't run |
| Cancelled | Cancelled | a job is cancelled |
| Expired | Completed | a job's results are removed |

```text
Submitted
```

```text
Running
```

```text
Completed
```

```text
Failed
```

```text
Cancelled
```

```text
Expired
```

## Setting it up

1. Create a space for gnoto, and add the bot to it as a space admin.
2. In the space's settings, under Workflows, create a workflow with the six statuses.
3. Create a folder in the space for gnoto's tasks.
4. In the space's settings, under Request forms, build a request form, as
   [How gnoto reads a request](#how-gnoto-reads-a-request) says, or start from
   [the example](#an-example-form). Its response settings:
    - Create task
    - Set status to: Submitted
    - Save to: the folder
5. Submit a test request with the form. Attach any small tab-separated file as its
   samplesheet: gnoto reads the request, and never runs it.
6. On the cluster, run `gnoto config wrike`. It asks for the bot's API token, then the
   folder, by its name or its Wrike link, suggesting the newest the bot can see. From the
   folder it finds the space, and from the test request, the workflow and the form. It
   makes its custom fields, tests that the bot can create and change tasks in the folder,
   shows what it read from the test request, and moves that to Cancelled, so it never
   runs.

```bash
./gnoto config wrike
```

## How gnoto reads a request

A request's answers arrive in its task's description, each under its question's title.

- **gnoto reads a question by the `gnoto start` option it answers,** named in square
  brackets anywhere in its title, such as `[--hostremoval_reference]`. gnoto reads only
  the brackets, so word each question and its description however suits the people
  asking.
- **Leave each question's "Add answer to" at Description,** Wrike's default. Title is the
  exception: add its answer to the task's Title.
- **A question's options are gnoto's answers, exactly,** but for `[pipeline]`'s, which
  each start with the pipeline's name and may say more after it.
- **A question without brackets is for the people asking.** gnoto leaves it alone, as it
  does the example's Settings, which shows the less common options only to those who
  want them.
- **An option the form doesn't ask takes gnoto's default,** so a form can start with only
  what matters to its users, and grow.
- **Follow-up questions,** under one of `[pipeline]`'s options, ask a pipeline's questions
  only when it's chosen. A question that several pipelines ask can be a follow-up under
  each.

`gnoto config wrike` and `gnoto lint` check the form for a key `gnoto start` doesn't take,
a question type that doesn't fit, or an answer gnoto doesn't know.

### What gnoto reads

| In brackets | For | Question type | Answers | Unanswered |
| --- | --- | --- | --- | --- |
| `[pipeline]` | every request | Single answer | ampliseq, biobakery, taxprofiler or repeat, at the start of each option | turned down |
| `[--previous_run]` | repeat | Single line text | the earlier run's ID, or its results address | turned down |
| `[--title]` | every request | Single line text | read from the task's title | |
| `[--samplesheet]` | every request | Attachment | read from the task's one attachment | turned down |
| `[--retention]` | every request | Single answer | 1 Month, 3 Months, 6 Months, 12 Months, 24 Months, Unlimited | 3 Months, or a repeat's earlier run's |
| `[--hostremoval_reference]` | biobakery, taxprofiler | Single answer | None, PhiX, Human + PhiX, Mouse + PhiX | PhiX |
| `[--delivered_reads]` | biobakery | Multiple answers | Raw, Host Depleted, Cleaned | none |
| `[--ampliseq.dada_ref_taxonomy]` | ampliseq | Single answer | silva=138.2 | silva=138.2 |
| `[--ampliseq.exclude_taxa]` | ampliseq | Multiple answers | mitochondria, chloroplast, Francisella | all three |
| `[--ampliseq.mergepairs_strategy]` | ampliseq | Single answer | merge, concatenate, consensus | merge |
| `[--ampliseq.picrust]` | ampliseq | Single answer | No, Yes | No |
| `[--taxprofiler.instrument_platform]` | taxprofiler | Single answer | ILLUMINA, OXFORD_NANOPORE, PACBIO_SMRT | measured from read length |

## An example form

A form that asks what most people need, with the less common options behind a Settings
question. Copy each piece into the matching box of Wrike's form builder.

### Response settings

- Create task
- Set status to: Submitted
- Save to: gnoto's folder

### Form name

```text
gnoto Request
```

### 1. Pipeline

Single answer, Answer required.

```text
Pipeline [pipeline]
```

```text
Which analysis to run. Each makes a dashboard of results to view and download.
```

Options:

```text
ampliseq: 16S rRNA amplicons, full length or a variable region
```

```text
biobakery: shotgun metagenomes, taxa with MetaPhlAn and functions with HUMAnN
```

```text
taxprofiler: shotgun metagenomes, taxa with several profilers
```

```text
repeat: new samples, with an earlier run's settings and software
```

#### Under ampliseq

**Settings**: Single answer, Answer required, Default preselected.

```text
Settings
```

```text
Default runs ampliseq with gnoto's defaults. Custom shows its other options.
```

```text
Default
```

```text
Custom
```

**Under Settings' Custom**, four follow-up questions, none required:

Taxonomy reference: Single answer.

```text
Taxonomy reference [--ampliseq.dada_ref_taxonomy]
```

```text
The database each sequence variant's taxonomy comes from. It names the taxa in every table.
```

```text
silva=138.2
```

Taxa to exclude: Multiple answers.

```text
Taxa to exclude [--ampliseq.exclude_taxa]
```

```text
Removed from every table and diversity measure. With none checked, all three are removed. CMMR uses Francisella DNA as a positive control.
```

```text
mitochondria
```

```text
chloroplast
```

```text
Francisella
```

Read pair joining: Single answer.

```text
Read pair joining [--ampliseq.mergepairs_strategy]
```

```text
How each read pair becomes one sequence. merge, the default, needs pairs that overlap, which V3-V5 pairs barely do.
```

```text
merge
```

```text
concatenate
```

```text
consensus
```

PICRUSt2 functions: Single answer, No preselected.

```text
PICRUSt2 functions [--ampliseq.picrust]
```

```text
Predicts the community's functions, its KEGG orthologs and pathways, from its taxa. Makes the run longer.
```

```text
No
```

```text
Yes
```

#### Under biobakery

**Settings**, as under ampliseq, with this description:

```text
Default runs biobakery with gnoto's defaults. Custom shows its other options.
```

**Under Settings' Custom**:

Reads to deliver: Multiple answers.

```text
Reads to deliver [--delivered_reads]
```

```text
Read sets to include in the download beside the results. None by default, as reads are large.
```

```text
Raw
```

```text
Host Depleted
```

```text
Cleaned
```

**Host removal**: Single answer, Answer required, PhiX preselected.

```text
Host removal [--hostremoval_reference]
```

```text
Reads that match the host are removed before profiling, and never published. Choose Human + PhiX for human samples. Every choice but None also removes PhiX, the sequencing control.
```

```text
None
```

```text
PhiX
```

```text
Human + PhiX
```

```text
Mouse + PhiX
```

#### Under taxprofiler

**Settings**, as under ampliseq, with this description:

```text
Default runs taxprofiler with gnoto's defaults. Custom shows its other options.
```

**Under Settings' Custom**:

Instrument platform: Single answer.

```text
Instrument platform [--taxprofiler.instrument_platform]
```

```text
The sequencer that made the reads. Measured from read length when left empty.
```

```text
ILLUMINA
```

```text
OXFORD_NANOPORE
```

```text
PACBIO_SMRT
```

**Host removal**, as under biobakery.

#### Under repeat

**Previous run**: Single line text, Answer required.

```text
Previous run [--previous_run]
```

```text
The earlier run to repeat, by its ID, eight letters and digits, or its results address. Its settings and software are used again on these samples.
```

### 2. Title

Single line text, Answer required, Add answer to: Title.

```text
Title [--title]
```

```text
Names the results. Collaborators see it as the dashboard's title.
```

### 3. Dashboard retention

Single answer, Answer required, 3 Months preselected.

```text
Dashboard retention [--retention]
```

```text
How long the results stay online. Then the dashboard and its downloads are removed. The task's Expiration date can change it later.
```

```text
1 Month
```

```text
3 Months
```

```text
6 Months
```

```text
12 Months
```

```text
24 Months
```

```text
Unlimited
```

### 4. Samplesheet

Attachment, Answer required.

```text
Samplesheet [--samplesheet]
```

```text
Tab-separated, with no header: each sample's name, its forward FASTQ's path, then its reverse FASTQ's. Leave out the reverse for single-end reads.
```
