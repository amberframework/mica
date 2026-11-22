# Benchmarks

Mica has three benchmark harnesses:

- **XML** (`bench/run.sh`): Mica::XML against libxml2. See the README,
  "Benchmarks".
- **Regex** (`bench/regex/`): Mica::Regex against PCRE2 as Crystal uses it
  today. This page covers it.
- **Inflate** (`bench/deflate/`): Mica's raw DEFLATE, zlib and gzip
  decoders against the system zlib. See "Inflate" at the end of this page.

## The bar

Mica::Regex must perform equal to or better than PCRE2 **as Crystal uses it
today**: stdlib `Regex`, PCRE2 with JIT on (Seth, 2026-11-18). Every search
must also be bounded by a work budget and a deadline, so a complex pattern
on a large input cannot run unbounded. The harness measures both.

## Run it against a Mica branch (one command)

```sh
bench/regex/run.sh --mica-ref origin/feature/regex-r2
```

This fetches and verifies the rebar corpus, checks the ref out into a
detached worktree under `bench/data/regex/`, builds every program with
`--release` (the Mica runner against that worktree's `src/`), runs all three
corpora in all three engines, and prints the path of the report
(`bench/data/regex/runs/<UTC time>/REPORT.md`, with `report.json`,
`results.jsonl` and `run.json` beside it).

Without `--mica-ref` it measures this checkout's `src/`. Other options:

| Option | Effect |
|---|---|
| `--engines pcre2-jit,pcre2-interpreter,mica` | engines to run; `pcre2-jit` (the baseline) is required |
| `--corpora rebar,amber,redos` | corpora to run |
| `--out DIR` | where results and the report go |
| `--quick` | Amber haystacks up to 1 MiB, 5 samples, 0.3 s phases |
| `--title TEXT` | report title |
| `-- --only redos/` | anything after `--` goes to the driver (`--only TEXT` filters case ids; `--case-timeout`, `--redos-timeout`, `--max-samples`, `--min-samples`, `--phase-seconds`, `--max-amber-bytes`) |

Requirements: `crystal-alpha`, `/usr/bin/ruby`, `git`, and libpcre2-8
(already required by Crystal's stdlib `Regex`). The rebar download is about
43 MB; extracted haystacks take about 120 MB under `bench/data/` (git
ignores it). The harness's own specs:

```sh
crystal-alpha spec bench/regex/spec
# with release runners built (bench/regex/run.sh builds them into bench/bin/regex):
REGEX_BENCH_RUNNERS=bench/bin/regex crystal-alpha spec bench/regex/spec/first_case_process_cold_spec.cr
```

The second command proves that the first case a runner binary meets gets
the process-cold time it measures standalone: over 9 interleaved rounds it
pairs a run of rebar's `captures/contiguous-letters` on a never-touched
copy of the runners with a run on a copy that has run it before, and
requires the 99% paired-bootstrap interval of their ratio to contain 1. As
a control it shows that, without the page-in, a never-touched Mica runner
is still slow on its first case. The samples go to
`bench/data/regex/spec-runs/<id>/first_case_process_cold.json`.

## Engines

Each engine is its own program, and every case runs in a fresh process of
it, one process at a time, so linkage and memory stay separate.

Cases run in an order shuffled by a seed (random unless `--seed N` is
given, and recorded in `run.json` and the report), and the engines run in
a shuffled order per case, so no case is always the first one a runner
binary meets. Each ReDoS family keeps its sizes ascending, so a timeout
still skips the larger sizes. The report lists cases in corpus order.

Every timed runner process starts right after an untimed `--page-in`
process of the same binary: it reads one byte of every file-backed page of
the runner and of each library it loaded from outside the system's shared
cache, and does no regex work. The first process to touch a page of a
freshly built binary pays to bring it into the page cache and, on macOS, to
check it against the code signature; that cost is paid once per binary, and
before this pass it landed inside the process-cold time of whichever case
ran first (rebar `captures/contiguous-letters`: Mica 986 us as the first case
against 84 us once paged in).

| Engine | Program | What it is |
|---|---|---|
| `pcre2-jit` | `bench/regex/pcre2_jit_runner.cr` | The baseline. Stdlib `Regex` exactly as a Crystal program uses it: `Regex.new` (UTF, UCP, DUPNAMES, then JIT compile), `match_at_byte_index` with a `MatchData` per match, `NO_UTF_CHECK` after the first search over a haystack (as `String#scan` does), groups read with `MatchData#[]?`. |
| `pcre2-interpreter` | `bench/regex/pcre2_interpreter_runner.cr` | PCRE2's interpreter through a direct binding in the harness only: `pcre2_compile_8` with the same options and no JIT compile, so compile and cold-search times are the interpreter's own; `pcre2_match_8` with one reused match-data block. |
| `mica` | `bench/regex/mica_runner.cr` | Mica::Regex through `bench/regex/src/regex_bench/engines/mica_engine.cr`. It references no stdlib `Regex`, so the program links no PCRE2. |
| `mica-static` | `bench/regex/mica_static_runner.cr` | `Mica::Regex.static` (docs/regex.md, "Static patterns"): every corpus pattern is compiled while the runner builds (`bench/regex/scripts/write_static_patterns.rb` writes the table; `run.sh` does both when `--engines` names it). Its "compile" is a lookup in the runner's index plus the first read of the pattern's constant; the index (the harness's own, which an application does not have) is built before any case is timed. Searches use the same limits and deadlines as `mica`. A pattern outside the static limits reports `unsupported` (outside the static limits), so the row holds static searches only. Not in the default `--engines`. |

The Mica adapter is written against the native API in the design
(followup-17 section 6.2.6): `Mica::Regex.compile(pattern, dialect:,
compile_limits:)` and `regex.search(haystack, offset, limits:, deadline:)`.
Until `Mica::Regex.compile` exists on the branch being measured, the adapter
compiles to a pending stand-in and every Mica case reports `pending`. If
the engine lands with a different signature, `mica_engine.cr` is the one
file to change. Throughput cases search with `SearchLimits::TRUSTED_INPUT`;
ReDoS cases with `SearchLimits::REQUEST` and the case's deadline.

## Corpora

**rebar**: the benchmark definitions of
[rebar](https://github.com/BurntSushi/rebar) at the commit pinned in
`bench/regex/corpus/rebar_source.json`. `bench/regex/scripts/rebar_corpus.rb`
(system `/usr/bin/ruby`, standard library only) downloads the tarball,
verifies it against the recorded sha256 (a mismatch deletes the download and
fails), extracts `benchmarks/` and converts the TOML definitions to
`bench/data/regex/rebar-<commit>/rebar.json`. That JSON is generated from
the verified tarball on every run, not committed: it is a pure function of
the pinned tarball, and rebar's fixtures include credential-shaped test
strings that stay out of this repository. A
benchmark is kept when rebar runs `pcre2/jit` on it, its model is one the
harness implements (all but `regex-redux`), and it has one pattern; the
excluded ones are listed in the JSON with the reason. To move the pin, edit
`rebar_source.json` (commit, URL, sha256 and size) and run
`/usr/bin/ruby bench/regex/scripts/rebar_corpus.rb`.

rebar's expected counts assume PCRE2 without UTF/UCP when a benchmark turns
Unicode off. Crystal always compiles with UTF and UCP, so the baseline's own
count is the reference every engine must match; the report lists the cases
where it differs from rebar's.

**Amber** (`bench/regex/corpus/amber.json`): 26 patterns taken from Amber
V2, Grant and amber_cli source (each entry cites file and line): route
constraints, the Grant email and URL validators, Markdown inline and block
rules, Crystal backtrace frames, Grant's SQL normalizers, CSV and Accept
separators, identifier and template rules. Each runs over a generated
haystack of 1 KiB, 64 KiB, 1 MiB and 100 MiB. The generators
(`haystack_generator.cr`) are deterministic, and each result records the
haystack's FNV-1a checksum. Each engine process builds its haystack in memory, so the
100 MiB haystacks never touch the disk.

**ReDoS** (`bench/regex/corpus/redos.json`): 13 families, including every
n-family in followup-17 section 6.8 (`(a+)+$`, `(a|a)*b`, `(a|aa)*c`,
`(x+x+)+y`, `(.*a){20}`, `^(\w+\s?)*$`, the OWASP email pattern, the
Cloudflare 2019 and Stack Overflow 2016 patterns) plus alternation blowups
and a long non-matching input. Each runs one search over
`prepend + unit * n + append` for n from 16 to 1,048,576 under a 1 s
deadline. A PCRE2 run records its time or the limit it stopped on
(`pcre2-match-limit`, `pcre2-jit-stack-limit`, ...); the driver stops a
process after 10 s and skips the larger sizes of that family.

## What is measured

Per case and engine:

- **compile**: compile alone;
- **cold first search**: compile plus one search, a new compiled pattern
  each sample, in a process that has already run the case once;
- **process-cold**: compile plus the first search as the first regex work
  of a fresh runner process: `--process-cold-samples` (default 5, 3 with
  `--quick`) fresh `--process-cold` processes per case and engine, each
  doing nothing else, in rounds that alternate the engines; the median is
  reported and every sample is kept in `results.jsonl`
  (`list_of_process_cold_seconds`);
- **warm search**: one full iteration of the case's model (rebar's
  `count`, `count-spans`, `count-captures`, `grep`, `grep-captures`, or
  `first-match` for ReDoS) with a compiled pattern;
- every timed cold and warm search gets its own String, equal to the
  haystack but a separate object, as a web app gets a new String with
  every request. The copies for a batch are made before its clock starts
  (`HaystackCopies`), so the copy is not timed, for every engine alike;
  a batch whose copies would pass 256 MiB rotates through as many as fit,
  never fewer than two, so consecutive searches still differ. An engine
  that remembers the last String it validated by identity therefore pays
  validation on every search, as PCRE2 does on a first search;
- **peak memory**: the process's peak RSS, and the part above the RSS
  right after the haystack was built.

Method: one verified iteration (its count must equal the baseline's), up to
3 warm-up iterations within 0.5 s, then samples until 11, or until 1 s has
passed with at least 3. An iteration slower than 2 s is sampled once.
An operation shorter than 10 us (a few ticks of the 41.67 ns Apple Silicon
clock) is timed in calibrated batches, by the same code for every engine:
the batch doubles until two timed loops of it in a row each take at
least 10 us, then each sample times one batch and divides by the batch
size; when the median sample still fell short of 10 us, the batch
doubles and the phase is sampled again. Longer operations are timed one
at a time, as before. Each metric records its
batch as `iterations_per_sample` in `results.jsonl`, and the slower-cases
table shows the primary metric's batch for both engines. The
report gives the median, p25/p75 and min/max; ratios use medians, and group
summaries are geometric means of ratios over eligible cases (both engines
finished and their counts agree), each shown with the geometric means of
both engines' medians behind it. `run.json` records the machine, the
toolchain, the commits and the settings.

## The report

`REPORT.md` and `report.json` hold:

1. engine status counts and the headline geometric means;
2. per group: cases, eligible cases, and the geometric-mean ratio to
   `pcre2-jit` for warm search, compile, cold first search and
   process-cold, each with its absolute times;
3. every case where Mica is slower than PCRE2-JIT, with the margin;
4. the ReDoS table (family by n, every engine);
5. the deadline and budget suite: for each engine and ReDoS family, whether
   every search returned a result or a named limit error within the
   deadline, and the log-log slope of time over n (sizes n >= 1024 that
   completed; at most 1.3 counts as linear). The gate is Mica's; PCRE2 rows
   are the contrast;
6. method, machine and toolchain;
7. cases outside the comparison (unsupported, rebar count differences);
8. every case, with the baseline's times and spread and each engine's
   ratio.

## GC-free study tools (`bench/regex/gc_study/`)

The tools behind the GC-free study (what the collector costs the runtime
engine, and what `Mica::Regex.static` gains), kept for re-measuring:

- `measure_allocations.cr` counts the heap allocations (calls and bytes)
  of a compile, a process's first search and a warm search for every
  corpus case, times each warm workload with the collector on and off
  (interleaved), and records each pattern's table shapes.
  `summarize_allocations.rb` turns its JSON lines into per-group tables.
- `allocation_cost.cr` measures one `GC.malloc` at the sizes searches use.
- `run_study.sh OUT_DIR [CASE_LIST]` builds the PCRE2-JIT, Mica and
  Mica-static runners with `--release` and runs the cases a list names
  (`case_list.txt`: the Amber corpus and the rebar cases whose haystack is
  at most 4 KiB), and `compare_engines.rb` compares the three engines per
  group. `run.sh --engines pcre2-jit,mica,mica-static` measures every case.
- `static_differential.cr` checks the static path against the runtime
  engine and PCRE2 on the Amber patterns and a generated sample
  (`list_differential_patterns.cr`, `write_differential_patterns.rb`) over
  generated Amber haystacks, and sums the heap bytes the static searches
  allocate. `spec/regex/static_corpus_differential_spec.cr` is the
  differential the spec suite runs on every corpus pattern.
- `build_cost.rb OUT_DIR` measures the build-time program per corpus
  pattern and the build of a small application with and without static
  patterns, and the size of each binary.

## Inflate (`bench/deflate/`)

Mica's Inflate decoders (`Mica::Deflate`, `Mica::Zlib`, `Mica::Gzip`)
against the system zlib. The bar is a speed of at least 1.0x zlib's on
every case, one-shot and streaming, with zlib allocating its output buffer
per decode as Mica's one-shot API does; the report lists every case below
it.

**Measured** (2026-11-22, Apple M1 Max, zlib 1.2.12, 93 cases, 8 to 12
interleaved rounds on a shared machine with a 1-minute load average
between 26 and 152):

| | Geometric mean, Mica / zlib (95% interval) | Cases at or above 1.0x | Cases whose whole interval is at or above 1.0x |
|---|---|---|---|
| One-shot | 1.023 (1.016 to 1.029) | 54 of 93 | 27 of 93 |
| Streaming, 64 KiB buffers | 1.082 (1.075 to 1.090) | 84 of 93 | 70 of 93 |

The Z1 run of 2026-11-21 measured 0.691 one-shot and 0.548 streaming. The
bar is met at the geometric mean and not on every case. The one-shot cases
furthest below it are 0.79 to 0.92: `ptt5`, the 64 KiB and 1 MiB JSON
bodies, the 1 MiB HTML body and `kennedy.xls`. For an output over 160 KiB
zlib's engine is handed the output size and Mica's decoder is not; and in
a process that only decodes 0.5 to 1 MiB outputs, the collector ran once
per decode for Mica against once every two or three decodes for zlib at
the same bytes allocated. With a 256 MiB initial heap for both engines the
one-shot geometric mean over the Canterbury and HTTP cases is 1.094 and
the lowest case 0.91. The same cases built with a newer compiler measured
1.041 one-shot and 1.063 streaming at the geometric mean, with the 64 KiB
JSON body at 1.29 to 1.49 one-shot and the 1 MiB JSON body at 0.84 to 0.87.

```sh
bench/deflate/run.sh            # every corpus; 8 rounds, 16 where an interval reaches 0.5x or 1.0x
bench/deflate/run.sh --quick    # Canterbury and the HTTP bodies, 3 rounds, for iteration
```

One command fetches and verifies the corpus, builds the three runners with
`--release`, runs the rounds and prints the path of the report
(`bench/data/deflate/runs/<UTC time>/REPORT.md`, with `results.json`,
`run.json`, `samples.jsonl`, `memory.jsonl` and `run.log` beside it).
Other options: `--out DIR` (a run directory is resumable: samples it
already holds are kept, so a long run can be done in pieces),
`--engines LIST`, `--corpora canterbury,silesia,http`, and anything after
`--` goes to the driver (`--only silesia/mozilla` filters case ids,
`--rounds`, `--max-rounds`, `--samples`, `--skip-memory`, `--timeout`).
Requirements: `crystal-alpha`, `/usr/bin/ruby` and macOS's `/usr/bin/time`,
`otool` and `dyld_info`. The downloads take 69 MB and the extracted and
compressed files about 500 MB under `bench/data/deflate/` (git ignores
it).

**Corpus** (`bench/deflate/corpus.tsv`, every row pinned by sha256 with
the source of the hash): the Canterbury corpus (11 files) and the Silesia
corpus (12 files, 212 MB), downloaded by
`bench/deflate/scripts/fetch_corpus.rb`, which deletes a download whose
sha256 differs and fails; and seven real HTTP response bodies committed
under `bench/deflate/corpus/http/` (HTML at about 1 KiB, 16 KiB, 64 KiB
and 1 MiB, JSON at about 1 KiB, 16 KiB and 64 KiB; `parts.tsv` lists each
URL and capture date, and `scripts/capture_http_bodies.rb` is how they
were captured). Each file is compressed once by the system zlib at level 6
as gzip, zlib and raw DEFLATE, so a case is a file in one format: 90
cases. (The Z1 run of 2026-11-21 also measured a 1 MiB JSON body of
joined Amber issue pages, 93 cases in all; it is not committed because
the issue bodies quote git commit hashes that the pre-commit secret
scanner reads as keys.)

**Engines**, each measured in its own release-built process, one process
at a time:

| Engine | Program | What it is |
|---|---|---|
| `zlib-oneshot-fresh` | `bench/deflate/zlib_runner.cr` | The baseline of the gate. System zlib through the harness's own `lib` binding: one `inflate(Z_FINISH)` into an output buffer of the known size, allocated untouched from the collector for every decode, as Mica's one-shot API allocates the `Bytes` it returns. |
| `zlib-oneshot-reused` | `bench/deflate/zlib_runner.cr` | zlib's best case: the same call into one buffer allocated when the process starts and reused by every decode. |
| `zlib-stream` | `bench/deflate/zlib_runner.cr` | The same binding with 64 KiB input and output buffers. |
| `mica-oneshot` | `bench/deflate/mica_runner.cr` | `Mica::Gzip.decode`, `Mica::Zlib.decode`, `Mica::Deflate.decode` with `DecodeLimits::TRUSTED_ASSET` and no timeout. The program links no libz. |
| `mica-stream` | `bench/deflate/mica_runner.cr` | `Mica::Gzip::Reader` and its siblings, read through a 64 KiB slice. |
| `stdlib-reader` | `bench/deflate/stdlib_runner.cr` | Crystal's `Compress::Gzip::Reader` and siblings, read through a 64 KiB slice. A context row. |

**Method.** A process does one warm-up decode and 11 timed samples, and
reports the median and the minimum as milliseconds and as MB (1,000,000
bytes) of decoded output per second; a decode under 10 ms is timed in
batches. Every sample's output is hashed after its clock stops and must
equal the original file's sha256, or the runner exits non-zero. Rounds
interleave the engines (Mica before its zlib pair in even rounds, the
reverse order in odd ones) and record the load average, because the ratio of two engines
measured back to back holds up on a busy machine where absolute times do
not. The Mica/zlib speed ratio of a case is the geometric mean of its
per-round ratios, with a 95% paired-bootstrap interval over the rounds
(10,000 resamples, fixed seed); the headline is the geometric mean over
the cases. Peak memory is the maximum resident set size of a separate
process doing one decode (`/usr/bin/time -l`). `run.json` records the
macOS build, the CPU, the `crystal-alpha` version and the zlib identity
(`zlibVersion()`, the sha256 of the SDK's `libz.tbd`, and the `dyld_info`
UUID of `/usr/lib/libz.1.dylib`).

**The report** lists the gate result and the gap, geometric means per
corpus and format, every case where Mica is slower than zlib with its
margin, every case's absolute numbers for both engines with the ratio and
interval, peak memory, the load averages, and the method and machine.

## YAML (`bench/yaml/`)

Mica's YAML parser against libyaml 0.2.5 (through the standard library's
`YAML::PullParser` and `YAML.parse_all`) on real configuration files. The
bar for M4 is a speed of at least 1.0x libyaml's on every corpus.

```sh
bench/yaml/run.sh                 # 7 interleaved rounds
bench/yaml/run.sh --rounds 3      # options after the script name go to scripts/run_ab.rb
```

One command fetches and verifies the corpus, builds the runner with
`--release`, runs the rounds and prints the path of the report
(`bench/data/yaml/runs/<UTC time>/REPORT.md`, with `results.json`,
`samples.tsv` and `run.json` beside it). With `CRYSTAL_MICA_STDLIB` set to
the `src/` directory of a crystal-alpha fork checkout that has the
`-Duse_mica` YAML engine and `CRYSTAL_BIN` to its compiler binary, a second
runner is built from that standard library with `-Duse_mica` (the script
checks that it links no libyaml), and the report also measures the
standard library's own calls on Mica.

**Corpus** (`bench/yaml/corpus.tsv`, every row pinned by sha256; `url`
rows also by the commit in their URL): Kubernetes manifests (ingress-nginx
`deploy.yaml`, Argo CD `install.yaml` at 2.1 MB, two kube-prometheus
manifests), GitHub Actions workflows (Crystal's Linux, Windows and macOS
workflows and two starter workflows), `shard.yml` and `shard.lock` files
(Crystal, Shards, Amber), and the configuration of a generated Amber V2
application (`config/environments/*.yml`, `shard.yml`, `shard.lock`, with
the secret key replaced by zeros): 19 files, 2,260,224 bytes.

**Engines.** `mica-events` reads every event and takes every scalar's
value with `Mica::YAML::PullParser` in the YAML 1.2 dialect;
`mica-events-libyaml-dialect` does the same in the libyaml dialect;
`stdlib-events` does the same with `YAML::PullParser` on libyaml.
`mica-parse` is `Mica::YAML.parse_all` and `stdlib-parse` is
`YAML.parse_all` (both build values under the core schema). `flag-events`
and `flag-parse` are the stdlib calls in the `-Duse_mica` build.
`stdlib-emit` and `flag-emit` write every document of the file back with
`to_yaml` (parsed once before the clock starts), which measures
`YAML::Builder` on libyaml's emitter and on Mica's; their MB/s counts the
bytes of the source file. The event
engines print a checksum (events plus scalar bytes); the driver stops when
the libyaml-dialect engines and libyaml disagree on it.

**Method.** Every round measures every engine on every file once, one
process at a time, with the engine order reversed on alternate rounds.
Each Mica engine is compared with the libyaml engine doing the same work
round by round; a file's ratio is the median of its paired ratios, and a
corpus or the whole set combines file ratios with the geometric mean.
MB/s is total bytes over total time (MB is 10^6 bytes).

**Result** (Apple M1 Max, macOS 26.5.2, 7 rounds, 2026-11-22T16:30:58Z; libyaml sha256 4970f13ebb9075a72f171d232ea9e990141e25806bf5c231cd0cf483dcb71552; load average { 104.42 102.62 118.11 }; the `to_yaml` row is from its own 7-round run right after):

| Comparison | Whole corpus | Mica MB/s | libyaml MB/s | kubernetes | github-actions | shards | amber | Slowest file |
|---|---|---|---|---|---|---|---|---|
| Events, YAML 1.2 dialect | **1.91x** | 128.7 | 66.0 | 1.98x | 1.95x | 1.86x | 1.87x | 1.44x (starter-crystal.yml) |
| Events, libyaml dialect | **1.79x** | 117.7 | 66.0 | 1.87x | 1.66x | 1.76x | 1.90x | 1.25x (starter-crystal.yml) |
| Values (`parse_all`) | **1.50x** | 95.3 | 61.4 | 1.55x | 1.36x | 1.63x | 1.48x | 1.20x (starter-crystal.yml) |
| `YAML::PullParser` with `-Duse_mica` | **1.84x** | 137.5 | 66.0 | 2.05x | 1.84x | 1.64x | 1.89x | 1.19x (crystal-shard.yml) |
| `YAML.parse_all` with `-Duse_mica` | **1.61x** | 95.7 | 61.4 | 1.52x | 1.65x | 1.53x | 1.74x | 1.16x (starter-crystal.yml) |
| `to_yaml` (`YAML::Builder`) with `-Duse_mica` | **1.26x** | 42.6 | 45.6 | 1.01x | 1.10x | 1.55x | 1.41x | 0.86x (argo-cd-install.yaml) |

Read as "N times as fast as libyaml". The machine was busy with
other builds during the run (the load average above), so single rounds
swing widely (`results.json` has every file's range and `samples.tsv`
every measurement); the paired medians are what the table reports. Every
file's median ratio is above 1.0 in every parsing comparison (the lowest
is 1.16x). Writing is 1.26x on the geometric mean, because short files
gain most; by total bytes it is 0.93x (42.6 against 45.6 MB/s), since the
2.1 MB Argo CD manifest, most of the corpus, is written at 0.86x.
