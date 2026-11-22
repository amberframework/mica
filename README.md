<a href="#install">
  <img src="docs/brand/hero.svg" width="100%" alt="Mica: reads untrusted bytes, never guesses. Mica, the Amber crew's reader, at a lectern in a library. A brass loupe sweeps across a request line and lights up the date a regex matches.">
</a>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/badges-dark.svg">
    <img src="docs/brand/badges-light.svg" width="860" alt="Pure Crystal · No PCRE2, no libz, no libxml2 · Linear-time search · Work budgets and deadlines · v0.2.0 · MIT">
  </picture>
</p>

<p align="center">
  <b>Mica is Amber's pure-Crystal parsing library.</b><br>
  Regex, gzip, zlib, DEFLATE, XML and UTF-8, with a work budget and a deadline on every parse.
</p>

<br>

## Install

```yaml
dependencies:
  mica:
    github: amberframework/mica
    version: 0.2.0
```

```crystal
require "mica"
```

> [!NOTE]
> 0.2.0 has `Mica::Regex` and `Mica::XML`. Inflate (`Mica::Gzip`, `Mica::Zlib`, `Mica::Deflate`) is on `main` and ships in the next release. To use it now, pin the merge commit: `commit: 25b528051464b7ce795478a3519f729eec10b590`.

## Two ways to use it

### 1. Mica's own API, on any Crystal compiler

```crystal
limits = Mica::Regex::SearchLimits::REQUEST
date = Mica::Regex::Expression.new("(?<year>\\d{4})-(?<month>\\d{2})",
  compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
date.match("due 2026-11", limits: limits).try(&.["year"]) # => "2026"

# Compiled while the app builds: read-only tables, no allocation per search.
SLUG = Mica::Regex.static(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
SLUG.matches?("pure-crystal-parsing") # => true

body = Mica::Gzip.decode(gzipped, limits: Mica::Deflate::DecodeLimits::REQUEST_BODY, timeout: 2.seconds)
document = Mica::XML.parse(File.read("feed.xml"))
```

`Mica::Regex::Expression` follows stdlib `Regex` method for method, plus the limits. Guides: [Regex](docs/regex.md) · [Inflate](docs/compression.md) · [XML](docs/xml.md).

### 2. Crystal's own `Regex` on Mica, with crystal-alpha

```sh
crystal-alpha build -Duse_mica src/app.cr
```

With `-Duse_mica`, Crystal's own `Regex` (regex literals, `$~`, `String#match`, `gsub`, `scan`, `split`) runs on Mica with no code changes, and the binary links no PCRE2. It arrived in [crimson-knight/crystal#17](https://github.com/crimson-knight/crystal/pull/17) (merged).

> [!IMPORTANT]
> This is opt-in today. PCRE2 stays the default without the flag, and stock Crystal does not have `-Duse_mica`: it needs the crystal-alpha compiler.

## What Mica leaves out, and the rewrite

Mica's searches run in time linear in the input, so it refuses the constructs that need backtracking. `Mica::Regex` raises `UnsupportedConstructError` naming the construct and its byte; under `-Duse_mica`, a regex literal that uses one is a compile error.

| Instead of | Write | Then, in Crystal |
|---|---|---|
| Backreference `(\w+) \1` | `(\w+) (\w+)` | `match[1] == match[2]` |
| Lookahead `\d+(?= USD)` | `(\d+) USD` | use `match[1]` |
| Lookbehind `(?<=\$)\d+` | `\$(\d+)` | use `match[1]` |
| Negative lookahead `\A(?!admin\z)\w+\z` | `\A\w+\z` | `&& name != "admin"` |
| Atomic group `(?>a+)`, possessive `a++` | `a+` | nothing: Mica never backtracks |

The full list (recursion, conditionals, `\K`, verbs, newline conventions) is in [Excluded constructs](docs/regex.md#excluded-constructs).

## Speed

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/regex-speed-dark.svg">
  <img src="docs/brand/regex-speed-light.svg" width="100%" alt="Mica::Regex against PCRE2 with JIT, geometric means over 479 cases. Compiled at run time: warm search 2.4× as fast (29.85 µs vs 72.39 µs), compile 1.7× as fast, cold first search 3.0× as fast, process-cold 2.3× as fast. Mica::Regex.static over 412 cases: warm search 2.0×, compile 24×, cold first search 11×, process-cold 6.2× as fast.">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/amber-patterns-dark.svg">
  <img src="docs/brand/amber-patterns-light.svg" width="100%" alt="The 26 patterns Amber apps run, process-cold, against PCRE2 with JIT: routes 2.5× as fast, templates 2.6×, Markdown 2.8×, logs 2.6×, CSV 2.7×, contacts 2.1×, identifiers 2.9×. All 104 Amber cases: 2.6× as fast (210.91 µs vs 552.64 µs).">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/redos-dark.svg">
  <img src="docs/brand/redos-light.svg" width="100%" alt="Hostile patterns finish. Over 112 ReDoS cases Mica::Regex is 8.8× as fast on warm search (330.1 ns vs 2.91 µs) and hits no limit, where PCRE2 with JIT stopped on a limit 28 times and timed out once. All 13 ReDoS families finish inside 1,000 ms, with linear growth.">
</picture>

<details>
<summary><b>See it run: the ReDoS corpus in a terminal</b></summary>
<br>

<img src="docs/img/redos-run.png" width="100%" alt="Terminal output of bench/regex/run.sh on the ReDoS corpus. At 262,144 and 1,048,576 input units, pcre2-jit lines end in 'JIT stack limit reached' or 'match limit exceeded', while every mica line reads ok with its warm, compile and process-cold times.">

<sub>`bench/regex/run.sh --quick --corpora redos --engines pcre2-jit,mica`, run on 2026-11-22 at `main` (25b5280). PCRE2-JIT stops on its stack or match limit; Mica finishes all 143 cases.</sub>

</details>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/inflate-dark.svg">
  <img src="docs/brand/inflate-light.svg" width="100%" alt="Inflate against system zlib, decode time over 93 cases. One-shot: 1.45× slower than zlib. Streaming with 64 KiB buffers: 1.83× slower. Against zlib reusing one output buffer: 1.86× slower. The Z1 milestone allowed up to 2× slower.">
</picture>

Regex numbers come from the full harness at commit `f0bb0f6`, the code tagged v0.2.0; Inflate numbers from the Z1 run merged in #18. How they are measured, and how to rerun them: [docs/benchmarks.md](docs/benchmarks.md).

## How a search runs

```mermaid
flowchart TD
    source(["Pattern text"]) --> parser["Parser<br/>Crystal dialect, PCRE2 syntax"]
    parser -- "backreference, lookaround ..." --> refused{{"UnsupportedConstructError<br/>names the construct and byte"}}
    parser --> limits["Compile limits<br/>size preflight"]
    limits --> hir["Hir<br/>Unicode 17 classes, case folding"]
    hir --> compiler["Compiler<br/>byte-level NFA program"]
    static(["Mica::Regex.static<br/>tables built at app build time"]) --> plan
    compiler --> plan{"Search plan<br/>picked per search"}
    plan --> fast["Required bytes<br/>literal prefilters"]
    plan --> dfa["One-pass DFA<br/>lazy DFAs, forward and reverse"]
    plan --> nfa["Pike VM<br/>bounded backtracker"]
    fast --> found(["Match"])
    dfa --> found
    nfa --> found
    budget[["Work budget + deadline<br/>charged on every step"]] -.-> fast
    budget -.-> dfa
    budget -.-> nfa
    classDef step fill:#1A2130,stroke:#7E9BEA,color:#EDEFF5
    classDef brass fill:#E2B65B,stroke:#8A6A1F,color:#1C2231
    classDef stop fill:#F7913A,stroke:#A93C08,color:#1C2231
    class parser,limits,hir,compiler,fast,dfa,nfa step
    class source,static,found,plan brass
    class refused,budget stop
```

Every engine is linear in the input; the plan only picks the fastest one that fits the pattern and the question asked.

## Formats

| Module | Reads | Guide |
|---|---|---|
| `Mica::Regex` | Regular expressions in Crystal's PCRE2 syntax, linear-time | [docs/regex.md](docs/regex.md) |
| `Mica::Gzip`, `Mica::Zlib`, `Mica::Deflate` | gzip (RFC 1952, multi-member), zlib (RFC 1950), raw DEFLATE (RFC 1951); one-shot and streaming | [docs/compression.md](docs/compression.md) |
| `Mica::XML` | XML 1.0 and 1.1 with Namespaces: streaming reader, DOM, builder, XPath 1.0 | [docs/xml.md](docs/xml.md) |
| `Mica::Core` | Strict UTF-8, UTF-16/UTF-32/ISO-8859-1 transcoding, positions, limits, work budgets | [docs/ADDING_A_FORMAT.md](docs/ADDING_A_FORMAT.md) |

More formats (JSON, YAML, CBOR, HTTP/1.1, URIs, multipart, CSV, TOML, Markdown) plug into the same core.

## Safe by default

Mica is built for bytes from strangers: request bodies, uploads, storage listings.

- **Work budgets.** Every parse and search counts its work and stops at its allowance, so no input can buy superlinear time.
- **Deadlines.** A timeout adds a wall-clock limit, checked as the work runs.
- **Limits.** Output size, decompression ratio, entity expansion, nesting depth and pattern size are capped before the bytes they guard are written.
- **No fetching.** Mica never reads the network or the file system while parsing.
- **No C parsers.** A Mica program links only libgc, libiconv and libSystem, which Crystal itself needs (`scripts/check_linkage.sh`).

> [!TIP]
> Each format ships presets for the common jobs, such as `SearchLimits::REQUEST` and `DecodeLimits::REQUEST_BODY`. Start from one and tighten it.

Found a way past a limit? Please report it privately: [SECURITY.md](SECURITY.md).

## Questions

<details>
<summary><b>Why no backreferences or lookaround?</b></summary>
<br>

They need backtracking, and backtracking is what lets one hostile input stall a server (ReDoS). Mica keeps every search linear instead. Each construct has a short rewrite above, usually one capture group and one comparison in Crystal.

</details>

<details>
<summary><b>Does my app still link PCRE2?</b></summary>
<br>

With Mica's own API, Mica adds no PCRE2, but Crystal's stdlib `Regex` still uses it wherever your code or your shards do. Build with crystal-alpha and `-Duse_mica` to move all of it onto Mica and drop the library.

</details>

<details>
<summary><b>I use stdlib <code>XML</code>. How much changes?</b></summary>
<br>

Mostly the name: `XML` becomes `Mica::XML`. Parsing is strict (the first error raises), and nodes are small structs. The differences are listed in [docs/xml.md](docs/xml.md#differences-from-stdlib-xml).

</details>

<details>
<summary><b>Is Inflate as fast as zlib?</b></summary>
<br>

Not yet. One-shot decoding is 1.45× slower than system zlib today, inside the Z1 goal of 2×. Encoders follow in milestone Z2.

</details>

## Development

```sh
shards-alpha install --frozen
crystal-alpha build $(find spec -name '*_spec.cr' | sort) -o bin/specs && bin/specs
crystal-alpha tool format --check
scripts/check_linkage.sh     # no PCRE2, libz or libxml2 in a Mica program
bench/regex/run.sh --quick   # Mica::Regex against PCRE2
bench/deflate/run.sh --quick # Inflate against zlib
```

Fuzzing, conformance suites and the XML benchmarks: [docs/xml.md](docs/xml.md), [docs/regex.md](docs/regex.md), [docs/compression.md](docs/compression.md) and [docs/benchmarks.md](docs/benchmarks.md). Requirement ids in `spec/requirements/*.tsv` map each standard's sections to the specs that cover them.

Something off? [Open an issue](../../issues/new/choose). Questions go to [SUPPORT.md](SUPPORT.md).

## License

MIT. `src/mica/xml/composing_characters.cr` is generated from the Unicode 17.0.0 character data that ships with the Crystal standard library, under the Unicode License v3.

<br>

<p align="center">
  <a href="https://amberframework.org"><img src="docs/brand/amber-crystal.svg" width="40" alt="Amber framework"></a>
</p>
<p align="center"><sub>Part of the <a href="https://amberframework.org">Amber framework</a>. Built and maintained by</sub></p>
<p align="center"><a href="https://agentc.consulting"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/AgentC-Consulting/.github/main/brand/wordmark-dark.png">
  <img src="https://raw.githubusercontent.com/AgentC-Consulting/.github/main/brand/wordmark-light.png" alt="AgentC Consulting" width="220">
</picture></a></p>
