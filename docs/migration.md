# Migrating from cmmr/nextflow to gnoto

gnoto gets built by copying code out of `cmmr/nextflow` and restructuring it, in eight
phases. Nothing is in production, so there's no cutover, and no old runs or published
results to honor. [design.md](design.md) describes the target.

Status on 2026-11-08: **phases 1 and 2 are done, and phase 3 passes in the test bed and, for
ampliseq and biobakery, on the cluster.** A CLI job runs ampliseq on `16s-v4` from `gnoto start` to a full
dashboard in `results/`, with no Wrike, AWS or Globus, under Slurm and on the machine itself.
taxprofiler is set aside, and phase 4 is next. The [phase 1](#phase-1-image-and-helper),
[phase 2](#phase-2-restructure) and [phase 3](#phase-3-job-core) notes record what's built and
every test result, and phase 1's notes list the two determinism probes still to run.

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
| 3. Job core | `lib/job.sh`, `options.yaml`, `new`, `lint job.yaml`, `start`, `start --debug`, `status`, `cancel`, input checksums, `history/`, core `config` and config `lint`, and the three job stages, with Publish a stub until phase 7 | A CLI job finishes with no Wrike, AWS or Globus configured, and leaves a full dashboard in `results/` |
| 4. Version cache | `pipeline@ref`, `start record.yaml`, `<data_dir>/current`, `gnoto upgrade`, `gnoto prune`, and `gnoto resume` with the cleanup that keeps a failed run's cache | A job re-runs correctly from its own commit after `main` has moved on, an upgrade while a job runs leaves that job on its own code, and a run that failed resumes from its own commit with its finished tasks cached |
| 5. Lock files | Image digests, GHCR images, `containers.config`, `db:` names, database digests and `lint --deep` | CI on `main` rejects an image address by tag, and a re-run pulls only by digest |
| 6. Determinism | `gnoto selftest`, seeds, `stable-files`, and the numeric comparison of core tables | A re-run reports its core tables as identical |
| 7. Integrations | `gnoto wrike` writing job files from Wrike tasks, CLI jobs creating tasks, the publish stage and `gnoto publish`, the daily timer, `extend`, `remove`, `config` and `lint` for the integrations, the CloudFormation stacks, and the health file `status` shows | A Wrike request and a CLI job on the same samples give the same core tables, and both appear as tasks |
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
GHCR, by digest, once the image is stable, and no later than phase 5.

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

1. Clone the repo, and put the `.sif` in `<data_dir>/images/` under the name `IMAGE` gives.
   Without `config.yaml`, the data directory is `<install>/data`.
2. With Slurm's module loaded, run `./gnoto config slurm --on`, which takes what `sinfo`
   suggests, and `./gnoto config core` from a terminal if the data directory is elsewhere.
   Then check that `./gnoto exec true` exits 0.
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
`slurm.partition` and `slurm.account`.

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
- **Reference choices.** An entry in `conf/databases.yaml` can carry a `choice`, such as
  `dada_ref_taxonomy` `silva=138.2`, with the `*_ref_tax_custom` files that replace it.
  `params_reference` swaps one for the other, so ampliseq downloads no reference, and a choice
  without an entry fails.
- **Step containers** run through `container_exec`: `--cleanenv`, `LC_ALL=C.UTF-8`, `TZ=UTC`,
  and an empty home directory bound at `/home/gnoto`, from the run directory, as phase 1's
  two-user check asked. Their images are pinned by digest in `pipelines/<name>/lock.yaml`,
  beside the upstream commit, which replaces each pipeline file's `-r` revision. vsearch moves
  from 2.31.0 to 2.32.0, the latest.
- **`conf/databases.yaml` and `references.yaml`** replace the JSON files. The retired sylph
  entry and the two old `test-fastq` sets are gone, SILVA 138.2 has an entry with its md5s, and
  the fixtures block from [fixtures.md](fixtures.md) is at the end.
- **Steps, modules, workflows and resources.** The eight phase 2 steps and the two R scripts
  are in `steps/` and `steps/R/`, the modules and the biobakery and HUMAnN workflows in
  `modules/` and `workflows/`, and the resource requests in `conf/<name>/resources.config`,
  without the site settings (executor, Apptainer cache and binds, CPU, memory and time caps).
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
  file checks `lint` and `start` share, and `record.yaml`. A section's keys that aren't
  options are checked against the pipeline's `nextflow_schema.json` at its pinned commit,
  fetched with git into `<data_dir>/schemas/`; gnoto's biobakery workflow carries its own
  schema. `pipeline.sh` is evaluated with the job's answers in a scratch run directory, which
  catches its own refusals and gives the owned keys, the parameters and the databases. A
  value naming gnoto's own file is a `code:` name, as `db:` names a database.
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
  forward from phase 5. Every download they make has its md5 in `conf/databases.yaml`,
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
  `conf/taxprofiler/resources.config` now lets either fail on MetaPhlAn.
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

taxprofiler is set aside for now, at Daniel's call, while ampliseq and biobakery are made
operational. It still has to pass on the cluster, where its tasks now avoid that node
once `lint` or a launch failure has listed it.

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
| `scripts/wrike_job.sh:2-7` hard-codes `--time=60:00:00` and sets neither `--no-requeue` nor `--signal` | Submit with `--no-requeue`, `--signal=B:TERM@300` and `--time` from `slurm.job_time` |
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
| `.env` | `lib/config/`, `lib/env.sh` | 2 | Settings and sourcing split. Don't copy the values |
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
| `scripts/fetch_taxprofiler_db.sh`, `build_host_reference.sh` | `steps/` | 5 | Add tree digests and recorded download md5s, fix their manifest names, and fill the directory the fetch job gives them, as `steps/build_pplace_reference.sh` does |
| (new) | `steps/fetch_files.sh` | 3 | Fetches any `conf/databases.yaml` entry or fixture that lists `files` |

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
| `modules/*.nf` | `modules/` | 2 | Add the Nonpareil seed in phase 6, and digests in phase 5 |
| `workflows/biobakery/`, `workflows/humann/` | `workflows/` | 2 | |
| `config/slurm.config`, `config/{biobakery,taxprofiler}/slurm.config` | `conf/<name>/resources.config` | 2 | Keep resource requests. Site parts such as `cacheDir` and executor settings go |
| `config/local.config` | Not copied | | Only `docs/layout.md` mentions it |
| `config/taxprofiler/database.csv` | `pipelines/taxprofiler/database.csv` | 2, 5 | Uses `db:` names |
| `config/databases.json`, `references.json` | `conf/databases.yaml`, `references.yaml` | 2 | `biobakery_methods.sh` reads these with `jq`, and `publish_dashboard.sh` reads the methods data it writes. The two `test-fastq` entries give way to the fixtures in [fixtures.md](fixtures.md) |
| `nix/rbiom.nix` | `images/gnoto-rbiom/` | 3, 5 | Replaced in phase 3 by a Dockerfile on `rocker/r-ver`, with a pak lockfile from a dated Posit CRAN snapshot and rbiom from GitHub. Phase 5 builds it in CI and publishes it |

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
- **Keep `db/` and Apptainer until phase 6 is done,** because phases 1 to 6 test against them.
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
