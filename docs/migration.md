# Migrating from cmmr/nextflow to gnoto

gnoto gets built by copying code out of `cmmr/nextflow` and restructuring it, in eight
phases. Nothing is in production, so there's no cutover, and no old runs or published
results to honor. [design.md](design.md) describes the target.

Status on 2026-11-09: **phases 1 to 3 are done, in the test bed and on the cluster.** A CLI
job runs each of ampliseq, biobakery and taxprofiler from `gnoto start` to a full dashboard
in `results/` under Slurm, with no Wrike, AWS or Globus, and ampliseq also does so on the
machine itself. **Phase 4, the version cache, is done too:** it passes its finish test in the
test bed, and on the cluster ampliseq runs from the cache and a failed run resumes. **Phase 5,
the lock files, is done:** it passes its finish test in the test bed and on the cluster, and
all three pipelines run there with every image by digest and every database pinned.
**Phase 6, determinism, is built** and passes its finish test in the test bed. The cluster's
runs, which choose the shotgun pipelines' core tables and make every pipeline's reference
tables, are next. The [phase 1](#phase-1-image-and-helper), [phase 2](#phase-2-restructure),
[phase 3](#phase-3-job-core), [phase 4](#phase-4-version-cache),
[phase 5](#phase-5-lock-files) and [phase 6](#phase-6-determinism) notes record what's
built and every test result.

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
| 3. Job core | `lib/job.sh`, `options.yaml`, `new`, `lint job.yaml`, `run`, `run --debug`, `start`, `status`, `cancel`, input checksums, `history/`, core `config` and config `lint`, and the three job stages, with Publish a stub until phase 7 | A CLI job finishes with no Wrike, AWS or Globus configured, and leaves a full dashboard in `results/` |
| 4. Version cache | `pipeline@ref`, `run record.yaml`, `<data_dir>/current`, `gnoto upgrade`, `gnoto prune`, and `gnoto resume` with the cleanup that keeps a failed run's cache | A job re-runs correctly from its own commit after `main` has moved on, an upgrade while a job runs leaves that job on its own code, and a run that failed resumes from its own commit with its finished tasks cached |
| 5. Lock files | Image digests, GHCR images, `containers.config`, `db:` names, database digests and `lint --deep` | CI on `main` rejects an image address by tag, and a re-run pulls only by digest |
| 6. Determinism | `gnoto selftest`, seeds, `stable-files`, and the numeric comparison of core tables | A re-run reports its core tables as identical |
| 7. Integrations | `gnoto wrike` writing job files from Wrike tasks, CLI jobs creating tasks, the publish stage and `gnoto publish`, the daily timer, `extend`, the integrations' part of `remove`, which came forward without it, `config` and `lint` for the integrations, the CloudFormation stacks, and the health file `status` shows | A Wrike request and a CLI job on the same samples give the same core tables, and both appear as tasks |
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
- `LC_ALL=C.UTF-8` works without a locale archive. nixpkgs' glibc installs C.UTF-8 compiled
  into its own `lib/locale`, which glibc reads when no archive holds the locale. Checked on
  2026-11-07: in the image, gawk and bash count `é` as one character, `locale charmap` from the
  same glibc gives `UTF-8`, and Java's `sun.jnu.encoding` is `UTF-8`. An archive holding only C.UTF-8 changed
  none of that, so the image has none. `launcher.sh` checks this still holds after the nixpkgs
  pin moves.
- Apptainer binds the host's `/etc/localtime` by default, so the image sets `TZ=UTC`. Without
  it, `date` in the image printed CST under a host clock set to America/Chicago. `launcher.sh`
  checks this too, though only a host outside UTC, such as the cluster, can fail it.
- The image is 1.47 GB as a tarball and 760 MB as a `.sif`. `nix-build --check` rebuilds it, and
  the locally built `globus-cli`, byte for byte.

**Getting the image to the cluster.** For the prototype, `IMAGE` names a `.sif` file in
`<data_dir>/images/`, so nothing has to be published. `test/testbed/testbed.sh image` builds the
recipe in `nixos/nix` in Docker, converts it with
`apptainer build <sif> docker-archive:<tarball>` in the test bed, and points `IMAGE` at it. The
launcher already accepts `docker://<image>@sha256:<digest>` and pulls it under a lock. Move to
GHCR, by digest, once the image is stable, and no later than phase 5. Phase 5 did, and the
recipe now builds in CI.

**Launcher and helper.** The launcher (`gnoto`) and helper (`host/helper.sh`) are POSIX `sh`,
because they run before any image tools exist. The stand-in is one bash script,
`host/standin.sh`, which runs inside the image. At launch, the launcher links it under each name
in `host/allowed/`, in its private directory, which goes first on `PATH` inside the image. The
repo itself holds no symlinks. The launcher reads its bootstrap settings from
`config.yaml` with its own awk, as [design.md](design.md#host-and-image) describes. Inside the
image, `lib/main.sh` is the entry point. Its only command so far is `gnoto exec <command>`, a
development aid.

The protocol as built and tested:

1. The launcher makes a private directory at mode 700 on node-local storage (`$TMPDIR`, else
   `/tmp`), because a FIFO only works within one machine. It starts the helper on a `requests`
   FIFO there, then runs `apptainer exec --cleanenv`, binding the install directory, the data and
   database directories, `apptainer.binds` and the private directory at their host paths.
   What reaches the image is set through `APPTAINERENV_` variables, after dropping any the caller
   set, because those survive `--cleanenv`.
2. For each call, a stand-in makes a request directory holding `request`, which sets `cwd` and
   the arguments as single-quoted shell words, and `stdout`, `stderr` and `alive` FIFOs. It starts
   a reader on each output FIFO, then writes the directory's name to `requests` as one line.
   Arguments aren't NUL-separated, because POSIX `sh` can't read that safely. If the helper has
   gone, opening `requests` blocks, so the write has a 5-second timeout. Phase 3 added two
   things, for Nextflow's local executor, which runs each task's `apptainer` inside the image
   as `env - PATH=...`: a stand-in with no `GNOTO_HELPER_DIR` finds the private directory from
   its own path, and an `apptainer` request carries the caller's `APPTAINERENV_` and
   `SINGULARITYENV_` variables, which hold the task's work directory and `TMPDIR`, as its first
   `pass` words. The helper accepts such words for `apptainer` only.
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
   through the `scancel` stand-in in between. Apptainer passes the signal on only when the
   command's output isn't a terminal, as phase 2's cluster notes say.

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
directory bound, so the stand-ins vanish from inside the job. Phase 4's version cache
prevents that: every job now runs from its version's read-only copy in `versions/`, so only
a `--dev` job, which runs the install's own files, can still be broken that way.

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

**Cluster runs.** The install directory is a clone of `cmmr/gnoto`. Until phase 4 it was
updated with `git pull`; from phase 4 on, its first command makes the clone's commit current,
and `./gnoto upgrade` moves it on, as phase 4's notes say. Until phase 5, the image went over
as the `.sif` the test bed built; since then, the launcher pulls it from GHCR. On the login
node:

1. Clone the repo. Until phase 5, put the `.sif` in `<data_dir>/images/` under the name
   `IMAGE` gives.
   Without `config.yaml`, the data directory is `<install>/data`.
2. With Slurm's module loaded, run `./gnoto config slurm --on`, which takes what `sinfo`
   suggests, and `./gnoto config core` from a terminal if the data directory is elsewhere.
   Then check that `./gnoto exec true` exits 0.
3. Run the same checks as the test bed. Where Slurm's defaults will do, as on CMMR's cluster,
   they need no options:
   - `bash test/testbed/checks/launcher.sh`
   - `./gnoto exec --dev bash test/testbed/checks/ampliseq-16s-v4.sh`
   - `bash test/testbed/checks/cancel.sh`

   Otherwise site options for jobs go in `TEST_SBATCH_ARGS` for the host-side scripts, such as
   `-p <partition> -A <account>`, and as arguments after a config file for those that run in
   the image. A small Nextflow config with `process.queue` and `process.clusterOptions` covers
   the tasks, passed as `TEST_NF_CONFIG` or as the in-image checks' first argument.

The helper's fixed environment drops `SBATCH_*` and `SLURM_*` defaults set in a user's shell,
so a site that needs a partition or account says so explicitly. In gnoto proper, that's
`slurm.partition` and `slurm.account`.

**Alongside phase 1,** two determinism probes were to run on the old code, so that phase 6
started with answers: one job twice and then at another CPU count, and `bowtie2-build` twice
on the host reference. They never ran there. At Daniel's call on 2026-11-09, phase 6 runs both
on gnoto instead, as its notes say: the first is the stable-files test, and the second a
build of the human host reference at another CPU count.

Daniel runs anything that needs the cluster, so give him exact commands and ask for the
output.

### Phase 2: restructure

Follow the [file map](#file-map). The main work:

- **Paths.** `NEXTFLOW_DIR` does two jobs today: code root and data root. Split it, so code
  comes from the script's location and data from `core.data_dir`. `/data/prod/nextflow`
  appears on 44 lines in 35 tracked files outside the docs, and on 74 lines in 47 files with
  them, mostly as `source /data/prod/nextflow/.env` at the top of each script. `-B /data`
  in six scripts becomes `apptainer.binds`.
- **Settings.** `lib/env.sh` reads `config.yaml` and `generated.yaml` with `yq`, exports only
  non-secret settings, and sources the helper scripts.
- **Pipelines.** `pipelines/<NAME>_01.sh` becomes `pipelines/<name>/pipeline.sh`, and the
  `<NAME>.sh` shortcuts go. Change `PIPELINE_NAME` handling to match, and remove the rule in
  the old `docs/pipelines/index.md` that a version file is immutable.

What's built:

- **`lib/env.sh`** finds the code from its own location, and the install directory from the
  launcher. It reads `config.yaml`, and `generated.yaml` from the data directory, with `yq` and
  `jq`, never by sourcing. `core.data_dir` becomes `DATA_DIR`, any other section's key takes
  the section as a prefix (`SLURM_MAX_CPUS`), and a nested key joins with underscores.
  `config.yaml` wins over `generated.yaml`. `lib/config/<section>.sh` declares the settings a
  version knows and their defaults, so `config.yaml`'s other keys are ignored, and a top-level
  key such as `PATH` can't overwrite a variable. Secrets are set but never exported. It also sets the `NXF_*`
  paths and `umask 002`, and sources the helpers. Every step sources it again, because
  functions don't pass to a child process.
- **`config.yaml` is optional and holds only the sections a site adds.** Without it, the
  launcher and `lib/env.sh` use the defaults: data in `<install>/data`, Slurm off, and
  Apptainer and Slurm from `PATH`. The launcher stops only when it can't find `apptainer`,
  and passes the image where it found `apptainer` and `sbatch`, and `SLURM_CONF`. Where
  Apptainer isn't on `PATH`, `gnoto init --apptainer=<path>`, in the launcher alone, writes
  a `config.yaml` holding only an `apptainer` section. `lib/config/<section>.sh` declares
  each section (`core`, `apptainer`, `slurm`, `wrike`, `aws` and `globus`), and
  `lib/config.sh` runs `gnoto config`: the list of sections, one section's questions, or
  `--on` and `--off`. A section it adds is written whole, and a new file is mode 660 in the
  user's own group. Each answer replaces the value on its line, keeping the line's comment
  in its column, and a key the section lacks goes at its end; `yq` handles only what that
  can't place. It writes into the existing file, because the image's user namespace may not
  map the file's group and so can't give a new file that group. Every section but `core`
  starts with `enabled`, which replaces `core.scheduler` and `core.container_engine`. The
  launcher reads `slurm.enabled` and `apptainer.enabled` among its bootstrap settings.
  Wrike, AWS and Globus get their questions now, and their own setup in phase 7.
- **Helpers.** `lib/utilities.sh`, `lib/run_state.sh` and `lib/params.sh` are ported, and
  `lib/containers.sh` and `lib/scheduler.sh` are new, so each kind of call has one place. A
  state write that can't get its lock now fails. `run_state.json` is never published. Template
  rendering and the results address move to `present/` and the integrations with their callers
  in phases 3 and 7.
- **Parameters** are held as JSON, so a list or a map from a job file keeps its shape, and a
  shell value of `true`, `false`, `null` or a number is written bare. A database is named
  `db:<path under core.db_dir>`. The record keeps the name, and the params file Nextflow reads
  gets the path.
- **Reference choices.** An entry in `pipelines/databases.yaml` can carry a `choice`, such as
  `dada_ref_taxonomy` `silva=138.2`, with the `*_ref_tax_custom` files that replace it.
  `params_reference` swaps one for the other, so ampliseq downloads no reference, and a choice
  without an entry fails.
- **Step containers** run through `container_exec`: `--cleanenv`, `LC_ALL=C.UTF-8`, `TZ=UTC`,
  and an empty home directory bound at `/home/gnoto`, from the run directory, as phase 1's
  two-user check asked. Their images are pinned by digest in `pipelines/<name>/lock.yaml`,
  beside the upstream commit, which replaces each pipeline file's `-r` revision. vsearch moves
  from 2.31.0 to 2.32.0, the latest.
- **`pipelines/databases.yaml` and `references.yaml`** replace the JSON files. The retired
  sylph entry and the two old `test-fastq` sets are gone, SILVA 138.2 has an entry with its
  md5s, and the fixtures block from [fixtures.md](fixtures.md) is at the end.
- **Steps, modules, workflows and resources.** The eight phase 2 steps and the two R scripts
  are in `steps/` and `steps/R/`, the modules and the biobakery and HUMAnN workflows in
  `modules/` and `workflows/`, and the resource requests in
  `pipelines/<name>/resources.config`, without the site settings (executor, Apptainer cache
  and binds, CPU, memory and time caps).
  `/tmp` still reaches task containers, because Apptainer binds it by default.

Tested on 2026-11-06, all passing:

- `test/lib/lib-test.sh`, in the real image: settings and their defaults, secrets kept out of
  child processes, `generated.yaml`, a config syntax error with its line, typed parameters and
  `db:` names, run state under 20 concurrent writers, a lock that can't be had, the text helpers,
  and a step container's clean environment and empty home, run from the user's home directory.
- `test/lib/pipelines-test.sh`: each `pipeline.sh` with different answers, its revision from
  `lock.yaml`, its steps present, and its params file resolving `db:` names.
- `test/steps/steps-test.sh`, on the `16s-v4` fixture in the test bed: the three samplesheet
  steps with gzip and bzip2 inputs and a sample name ampliseq rejects, region detection failing
  cleanly without its reference, and pruning a small tree with the real gotree image.
- `test/helper/launcher-test.sh`, with a stub `apptainer`: running without `config.yaml`,
  stopping without `apptainer`, passing in where `apptainer` and `sbatch` were found,
  `gnoto init` with no `apptainer` on `PATH` and its refusals, and Slurm's settings counting
  only while `slurm.enabled` is `true`.
- `test/lib/lib-test.sh` also covers `config_set`: a line changed in place with its comment's
  column kept, a missing `enabled` first and another missing key last, bare numbers and
  booleans, and `yq` adding a missing section; and the list of sections.
- `test/testbed/checks/config.sh`, as `alice` on a copy with no `config.yaml`: the defaults,
  the list, `gnoto init`, `slurm --on` adding what `sinfo` and the launcher found, `--off`
  keeping it, questions for `apptainer`, `core`, `slurm` and `wrike` with their suggestions,
  refusals, and only the sections asked for, at mode 660 in `alice`'s group.
- Both tests from a second install path, where every path follows the install directory.
- No tracked file names `/data/prod/nextflow` but this one, which describes the old repo.

Two things the port found in the old code: rerunning the ampliseq samplesheet step in the same
run directory wrote through a leftover link into the requester's own input file, and a failed
prune left an empty `.tmp` behind. Both are fixed. vsearch 2.32.0 gave hit tables identical to
2.31.0's on synthetic fixtures. Region detection on real reads needs the 16S landmarks that
phase 5's builder makes.

**On the cluster, 2026-11-06,** from a fresh clone of `653bd55` with no `config.yaml`:

- With the old `kubernetes` module gone from the login shell, Apptainer isn't on `PATH`.
  `gnoto init --apptainer=/data/prod/nextflow/opt/apptainer/bin/apptainer` points at the copy
  inside the old install, which needs a home of its own before that install is torn down.
- Without `config.yaml`, gnoto ran with data in `<install>/data`, and found Slurm on `PATH`.
- `gnoto config slurm --on` recorded Slurm's directory and `SLURM_CONF`, and suggested the
  default partition, its largest node's 32 CPUs and 1007 GB, and no `max_time`, because the
  partition has no time limit.
- The `16s-v4` check ran to completion from scratch, downloading the fixture, SILVA and every
  tool image again, with 22 ASVs in both tables. The cancellation checks and all but one
  launcher check passed.

The launcher check that failed sends SIGTERM to the launcher while the command's output goes to
the terminal. Apptainer passes no signal on to such a command: it leaves that to the terminal,
which sends Ctrl-C to the whole foreground job. That held for 1.5.3 on the cluster and 1.5.5 in
the test bed under a pseudo-terminal, and in both a command writing to a file got the signal. So
a head job, a systemd unit and anything writing to a log get it. Only a `kill` from another
shell, aimed at a gnoto running in a terminal's foreground, is lost, which isn't worth
signalling the launcher's whole process group to catch. The check now sends the command's
output to a file, as a job's is, and passes in the test bed with and without a terminal.

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
- Left over from phase 2's port, all now done:
  - The run's `taxprofiler_database.csv` holds real paths. The published copy has `db:`
    names instead.
  - `steps/biobakery_disk_check.sh` counts the download against `globus.dir` when Globus is
    on, and against the run directory otherwise, where the zip stays.
  - `steps/taxprofiler_humann.sh` runs its own Nextflow with the job's `site.config` and
    `core.nextflow_config`, and `-ansi-log false`. The command record it publishes beside
    the HUMAnN tables names databases as `db:`, the code as `<gnoto>`, and no run path.
  - HUMANN_PROFILE asks for 48 hours, and `lint` warns when `slurm.max_time` cuts it, or any
    task's plain time request, short. A CPU count marked `// fixed` fails `lint` when
    `slurm.max_cpus` is below it; nothing is marked yet, which is phase 6's question.
  - taxprofiler's `instrument_platform` is a measured option: a job file can set it, which
    the job passes as `INSTRUMENT_PLATFORM`, and the record keeps what was measured.
  - ampliseq's report abstract names no site (Daniel, 2026-11-06).
  - Steps that note a missing database say `gnoto lint <job file>` offers to fetch it.

What's built:

- **Job files.** `pipelines/<name>/options.yaml` lists each pipeline's options, as
  [design.md](design.md#job-files) describes. `lib/jobfile.sh` holds `gnoto new`, the job
  file checks `lint`, `run` and `start` share, and `record.yaml`. A section's keys that aren't
  options are checked against the pipeline's `nextflow_schema.json` at its pinned commit,
  fetched with git into `<data_dir>/schemas/`; gnoto's biobakery workflow carries its own
  schema. `pipeline.sh` is evaluated with the job's answers in a scratch run directory, which
  catches its own refusals and gives the owned keys, the parameters and the databases. A
  value naming gnoto's own file is a `code:` name, as `db:` names a database.
- **The command line,** changed after phase 3's commit at Daniel's request (2026-11-07).
  `gnoto start job.yaml` became `gnoto run job.yaml`. `gnoto new` prints the job file to
  stdout, with no `<pipeline>.yaml` written and nothing refused for being there, and takes
  any of the file's keys as `--<key>=<value>`, typed from `options.yaml` or the schema.
  `gnoto start <pipeline>` takes the same arguments and runs the file they make, from a
  temporary file, through `run`'s checks and submission, so a relative `--samplesheet` is
  made absolute against the current directory. `gnoto config <section>` takes settings as
  `--<key>=<value>` and then asks nothing. `lib/args.sh` parses every command's arguments in
  the image, `--<key>=<value>` or `--<key> <value>`, and the launcher parses `gnoto init`'s the
  same way. [design.md](design.md#the-command-line) has the rules, and
  [decisions.md](decisions.md) the two rows for them.
- **`lint` with no job file** checks `config.yaml` and the scheduler, as
  [design.md](design.md#the-command-line) lists. The launcher passes what it read of its eight
  bootstrap settings as `GNOTO_BOOTSTRAP`, for `lint` to compare with `yq`.
- **The head job,** `lib/job.sh`, runs Compute, Present and a Publish stub, and records each
  in `stages`. `lib/followup.sh` settles the run, `lib/start.sh` makes and submits it, and
  `lib/runs.sh` holds `status` and `cancel`. `lib/scheduler.sh` picks Slurm when
  `SLURM_ENABLED` is `true` and runs jobs on this machine otherwise, where the launcher
  starts them detached once the image has exited.
- **Databases.** `lib/databases.sh` finds what a job needs, offers the fetch, submits it as a
  job, and waits on it. `steps/fetch_files.sh` fetches any entry that lists `files`, fixtures
  included, and `steps/build_pplace_reference.sh` and `steps/build_16s_reference.sh` came
  forward from phase 5. Every download they make has its md5 in `pipelines/databases.yaml`,
  checked against figshare's API and NCBI's `md5checksums.txt`. The 16S builder reads its
  genomes from its entry rather than taking accessions. The old pplace tree check died
  silently on a wholesale tip mismatch (`head` under `pipefail`), which is fixed.
- **Composition,** `steps/<name>_composition.sh`, runs in Compute, in `gnoto-rbiom`. A
  feature table that can't be built now fails the run, where the old scripts warned. The
  image was first a Nix recipe, on nixos-unstable because nixos-26.05 has rbiom 2.2.1, and
  patched rbiom 3.1.0, whose subsetting without `drop = FALSE` turned a single-sample run's
  counts into a vector and broke the feature table on `16s-v4`. rbiom's `master` has the
  fix, as 4.0.0, which needs ecodive 2.3.1, newer than nixpkgs had. So at Daniel's request
  `images/gnoto-rbiom/` builds it with Docker instead: `rocker/r-ver:4.6.2` by digest (Ubuntu
  26.04), and pak installing `pkg.lock`, which `lock.sh` resolves against Posit's CRAN
  snapshot of 2026-11-06, with rbiom at commit `1248db3`. Its 42 packages are 35 Ubuntu
  binaries, R's 6 recommended packages from the base image, and rbiom, the only one
  compiled. The build takes about a minute, `lock.sh` gives the same lockfile twice, and the
  `.sif` is 438 MB, against 1.16 GB for the Nix one, which also carried phyloseq, which
  nothing uses. R reports C.UTF-8 and UTF-8, and the four "cannot be translated to UTF-8"
  warnings rbiom printed on every run are gone.
- **Present,** `present/<name>.sh results`, prunes the results, writes every page and
  folder listing, and builds `<title>_<uid>.zip` in the run directory, which the pages link
  as `../<name>.zip`. `present/dashboard.sh` is the old `publish_dashboard.sh` without its
  upload, `present/common.sh` holds the run's facts, path redaction and the zip, and
  `present/progress.sh` keeps the progress page current and acts on the cancel file. Text
  files in `results/` have this site's paths taken out: the run directory becomes `./`,
  the code `gnoto:`, the database directory `db:`, the rest of the data directory `data:`,
  and `$HOME` `~`. The pages load nothing from the network: `present/build-assets.sh` builds
  `present/assets/` in a pinned `python:3.12-slim`, with Tailwind 4.3.5's standalone CLI and
  its forms plugin, Inter 4.1, JetBrains Mono 2.304, and Material Symbols cut to the 17
  icons the pages use, every download pinned by SHA-256, and two builds give the same
  bytes. The pipelines' own reports still load a little from the network: fastp's loads
  Plotly from its CDN, and MultiQC's and Nextflow's reports a favicon and an image.
  `-ansi-log false` prints no task completions, so the progress page reads them from each
  Nextflow run's `-log` file. The bar now says gnoto and the footer "Made with gnoto", and
  ampliseq's and taxprofiler's read folders now appear in the download's listing, which the
  old pages left out.
- **What phase 7 needs from the dropped calls.** The task ID, and the task's title and
  Expiration date, which the old pages read from Wrike. The zip went straight to
  `$GLOBUS_DIR/$GLOBUS_RUN_PREFIX/<uid>/`, and `bundle_href` in `present/common.sh` is where
  the pages should get its Globus or S3 address. The S3 upload sent text files
  (`txt tsv csv log yaml yml gff fasta fa fna nwk newick sh`) as `text/plain;
  charset=utf-8`, then the pages with `index.html` last, then `{"state":"final"}` to
  `progress.json` with `no-cache`, and set the task's dashboard URL field. During a run the
  watcher uploaded `index.html` and `progress.json` whenever they changed.
- **Fixes found on the way.** `run_state.json`, the record and other files written through
  `mktemp` were mode 600, so other group members couldn't read a run; they're 664 now.
  gotree 0.5.2 writes a file named `none` unless given `--outtipfile`. The helper protocol
  gained what Nextflow's local executor needs, as phase 1's notes now say.

Tested on 2026-11-07, in the test bed:

| Test | Result |
| --- | --- |
| `test/lib/job-test.sh`: `new`, the job file checks (answers, unknown keys, owned keys, schema types, nf-core's generic parameters, path parameters, reference choices, samplesheets), database lookups, `record.yaml`, the expiry file, local queueing and quoting | Pass |
| `test/lib/lib-test.sh`, `pipelines-test.sh` and `test/steps/steps-test.sh`, updated for picrust's values, `pplace/v1` and `code:` names | Pass |
| `test/helper/stub-test.sh` under `dash` and `bash`, with new checks: a stand-in with no environment, `apptainer`'s variables passed and quoted, other commands not getting them, a forged request refused; and `launcher-test.sh` | Pass |
| `test/steps/composition-test.sh`, 83 checks on the phase 1 outputs and synthetic additions; `test/present/present-test.sh` and `progress-test.sh`; and the three database script tests | Pass, as their notes above say |
| `gnoto lint` on the test bed's settings, then on a `config.yaml` with an unknown key, a section that doesn't exist, mode 664, a duplicate key the launcher and `yq` read differently, `job_time` over the partition's limit, `max_memory` written as `14GB`, a `core.nextflow_config` setting `params` and `cpus`, and an unreadable `slurm.conf` | Each reported, the last with the module hint. The compute node check ran as a Slurm job |
| `lint --yes` on a job naming a missing fixture, a second `lint`, and `start` | The fetch ran as job 109 and landed whole; the second `lint` reported "being fetched by job 109"; the job was submitted with `afterok:109` |
| `cancel` on a queued job, as `bob` and as its owner `alice` | Both wrote the cancel file, the owner's also took the job out of the queue, and the followup recorded it as Cancelled |
| `scancel` on a running head job, and a job whose Nextflow failed on a bad parameter | Nextflow cancelled its queued task; the message gave the cause from Nextflow's log; history kept `error.txt`; the failed run kept its logs and task scripts only |
| `job.sh --small --cancel` under Slurm and without it: `gnoto cancel` on a running job | Pass both ways: Cancelled, no task left, an error summary in history, task outputs gone at once. The first try ran on, because the job handed the watcher `$BASHPID` inside the `&` command, which is the watcher's own PID, so it stopped itself |
| The pak-built `gnoto-rbiom` with rbiom 4.0.0: `composition-test.sh`, then `job.sh --small` under Slurm | Pass: 83 and 18 checks, with no R warnings |
| `gnoto start --debug` under Slurm | Completed, with the work directory and staged reads kept, and `cleanup_utc` 14 days out beside `remove_utc` in the expiry file |
| ampliseq on `16s-v4` with the full pplace reference | EPA-NG was killed for memory at the test bed's 14 GB cap, which the run reported with the task's `.command.err`. The cluster's nodes have room |
| `test/testbed/checks/job.sh --small` under Slurm, as `alice`, and without Slurm, as `bob` | Pass both ways, 18 checks each: Completed, the dashboard, no network loads from gnoto's pages, the feature table (22 ASVs), the zip, the published job file and record with checksums, batch and primers and no site path, cleanup, history, expiry a month out, group-writable, listed by `status`. About 8 minutes each |
| The command line, after phase 3: `job-test.sh` with `gnoto new`'s values (a space and `=` in one, the space form, an empty value, a relative samplesheet, options and parameters typed) and refusals (an unknown key, a section option without its section, another pipeline's key, an unknown parameter, a word for a number, a value not offered, a key with no value or a value starting with `--`, a key given twice, a single dash); `lib-test.sh` with `gnoto config`'s arguments and refusals; `launcher-test.sh` with `gnoto init`'s, in `debian:13-slim`, since neither the image nor the test bed has `dash` | Pass: 74, 58 and 42 checks |
| `config.sh` on its own install, now with `gnoto config slurm --max_cpus=4 --max_memory=14.GB --max_time 4.h` off a terminal, an unknown setting, and a `globus` section added from arguments | Pass, 28 checks |
| A fresh install set up with no prompt by `gnoto config core --data_dir=… --db_dir=…`, `gnoto config apptainer --binds=…` and `gnoto config slurm --max_cpus=4 --max_memory=14.GB --max_time=4.h`, then `job.sh --small`, which writes its job file with `gnoto new` and runs it with `gnoto start`, under Slurm and after `gnoto config slurm --off`; then `job.sh --small --cancel`, which runs that file with `gnoto run`, without Slurm | Pass: 19 checks each way, the job file in history naming the samplesheet in full, and the cancel's 5 |

The test bed's node can't hold EPA-NG on the full pplace reference, so its end-to-end runs use
`db:test/pplace-small`, 2,000 tips cut from it with gotree, made by hand there.

**On the cluster, 2026-11-07,** from its install, a git clone, with the gnoto and `gnoto-rbiom`
images copied over by `scp`:

- `./gnoto lint` passed every check, the compute node job included.
- The first `bash test/testbed/checks/job.sh` fetched the pplace and 16S references as Slurm
  jobs through `lint --yes`, then stopped at `sbatch`: `slurm.job_time` was `48.h`, which
  `lint` had read but `sbatch --time` refused. `c4289c3` now turns Nextflow's form into
  Slurm's, has `lint` and `start` refuse anything else, and stops `job.sh` when `start`
  fails.
- `test/testbed/checks/launcher.sh` passed, its new checks included: C.UTF-8 takes effect,
  and the clock is UTC under the host's Central time. It listed the image's environment by
  reading `env` line by line, so `GNOTO_BOOTSTRAP`'s lines looked like variables of their own;
  it now lists names with `compgen -e`.
- `job.sh` ran ampliseq on `16s-v4` to Completed with the full pplace reference, and passed
  all 18 checks. `job.sh --cancel` passed.

Then taxprofiler and biobakery, against the old shotgun databases, linked into gnoto's
database directory, whose relative paths match, with `apptainer.binds` set to the old
directory so containers can follow the links. `lint` found all 6 and all 7. Each ran one
job on the `wgs-mock` reads from ENA:

- biobakery completed in 22 minutes, with every page, the methods page and a 7.3 MB zip.
- taxprofiler failed after 6 minutes, in `TAXPASTA_STANDARDISE` on MetaPhlAn's profile:
  taxpasta 0.7.0 reads the four columns `-t rel_ab` writes, not the fifth that
  `-t rel_ab_w_read_stats` adds. The old config let `TAXPASTA_MERGE` fail on MetaPhlAn,
  because nothing reads that table, but a run of one sample standardises rather than merges.
  `pipelines/taxprofiler/resources.config` now lets either fail on MetaPhlAn.
- That run's message had no cause, because a run that lets its other tasks finish logs no
  "Session aborted", and `status` showed the end of `.command.err`, which was pandera's
  warnings alone. Both now come from Nextflow's report on the failing task.
- taxprofiler's rerun with that fix failed before taxpasta: its mOTUs and Kraken2 tasks,
  the two that ask for 16 CPUs, were put on a node without the `/data` mount and failed
  within a second, with no log. Nextflow called them "terminated by the external system",
  and `sacct` showed `FAILED` with exit code `0:53`. That node is the only one missing the
  mount. gnoto now names the node when a job dies at launch, as the design's notes on jobs
  that die at launch say, and `lint` checks every node over `ssh`, which the cluster
  allows without a password, or with a Slurm job on each node with CPUs free where `ssh`
  can't. In the test bed, the `ssh` check passed through the helper with `bash` and with
  `tcsh` as the login shell, and without `ssh` it fell back to the Slurm jobs. gnoto's
  jobs now avoid such a node: one that fails `lint`'s check, or that a job died at launch
  on, goes on `<data_dir>/excluded-nodes`, and every job gnoto submits, and each of
  Nextflow's tasks, excludes it until `lint` finds it working. In the test bed, with a
  down stand-in node on that list, a whole ampliseq run's head job, followup and tasks
  carried it in `ExcNodeList`, and `sbatch` refused a name Slurm doesn't know, which is
  why only the listed nodes Slurm still has are passed. Since then, `start` asks the nodes
  over `ssh` before each job, `gnoto config slurm --probe` checks every node with a Slurm
  job, waiting for busy ones, and every check also wants `slurm.min_tmp`, 50 GB by default,
  free in a node's `/tmp`. In the test bed, the probe waited 75 seconds for a busy node and
  then passed it; the check before a job ran over `ssh`, with `bash` and with `tcsh` as the
  login shell, and said nothing without `ssh`; and a `slurm.min_tmp` larger than the node's
  `/tmp` put the node on the list, so `start` refused, until `lint` found it working
  again. A head job that does run checks
  that it can see `core.db_dir` when it needs databases, and a job waiting on a failed
  fetch is cancelled rather than left queued. `scheduler_job_state` now asks `squeue` with `-t all`, without which
  a job that had just ended showed no state where Slurm has no accounting.

**On the cluster again, 2026-11-08,** from `d2241b0`, after the cluster's admins had fixed
the node without the mount:

- `./gnoto lint` checked every node over `ssh`. The 8 taking jobs passed: each sees the
  data and database directories, `flock` works there, and `/tmp` has 50 GB free. The one
  that was down was skipped. `gnoto config slurm --probe` passed the same 8, with a Slurm
  job on each. No node failed, so `excluded-nodes` was never written. Excluding a node has
  been tested only in the test bed.
- `job.sh` ran ampliseq on `16s-v4` with the full pplace reference to Completed, and passed
  all 18 checks.
- biobakery and taxprofiler were started together with
  `gnoto start <pipeline> --title=… --samplesheet=mock.tsv --retention="1 Month" --yes`, on
  the full `wgs-mock` reads. Before each was submitted, the check over `ssh` found all 8
  nodes fit. Both completed in about 20 minutes:
  - biobakery's zip was 7.3 MB;
  - taxprofiler's was 278 MB, because it holds the reads.

  So taxprofiler now passes on the cluster too, with `b75a454`'s change to taxpasta.
- gnoto can't fetch the `wgs-*` fixtures until phase 6, which cuts them to 100,000 reads.
  So a samplesheet naming `fixtures/wgs-mock/v1` fails `lint` because the files don't
  exist, and `--yes` can't help. These runs used the full reads, downloaded by hand.

### Phase 4: version cache

Settled with Daniel before building (2026-11-08), as [decisions.md](decisions.md) records:
until the first release, `current` names a commit of `main`; a git clone install works as a
tarball install does, with `gnoto upgrade` in place of `git pull`; and the floor is a
`COMPAT` number in each commit, 1 from phase 4.

What's built:

- **The launcher** has two roles. The install directory's copy reads its bootstrap
  settings, then hands every command to `<data_dir>/versions/<current>/gnoto` with
  `GNOTO_INSTALL_DIR` set, except under `--dev`, which runs the install's own files. When
  the current version has no copy yet, the install's own files fetch it first, with
  `_current`, which on the first command makes a release's or a clone's own commit current.
  A copy in `versions/`, handed a command, runs it in its own image with the install's
  `config.yaml`, binding both directories. After the image exits, it acts on a hand-over in
  its private directory: the commit, and `resolved`, `current` or `lint`.
- **`lib/versions.sh`** resolves a version with `git ls-remote` (a release `1.2.0` is the tag
  `v1.2.0`, a branch or tag by its name, a full commit as it is), fetches a commit into
  `repo.git` under `refs/gnoto/`, checks its `COMPAT`, extracts it read-only with a
  `VERSION` naming its commit and repository, and hands a command over. It holds `upgrade`,
  `prune` and `_current`, the cache lock, and the lint warnings for a moving branch and a
  commit no release or `main` reaches. `code_version` moved here: only a copy in the cache
  has a commit, and everything else is dev.
- **Jobs at their own version.** `new`, `start`, `lint` and `run` route to the version the
  job names before checking anything, and `new` pins that version's commit. A Slurm job's
  `--wrap` sets `GNOTO_INSTALL_DIR` and names the submitting version's launcher, and a job
  on this machine inherits both, so a job and its followup keep their version after an
  upgrade. The head job records its image and code directory in the run's state, and the
  followup its code directory.
- **`gnoto run --inputs=<dir> record.yaml`** re-runs a record at its commit. `job_check`
  takes a record as a job file: its own keys are allowed, its section is the parameters,
  passed as they are, and its measured options are answers. Its inputs are found under the
  directory by size, and by checksum only where sizes are shared. The head job checks every
  checksum against the record's, and ampliseq's samplesheet step keeps each sample's
  recorded batch.
- **`gnoto resume [uid]`** lists the runs it can resume, or checks one and hands it to the
  run's own commit, which records the attempt that ended in `attempts` and submits the run
  again. The head job checks the inputs against the first attempt's checksums, skips the
  pre-process steps that finished, checks that the parameters come out the same, and runs
  Nextflow with `-resume` and the session ID of its earlier run, from `.nextflow/history`.
  taxprofiler's HUMAnN step resumes its own session the same way. A failed or cancelled run
  now keeps `work/`, `.nextflow/` and its staged inputs until `cleanup_utc`.
- **`gnoto upgrade [--yes] [version]`** and **`gnoto prune [--yes]`**, as
  [design.md](design.md#versions-and-the-code-cache) describes. `prune` keeps any version used
  in the last hour, and every `.sif` until phase 5, because a local `.sif` can't be pulled
  again.
- **The test bed** has a repository of its own, `/tmp/gnoto.git`, which `testbed.sh repo`
  makes from this repo's `main` and `testbed.sh commit` adds the working tree to, as a test
  commit that goes nowhere else. `testbed.sh install` is now a clone of it at that commit,
  made current in the install's data directory. It's in `/tmp` because Apptainer binds `/tmp`
  by default, so even an install without `config.yaml` can fetch from it. The test bed's
  container gained `git-core` for this, and `checks/versions.sh` is phase 4's finish test.

Tested on 2026-11-08, in the test bed, under Slurm unless it says otherwise:

| Test | Result |
| --- | --- |
| `test/lib/versions-test.sh`, against a `file://` repository of its own: repository URLs, resolving releases (annotated and lightweight tags), branches, tags and commits, refusing short commits and unknown names, the newest release, fetching with the `COMPAT` floor (a commit from before the version cache, and one below this version's number), read-only files and group-writable directories, which a release or `main` reaches, the code's own version, `current`, handing a command over, `upgrade` (newest release, going back, a branch, refusing without `--yes` or a terminal), `prune` (the current version, a running job's, one used in the last hour, renaming before deleting), a record's inputs by size and checksum, a record checked as a job file, its parameters as they are, inputs against their checksums, Nextflow's session, what a failed run keeps, which runs can be resumed, and a Slurm job's `--wrap` | Pass, 95 checks |
| `lib-test.sh`, `pipelines-test.sh`, `job-test.sh` and `steps-test.sh`, through `gnoto exec --dev` | Pass: 60, 21, 141 and 15 checks |
| `test/helper/launcher-test.sh` in `debian:13-slim` under `dash`, with new cases: no current version (the install's files run `_current`, or `upgrade` itself), a hand-over with and without a copy to run, every command going to the current version but `--dev`, `gnoto exec --dev` only as its first word, a resolved hand-over, `lint` after `upgrade`, refused hand-overs, and a cached launcher binding the install and its own code and passing `GNOTO_IMAGE` and `GNOTO_RESOLVED`; and `stub-test.sh` | Pass |
| `test/testbed/checks/versions.sh --small`, phase 4's finish test, as `alice`, with three commits: A, the install's; C, naming another `.sif` in `IMAGE`; and B, `main` moved on | Pass, 61 checks in 30 minutes. A job at C ran in C's image, its head job and followup from C's copy. After `gnoto upgrade` with no version went to `main` (B), C's `record.yaml` re-ran with `--inputs` from files of other names and paths, found by size: at C, in C's image, with the record's parameters and batch, and core tables (`ASV_table.tsv`, `DADA2_table.tsv`, `ASV_seqs.fasta`) byte-identical. A job at B kept B's code, head job and followup, through `gnoto upgrade` back to A, and `prune` kept A and B and removed C, keeping its `.sif`; naming C again fetched it again. A job at A, its head job cancelled in Slurm once 8 tasks had finished, ended as Failed with `work/`, `.nextflow/` and its staged inputs kept; after an upgrade to B, `gnoto resume` ran it at A, skipped its samplesheet and region steps, resumed its Nextflow session with all 8 tasks cached, and completed with the same core tables. Run again on the final tree: 61 checks, with 9 of 9 finished tasks cached |
| `checks/launcher.sh` and `cancel.sh` as `alice`, `job.sh --small --cancel` (now checking that a cancelled run keeps its work directory and that `gnoto resume` lists it), and `config.sh` on a copy with no `config.yaml`, now first checking that its first command makes the clone's commit current | Pass: 20, 3, 7 and 30 checks |
| `job.sh --small` without Slurm, as `bob`, on that copy, its job detached on this machine by the version's own launcher | Pass, 19 checks, on the second try, below |
| Nextflow on a workflow in a read-only copy in `versions/`, as biobakery's runs | Pass, with the test bed's `sleep.nf` |

Not yet run: biobakery and taxprofiler from the version cache.

**On the cluster, 2026-11-08,** from `507ebc8`, the install's clone pulled to it, with the
same image as phase 3:

- `./gnoto lint` ran from the copy in `versions/`, naming `507ebc8`, fetched from
  `https://github.com/cmmr/gnoto`, as the current version, and passed every check: the 8
  nodes taking jobs passed the node check, and the one that was down was skipped.
- `job.sh` ran ampliseq on `16s-v4` with the full pplace reference to Completed from the
  version cache, and passed all 19 checks.
- `versions.sh --resume` passed all 19 of its checks: a run cancelled in Slurm once 8 tasks
  had finished ended as Failed with its cache kept, and `gnoto resume` ran it at its own
  commit to Completed, with all 8 tasks taken from the cache and its samplesheet step not run
  again.

Found on the way: the pages' stylesheet and fonts were copied from the code with their
modes, so from the read-only cache the progress page's copy blocked Present's, and the first
run at a cached version ended as "Publish failed". They're copied without their modes now.
A record checked as a job file had its own keys refused as unknown options, a `jq` scoping
slip. `git ls-remote` given a tag's name doesn't list the commit an annotated tag points at,
so gnoto lists every branch and tag and picks. Without Slurm, `job.sh` once stopped waiting at
once, having seen a final status, though its job ran on to Completed. The likely cause, as
old as phase 3: `_local` wrote the job's host and then its process ID, and `status` read
between the two writes says Lost. They're written together now, and the rerun passed.

Afterwards, at Daniel's request, `conf/` moved into `pipelines/`, so that `config.yaml`
tab-completes from `c`: each pipeline's `resources.config` into `pipelines/<name>/`, and
`databases.yaml` and `references.yaml` into `pipelines/`.

### Phase 5: lock files

Settled with Daniel before building (2026-11-08), as [decisions.md](decisions.md) records: CI
publishes the images gnoto builds to GHCR whenever a push to `main` changes a recipe, and the
workflow went to `main` on its own first; and the shotgun databases are fetched fresh on the
cluster with gnoto's own fetchers, whose manifests give the lock files their digests.

What's built:

- **GHCR images.** `.github/workflows/images.yml` runs `images/publish.sh`, which builds gnoto
  with Nix and `gnoto-rbiom` with Docker, copies the images `images/mirrors.txt` lists, and
  pushes each to `ghcr.io/cmmr/`. An image's tag is the first 12 characters of its recipe's git
  hash, so a recipe already published is left alone. skopeo runs from its own image, v1.22.3 by
  digest. gnoto's digest is learned from a local registry first, and a tag that already holds
  another digest fails the run, as a build that no longer reproduces. Both recipes carry the
  `org.opencontainers.image.source` label, which links a package to this repo. The first run,
  on `2beb27c`, published all three, and they were public from the start. `IMAGE` names
  `docker://ghcr.io/cmmr/gnoto@sha256:c7129468…`, and both locks name
  `ghcr.io/cmmr/gnoto-rbiom@sha256:533e61f1…`.
- **Image identity.** The Nix tarball rebuilds byte for byte, and pushing it with the pinned
  skopeo gives the same digest every time: twice here, into an empty registry each time, and
  once from GitHub's runner, which published the same `c7129468…`. Copying Wave's image with
  `--preserve-digests` keeps its digest.
- **`containers.config`.** `pipelines/lock.sh containers <pipeline>`, run through
  `gnoto exec --dev`, fetches the pinned upstream, reads each process's Docker-style address
  and every alias it's included under, asks the registry for each address's digest, and
  writes a `withName` selector for each name and alias, with the tag in a comment. An address
  with no registry takes the pipeline's `apptainer.registry`, quay.io for both. ampliseq's has
  184 names and aliases in 41 images, and taxprofiler's 74 in 37. Every module at both pinned
  commits has exactly one address that can be read, none built from an expression, and every
  one is in its registry. Under `-profile apptainer`, ampliseq's modules named `https://`
  Singularity files; now its tasks run OCI images that Apptainer pulls by digest, but for one
  kind. The first run in the test bed stopped at `DUCKDB_TABLE2PARQUET`, exit 127,
  `duckdb: command not found`: Seqera's pixi-built images put their tools on `PATH` only in
  their entrypoint, `/shell-hook.sh`, which `apptainer exec` never runs. Their older
  micromamba-built ones, such as DADA2's, set `PATH` in the image's configuration and run
  fine. So a process whose image is pixi-built takes its module's own file for Apptainer,
  which Seqera serves at a path naming its SHA-256, and `lock.sh` checks each one against it:
  in ampliseq, 5 images in 14 selectors, among them MultiQC and `FORMAT_TAXONOMY`; in
  taxprofiler, none. The `check` also fails on any image by digest that would need its
  entrypoint.
  `pipeline.sh` passes the file with `-c`, after `resources.config`, as `lock.yaml`'s
  `nextflow_containers` names it.
- **gnoto's own modules** name their images by digest, with the tag in a comment after it, which
  the biobakery methods page reads. Host depletion uses the GHCR copy of Wave's bowtie2 image.
- **The CI check.** `.github/workflows/checks.yml`, on every push and pull request, runs
  `pipelines/lock.sh check` in the image `IMAGE` names. `IMAGE`, each Dockerfile's `FROM`, every
  lock's step images, every `containers.config` and gnoto's own modules must name their images
  by digest, each in its registry, and each `containers.config` must match the modules at its
  pinned commit, selector for selector and tag for tag.
- **Database digests.** Each `lock.yaml` has `databases`, keyed by `db:` name, with `files`,
  `bytes` and `tree_sha256`, which `lock.sh databases <pipeline>` writes from the manifests in
  `core.db_dir`. `lint`, `run` and `start` compare each pinned database's file count and bytes,
  following links, and so does the head job, and each fails on a mismatch. `lint --deep`, and
  the head job of an exact re-run, compare its tree digest as well. A `db:` name no lock pins,
  such as a site's own database or the test bed's `db:test/pplace-small`, gets a warning, and
  the record keeps its file count and bytes, which an exact re-run then checks. `record.yaml`
  gains `databases`, before `outputs`. biobakery has a `lock.yaml` for its databases.
- **Shotgun fetchers.** `steps/fetch_shotgun_db.sh` ports `fetch_taxprofiler_db.sh` for
  Kraken2, MetaPhlAn, mOTUs, HUMAnN, EsViritu and Marker-MAGu, and
  `steps/build_host_reference.sh` ports the host builder, which builds in the images
  taxprofiler's lock pins for it. Both fill the directory the fetch job gives them and write a
  manifest. Every download's md5 and size is in `pipelines/databases.yaml`, 162 GB in all:
  from Zenodo's API, the `.md5` files MetaPhlAn and Kraken2 publish beside their archives, and
  NCBI's `md5checksums.txt`; and for HUMAnN's three archives and the MetaPhlAn tree, which have
  none, from the files as fetched on 2026-11-08. The tree's matches the md5 the old script
  pinned on 2026-09-04. The host references are versioned as `hostremoval/<name>/v1`, holding
  `<name>.fa`, `<name>/` and `<name>.mmi`. An entry's `fetch_job` sets its fetch job's CPUs,
  memory and time. The sewage reads stayed behind, since the fixtures cover them. `lbunzip2`
  copies the archive's owner and group onto what it writes, which fails where the image's user
  namespace doesn't map them, so MetaPhlAn's index decompresses through `lbzcat`.
- **`prune`** removes every image file in `images/` that no version it keeps names, by the file
  names gnoto, the step images and Nextflow each give them, except a local `.sif` a version
  names and anything pulled in the last hour. A version from before the lock files named its
  task images by tag, so they're pulled again if it runs.
- **Found on the way.** The methods page looked a database up by its entry's own path only, so
  mOTUs' `db:motus/db_mOTU_v3.1.0/db_mOTU` was named by its folder, with a warning. A name inside
  an entry now finds the entry. `read` collapses an empty field between two tabs, which first
  shifted the head job's database entries into the wrong variable; the field that can be empty
  now comes last.

Tested on 2026-11-08 and 9, in the test bed and in Docker:

| Test | Result |
| --- | --- |
| `images/publish.sh` against a local registry, for gnoto, `gnoto-rbiom` and the mirror, each run twice | Pass: the second run of each left its tag alone. gnoto's tarball pushed with the pinned skopeo gave `sha256:c7129468…` each time, into an empty registry too, and CI's run on GitHub's runner published the same digest |
| `pipelines/lock.sh check`, as CI runs it, in the gnoto image | Pass, 87 images, in about 4 minutes. On a copy of the tree with an image by tag in `IMAGE`, a module, a lock and a `FROM`, a digest the registry hasn't got, a `containers.config` missing a selector, and a selector swapped to another image, each failed, named |
| A first command on a new install, pulling the gnoto image from GHCR | 2 minutes 51 seconds, fetching its version included |
| `gnoto lint --yes` fetching SILVA, `pplace/v1` and `16s/v1` into an empty database directory | Each landed with its manifest. `pplace/v1` and `16s/v1` have the same tree digests as the test bed's builds of 2026-11-06, so both builders reproduce |
| `test/lib/job-test.sh`, with new checks: the tree digest a manifest records, a database matching its lock by size and by digest, a byte added, the same size with other bytes (passing by size, failing by digest), an unpinned name measured, `lint` and `lint --deep` on each, the head job's entries, an exact re-run failing on a changed unpinned database and on a digest, and the record's `databases` | Pass, 161 checks |
| `lib-test.sh`, `pipelines-test.sh` (the versioned host paths), `versions-test.sh` (`prune` keeping and removing image files by the names each puller gives them) and `steps-test.sh` | Pass: 60, 21, 98 and 15 checks |
| `test/steps/fetch_shotgun_db-test.sh`: each of the six databases from fake archives as `file://` URLs, and a wrong md5, a Kraken2 file its list disagrees with, a MetaPhlAn tree of 2 tips, a missing mOTUs file, a ChocoPhlAn file of no version and an archive of another release | Pass, 22 checks. The first run found `lbunzip2` failing on ownership in the image's user namespace |
| `test/steps/build_host_reference-test.sh`: PhiX built twice for real, then from a download with one base changed | Pass, 11 checks: the two builds identical, with the GHCR copy of Wave's bowtie2 image and minimap2, both by digest |
| `test/steps/composition-test.sh`, with `gnoto-rbiom` pulled from GHCR by digest | Pass, 84 checks |
| `test/testbed/checks/digests.sh --small`, phase 5's finish test, as `alice`: ampliseq on `16s-v4` with `--debug`, without any of its task images, then its record re-run with `--inputs` after removing every image the job pulled | Pass, 22 checks. The job pulled 17 images, every one by digest: 13 task images by registry digest, the 3 Apptainer files it needed by SHA-256, and vsearch for region detection; every task's script named its image so. `lint --deep` passed on the job file and on the record. The re-run pulled 16 of them again, all by digest, without vsearch, since an exact re-run reuses the recorded region; checked SILVA, the one pinned database it read, by its tree digest; and gave byte-identical core tables. 7 minutes each, with Apptainer's layer cache warm |
| `digests.sh --small` again, once it removed only the images its own job's tasks ran in (below) | Pass, 19 checks: 16 task images in each run, every one by digest and pulled during that run, and the re-run's a subset of the job's |

**On the cluster, 2026-11-09,** from its clone, with Slurm's module loaded:

- `./gnoto upgrade --yes` to `713cf27` took 34 seconds, including the first pull of the gnoto
  image from GHCR, by digest, and the new version's `lint`.
- `gnoto lint --deep` on an ampliseq job found the cluster's SILVA, `pplace/v1` and `16s/v1`
  byte-identical to the test bed's, which ampliseq's lock pins: the reference builders
  reproduce across sites.
- The links to the old shotgun databases moved aside, and `gnoto lint --yes` on taxprofiler
  jobs for each host, and a biobakery job with EsViritu, fetched all nine fresh as Slurm jobs.
  Every one landed whole with its manifest: PhiX in a minute, the human and mouse references
  in about 20 minutes each with 16 CPUs, mOTUs, EsViritu and Marker-MAGu within 25 minutes,
  HUMAnN in an hour, MetaPhlAn in 80 minutes and Kraken2, a 91 GB download, in 95. `lock.sh
  databases` then wrote their digests into the taxprofiler and biobakery locks, in `b4d5686`.
  The test bed's own PhiX build, with 6 threads, has the same digest as the cluster's, with 2.
- Doing that found a bug from phase 3: biobakery's `pipeline.sh` decided whether to name
  EsViritu's database before the job's own `run_esviritu` was applied, so turning EsViritu on
  named no database. It now reads the job's parameters, as ampliseq's does for `primer_fwd`,
  in the same commit.
- The first round's jobs died at launch on a node that had come back from repair unable to
  reach `/data`, and that refused ssh. gnoto named the node and excluded it, as phase 3 built.
  At Daniel's call, a node ssh can't reach while it reaches the others now fails the node
  check too, in `9fbec38`. ssh's messages also ended in a carriage return, which garbled
  `lint`'s line about such a node; it's taken out.
- `test/testbed/checks/digests.sh`, the finish test, passed at `9fbec38` with the full
  pplace reference: the job and its record's re-run each pulled every image by digest, with
  `lint --deep` passing on both and byte-identical core tables.
- That run removed, before its re-run, every image pulled since its job began, so it also
  took the HUMAnN image that taxprofiler and biobakery, running beside it, had just pulled,
  and their HUMAnN tasks failed on the missing file. The check now removes only the images its
  own job's tasks ran in.
- taxprofiler and biobakery, run again at `9fbec38` with the fresh databases, both completed,
  HUMAnN included, in 21 and 20 minutes, from the version cache, with every database the lock
  pins and every image by digest: the 11 images the two pulled anew, HUMAnN's among them, are
  each named by digest, as are the 25 the first round pulled. So phase 5 is done, and
  biobakery and taxprofiler have run from the version cache, which phase 4 left for later.

### Phase 6: determinism

Settled with Daniel before building (2026-11-09), as [decisions.md](decisions.md) records:
phase 1's two probes run on gnoto rather than on the old code.

What's built:

- **Fixtures.** `steps/fetch_fixture.sh` makes the fixtures that aren't used as
  downloaded, as [fixtures.md](fixtures.md) says: each `wgs-*` file cut to its first
  100,000 reads, and `16s-v5v6` converted from NCBI's `.sra` file, each recompressed with
  `gzip -n`. sra-tools 3.4.1, the latest, segfaults reading that file, in both its builds,
  so ampliseq's lock pins 3.2.1, which converts it offline in seconds. A samplesheet file
  in `core.db_dir` is now one of the job's databases, so `lint --yes` fetches a missing
  fixture as it does a database, and `lock.sh databases` pins the fixtures each
  pipeline's selftest runs on.
- **Seeds.** Nonpareil takes `-r` from a new `nonpareil_seed` parameter, 42. Its help says
  only alignment mode uses it, and it's so: in k-mer mode, which both shotgun pipelines run,
  two runs of 100,000 PhiX reads gave curves about 1% apart, with or without it. In
  alignment mode with the seed, two runs at 2 threads were byte-identical and one at 1
  thread wasn't, and it took 61 seconds where k-mer mode took a few. Daniel kept k-mer mode
  (2026-11-09), so `stable-files` gained `drop`, which leaves Nonpareil's six columns out of
  `alpha_diversity.tsv`'s checksum and comparison.
- **Core tables.** `pipelines/<name>/stable-files` lists them, with `sort` and `strip` for
  tables whose rows or timestamps vary. At the end of Compute the job writes their
  checksums to the record's `outputs`, of the tables as Present will publish them, as the
  first selftest, below, showed they must be. An exact re-run copies the tables beside its record
  whose checksums are the record's into `recorded-outputs/`, compares its own with the
  record's at the end of Compute, and says how in its notes, its state and `status <uid>`,
  with the numeric comparison, `compare_tables` in `lib/outputs.sh`, for any that differ.
- **`gnoto selftest [--dev] [--yes] [pipeline ...]`,** in `lib/selftest.sh`, as
  [design.md](design.md#what-same-output-means) describes: `pipelines/<name>/selftest.yaml`
  lists the jobs, and `pipelines/<name>/selftest/<job>/` holds the reference tables, from
  the cluster's first selftest. The report job is `_selftest`, which the launcher now starts
  on this machine too.
- **Fetching a pipeline once.** Two runs of a pipeline new to a data directory, started
  together, both fetched it, and one failed with `LOCK_FAILURE` from Nextflow, as a
  selftest's would. The head job now fetches the pipeline's commit under a lock first,
  unless it's there.
- **The test.** `test/testbed/checks/repeat.sh` runs each fixture job of a pipeline twice,
  and once more from another install whose `slurm.max_cpus` differs, and
  `classify-outputs.sh` sorts every file the three made into stable, varying with CPUs,
  unstable, or missing, saying whether sorting its rows or dropping its dated lines makes
  it match. `checks/determinism.sh` is the finish test, and `checks/selftest.sh` tests
  `selftest --dev`.
- **Found on the way.** `gnoto new --dev`, which the design lists, was refused, because
  `new` didn't take the flag the launcher acts on. Several runs at once on the test bed's
  one node can hold all its CPUs in head jobs, so their tasks never start.

Tested on 2026-11-09, in the test bed:

| Test | Result |
| --- | --- |
| ampliseq on `16s-v4`, with `db:test/pplace-small`, twice at `slurm.max_cpus` 4 and once at 2, sorted by `classify-outputs.sh` | 120 files identical in all three, every core table among them. Only cutadapt's two logs vary with CPUs, as they print the count. Varying between the two runs at 4: the placement trees, whose ASVs placed on one edge with no length come in another order, and the jplace file's placements, the same ones in another order, which EPA-NG's threads decide; the BIOM files' timestamps; the PDFs; and the pages, record and job file, which name the run's title, different in each |
| `test/lib/outputs-test.sh`: core tables by glob, `sort`, `strip`, `drop` and gzip; the comparison, with rows by key, repeated keys, CSV, a FASTA, text cells and an empty table; two runs' outputs; the sentence and `status` lines; keeping a record's tables | Pass, 32 checks. The first run found a table only one run had reported as missing, because `read` collapses an empty field between two tabs |
| `job-test.sh`, with new checks: a samplesheet naming a missing fixture's files fails only on the fetchable fixture, a file in the database directory with no entry still fails, the files are the job's databases, and the fixtures' setups | Pass, 173 checks |
| `lib-test.sh`, `pipelines-test.sh`, `versions-test.sh`, `runs-test.sh` and `steps-test.sh` | Pass: 66, 24, 98, 75 and 15 checks |
| `steps/fetch_fixture.sh` on `wgs-phix`, and twice on `16s-v5v6`; then all 13 fixtures through the fetch job, two of them from `lint --yes` on a job naming them | Each landed with its manifest. `16s-v5v6` gave the same tree digest all three times, and `wgs-phix` twice. Every `wgs-*` file holds 100,000 reads, or `wgs-ont`'s 29,000, and `16s-v5v6` 236,666 pairs. `lock.sh databases` then pinned all 13 |
| `test/testbed/checks/determinism.sh --small`, the finish test | Pass, 17 checks: the re-run of the record reported all 27 core tables identical, and `lint --deep` passed on it; the re-run of a copy with one count raised by one reported that table's largest relative difference, 1 in 14,186, at its row and column with both values, and the table whose checksum alone changed as differing with no copy to compare |
| `test/testbed/checks/selftest.sh --small`: `selftest --dev` on a copy whose ampliseq selftest is the `v4` job, with no reference tables, then against the tables that run made, committed to the test bed's repository | Pass, 14 checks: the refusals; a report against `main`'s tip, the run's 27 tables kept, the run removed with its history kept and no expiry, and `status` listing the selftest; then all 27 tables identical to the reference |
| `pipelines/lock.sh check` | Pass, 88 images, sra-tools 3.2.1 among them |

**On the cluster, 2026-11-10,** from `86eecb7`, on a queue busy with other work: the first
`determinism.sh` gave up on its first run after two hours, still running, and went on
through the checks that read its results. It now waits for as long as a run takes, since
`status` says Lost when nothing runs for one, stops at a run that doesn't complete, with its
message, and takes `--from=<uid>` to carry on from a run it started before. The last of
those checks, `gnoto run --inputs` on a record it couldn't read, called the record a job
file; `run` now says that only of a file it read.

The second probe answered: `steps/build_host_reference.sh` built `hostremoval/chm13v2phix/v1`
again as a Slurm job with 8 CPUs, against the 16 its fetch had, its indexes in 25 minutes, and its tree
digest is the lock's, `cc5b3104…`. So the host references rebuild identically at any CPU
count, as PhiX had, and none needs depositing on Zenodo.

The first round of `repeat.sh` found that ampliseq's `single` job, on `16s-single`, fails
every time: "Barrnap could not identify any rRNA in the ASV sequences". ampliseq runs Barrnap
with `--reject 0.1`, and its 13 ASVs of 149 and 151 bp align about 9% of 16S, so none counted,
and with `filter_ssu` set ampliseq stops the run. The test bed showed the same. At 0.08 or
0.05, 12 of them were found as bacterial 16S, with e-values near 1e-29, and V4's 22 ASVs
were found at either. At Daniel's call, `pipelines/ampliseq/resources.config` keeps
`--reject 0.1` for paired reads that merge, the usual run, and passes `--reject 0.05` for
any other, reading `sequencing_type` and `mergepairs_strategy`, and the filter stays on. The job then failed at the next
check: region detection had given it a length window around V4's 253-base amplicon, which
reads of 151 bases can't span, so the length filter removed every ASV. Where single-end reads
end before the amplicon does, `steps/ampliseq_detect_region.sh` now sets no window, and its
report says why. With both, the job completed in the test bed, with 12 of its 13 ASVs kept.
So no short single-end 16S run had worked, in the old code either, which had both.

Running ampliseq's other fixture jobs in the test bed then found one more: `v3v5`, whose
pairs are joined end to end with 10 Ns, failed in DADA2's exact species match, which refuses
any base that isn't ACGT ("Non-ACGT characters present in the query sequences"). At Daniel's
call, a job with `mergepairs_strategy` `concatenate` or `consensus` skips that match. Then
all six completed in the test bed, with `db:test/pplace-small`: `v1v3`, `v3v5` with 276
ASVs, `v5v6`, `single` and `ont`, and `v4` as before.

The rest of the first round, at `2600665`, with each job twice at 32 CPUs and once at 8:

- **Four runs never started.** Jobs started together each submitted a fetch of the same
  fixture, and a second fetch failed after 60 seconds waiting for the first's lock, so every
  job waiting on it was cancelled: taxprofiler's `mouse` and its `human` at 8 CPUs, and
  biobakery's `human` and `mouse`. A fetch now waits for the lock for as long as its job may
  run, then finds the entry there; two fetches of `16s-single` at once in the test bed both
  succeeded, with the lock's tree digest.
- **taxprofiler's `mixed` failed in MetaPhlAn** on `wgs-phix`: "no reads longer than 70 bp
  found". At Daniel's call, that fixture is now a job of its own, `phix`, and a follow-up,
  below, lets taxprofiler drop such a sample.
- **What repeated.** ampliseq's `v4`, `v1v3`, `v5v6` and `ont`, taxprofiler's `ont` and
  biobakery's `mixed` and `virus` completed three times each, with their core tables
  identical but for three values: Faith's PD in ampliseq's `alpha_diversity.tsv`, 10.64
  against 10.7 between the finish test's job and its re-run, since EPA-NG's placements on the
  full reference differed; DADA2's bootstrap confidences, by one or two replicates in `v1v3`
  and `v5v6`, with the same taxa; and one sum in HUMAnN's `pathway-abundance-rpk.tsv`, 3e-15
  apart. Each came from two runs at the same CPU count, and in the test bed DADA2's classifier
  gave the same output twice at 4 threads and twice at 1, so the likely cause is tasks
  landing on nodes of different CPUs, though the second round, below, found every node one
  CPU model, and two runs on one node differing. At Daniel's call, `stable-files` leaves Faith's PD and
  the confidences out and reads HUMAnN's tables at 12 significant digits, with a new `round`
  mode. EsViritu's assemblies repeat with their rows sorted, and Nonpareil's curves vary, as
  expected.
- Every pipeline now has its `stable-files`. The finish test passed but for Faith's PD, and
  the doctored record reported its changed count exactly.

**Dropping a nearly empty taxprofiler sample,** the follow-up, as
[decisions.md](decisions.md) records. `wgs-phix` is 2×50 bp PhiX, so after PhiX removal
the few reads left are all shorter than MetaPhlAn's 70 bp minimum. Each tool on such a
sample, run in its pinned image:

- **MetaPhlAn 4.1.1** exits 1 with "Error: no reads longer than 70 bp found.", run as the
  module runs it on a pair of 50 bp reads.
- **Bracken 3.1** exits 1 with "Error: no reads found. Please check your Kraken report" when
  no species has its 10 reads, which a blank whose reads Kraken2 can't classify, as on a
  one-species test database, won't. With 12 reads of one species it passed. Whether PlusPF
  places 10 of `wgs-phix`'s leftovers at one species decides whether it's dropped there too.
- **Kraken2, taxpasta's Kraken2 merge, Krona and HUMAnN** take it: Kraken2 writes a report
  with only its unclassified line, taxpasta merges it as a column of zeros, Krona draws
  nothing for it, and `taxprofiler_humann.sh` already skips a sample with no MetaPhlAn
  profile and says so in the run's notes. **Nonpareil** runs before host removal, on all
  100,000 reads. **mOTUs 3.1.0** only warns when no read maps, but needs its 7.7 GB database
  to run, so the cluster is its test.

So `pipelines/taxprofiler/resources.config` gives MetaPhlAn and Bracken an `errorStrategy`
that reads the task's `.command.err` and ignores the task when it holds that message, and
otherwise retries or finishes as taxprofiler's base config does. In
`nextflow/nextflow:26.10.5`, with the real `resources.config` and `scratch` on, stand-ins
under the two process names writing each message were ignored, and the merge after them
ran on the other sample. A different message stopped the run, and exit 137 was retried once.
`steps/taxprofiler_composition.sh` records as statistics the samples in the samplesheet the
plotted profiler has no report on, `samples_dropped`, and of the rest those without a
MetaPhlAn, mOTUs, Nonpareil or HUMAnN result, and `present/taxprofiler.sh` names them on the
Overview as biobakery's page does. A tool that profiled no sample names none, as MetaPhlAn on
a long-read run.

**A sample with no reads at all** after quality filtering and host removal, the second
follow-up, would still have stopped the run. In the pinned images, fastp exits 0 on it but
writes 0-byte files, not gzip, and FastQC exits 1 on those. bowtie2 reads them as 0 reads and
writes empty gzip files. Kraken2 writes an empty report, and taxpasta's Kraken2 merge, which
`resources.config` requires to pass, fails on that for every sample with "No columns to parse
from file". MetaPhlAn says "Error, input data has to be in fastq or fasta format", Bracken
fails on an `IndexError` and Nonpareil on "No reads found". samtools, MultiQC beside a sample
with reads, and FastQC on a raw empty gzip take it. So every step from FastQC on the processed
reads to the profilers gets an `ext.when` that skips a sample whose files are all 0 bytes or
gzip that decompresses to nothing, as [decisions.md](decisions.md) records. In
`nextflow/nextflow:26.10.5`, with the real `resources.config` after a config setting
`ext.args` and `ext.prefix` as taxprofiler's does, stand-ins under the six process names ran
on a sample with reads, one whose first merged run was empty, and one named `.gz` that isn't
gzip, and skipped an empty gzip, a 0-byte file and two empty runs merged, with `ext.args` and
`ext.prefix` intact. The closure is handed a `TaskPath`, whose `size()` works but whose
streams don't, so it opens `toRealPath()`; strict syntax has no `finally`, so
`withInputStream` closes the file. The composition step's read totals left out a sample whose
reads Kraken2 classified none of, so `wgs-phix` was missing from them; they now count every
sample with a report. `composition-test.sh` (89 checks, with both kinds of dropped sample)
and `present-test.sh` (138) pass in the test bed. The long-read path's own steps are untested
on an empty sample.

**The second round,** on 2026-11-10 at `0552d35`, reran the jobs the first round lost, and
the finish test passed on the cluster with the full placement reference, all 17 checks,
every core table identical. `outputs_compare`, under `stable-files`, then gave:

- **ampliseq is done.** `v3v5` and `single` completed three times each, with all their core
  tables identical, at 32 CPUs and at 8.
- **Both `mouse` jobs never ran,** cancelled when the fetch of `wgs-mouse` they waited on
  failed in a second: `curl` couldn't connect to `ftp.sra.ebi.ac.uk` from `cmp01`, and
  `--retry` doesn't retry a connection that fails. `steps/fetch_files.sh` now retries any
  error, 5 times 30 seconds apart; in the test bed it reached a server that came up 20
  seconds late, and failed after 2.5 minutes, naming the address, where none ever did.
- **taxprofiler's merges vary in order.** In `mixed`, MetaPhlAn's and mOTUs' merged reports
  and taxpasta's mOTUs table had their two samples' columns swapped between runs, and
  taxpasta's rows in another order: taxprofiler 2.0.1 merges Bracken, MetaPhlAn, mOTUs and
  every taxpasta table in the order the samples' tasks end, and only Kraken2's by size.
  `stable-files` reads those with a new mode, `unordered`.
- **HUMAnN varies by about a read.** In both `human` jobs, one run of three had one gene
  family the others hadn't, its count of families one apart, so HUMAnN's other values were
  about 5e-5 apart, and one rare KO 4.8%. It isn't the thread count, which `slurm.max_cpus`
  caps at 8 in the third run of each, nor the CPU: every node is a Xeon Gold 6526Y, and
  biobakery's two runs on `cmp08` differed, while gnoto's host depletion keeps the reads in
  order with `--reorder`. So HUMAnN's search itself doesn't repeat to the read. At Daniel's
  call (2026-11-11), its tables stay core tables, read at 12 digits: a re-run or selftest
  reports them identical most times, and otherwise how far apart, and fails nothing.
  HUMAnN's own log of taxprofiler's two runs puts the read in its nucleotide search, bowtie2
  against the sample's ChocoPhlAn genes, 6,397 gene families in one run and 6,398 in the
  other, and the protein search only carried it on. Why is still open: HUMAnN 3.9 runs
  bowtie2 with `--very-sensitive`, which seeds its choices from each read, and takes its
  species from MetaPhlAn's profile, the same in both runs, and its files in the database
  directory's order.

Under `unordered`, `mixed`'s three runs then compared identical, all 32 core tables.

**The third round,** on 2026-11-11 at `d8b054e`, ran the two `mouse` jobs and taxprofiler's
`phix`, each three times, and all nine completed. So dropping a nearly empty sample works on
the cluster too. biobakery's `mouse` repeated with no core table among the files that
differed. In taxprofiler's `mouse` and `phix`, only `alpha_diversity.tsv` and HUMAnN's
`pathway-abundance-rpk.tsv` differed in their bytes, and `stable-files` reads both past
what varies: it drops Nonpareil's columns from the first and rounds the second.

**The first selftest,** `nbw26b2m` at `d8b054e`, completed all 15 jobs in 22 minutes, and
its 420 tables are the reference tables in `pipelines/<name>/selftest/`. Its report counted
34 core tables in each of taxprofiler's short-read jobs, where 32 were kept. Present prunes
after the record's checksums are taken, deleting Kraken2's two `-bracken` copies and dropping
mOTUs' empty rows, as biobakery's prune list does to `motus/motus-counts.tsv` too. So a
record's checksums weren't of the tables it was published with, and no selftest could have
found taxprofiler or biobakery identical. `outputs_published` in `lib/outputs.sh` now copies
the core tables, prunes and scrubs the copy as Present will, and the record's checksums are
taken from it. `outputs-test.sh` passes 45 checks in the test bed, with its own for the
copy. Then the cluster's tables from taxprofiler's `human` and `phix` and biobakery's
`human` and `virus`, with the two copies and two empty mOTUs rows put back, came back from
it identical to what was published, and `checks/selftest.sh --small` passed again, 14 checks.

**The second selftest,** `trfwbesx` at `1a55349`, found 12 of the 15 jobs identical to the
reference. biobakery's `human` had HUMAnN's one-read difference again, 8,378 gene families
against 8,377. taxprofiler's `mouse` and `mixed` each had one mOTUs count one apart, in its
merge, its count table and taxpasta's table: a Muribaculaceae mOTU 2 then 1, and *C.
difficile* in the mock 2 then 3. taxprofiler's host removal is nf-core's `BOWTIE2_ALIGN` on
16 threads, given no `--reorder`. Its bowtie2 command, in its pinned image, run three times
on `wgs-mock` at 8 threads, wrote the same 99,987 unaligned pairs in three different orders,
and with `--reorder` in one order all three times. fastp, before it, wrote one order in
three runs at 8 threads. bwa 0.7.17, which mOTUs runs, breaks a tie between equal hits by
the read's place in its input, and mOTUs sorts each read's alignment lines, whose flags and
clipping follow that choice. biobakery's mOTUs, behind gnoto's own host depletion with
`--reorder`, repeated in every run. So `pipelines/taxprofiler/resources.config` gives
`BOWTIE2_ALIGN` `--reorder`, which in `nextflow/nextflow:26.10.5` reached a stand-in under
that name in a subworkflow, with the real config. Running mOTUs itself on one input in two
orders, which needs its database, wasn't done. taxprofiler's short-read jobs may then make
slightly different tables, so their reference tables come from the next selftest.

**The third selftest,** `nwmvidx4` at `9f8ec49`, ran taxprofiler's five jobs alone, and all
completed in 13 minutes. `human`, `mouse` and `ont` were identical to the reference. `mixed`
and `phix`, which both run the mock, each had one mOTUs count one apart in the same three
tables: *B. fragilis* in the mock, 9 then 10. Those six tables replaced theirs in
`pipelines/taxprofiler/selftest/`. The files that differed only where `stable-files` reads
past were left as they were. The next full selftest shows whether `--reorder` makes the
mOTUs counts repeat.

**The fourth selftest,** `wvkautfs` at `3d50bfc`, found 14 of the 15 jobs identical, every
one of taxprofiler's among them, so `--reorder` held, and biobakery's `human` had no HUMAnN
difference this time. ampliseq's `v5v6` named a species its reference hadn't: one
*Gordonia* ASV's species bootstrap was 50 where the reference's was 48, and `minBoot` is
50, so *namibiensis* appeared in its taxonomy, its feature table and the L7 tables. Three
other ASVs' confidences moved by 1 to 4 replicates. DADA2's classifier, 1.38.0 in the pinned
image, breaks an exact tie between two reference taxa with a generator seeded from
`std::random_device`, which `set.seed()` doesn't reach. In that image, a query tied
between two species of one genus, classified eight times with `set.seed(100)` before each
call, at 1 thread and 4, got species bootstraps from 39 to 54, and named either species or
none. So the confidences that `stable-files` leaves out vary for that reason, not with the
node, and a taxon whose confidence sits at the cutoff can vary with them.

**`gnoto-dada2`,** at Daniel's call. DADA2's own issues 1115, from 2020, and 2211, from August
2026, report the same thing, unfixed. `cmmr/dada2` is Daniel's fork of DADA2's repository, and
one commit there gives each query sequence its own `std::mt19937`, seeded from one `runif()`
drawn after the bootstrap numbers, which stay as they were, and takes a tie's uniform straight
from the generator's output, which every standard library computes alike. The commit is on
`seeded-tie-breaks`, from `master`, for upstream, and on `RELEASE_3_22-seeded-tie-breaks`,
Bioconductor's 1.38.0 with it, for gnoto. Bioconductor's 1.38.0 differs from `master` only in
its version, README and Windows build flags. In ampliseq's DADA2 image, after
`set.seed(100)` each time, a query tied between two species got confidences from 39 to 59 in
24 calls from the released build, naming either species or none, and 55 for the same species
in 16 calls from the patched one. On `v5v6`'s 38 ASVs against SILVA 138.2's training set,
two sessions of the released build, at 1 thread and 4, disagreed by up to 6 confidences in 3
ASVs, and so did the released code rebuilt with the image's compilers, while two sessions of
the patched build gave identical results. `images/gnoto-dada2/` rebuilds
DADA2 from that commit in ampliseq's DADA2 image, with the image's own GCC 15.2, and
`check.R` stops the build unless a tie repeats under `set.seed()`: the built image named the
same species at the same confidence in all 16 calls, at 1 thread and 4, in two processes, as
an ordinary user. `lock.yaml`'s new `process_images` names an image for one process, which
`lock.sh containers` writes into `containers.config`. In the gnoto image, with a stand-in
image for `DADA2_TAXONOMY`, `check` failed while the config didn't name it, passed once
`containers` had written it, and failed again with the entry gone from `lock.yaml`;
`containers` refused a process ampliseq doesn't have and an image by tag, and without
`process_images` wrote the committed `containers.config` again. The fix is offered upstream
as benjjneb/dada2 pull request 2230, with a comment on issue 2211 that points to it, both
posted on 2026-11-12 with Daniel's approval. CI published `gnoto-dada2` from `73c2aa8`,
tagged `b0a2dfc2756c` and public, and checked every image with the new `lock.sh`. Pulled
by digest, as an ordinary user, it named the tie's species at the same confidence every
time. ampliseq's `lock.yaml` names it for `DADA2_TAXONOMY`, and `lock.sh containers`
changed only that process's line in `containers.config`. In the test bed, `checks/job.sh
--small` passed with it: Apptainer pulled `gnoto-dada2` by digest and `DADA2_TAXONOMY` ran
in it. ampliseq's reference tables come from the next selftest, since its ties now break
one fixed way.

**The fifth selftest,** `d7c3226k` at `63033df`, found 13 of the 15 jobs identical. All six
of ampliseq's were, `v5v6` among them: with its ties broken one fixed way, it named no
species for the *Gordonia* ASV, as the reference does, so ampliseq's reference tables stay.
biobakery's `human` had no HUMAnN difference. Two tables differed only in their order:

- **biobakery's `virus`:** one `assembly_list` cell in `esviritu/virus-taxa.tsv` named its
  two assemblies the other way round. EsViritu 1.3.3 builds that list with Polars'
  `unique()`, which keeps no order. `ESVIRITU_SUMMARY` now sorts each cell's list. Its
  script, rendered by Nextflow and run in EsViritu's image, turned this run's table into
  the reference's, which was in sorted order already, and sorted a list of three and left an
  empty cell as it was.
- **taxprofiler's `mixed`:** `count_tables/bracken-reads.tsv` and
  `feature_table/feature-table.tsv` had the same rows in another order. They took their
  rows in taxpasta's order, and taxpasta merges its samples in the order their tasks ended,
  so a job of two samples could come out either way. `steps/R/taxprofiler_tables.R` now
  sorts both by taxon id, the count table's species first and its `u` rows above species
  after. In the `gnoto-rbiom` image, run on each reference job's taxpasta profile, it wrote
  each job's count table as the reference's, sorted, byte for byte, and its feature table's
  rows in the same order, and it gave this run's `mixed` the same tables. The reference
  count and feature tables of all five taxprofiler jobs were sorted to match.

The report had called both differences "0 rows only in one, 0 text cells differing, no
number different". A table whose rows and values all match but whose bytes don't is now
"the same rows and values, in another order or written differently", in the selftest
report and in `gnoto status`. `outputs-test.sh`, 45 checks, and `runs-test.sh`, 75, pass
in the test bed.

### Phase 7: integrations

- **`remove` came forward.** Daniel asked for it on 2026-11-09, to clear out old test runs
  on the cluster, several in one command. `gnoto remove [--yes] <uid>...` is built, with
  everything but the integrations: the teardown, `teardown_run` in `service/expire.sh`;
  the `remove` marker the followup acts on; a lost run recorded in history and removed at
  once; and the run lock, `run_lock` in `lib/runs.sh`, which `cancel` and `resume` share.
  This phase fills in the teardown's marked place for Wrike's task status, S3's results
  and expired page, and Globus's archive, and adds the daily expiry check to the same
  file. Once S3 or Globus is set, a completed run has no run directory, so `extend`, the
  expiry check and `publish` take the run's lock through `run_lock`, which finds it in
  `history/<uid>/`. `test/lib/runs-test.sh` and `test/testbed/checks/job.sh --remove`
  test it.
- Build the three CloudFormation stacks (IAM user, S3, SQS) from the settings saved during
  [teardown](#teardown).
- `docs/wrike/responses.md` in the old repo has the live definitions of the workflow, custom
  fields and request form. Use it for `config wrike` and the form checklist, and don't copy its
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
  2. Regenerate `containers.config` and the database digests with `pipelines/lock.sh`, and
     commit them.
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
| `run` builds a Wrike task, stages it in a Personal space and waits for the webhook | `gnoto run` and `gnoto start` create the task and submit the job themselves |
| The listener runs the task handler itself, so form requests need SQS | The listener calls `gnoto wrike <task_id>`. In both modes, a user timer runs the `gnoto wrike` reconciliation scan every `wrike.poll_minutes`, or a person does |
| The listener reads only the first event in each payload, and deletes the SQS message before handling it (`scripts/wrike_sqs_listener.sh:79-96`) | Handle every event, and delete a message only after handling it |
| `scripts/run_state.sh:95-99` writes unlocked when `flock` fails (`flock 9 \|\| true`) | A write that can't get its lock fails |
| The log paths are fixed in `scripts/wrike_job.sh:6-7` and `scripts/wrike_followup.sh:6-7` | Move to the `sbatch` command line |
| `scripts/wrike_job.sh:2-7` hard-codes `--time=60:00:00` and sets neither `--no-requeue` nor `--signal` | Submit with `--no-requeue`, `--signal=B:TERM@300` and `--time` from `slurm.job_time` |
| `scancel --user="$(whoami)"` (`scripts/wrike_delete_handler.sh:81`) can't cancel another user's job | Write a cancel file that the job's progress watcher acts on |
| The Lambda and CloudFront function exist only as code blocks in `docs/wrike/webhook_bridge.md` and `docs/results/cloudfront.md` | Real files under `service/aws/`, with the IAM policies, so a site can attach them itself or let `--deploy` build the stacks |
| The results address assumes the bucket name is a domain (`run_results_url` in `scripts/utilities.sh`) | Use `aws.results_base_url` |
| systemd units hard-code `/data/prod/nextflow` and Slurm paths | Unit templates |
| `modules/nonpareil.nf:46` passes no `-r`, and [Nonpareil seeds from the current time by default](https://nonpareil.readthedocs.io/en/latest/redundancy.html) | Pass a fixed seed. Phase 6 found that only alignment mode takes one: k-mer mode, which both shotgun pipelines run, subsamples from the clock whatever `-r` says, so its columns in `alpha_diversity.tsv` are left out of the comparison |
| `docs/operations/running-by-hand.md:52` says form submission is UI-only, but Wrike now lists [Submit Request Form](https://developers.wrike.com/reference/postrequest_formssinglesubmit.md) | Correct it. That endpoint would also allow an automated test of the Wrike route |
| Database paths are absolute or fixed to `NEXTFLOW_DIR/db`, in 10 files including `config/taxprofiler/database.csv` | Use `db:` names whose paths carry a version |
| `pplace` and `16s` write `manifest.json`, but the lookup in `scripts/wrike_job.sh:387` wants `<path>.manifest.json` | Manifests become YAML, and builders write the name the lookup expects |
| The form has no question for how ampliseq joins read pairs, so V3–V5 pairs that barely overlap are mostly lost | Add `ampliseq.mergepairs_strategy` to ampliseq's `options.yaml`, with ampliseq's default, `merge` |
| `WRIKE_FORM_ANSWERS` and the pipeline files cover only the options the form asks | `job.yaml` gets a section per pipeline. Any parameter the pipeline's schema accepts can be added there by hand and is passed through |
| The samplesheet steps check only that each FASTQ is readable, and follow symlinks (`scripts/ampliseq_samplesheet.sh:179-183`) | In the form route, each file's real path must sit under `core.input_roots` |
| `scripts/ampliseq_samplesheet.sh:250-267` sets each sample's `run` from a hash of its FASTQ directories, so a re-run from other paths batches samples differently | Record each input's `run` in `record.yaml`, and reuse it on a re-run |
| `16s` is read by region detection (`scripts/ampliseq_detect_region.sh:91`) but isn't a parameter, so runs don't record it | Declare it in the lock file, under a versioned path |
| `ampliseq/` has no manifest, because nf-core downloads SILVA by itself, and `pipelines/AMPLISEQ_01.sh:29-33` passes `dada_ref_taxonomy` straight through | Give each reference choice a fetch entry in `pipelines/databases.yaml`, with md5s, and pass the files through `*_ref_tax_custom`, so ampliseq downloads nothing |
| nf-core pipelines load nf-core/configs from its `master` branch at run time by default, through `custom_config_base` | gnoto passes `custom_config_base` empty |
| The host and 16S builders check each download against the md5 NCBI serves at build time, and `config/databases.json` holds 14 md5 values for 38 URLs | Record every download's md5 in `pipelines/databases.yaml`, and check it before any transformation such as `bowtie2-build` |

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
| `.env` | `lib/config/`, `lib/env.sh` | 2 | Settings and sourcing split. Don't copy the values |
| `README.md` | `README.md` | 8 | Written early, on 2026-11-09 at Daniel's request: what gnoto is and the problems it solves, for outside readers. Phase 8 updates its install steps and status, and links the docs site, which holds the detail |
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
| `scripts/wrike_followup.sh` | `lib/followup.sh`, plus a Wrike part in `service/wrike/` | 3, 7 | Reads how Slurm says a job ended, and cancels any task of the run Slurm still has |

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
| `scripts/build_pplace_reference.sh`, `build_16s_reference.sh` | `steps/` | 3 | Done: md5s recorded, manifests as `<path>.manifest.yaml`, versioned paths, filling a directory the fetch job renames into place |
| `scripts/fetch_taxprofiler_db.sh`, `build_host_reference.sh` | `steps/fetch_shotgun_db.sh`, `steps/build_host_reference.sh` | 5 | Done: tree digests, recorded download md5s, manifests as `<path>.manifest.yaml`, host references at `hostremoval/<name>/v1`, filling the directory the fetch job gives them. The sewage reads stayed behind |
| (new) | `steps/fetch_files.sh` | 3 | Fetches any `pipelines/databases.yaml` entry or fixture that lists `files` |
| (new) | `steps/fetch_fixture.sh` | 6 | Makes the fixtures that aren't used as downloaded: the shotgun fixtures cut to 100,000 reads, and `16s-v5v6` from NCBI's `.sra` |

### Dashboard and publishing

| Old | New | Phase | Notes |
| --- | --- | --- | --- |
| `scripts/{ampliseq,taxprofiler,biobakery}_upload.sh` | Split across `present/` and `service/publish.sh` | 3, 7 | See the table above |
| `scripts/publish_dashboard.sh` | `present/dashboard.sh`, with its upload moved to `service/publish.sh` | 3, 7 | |
| `scripts/nextflow_progress.sh` | `present/progress.sh` | 3 | Also becomes the cancel-file watcher |
| `scripts/index_directories.sh`, `prune_results.sh`, `biobakery_methods.sh` | `present/` | 3 | |
| `templates/*.html`, `common.css` | `present/templates/` | 3 | `tailwind.html` became `head.html`, which links the CSS built into `present/assets/` |
| `templates/{ampliseq,taxprofiler,biobakery}/` | `present/templates/` | 3 | |
| `templates/redesign/` | Not copied | | Nothing reads it at run time |

### Pipelines and Nextflow

| Old | New | Phase | Notes |
| --- | --- | --- | --- |
| `pipelines/<NAME>_01.sh` | `pipelines/<name>/pipeline.sh` | 2 | Keep each parameter's reason. The nf-core pins move to `lock.yaml`, at the latest releases, and `PARAMS_LOCKED` becomes the list of keys gnoto owns |
| `pipelines/<NAME>.sh` | Not copied | | Shortcuts aren't needed |
| `modules/*.nf` | `modules/` | 2, 5, 6 | Images by digest since phase 5. Nonpareil takes a seed since phase 6, which only its alignment mode uses |
| `workflows/biobakery/`, `workflows/humann/` | `workflows/` | 2 | |
| `config/slurm.config`, `config/{biobakery,taxprofiler}/slurm.config` | `pipelines/<name>/resources.config` | 2 | Keep resource requests. Site parts such as `cacheDir` and executor settings go |
| `config/local.config` | Not copied | | Only `docs/layout.md` mentions it |
| `config/taxprofiler/database.csv` | `pipelines/taxprofiler/database.csv` | 2, 5 | Uses `db:` names |
| `config/databases.json`, `references.json` | `pipelines/databases.yaml`, `references.yaml` | 2 | `biobakery_methods.sh` reads these with `jq`, and `publish_dashboard.sh` reads the methods data it writes. The two `test-fastq` entries give way to the fixtures in [fixtures.md](fixtures.md) |
| `nix/rbiom.nix` | `images/gnoto-rbiom/` | 3, 5 | Replaced in phase 3 by a Dockerfile on `rocker/r-ver`, with a pak lockfile from a dated Posit CRAN snapshot and rbiom from GitHub. Phase 5 builds it in CI and publishes it to GHCR |

### Docs, all for phase 8

| Old | Use |
| --- | --- |
| `docs/conventions.md` | The uid, state file and message-bus conventions. Read this before phase 3 |
| `docs/pipelines/*.md` | Why each pipeline is set up as it is, and most of the science reasoning. Keep these |
| `docs/results/*.md` | How the dashboard works, including composition and browsable folders. Keep these |
| `docs/operations/nix.md`, `databases.md`, `expiration.md`, `daemon.md`, `cluster-requirements.md`, `running-by-hand.md`, `index.md` | Rewrite for gnoto, because `config`, `lint` and `status` replace many of the manual steps |
| `docs/operations/globus.md`, `docs/wrike/*.md` | Rewrite, removing IDs, addresses and hostnames |
| `docs/index.md`, `layout.md`, `configuration.md` | Rewrite against [design.md](design.md) |

## Teardown

Daniel plans to tear down everything in place and roll out gnoto as an external user would.

- **Save the AWS settings first.** The old repo records the Wrike fields, workflow and form
  (`docs/wrike/responses.md`), and the Lambda and CloudFront function source. It has no record
  of the IAM policies, bucket policy, CloudFront distribution settings, API Gateway setup or
  queue settings, and the CloudFormation stacks have to reproduce them. Save them outside this
  public repo.
- **Keep `db/` and Apptainer until phase 6 is done.** Since phase 5, gnoto fetches every
  database it reads into its own `core.db_dir`, and phase 6's probes run on gnoto, so only
  the cluster's Apptainer, still the copy inside the old install, needs a home of its own
  before the teardown.
  The fixtures in [fixtures.md](fixtures.md) are public and can be fetched again at any time.
  The Wrike, AWS, Globus and systemd pieces can go at any time after the AWS settings are saved.
- **Finish the teardown before the rollout test.** `config` adopts any object it finds by name,
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
