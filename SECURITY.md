# Security policy

Mica parses untrusted input: request bodies, uploads, storage listings,
patterns and compressed streams from people you have never met. A way to
make it do more work than its budget allows, use more memory than its
limits allow, read past a buffer, or fetch something while parsing is a
security bug, and we want to hear about it.

## Reporting a vulnerability

Report it privately through
[GitHub's private vulnerability reporting](https://github.com/amberframework/mica/security/advisories/new)
(the **Report a vulnerability** button on the Security tab), or email
agent_c@agentc.consulting with "Mica security" in the subject.

Please include the Mica version or commit, the compiler (stock Crystal or
crystal-alpha, with or without `-Duse_mica`), the limits you passed, and the
smallest input that shows the problem. A test case that runs under
`bin/specs` is ideal.

We confirm each report, keep you posted while we fix it, and credit you in the advisory and the changelog unless you would
rather stay anonymous.

## Supported versions

| Version | Security fixes |
|---|---|
| `main` | yes |
| 0.2.x | yes |
| 0.1.x | upgrade to 0.2.x |

## What Mica promises

Every parse runs under three kinds of bounds. The defaults are listed in
each format's guide, and every entry point requires the limits as an
argument, so no call runs unbounded by accident.

**Work budgets.** Each parse, search, decode and XPath evaluation counts
its work in abstract operations against an allowance that grows linearly
with its input. An input that needs superlinear work trips the budget and
raises `Mica::WorkBudgetExceededError`.

| Format | Allowance |
|---|---|
| `Mica::Regex` search (`SearchLimits::REQUEST`) | min(10^8, 64 per program state + 4,096 + 4,096 per haystack byte) operations |
| Inflate (`DecodeLimits` presets) | 10^6 + 64 per byte read and per byte written |
| XML parse (`ParserOptions::DEFAULT_WORK_BUDGET`) | 10^6 + 64 per input byte |
| XPath evaluation | 10^6 + 64 per node |

**Deadlines.** A `timeout:` adds a wall-clock deadline, checked at work
checkpoints, at every read from a stream, and before a search reads its
haystack. It raises `Mica::DeadlineExceededError`. A read that blocks
forever never returns to Mica, so give sockets a read timeout
(`IO#read_timeout`).

**Limits.** Each limit is checked before the bytes it guards are written:

- Regex: pattern bytes, nesting depth, captures, class ranges, program
  states and compile memory (`CompileLimits::UNTRUSTED_PATTERN` allows a
  4 KiB pattern and 4 MiB of compile memory), and output bytes for `gsub`,
  `sub` and `split`.
- Inflate: output bytes (8 MiB for `REQUEST_BODY`), output-to-input ratio
  (1,100), window size (32 KiB), gzip members and metadata bytes. A
  decompression bomb costs at most its output cap plus fixed buffers.
- XML: entity expansions and their bytes, default attributes, entity and
  element depth, name, token and input size, attributes per element.
  External entities and external DTD subsets are never fetched.

**No unbounded backtracking.** `Mica::Regex` searches run in time linear in
the haystack. Backreferences, lookaround and the other constructs that need
backtracking are refused at compile time, so a pattern cannot be a ReDoS.

**Memory safety.** Scanners and node storage read memory only through
bounds-checked slices, and the parsers and tree walks are iterative, so
deep input cannot overflow the machine stack.

**No C parsers.** A Mica program links no PCRE2, libz or libxml2
(`scripts/check_linkage.sh` proves it), so their CVEs do not reach it.

## How we test it

Differential fuzzing against PCRE2, system zlib and libxml2; complexity
specs that run each hostile family at n and 4n and require linear growth;
the ReDoS benchmark corpus; zip-bomb and malformed-stream corpora; and the
W3C XML conformance suite. See [docs/regex.md](docs/regex.md),
[docs/compression.md](docs/compression.md), [docs/xml.md](docs/xml.md) and
[docs/benchmarks.md](docs/benchmarks.md).
