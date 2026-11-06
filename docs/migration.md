# Migrating from cmmr/nextflow to gnoto

gnoto gets built by copying code out of `cmmr/nextflow` and restructuring it, in eight
phases. Nothing is in production, so there's no cutover, and no old runs or published
results to honor. [design.md](design.md) describes the target.

Status on 2026-11-06: **phase 1 is done.** ampliseq ran the `16s-v4` fixture under Slurm through
the helper, in the local test bed and on the cluster, and every phase 1 check passes on both. The
next step is phase 2. The [phase 1 notes](#phase-1-image-and-helper) record what's built, every
test result, and the two determinism probes still to run.

## Where the old code is

| What | Where |
| --- | --- |
| Local checkout | `D:\Dropbox\Baylor\GitHub\nextflow` |
| Public repo | <https://github.com/cmmr/nextflow> |
| Commit this guide was written against | `649ec0f9d0f1173239f0e3fee687dea08b5ebfd1` |

If the local path isn't readable from your session, clone the public repo somewhere
outside this one, and don't vendor it here.

The old repo is a read-only reference, so don't commit to it.

**Not in git, and only on the cluster or Daniel's machine:** `secrets/.env`, `db/`,
`opt/`, `bin/`, `cache/`, `assets/`, `log/` and `tmp/`. Never copy `secrets/` or its
values anywhere.

## Rules for copying

- **Copy files, not history.** gnoto starts with a clean history.
- **No backward compatibility.** Drop anything that exists only for old runs, such as the
  `pipeline_manifest.json` fallback in `wrike_task_handler.sh`.
- **This repo is public from its first commit.** No secrets, Wrike object IDs, Globus
  UUIDs, site hostnames or personal email addresses.
- **Keep what's expensive to relearn.** The old comments and docs record real failures.
  The comment style in `CLAUDE.md` trims rationale from scripts, but keep any "why" whose
  absence would invite a breaking change, and move the longer stories into `docs/`.

## Build order

Each phase has a test that shows it's finished.

| Phase | Work | Finished when |
| --- | --- | --- |
| 1. Image and helper | The `gnoto` image, launcher, helper and stand-ins | One fixture job, such as `16s-v4` from [fixtures.md](fixtures.md), runs under Slurm through the helper, with no tool taken from the host except Slurm and Apptainer |
| 2. Restructure | New repo layout, `lib/env.sh`, `config.yaml`, `generated.yaml`, `databases.yaml`, `references.yaml`, `pipelines/<name>/` replacing the `_01` files, no hard-coded paths, unexported secrets | No tracked file names `/data/prod/nextflow`, and scripts load their settings from any install path |
| 3. Job core | `lib/job.sh`, `options.yaml`, `new`, `lint job.yaml`, `start`, `start --debug`, `status`, `cancel`, input checksums, `history/`, core `setup` and config `lint`, and the three job stages, with Publish a stub until phase 7 | A CLI job finishes with no Wrike, AWS or Globus configured, and leaves a full dashboard in `results/` |
| 4. Version cache | `pipeline@ref`, `start record.yaml`, `<data_dir>/current`, `gnoto upgrade` and `gnoto prune` | A job re-runs correctly from its own commit after `main` has moved on, and an upgrade while a job runs leaves that job on its own code |
| 5. Lock files | Image digests, GHCR images, `containers.config`, `db:` names, database digests and `lint --deep` | CI on `main` rejects an image address by tag, and a re-run pulls only by digest |
| 6. Determinism | `gnoto selftest`, seeds, `stable-files`, and the numeric comparison of core tables | A re-run reports its core tables as identical |
| 7. Integrations | `gnoto wrike` writing job files from Wrike tasks, CLI jobs creating tasks, the publish stage and `gnoto publish`, the daily timer, `extend`, `remove`, `setup` and `lint` for the integrations, the CloudFormation stacks, and the health file `status` shows | A Wrike request and a CLI job on the same samples give the same core tables, and both appear as tasks |
| 8. Public release | README, tarball CI, Zenodo, docs rewrite | A full rollout works from the published tarball using only the README, starting from a complete teardown |

Phase 1 comes first because the helper is the riskiest part of the design and everything
else runs on it. Wrike comes late because the CLI route doesn't need it, so the core can be
built and tested with no cloud account.

## Phase notes

### Phase 1: image and helper

Treat this as a prototype. If it fails, take the fallback in
[design.md](design.md#host-and-image) and update the docs.

**Before the first script:** add a `.gitignore` covering `config.yaml` and local scratch
directories. `.gitattributes` is already copied from the old repo, so everything is committed
with LF.

**The image (`images/gnoto.nix`).** Start from the old `nix/rbiom.nix`, and read the old
`docs/operations/nix.md` first. The points that matter:

- Pin nixpkgs by revision, on the most recent stable branch (`nixos-26.05` on 2026-11-05), and
  use `dockerTools.buildLayeredImage` with `contents`.
- Set `compressor = "none"`, because Apptainer's `docker-archive` reader rejects gzip with
  a misleading error.
- The tool list is in [design.md](design.md#host-and-image). Pin the most recent stable
  Nextflow, 26.10.5 on 2026-11-05. ampliseq 3.1.0 requires at least 26.04.0, and taxprofiler
  2.0.1 at least 25.10.4.
- Ship Nextflow's self-contained dist jar in the image. The standard launcher otherwise
  downloads its framework into `NXF_HOME`, which sits in `core.data_dir`, outside the image's
  pin. If nixpkgs lacks the exact version, fetch the official dist jar by hash.
- A bare Nix image has nothing it isn't given. Expect to add CA certificates for `curl`,
  `git` and the AWS CLI, `/usr/bin/env`, a `/tmp`, and `LC_ALL=C.UTF-8`. Also set
  `NXF_DISABLE_CHECK_LATEST=true`, so Nextflow doesn't check online for a newer version at
  every launch.

What building it taught, all now in `images/gnoto.nix`:

- nixpkgs is pinned at `nixos-26.05` revision `7dcdd873`. Its newest JDK is 25, which Nextflow
  26.10 supports (17 to 26). It carries Nextflow 25.10.2, so the dist file is fetched by hash.
- The dist file has to be executable. It finds the framework inside itself through
  `command -v "$0"`, and otherwise falls back to `./$0` and downloads the framework into
  `NXF_HOME`. That fallback works by accident when the current directory is `/`, which hid it in
  the first test.
- `/etc/passwd` and `/etc/group` have to be real files. `dockerTools.fakeNss` makes them
  symlinks into the store, which Apptainer can't follow to append the user. Java's `user.name`
  is then `?`, and Nextflow passes that to `squeue -u`.
- The JDK's top-level `bin` is a symlink, so the image's `/bin` doesn't take it in without links
  of its own.
- `globus-cli` 3.41.0 doesn't build in `nixos-26.05`, because it pins `jmespath` 1.0.1 and the
  branch has 1.1.0. The recipe relaxes that one pin.
- The image is 1.47 GB as a tarball and 760 MB as a `.sif`. `nix-build --check` rebuilds it, and
  the locally built `globus-cli`, byte for byte.

**Getting the image to the cluster.** For the prototype, `IMAGE` names a `.sif` file in
`<data_dir>/images/`, so nothing has to be published. `test/testbed/testbed.sh image` builds the
recipe in `nixos/nix` in Docker, converts it with
`apptainer build <sif> docker-archive:<tarball>` in the test bed, and points `IMAGE` at it. The
launcher already accepts `docker://<image>@sha256:<digest>` and pulls it under a lock. Move to
GHCR, by digest, once the image is stable, and no later than phase 5.

**Launcher and helper.** The launcher (`gnoto`) and helper (`host/helper.sh`) are POSIX `sh`,
because they run before any image tools exist. The stand-in is one bash script,
`host/standin.sh`, which runs inside the image. At launch, the launcher links it under each name
in `host/allowed/`, in its private directory, which goes first on `PATH` inside the image. The
repo itself holds no symlinks. The launcher reads its four bootstrap settings from
`config.yaml` with its own awk, as [design.md](design.md#host-and-image) describes. Inside the
image, `lib/main.sh` is the entry point. Its only command so far is `gnoto exec <command>`, a
development aid.

The protocol as built and tested:

1. The launcher makes a private directory at mode 700 on node-local storage (`$TMPDIR`, else
   `/tmp`), because a FIFO only works within one machine. It starts the helper on a `requests`
   FIFO there, then runs `apptainer exec --cleanenv`, binding the install directory, the data and
   database directories, `core.apptainer_binds` and the private directory at their host paths.
   What reaches the image is set through `APPTAINERENV_` variables, after dropping any the caller
   set, because those survive `--cleanenv`.
2. For each call, a stand-in makes a request directory holding `request`, which sets `cwd` and
   the arguments as single-quoted shell words, and `stdout`, `stderr` and `alive` FIFOs. It starts
   a reader on each output FIFO, then writes the directory's name to `requests` as one line.
   Arguments aren't NUL-separated, because POSIX `sh` can't read that safely. If the helper has
   gone, opening `requests` blocks, so the write has a 5-second timeout.
3. The helper double-forks a handler per request, so nothing waits to be reaped by the helper.
   Its parent process, init on a real host, reaps them. The handler writes an `accepted` file,
   then runs the command only if it's on the allowed list, from `cwd`, with standard input from
   `/dev/null`, under `env -i` with `PATH`, `HOME`, `USER`, `LOGNAME` and, when set,
   `SLURM_CONF`, `APPTAINER_CACHEDIR` and `APPTAINER_TMPDIR`. `systemctl` and `loginctl` also
   get `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`, which they need for user units. Jobs
   don't get those, which the first cluster run showed they had been. A job submitted from
   inside another job therefore never inherits its Slurm variables or `TMPDIR`. The launcher puts both Apptainer directories in a per-user
   directory on its node-local base, because a large image such as QIIME 2's is built in
   `APPTAINER_TMPDIR`, and `/tmp` may be too small for it. A refusal runs as a command too, one
   that prints the reason and exits 125 or 126.
4. The command's own process opens the output FIFOs for writing, which waits for the stand-in's
   readers, so nothing is lost and neither side sees an early end-of-file. When the command
   exits, the readers finish and the handler writes the exit code to a `status` file. The
   stand-in waits up to 10 seconds for it, then exits with that status, or with 125 and a
   message if the helper didn't take the request or never wrote one.
5. The stand-in holds `alive` open until it exits. When the handler sees end-of-file on it while
   the command still runs, or is still waiting to open the FIFOs, it sends the command SIGTERM.
   That works when the stand-in is SIGKILLed too, and needs no process IDs across the container
   boundary.
6. The helper ignores SIGTERM, and each handler restores the default before running a command.
   The launcher forwards SIGTERM, SIGINT and SIGHUP to `apptainer` as SIGTERM, waits for it to
   exit, then stops the helper with SIGKILL and removes the directory. Nextflow cancels its tasks
   through the `scancel` stand-in in between.

Three traps found on the way:

- **Opening the FIFOs early.** The first version opened the output FIFOs read-write in the
  handler, so neither side would wait. Under load a quick command could finish, and the handler
  close them, before the stand-in's reader had opened its end. The reader then waited forever, and
  any output was lost. The stub tests caught it as a hang in 2 runs out of 3 under `dash`.
- **Saved descriptors in `dash`.** `dash` keeps a saved copy of a file descriptor that a
  redirection on a function call closes, so the handler closes `requests` with `exec`.
- **Stand-ins shadowing tools.** A stand-in must never find another stand-in under the name of a
  tool it uses, so it drops its own directory from `PATH`.

**Local test bed.** Before any cluster test, build a single-node Slurm with Apptainer in a
privileged Docker container on the development machine. Docker Desktop's WSL2 VM gives a
privileged container FUSE, unprivileged user namespaces and mounts (checked 2026-11-05). The
cluster is then needed only for munge across nodes, real partitions, its own Apptainer setup and
login-node limits.

It's in `test/testbed/`, driven by `testbed.sh` (`up`, `image`, `install`, `down`, `purge`):
Rocky Linux 10.2, Slurm 26.05.5 built from source in a separate stage, and Apptainer 1.5.5 from
its unprivileged el10 RPM. slurmd tracks jobs with cgroup v2 (`IgnoreSystemd=yes`), so a
cancelled job loses orphaned processes too, as on the cluster. The node has 6 CPUs and 24 GB,
with a default of 2 GB per CPU, because a job that asks for no memory otherwise gets the whole
node, and a 5-second scheduling interval, so a pipeline's short tasks don't queue for a minute
each.
`alice` and `bob` share the group `gnoto`, and `/data/gnoto`, on a Docker volume, is the data
directory. The checks in `test/testbed/checks/` run as either user through `runuser -l`, which
sets a login environment. `test/helper/` holds the stub tests, which run in `debian:13-slim`
under both `dash` and `bash`.

**Test these, in this order.** Start in Docker with stub commands, then the local test bed,
then the cluster. Results so far, all from 2026-11-05:

| Test | Result |
| --- | --- |
| Exit codes, arguments with spaces, large output and concurrent calls | Pass, in the stub tests under `dash` and `bash` and in the test bed: awkward quoting, 5000 arguments, 5 MB of binary output, 100 concurrent calls, passing 8 runs in a row. A call takes 20 to 45 ms |
| The helper dying, which must fail the stand-in rather than hang it | Pass: a call in flight still finishes, and the next one fails with 125 after 5 seconds |
| Killing a stand-in, which must stop the host process, because Nextflow relies on this when it's interrupted | Pass, for SIGTERM and SIGKILL |
| `nextflow run nextflow-io/hello` under the Slurm executor with a process container | Pass in the test bed |
| The image pull Nextflow does through the `apptainer` stand-in | Pass for `docker://` and `https://` addresses. nf-core modules under `-profile apptainer` mostly name `https://` image files, which Nextflow downloads itself |
| `apptainer pull docker://…@sha256:…`, because Apptainer's docs don't cover pulls by digest | Pass with Apptainer 1.5.5 |
| Which environment `sbatch` passes to tasks, since the helper's environment reaches them | The helper's fixed set plus Slurm's own variables. The caller's `TMPDIR` and an outer job's Slurm variables don't arrive. Nextflow then starts each container with `env - PATH=…`, passing only `TMP`, `TMPDIR` and `NXF_TASK_WORKDIR`, with `--no-home --pid` |
| Two users running the same step container, each printing `env` and R's `Sys.getlocale()`, which must give the same output | Locale, time zone and R's library paths match. `HOME` and `R_LIBS_USER` name each user's home, which isn't mounted, but Apptainer does mount it when it's the current directory. So `lib/containers.sh` should run steps from the run directory and give containers a fixed `HOME` |
| One real pipeline on its fixtures from [fixtures.md](fixtures.md) | Pass in the test bed: ampliseq 3.1.0 on `16s-v4` ran 31 tasks in 10 minutes and found 22 ASVs, with the mock's genera. Pass on the cluster on 2026-11-06, with the same 22 ASVs, in 51 minutes on a busy queue. `ASV_table.tsv`, `ASV_tax.user.tsv`, `ASV_seqs.fasta` and `DADA2_table.tsv` were byte-identical on the two. Both capped tasks at 4 CPUs, so thread count is still phase 6's question |
| Each pinned pipeline's own `test` profile on the pinned Nextflow. taxprofiler 2.0.1 was released for Nextflow 25.10, so this is the first check that it runs on 26.10 | Pass in the test bed: ampliseq 3.1.0 ran 130 tasks, and taxprofiler 2.0.1 ran 179, the last 5 after `-resume` because a DNS lookup in Docker Desktop timed out during MultiQC's image pull. The stand-in passed Apptainer's error and exit status back. They ran as `alice` and `bob`, sharing `images/` and `NXF_HOME` |
| `-resume`, and cancelling a run, which should cancel its tasks through the `scancel` stand-in | Pass: a resumed run cached 29 of 31 tasks, and SIGTERM to an interactive run left no task 3 seconds later |
| `scancel` on the head job, and the head job hitting its time limit, which should both leave no task running | Pass: no task left 2 seconds after `scancel`, and the `--signal=B:TERM` warning reached Nextflow through the launcher. Pass on the cluster on 2026-11-06, with all three tasks running each time, along with SIGTERM to an interactive run on a login node |
| Building the image twice, which should give the same digest | Pass: `nix-build --check` rebuilds the tarball byte for byte. The registry digest waits for phase 5 |
| `nextflow -version` with an empty `NXF_HOME`, which should download nothing | Pass, once the dist file is executable |

Replacing the install directory under a running head job breaks it: Apptainer has the old
directory bound, so the stand-ins vanish from inside the job. The version cache in phase 4 is
what prevents that, and until then the test bed's `install` must wait for jobs to finish.

**On the cluster, 2026-11-06.** The cluster runs RHEL 9.4, Slurm 23.02.8 and Apptainer 1.5.3,
an el8 build, with unprivileged user namespaces enabled. `TMPDIR` is unset on login nodes and
`/tmp` on compute nodes, which have over 400 GB free there. The launcher checks all pass,
including jobs submitted through the helper from a compute node, so munge works across nodes.
They also showed jobs inheriting the login session's `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS`. Those are now kept for `systemctl` and `loginctl` only, which a
rerun on the cluster confirmed. The `16s-v4` and cancellation checks passed there too, the latter
running Nextflow on a login node for a few minutes without hitting its limits. The first pull of
the image from a registry waits for phase 5.

On a busy queue, tasks can stay pending past the head job's warning signal, so `cancel.sh`
waits for the tasks to be submitted, not running, and reports how many ran. Nextflow cancels
pending and running tasks through the same `scancel` stand-in, and the test bed showed both with
a blocking job holding most of the node. Nextflow 26 also writes its live progress display,
terminal hyperlinks included, into a head job's log, which isn't a terminal. So phase 3 should
run Nextflow with `-ansi-log false` in head jobs, as the checks now do.

Slurm's commands reach a login shell's `PATH` through an environment module there, so a shell
without that module has no `sbatch`. The helper runs Slurm with the `PATH` of the shell that
started the launcher, and jobs inherit it, so the same holds for gnoto. `lint`'s `sinfo` check
in phase 3 should say so when it fails, and the systemd templates already take `command -v
sbatch` at setup for this reason.

**Cluster runs.** The install directory is a clone of `cmmr/gnoto`, updated with `git pull`.
Until phase 5, the image goes over as the `.sif` the test bed built. On the login node:

1. Clone the repo, copy `config.example.yaml` to `config.yaml` at mode 660, and fill in
   `core.data_dir`, plus `core.apptainer_home` if `apptainer` isn't on `PATH` and
   `core.apptainer_binds` for any other path containers need.
2. Put the `.sif` in `<data_dir>/images/` under the name `IMAGE` gives, then check that
   `./gnoto exec true` exits 0.
3. Run the same checks as the test bed. Where Slurm's defaults will do, as on CMMR's cluster,
   they need no options:
   - `bash test/testbed/checks/launcher.sh`
   - `./gnoto exec bash test/testbed/checks/ampliseq-16s-v4.sh`
   - `bash test/testbed/checks/cancel.sh`

   Otherwise site options for jobs go in `TEST_SBATCH_ARGS` for the host-side scripts, such as
   `-p <partition> -A <account>`, and as arguments after a config file for those that run in
   the image. A small Nextflow config with `process.queue` and `process.clusterOptions` covers
   the tasks, passed as `TEST_NF_CONFIG` or as the in-image checks' first argument.

The helper's fixed environment drops `SBATCH_*` and `SLURM_*` defaults set in a user's shell,
so a site that needs a partition or account says so explicitly. In gnoto proper, that's
`core.slurm_partition` and `core.slurm_account`.

**Alongside phase 1,** run two determinism probes, so that phase 6 starts with answers. Neither
needs any gnoto code:

- run one job twice on the old code, then once with a different CPU count, and compare the outputs
- run `bowtie2-build` twice on the host reference, and compare the indexes byte for byte

Daniel runs anything that needs the cluster, so give him exact commands and ask for the
output.

### Phase 2: restructure

Follow the [file map](#file-map). The main work:

- **Paths.** `NEXTFLOW_DIR` does two jobs today: code root and data root. Split it, so code
  comes from the script's location and data from `core.data_dir`. `/data/prod/nextflow`
  appears on 44 lines in 35 tracked files outside the docs, and on 74 lines in 47 files with
  them, mostly as `source /data/prod/nextflow/.env` at the top of each script. `-B /data`
  in six scripts becomes `core.apptainer_binds`.
- **Settings.** `lib/env.sh` reads `config.yaml` and `generated.yaml` with `yq`, exports only
  non-secret settings, and sources the helper scripts.
- **Pipelines.** `pipelines/<NAME>_01.sh` becomes `pipelines/<name>/pipeline.sh`, and the
  `<NAME>.sh` shortcuts go. Change `PIPELINE_NAME` handling to match, and remove the rule in
  the old `docs/pipelines/index.md` that a version file is immutable.

### Phase 3: job core

- `scripts/wrike_job.sh` is the template for `lib/job.sh`. Its Wrike calls are the task ID,
  the attachment download, one custom field and the retention answer.
- Wrike names also appear outside the `wrike_*` scripts. The heaviest are
  `pipeline_params.sh` and the three `*_upload.sh` scripts, and `run` has 12 matches. Use this
  to find them:

  ```bash
  git grep -nE 'call_wrike_api|set_wrike_|add_wrike_|update_wrike_|read_wrike_task_id|WRIKE_|form_answer' -- scripts pipelines run
  ```

- Keep `form_answer` and the `.answers` section of the state file. Both routes fill them, and
  pipeline definitions then need no changes.
- With no Wrike, the uid is random. Keep the `mkdir "$RUN_DIR"` guard from
  `scripts/wrike_task_handler.sh:172`, which is what stops duplicate submissions.
- Split each `*_upload.sh` into compute, present and publish. Composition, `prune_results` and
  the methods page are currently called from inside them.

### Phases 4 to 6

- **Version cache:** the launcher, helper and `IMAGE` all come from the target commit, so
  test a re-run against a commit whose image differs from the current release's.
- **Lock files:** today's container addresses are tags in `modules/*.nf`, in the step scripts,
  and in the nf-core pipelines' own code. The old `pipelines/*_01.sh` pin the nf-core
  revisions, but don't carry those pins over. Start from the most recent releases,
  ampliseq 3.1.0 and taxprofiler 2.0.1 on 2026-11-05.
- **Determinism:** start with the Nonpareil seed in the table below. Multi-threaded bowtie2
  output order varies, so compare FASTQ as sorted records.

### Phase 7: integrations

- Build the three CloudFormation stacks (IAM user, S3, SQS) from the settings saved during
  [teardown](#teardown).
- `docs/wrike/responses.md` in the old repo has the live definitions of the workflow, custom
  fields and request form. Use it for `setup wrike` and the form checklist, and don't copy its
  IDs.
- The webhook's events must stay in step with the listener's `case` statement, because an
  unsubscribed event simply never arrives. See `docs/wrike/webhook_bridge.md`, which also
  explains why the Lambda's challenge check must not be loosened.

### Phase 8: public release

- Rewrite the docs for gnoto, cleaning them as they move. The old `docs/wrike/*` and
  `docs/operations/globus.md` hold object IDs, addresses and hostnames.
- Point `mkdocs.yml` and `docs_hooks.py` at `cmmr/gnoto`, and copy `.github/workflows/docs.yml`.
- Release steps, in order. Daniel approves each outward-facing one:
  1. CI builds and pushes any changed image. Commit the new digests to `IMAGE` and
     `lock.yaml`.
  2. Regenerate `containers.config` and the database digests, and commit them.
  3. Check that CI on `main` passes every release check, including no image address by tag.
  4. Run `gnoto selftest --dev` on the cluster from the candidate's working tree.
  5. Where a pipeline's results changed on purpose, copy the new checksums from its report
     into that pipeline's `selftest.yaml`.
  6. Add the release's entry to `CHANGELOG.md`, naming the pipelines whose core tables
     changed, and commit. The tagged commit then differs from the tested one only in
     `selftest.yaml` and `CHANGELOG.md`.
  7. Tag the commit. CI creates a draft release, uploads the tarball and its `.sha256`, then
     publishes it.
  8. If any image changed, upload the image bundle to Zenodo.

  `gnoto upgrade` then shows the CHANGELOG entry.

## Existing code that changes

| Today | Change |
| --- | --- |
| `.env` sources the helper scripts and sets `NEXTFLOW_DIR` | `lib/env.sh` does the sourcing, the code finds its own location, and the `NXF_*` paths come from `core.data_dir` |
| `.env:44` sets `NXF_ASSET_DIR`, which Nextflow doesn't read, so pipelines landed in `~/.nextflow/assets` | Set `NXF_ASSETS`, and leave `NXF_SCM_LEGACY` unset so each pipeline commit gets its own clone |
| `pipelines/AMPLISEQ_01.sh:11` pins ampliseq `827a6b7`, an unreleased 2.19.0dev commit | Pin the most recent release, 3.1.0 (`b9bd579`) on 2026-11-05 |
| Object IDs sit in `scripts/wrike_api.sh:29`, and `WRIKE_FORM_ANSWERS` (`:74`) mixes field IDs with allowed answers | IDs move to `generated.yaml`, and answers to `options.yaml` |
| `.env:45-46` sets Nextflow's image cache but not `APPTAINER_CACHEDIR`, so the step scripts' pulls fill each user's home with layers | `images/` holds only shared `.sif` files, and `APPTAINER_CACHEDIR` points at per-user node-local storage |
| `RBIOM_CONTAINER`, `VSEARCH_CONTAINER` and `GOTREE_CONTAINER` can be overridden | Removed, because `lock.yaml` pins these images |
| Step scripts call `apptainer exec -B /data` with no isolation (`scripts/ampliseq_composition.sh:326`), so the caller's locale, R library paths and home directory reach rbiom | `lib/containers.sh` adds `--cleanenv --no-home`, `LC_ALL=C.UTF-8` and `TZ=UTC` |
| `call_wrike_api` (`scripts/wrike_api.sh:173`) puts the token on curl's command line, where `ps` shows it to anyone on a shared login node | Pass it with `curl --config`, read from stdin |
| `call_wrike_api` has no retry or 429 handling (`scripts/wrike_api.sh:164-190`), and a failed Wrike call at the end of a run stops the followup before cleanup, leaving the task `Running` (`scripts/wrike_followup.sh:400,425`) | Retry with backoff, log what still fails for the daily timer to replay, and never fail a stage or skip cleanup |
| Each run's `run_state.json` is published from intake on, request record included (`scripts/run_state.sh:26-30`) | Never publish it. Publish `progress.json` with only what the page shows |
| The pages load Tailwind's Play CDN script and Google Fonts when viewed (`templates/tailwind.html:11-14`) | Build the Tailwind CSS once, and ship it and the fonts in `present/` |
| `*_upload.sh` scripts mix compute, dashboard pages and publishing | Split into the three job stages |
| The run directory is deleted on success (`scripts/wrike_followup.sh:419`) | Copy `job.yaml`, the record and the final state to `history/<uid>/` first. Delete the whole directory only when Globus or S3 is set and the zip, and with S3 the pages, are confirmed there. Otherwise keep `results/` and the zip, and delete the rest |
| The deliverables zip goes only to Globus, and the upload fails without it (`scripts/ampliseq_upload.sh:477-479`) | Keep the zip in exactly one place: Globus if it's set, otherwise S3, otherwise the run directory |
| `run` builds a Wrike task, stages it in a Personal space and waits for the webhook | `start` creates the task and submits the job itself |
| The listener runs the task handler itself, so form requests need SQS | The listener calls `gnoto wrike <task_id>`. In both modes, a user timer runs the `gnoto wrike` reconciliation scan every `wrike.poll_minutes`, or a person does |
| The listener reads only the first event in each payload, and deletes the SQS message before handling it (`scripts/wrike_sqs_listener.sh:79-96`) | Handle every event, and delete a message only after handling it |
| `scripts/run_state.sh:95-99` writes unlocked when `flock` fails (`flock 9 \|\| true`) | A write that can't get its lock fails |
| The log paths are fixed in `scripts/wrike_job.sh:6-7` and `scripts/wrike_followup.sh:6-7` | Move to the `sbatch` command line |
| `scripts/wrike_job.sh:2-7` hard-codes `--time=60:00:00` and sets neither `--no-requeue` nor `--signal` | Submit with `--no-requeue`, `--signal=B:TERM@300` and `--time` from `core.job_time` |
| `scancel --user="$(whoami)"` (`scripts/wrike_delete_handler.sh:81`) can't cancel another user's job | Write a cancel file that the job's progress watcher acts on |
| The Lambda and CloudFront function exist only as code blocks in `docs/wrike/webhook_bridge.md` and `docs/results/cloudfront.md` | Real files under `service/aws/`, with the IAM policies, so a site can attach them itself or let `--deploy` build the stacks |
| The results address assumes the bucket name is a domain (`run_results_url` in `scripts/utilities.sh`) | Use `aws.results_base_url` |
| systemd units hard-code `/data/prod/nextflow` and Slurm paths | Unit templates |
| `modules/nonpareil.nf:46` passes no `-r`, and [Nonpareil seeds from the current time by default](https://nonpareil.readthedocs.io/en/latest/redundancy.html) | Pass a fixed seed |
| `docs/operations/running-by-hand.md:52` says form submission is UI-only, but Wrike now lists [Submit Request Form](https://developers.wrike.com/reference/postrequest_formssinglesubmit.md) | Correct it. That endpoint would also allow an automated test of the Wrike route |
| Database paths are absolute or fixed to `NEXTFLOW_DIR/db`, in 10 files including `config/taxprofiler/database.csv` | Use `db:` names whose paths carry a version |
| `pplace` and `16s` write `manifest.json`, but the lookup in `scripts/wrike_job.sh:387` wants `<path>.manifest.json` | Manifests become YAML, and builders write the name the lookup expects |
| The form has no question for how ampliseq joins read pairs, so V3–V5 pairs that barely overlap are mostly lost | Add `ampliseq.mergepairs_strategy` to ampliseq's `options.yaml`, with ampliseq's default, `merge` |
| `WRIKE_FORM_ANSWERS` and the pipeline files cover only the options the form asks | `job.yaml` gets a section per pipeline. Any parameter the pipeline's schema accepts can be added there by hand and is passed through |
| The samplesheet steps check only that each FASTQ is readable, and follow symlinks (`scripts/ampliseq_samplesheet.sh:179-183`) | In the form route, each file's real path must sit under `core.input_roots` |
| `scripts/ampliseq_samplesheet.sh:250-267` sets each sample's `run` from a hash of its FASTQ directories, so a re-run from other paths batches samples differently | Record each input's `run` in `record.yaml`, and reuse it on a re-run |
| `16s` is read by region detection (`scripts/ampliseq_detect_region.sh:91`) but isn't a parameter, so runs don't record it | Declare it in the lock file, under a versioned path |
| `ampliseq/` has no manifest, because nf-core downloads SILVA by itself, and `pipelines/AMPLISEQ_01.sh:29-33` passes `dada_ref_taxonomy` straight through | Give each reference choice a fetch entry in `conf/databases.yaml`, with md5s, and pass the files through `*_ref_tax_custom`, so ampliseq downloads nothing |
| nf-core pipelines load nf-core/configs from its `master` branch at run time by default, through `custom_config_base` | gnoto passes `custom_config_base` empty |
| The host and 16S builders check each download against the md5 NCBI serves at build time, and `config/databases.json` holds 14 md5 values for 38 URLs | Record every download's md5 in `conf/databases.yaml`, and check it before any transformation such as `bowtie2-build` |

## File map

Every tracked file in the old repo, and where it goes. The new names are suggestions, so
adjust them if the code wants something better, and keep this table and the design's layout
in step.

### Top level

| Old | New | Phase | Notes |
| --- | --- | --- | --- |
| `.gitattributes` | `.gitattributes` | 1 | Copied unchanged on 2026-11-05. It enforces LF |
| `.gitignore` | `.gitignore` | 1 | Rewrite, adding `config.yaml` |
| `run` | `gnoto` | 1, 3 | Rewritten. Its task creation moves to `service/wrike/` |
| `.env` | `config.example.yaml`, `lib/env.sh` | 2 | Settings and sourcing split. Don't copy the values |
| `README.md` | `README.md` | 8 | Rewritten around the install steps |
| `dev.md` | Not copied | | Holds emails and rule IDs. Move anything useful into `docs/` |
| `mkdocs.yml`, `docs_hooks.py`, `requirements-docs.txt`, `.github/workflows/docs.yml` | Same paths | 8 | Update the repo name and URLs |
| `images/bot_100px.png`, `images/bot_large.png` | `docs/images/` or similar | 8 | Note that `images/` now means Nix recipes |

### Core scripts

| Old | New | Phase | Notes |
| --- | --- | --- | --- |
| `scripts/utilities.sh` | `lib/utilities.sh` | 2 | `derive_uid` stays for Wrike tasks |
| `scripts/run_state.sh` | `lib/run_state.sh` | 2 | Stays JSON, driven by `jq` |
| `scripts/pipeline_params.sh` | `lib/params.sh` | 2 | `params_load` can use `yq`, which also lifts the scalar-only limit |
| `scripts/wrike_job.sh` | `lib/job.sh` | 3 | Wrike calls move out, and the manifest becomes `record.yaml` |
| `scripts/wrike_followup.sh` | `lib/followup.sh`, plus a Wrike part in `service/wrike/` | 3, 7 | Reads how Slurm says a job ended, and cancels any task the trace still shows as running |

### Wrike, AWS, Globus and systemd

| Old | New | Phase | Notes |
| --- | --- | --- | --- |
| `scripts/wrike_api.sh` | `service/wrike/api.sh` | 7 | IDs and `WRIKE_FORM_ANSWERS` move out |
| `scripts/wrike_task_handler.sh` | `service/wrike/task_handler.sh` | 7 | Becomes `gnoto wrike`. Writes a job file, then calls the shared lint and submit code |
| `scripts/wrike_sqs_listener.sh` | `service/wrike/listener.sh` | 7 | Calls `gnoto wrike <task_id>` for each new task, and rewrites `expiry/<uid>` when a task's Expiration date changes |
| `scripts/wrike_delete_handler.sh` | `service/wrike/delete_handler.sh` | 7 | Runs `remove`, which uses the cancel file for a running job |
| `scripts/wrike_expiration.sh` | `service/expire.sh`, plus a Wrike part in `service/wrike/` | 7 | Acts only on `<data_dir>/expiry/`. With Wrike, it first copies each task's Expiration date into its file |
| `scripts/globus.sh` | `service/publish.sh` | 7 | Its Globus copy joins the S3 upload |
| `systemd/wrike-sqs-listener.service` | `service/systemd/gnoto-listener.service` | 7 | Template |
| `systemd/wrike-expiration.service`, `.timer` | `service/systemd/gnoto-daily.service`, `.timer` | 7 | Template. Installs with or without Wrike, and runs expiry, `lint`, Wrike replays, delayed deletions and log rotation |

### Compute steps

| Old | New | Phase | Notes |
| --- | --- | --- | --- |
| `scripts/{ampliseq,taxprofiler,biobakery}_samplesheet.sh` | `steps/` | 2 | Biobakery calls the taxprofiler one |
| `scripts/ampliseq_detect_region.sh`, `ampliseq_prune_tree.sh` | `steps/` | 2 | |
| `scripts/biobakery_disk_check.sh` | `steps/` | 2 | Also feeds the `lint job.yaml` disk check |
| `scripts/{ampliseq,taxprofiler,biobakery}_composition.sh` | `steps/` | 3 | Called from the compute stage |
| `scripts/taxprofiler_humann.sh`, `taxprofiler_taxonomy_tree.sh` | `steps/` | 2 | The first runs its own Nextflow |
| `scripts/R/ampliseq_tables.R`, `taxprofiler_tables.R` | `steps/R/` | 2 | Run in `gnoto-rbiom` |
| `scripts/fetch_taxprofiler_db.sh`, `build_host_reference.sh`, `build_pplace_reference.sh`, `build_16s_reference.sh` | `steps/` | 5 | Add tree digests and recorded download md5s, fix their manifest names, and fetch into a temporary path that's renamed on success |

### Dashboard and publishing

| Old | New | Phase | Notes |
| --- | --- | --- | --- |
| `scripts/{ampliseq,taxprofiler,biobakery}_upload.sh` | Split across `present/` and `service/publish.sh` | 3, 7 | See the table above |
| `scripts/publish_dashboard.sh` | `present/dashboard.sh`, with its upload moved to `service/publish.sh` | 3, 7 | |
| `scripts/nextflow_progress.sh` | `present/progress.sh` | 3 | Also becomes the cancel-file watcher |
| `scripts/index_directories.sh`, `prune_results.sh`, `biobakery_methods.sh` | `present/` | 3 | |
| `templates/*.html`, `common.css` | `present/templates/` | 3 | |
| `templates/{ampliseq,taxprofiler,biobakery}/` | `present/templates/` | 3 | |
| `templates/redesign/` | Copy only if needed | 3 | Design reference. Check what reads it first |

### Pipelines and Nextflow

| Old | New | Phase | Notes |
| --- | --- | --- | --- |
| `pipelines/<NAME>_01.sh` | `pipelines/<name>/pipeline.sh` | 2 | Keep each parameter's reason. The nf-core pins move to `lock.yaml`, at the latest releases, and `PARAMS_LOCKED` becomes the list of keys gnoto owns |
| `pipelines/<NAME>.sh` | Not copied | | Shortcuts aren't needed |
| `modules/*.nf` | `modules/` | 2 | Add the Nonpareil seed in phase 6, and digests in phase 5 |
| `workflows/biobakery/`, `workflows/humann/` | `workflows/` | 2 | |
| `config/slurm.config`, `config/{biobakery,taxprofiler}/slurm.config` | `conf/<name>/resources.config` | 2 | Keep resource requests. Site parts such as `cacheDir` and executor settings go |
| `config/local.config` | Not copied | | Only `docs/layout.md` mentions it |
| `config/taxprofiler/database.csv` | `pipelines/taxprofiler/database.csv` | 2, 5 | Uses `db:` names |
| `config/databases.json`, `references.json` | `conf/databases.yaml`, `references.yaml` | 2 | `biobakery_methods.sh` reads these with `jq`, and `publish_dashboard.sh` reads the methods data it writes. The two `test-fastq` entries give way to the fixtures in [fixtures.md](fixtures.md) |
| `nix/rbiom.nix` | `images/gnoto-rbiom.nix` | 1, 5 | Also fill in the commented-out `sha256` |

### Docs, all for phase 8

| Old | Use |
| --- | --- |
| `docs/conventions.md` | The uid, state file and message-bus conventions. Read this before phase 3 |
| `docs/pipelines/*.md` | Why each pipeline is set up as it is, and most of the science reasoning. Keep these |
| `docs/results/*.md` | How the dashboard works, including composition and browsable folders. Keep these |
| `docs/operations/nix.md`, `databases.md`, `expiration.md`, `daemon.md`, `cluster-requirements.md`, `running-by-hand.md`, `index.md` | Rewrite for gnoto, because `setup`, `lint` and `status` replace many of the manual steps |
| `docs/operations/globus.md`, `docs/wrike/*.md` | Rewrite, removing IDs, addresses and hostnames |
| `docs/index.md`, `layout.md`, `configuration.md` | Rewrite against [design.md](design.md) |

## Teardown

Daniel plans to tear down everything in place and roll out gnoto as an external user would.

- **Save the AWS settings first.** The old repo records the Wrike fields, workflow and form
  (`docs/wrike/responses.md`), and the Lambda and CloudFront function source. It has no record
  of the IAM policies, bucket policy, CloudFront distribution settings, API Gateway setup or
  queue settings, and the CloudFormation stacks have to reproduce them. Save them outside this
  public repo.
- **Keep `db/` and Apptainer until phase 6 is done,** because phases 1 to 6 test against them.
  The fixtures in [fixtures.md](fixtures.md) are public and can be fetched again at any time.
  The Wrike, AWS, Globus and systemd pieces can go at any time after the AWS settings are saved.
- **Finish the teardown before the rollout test.** `setup` adopts any object it finds by name,
  so a leftover custom field or an earlier "gnoto Jobs" folder would hide a bug in the code
  that creates it. Removing `db/` as well also tests the download offers in `lint`.
- **Scan the old repo's history for real credentials.** `cmmr/nextflow` is public and hasn't
  been scanned. gnoto starts clean, so this concerns only the old repo. Retire anything found.

The local AWS CLI user can read some of the old stack but not all of it. These worked when last
checked: `lambda get-function-configuration` (query only the environment variable keys, because
the values include the webhook secret), the Lambda's CloudWatch logs, `cloudwatch list-metrics`
and `get-metric-data`. These were denied: `sqs get-queue-attributes` and any `apigateway` or
`apigatewayv2` read. The AWS console may be easier for those. In Git Bash, set
`MSYS_NO_PATHCONV=1`, or `/aws/lambda/...` gets rewritten into a Windows path and fails as
`AccessDenied`.
