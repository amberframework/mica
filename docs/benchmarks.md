# Benchmarks

Mica has two benchmark harnesses:

- **XML** (`bench/run.sh`): Mica::XML against libxml2. See the README,
  "Benchmarks".
- **Regex** (`bench/regex/`): Mica::Regex against PCRE2 as Crystal uses it
  today. This page covers it.

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
  (`list_of_process_cold_seconds`). The runner builds the haystack, then
  runs a full collection outside the clock, so the window opens with the
  collector at rest: the garbage the haystack builder leaves is the
  harness's, and the collection it is owed (about 150 us in any Crystal
  process) would otherwise land inside the window of whichever engine
  allocates on the GC heap first. PCRE2 allocates with `malloc`, so it
  never did; a collection the engine's own allocation causes is still
  timed;
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
