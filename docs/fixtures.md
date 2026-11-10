# Test fixtures

gnoto's test fixtures are 13 public datasets, one for each path through the pipelines. Most
are mock communities with known composition. `gnoto selftest` runs them, as each pipeline's
`selftest.yaml` lists, and phases 1 and 6 of [migration.md](migration.md) test against them.
Every file was checked against its source, ENA, NCBI or nf-core, on 2026-11-05.

## How they're used

- **Fetched like databases.** Each fixture is an entry under `fixtures/` in
  `pipelines/databases.yaml`, so `lint` and `selftest` fetch it into
  `<db_dir>/fixtures/<name>/v1/`. A samplesheet naming a file there makes the fixture one of
  the job's databases, which `lint --yes` fetches. The version changes if the cut rule below
  ever does. Each pipeline's `lock.yaml` pins, by tree digest, the fixtures its selftest runs
  on.
- **Checked before use.** Every file is checked against the md5 below before anything reads
  it, as for any download.
- **Shotgun fixtures are cut short.** After the check, `steps/fetch_fixture.sh` cuts each
  file to its first 100,000 reads, 400,000 lines, so a pair's mates stay in step, to keep
  `selftest` quick. The cut files are recompressed with `gzip -n`, which leaves out the name
  and time, so they're the same bytes every time, and their tree digest is recorded like any
  database's. 16S fixtures are used whole.
- **One comes from NCBI.** ENA's copy of `SRR24187307` has no quality scores, so `16s-v5v6`
  downloads NCBI's `.sra` file and converts it after the check, with `fasterq-dump
  --split-files --threads 1` from the sra-tools image ampliseq's lock pins, then `gzip -n`,
  into `SRR24187307_1.fastq.gz` and `_2`. The file is an aligned SRA, but it needs no
  reference to convert, and nothing is fetched besides it. sra-tools is 3.2.1, not the latest,
  3.4.1, because both of 3.4.1's builds segfault reading it (2026-11-09). Two builds gave the
  same tree digest.
- **One comes from nf-core.** The `16s-ont` files are pinned to a commit of
  [nf-core/test-datasets](https://github.com/nf-core/test-datasets/tree/ampliseq/testdata).
  nf-core publishes no md5, so the values below were computed on 2026-11-05.

## 16S, for ampliseq

| Name | Path it tests | Source | What it is | Reads | Expect |
| --- | --- | --- | --- | --- | --- |
| `16s-v4` | V4, Illumina paired | [SRR17380142](https://www.ebi.ac.uk/ena/browser/view/SRR17380142) | NBRC cell mock, 18 strains, MiSeq 2×250 | 19.0k pairs | Truth is by genome copy, so weight it by 16S copy number |
| `16s-v1v3` | V1–V3, Illumina paired | [SRR13272540](https://www.ebi.ac.uk/ena/browser/view/SRR13272540) | BEI HM-276D even mock, 20 species, MiSeq 2×301 | 32.6k pairs | Truth is in mockrobiota's mock-20 |
| `16s-v3v5` | V3–V5, Illumina paired | [SRR7636994](https://www.ebi.ac.uk/ena/browser/view/SRR7636994) | Mayo positive control, MiSeq 2×301 | 29.1k pairs | Not a mock, so only detection and merging are checked. Pairs overlap by about 16 bp after primer removal, so merging may lose most of them |
| `16s-v5v6` | V5–V6, Illumina paired | [SRR24187307](https://www.ncbi.nlm.nih.gov/sra/SRR24187307) | ATCC MSA-1002, 20 strains at 5% each, MiSeq 2×250 | 236.7k pairs | Even composition |
| `16s-single` | Illumina single-end | [ERR5002560](https://www.ebi.ac.uk/ena/browser/view/ERR5002560) | Zymo positive control, V4, MiSeq 1×151 | 17.1k reads | Reads start after the forward primer, so this also tests reads without primers |
| `16s-ont` | ONT full-length, Savont | [nf-core Std1–3 and Log1–3](https://github.com/nf-core/test-datasets/tree/ampliseq/testdata) | Zymo D6305 even and D6311 log, R10.4.1, SQK-16S114.24 | 1,000 or 3,000 per file | What ampliseq's `test_savont` runs at the pinned commit. The reads are already filtered and primer-trimmed |

## Shotgun, for taxprofiler and biobakery

| Name | Path it tests | Source | What it is | Reads | Expect |
| --- | --- | --- | --- | --- | --- |
| `wgs-human` | Human + PhiX host removal | [SRR32527649](https://www.ebi.ac.uk/ena/browser/view/SRR32527649) | UC stool, NovaSeq 2×151 | 843k pairs | At least 2% human |
| `wgs-mouse` | Mouse + PhiX host removal | [SRR19086211](https://www.ebi.ac.uk/ena/browser/view/SRR19086211) | Mouse feces, MiSeq 2×151 | 1.39M pairs | At least 8% mouse |
| `wgs-mock` | Profiles against known truth | [SRR37882354](https://www.ebi.ac.uk/ena/browser/view/SRR37882354) | Zymo D6331 gut standard, NextSeq 2000 | 1.86M pairs | Staggered, with archaea and yeast |
| `wgs-virus` | EsViritu, in biobakery | [SRR24403534](https://www.ebi.ac.uk/ena/browser/view/SRR24403534) | El Paso wastewater, viral capture, NovaSeq | 2.56M pairs | EsViritu's own validation data. Capture skews the bacterial profiles |
| `wgs-phix` | A sample left with no reads | [SRR353672](https://www.ebi.ac.uk/ena/browser/view/SRR353672) | Pure PhiX, HiSeq 2000 2×50 | 964k pairs | Nothing but a few adapter dimers left after PhiX removal |
| `wgs-single` | Illumina single-end | [SRR22959674](https://www.ebi.ac.uk/ena/browser/view/SRR22959674) | Shallow-shotgun stool, NextSeq 1×101 | 722k reads | No human reads |
| `wgs-ont` | ONT long reads | [ERR3078231](https://www.ebi.ac.uk/ena/browser/view/ERR3078231) | Zymo D6305, MinION | 29k reads | taxprofiler runs it, and biobakery refuses it |

The read counts are for the full downloads. `selftest` uses the first 100,000 pairs of each
paired shotgun fixture and the first 100,000 reads of `wgs-single`. `wgs-ont` has only 29k reads, so
it runs whole. Host fractions come from NCBI's taxonomy screen, which undercounts host reads,
so treat them as minimums.

## The selftest's jobs

Each pipeline's `selftest.yaml` groups its fixtures into jobs, a job wherever the options
differ, and `pipelines/<name>/selftest/<job>/` holds the reference copy of each job's core
tables.

| Pipeline | Job | Fixtures, as samples | Options |
| --- | --- | --- | --- |
| ampliseq | `v4`, `v1v3`, `v5v6` | `16s-v4`, `16s-v1v3`, `16s-v5v6` | |
| ampliseq | `v3v5` | `16s-v3v5` | `mergepairs_strategy` `concatenate`, since its pairs barely overlap |
| ampliseq | `single` | `16s-single` | |
| ampliseq | `ont` | `16s-ont`, six samples | |
| taxprofiler, biobakery | `human` | `wgs-human` | `Human + PhiX` |
| taxprofiler, biobakery | `mouse` | `wgs-mouse` | `Mouse + PhiX` |
| biobakery | `mixed` | `wgs-mock`, `wgs-phix` and `wgs-single` | PhiX, the default |
| taxprofiler | `mixed` | `wgs-mock` and `wgs-single` | PhiX, the default |
| taxprofiler | `phix` | `wgs-mock` and `wgs-phix` | PhiX, the default. It fails until taxprofiler can drop a sample MetaPhlAn finds no read over 70 bp in |
| taxprofiler | `ont` | `wgs-ont` | |
| biobakery | `virus` | `wgs-virus` | `run_esviritu` |

ampliseq runs every sample of a job one way, paired or single-end, and measures one region
for the job, so each of its fixtures is a job of its own. biobakery refuses ONT reads, so
`wgs-ont` has no biobakery job.

## Files and checksums

This block moves into `pipelines/databases.yaml` in phase 2.

```yaml
fixtures:
  16s-v4:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR173/042/SRR17380142/SRR17380142_1.fastq.gz
      md5: f73c4461d0e1674ccb357f55e985e120
      bytes: 1201431
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR173/042/SRR17380142/SRR17380142_2.fastq.gz
      md5: f63251aa1deb2aa16433ccb301ff6761
      bytes: 1723469
  16s-v1v3:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR132/040/SRR13272540/SRR13272540_1.fastq.gz
      md5: 7d47ec5f865ef8b3787c012ef0438eef
      bytes: 5361392
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR132/040/SRR13272540/SRR13272540_2.fastq.gz
      md5: 4508a636f785b6002ddac1d73901ef2e
      bytes: 6221968
  16s-v3v5:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR763/004/SRR7636994/SRR7636994_1.fastq.gz
      md5: 014896f07e13528d4600dfc24336bd27
      bytes: 3748238
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR763/004/SRR7636994/SRR7636994_2.fastq.gz
      md5: 9c63357d7a47fc0d73c893474d78fc35
      bytes: 4306606
  16s-v5v6:
    - url: https://sra-pub-run-odp.s3.amazonaws.com/sra/SRR24187307/SRR24187307
      md5: eb02a54d3c9c69a0519438aee3c11f87
      bytes: 77927688
  16s-single:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR500/000/ERR5002560/ERR5002560.fastq.gz
      md5: ce45ed942eefc9adef40822f8871af74
      bytes: 1220577
  16s-ont:
    # nf-core/test-datasets at commit 3cc618ea14e87fd944c30dd37acbef08ad01d590
    - url: https://raw.githubusercontent.com/nf-core/test-datasets/3cc618ea14e87fd944c30dd37acbef08ad01d590/testdata/Std1_ZymoD6305_16SBarcodingKit24V14_SQK-16S114.24_r10.4.1_sup.chopper.1000.fastq.gz
      md5: eaf977dbbdfef44a115f0ded70b96633
      bytes: 1208593
    - url: https://raw.githubusercontent.com/nf-core/test-datasets/3cc618ea14e87fd944c30dd37acbef08ad01d590/testdata/Std2_ZymoD6305_16SBarcodingKit24V14_SQK-16S114.24_r10.4.1_sup.chopper.1000.fastq.gz
      md5: 91cb0c83a259ec4539fb40e5a7718b13
      bytes: 1204156
    - url: https://raw.githubusercontent.com/nf-core/test-datasets/3cc618ea14e87fd944c30dd37acbef08ad01d590/testdata/Std3_ZymoD6305_16SBarcodingKit24V14_SQK-16S114.24_r10.4.1_sup.chopper.1000.fastq.gz
      md5: bff8af75614ecaf2ccc76695760b0dea
      bytes: 1197241
    - url: https://raw.githubusercontent.com/nf-core/test-datasets/3cc618ea14e87fd944c30dd37acbef08ad01d590/testdata/Log1_ZymoD6311_16SBarcodingKit24V14_SQK-16S114.24_r10.4.1_sup.chopper.3000.fastq.gz
      md5: d2884a8a471be6908d201bb3246e5baa
      bytes: 3134294
    - url: https://raw.githubusercontent.com/nf-core/test-datasets/3cc618ea14e87fd944c30dd37acbef08ad01d590/testdata/Log2_ZymoD6311_16SBarcodingKit24V14_SQK-16S114.24_r10.4.1_sup.chopper.3000.fastq.gz
      md5: a5c9f628ddd2c8c36d029d234d1a1d86
      bytes: 3131051
    - url: https://raw.githubusercontent.com/nf-core/test-datasets/3cc618ea14e87fd944c30dd37acbef08ad01d590/testdata/Log3_ZymoD6311_16SBarcodingKit24V14_SQK-16S114.24_r10.4.1_sup.chopper.3000.fastq.gz
      md5: 0cfa25354e6ef88ac79a81a2bc1c9a93
      bytes: 3126648
  wgs-human:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR325/049/SRR32527649/SRR32527649_1.fastq.gz
      md5: 3485b3da3b46320446869e3ea92e98eb
      bytes: 62126670
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR325/049/SRR32527649/SRR32527649_2.fastq.gz
      md5: 25cfa9266662162cd7da63a42bc867a3
      bytes: 64266568
  wgs-mouse:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR190/011/SRR19086211/SRR19086211_1.fastq.gz
      md5: c8a9398dedfd5a0e50432d1a2e1f5ce3
      bytes: 74021626
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR190/011/SRR19086211/SRR19086211_2.fastq.gz
      md5: ea092a898b1e5305c8c62668f318908c
      bytes: 74523317
  wgs-mock:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR378/054/SRR37882354/SRR37882354_1.fastq.gz
      md5: c32a32cd54500a9a93a8ae854ba1364e
      bytes: 136341100
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR378/054/SRR37882354/SRR37882354_2.fastq.gz
      md5: 84316bc33efec6f4d7272f4c9126aa42
      bytes: 147404388
  wgs-virus:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR244/034/SRR24403534/SRR24403534_1.fastq.gz
      md5: 66f6db75de206e9ba7a929b601c24eee
      bytes: 184506113
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR244/034/SRR24403534/SRR24403534_2.fastq.gz
      md5: c80aeb7957b34612174ad00dfa56372d
      bytes: 187858336
  wgs-phix:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR353/SRR353672/SRR353672_1.fastq.gz
      md5: fd9f5200e8e2820b794883891f5cb0ad
      bytes: 21083237
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR353/SRR353672/SRR353672_2.fastq.gz
      md5: 7c40c0756a53af18a6c63cb09ca62d2f
      bytes: 20987851
  wgs-single:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR229/074/SRR22959674/SRR22959674.fastq.gz
      md5: 9d14a1c6a46a1f165088a0a1822f751c
      bytes: 28049214
  wgs-ont:
    - url: https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR307/001/ERR3078231/ERR3078231.fastq.gz
      md5: 192cf5f6b89b9122bcc14ab3a7da7095
      bytes: 47756094
```
