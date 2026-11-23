# Changelog

## Unreleased

Speeds up Brotli decoding. Against libbrotlidec 1.2.1 over 36 cases on an
Apple M4 Mac mini (m4-mini-01, 10 interleaved rounds), one-shot decoding
goes from 1.04× slower to 1.06× as fast and streaming from 1.06× slower to
1.04× as fast (geometric means; tables in `docs/brotli.md`):

- The output ring is allocated without zeroing, sized exactly for the last
  metablock when streaming too, and kept (up to 4 MiB) by a released
  streaming decoder, so a large-enough ring grows in place.
- Prefix code tables fill only `1 << max_length` root entries and repeat
  them; complex codes count their symbols in locals.
- Dictionary words with a plain transform go straight into the ring.
- The fast command loop keeps block counts, the last four distances, the
  metablock length left, the command tree and the output stop in locals,
  and decodes runs of literals of a one-tree block without per-literal
  checks; which block types use one tree is worked out once per header.
- Still slower: 13 one-shot and 15 streaming cases, all at quality 11 but
  one (`html_1m` at quality 5), the slowest 1.08× slower one-shot and
  1.14× slower streaming (alice29); run-to-run spread is a few percent per
  case. Context-modeled literal decoding is where the time goes.

Speeds up Inflate (milestone Z3). Against system zlib 1.2.12 over 93
cases, one-shot decoding goes from 1.02× to 1.09× as fast and streaming
from 1.08× to 1.12× as fast (geometric means; per case in
docs/benchmarks.md, "Z3 run: every case"):

- The fast loop comes in two builds: one for runs with no history behind
  the output (one-shot decodes and the inflater's own buffer), which
  checks a back reference against the output alone, and one for reads
  straight into a caller's slice, which may reach into the history.
- A back reference the careful path finishes is copied in whole pieces
  instead of a byte at a time.
- 19 one-shot cases are still slower than zlib (the slowest 1.21×
  slower), and one streaming case 1.01× slower. The decoder passed a
  2,000,000-case differential campaign against zlib with 0
  disagreements, and the encoder a 1,000,000-case round trip with 0
  failures.

Fixes a crash on x86_64: the guard that frees an unclosed writer's tables
had a finalizer whose last expression returned its `StaticArray`, so the
compiler gave the finalizer a hidden result pointer in the first argument
register, where the collector passes the object. The finalizer then ran
with a null `self` ("Invalid memory access at address 0x8" inside
`ReleaseGuard#finalize`). It now returns nil. Apple silicon passes that
pointer in a register of its own, which is why only x86_64 crashed.

Builds the CRC-32 for Apple silicon with the stock Crystal compiler. The
CRC32X and CRC32B instructions are now inline assembly that enables the
CRC extension itself; the LLVM intrinsics they replace stopped the build
("Cannot select: intrinsic %llvm.aarch64.crc32x") wherever the target CPU
did not declare that extension, which a default macOS build does not. CI
now runs the Deflate specs on macOS with the stock compiler too.

Fixes a leak in the streaming encoders: a `Deflate::Writer`, `Zlib::Writer`
or `Gzip::Writer` that was dropped without `close` kept its 270 KB of
tables when its destination referred back to the writer (a response whose
output is the writer), because the collector does not finalize an object it
reaches from itself. The tables now belong to a guard that holds addresses
only, which the collector finalizes in every case.

Adds `scripts/vendor_into.rb`: it places a pinned copy of one Mica component
(today `deflate`: `Mica::Deflate`, `Mica::Zlib` and `Mica::Gzip` with
`Mica::Core`) inside a library that cannot name the Mica shard as a
dependency, under that library's namespace (`Amber::Mica::Gzip`), with a
manifest of the commit and each file's sha256. `--check` fails on a file
that is missing, extra or edited.

Adds YAML (milestone M4): `Mica::YAML` reads and writes YAML in pure
Crystal.

- `PullParser` (events), `compose` (the node graph), `parse` and
  `parse_all` (values under the core, JSON or failsafe schema, with `<<`
  merge keys) and `Emitter`. Sources are a `String`, `Bytes` or `IO` in
  UTF-8, UTF-16 or UTF-32.
- Two dialects: YAML 1.2.2, which passes all 402 cases of the official
  yaml-test-suite (`data-2022-01-17`), and libyaml 0.2.5, which gives
  libyaml's events, marks and error messages (0 disagreements with
  libyaml over the differential campaigns; see `docs/yaml.md`).
- Every parse takes required `limits:` (`ParseLimits`: `max_input_bytes`,
  `max_depth`, `max_nodes`, `max_alias_expansion` and the work budget;
  presets `CONFIG_FILE`, `UNTRUSTED`, `TRUSTED_FILE`, `LIBYAML`) and a
  required `timeout:`. Aliases are shared nodes, and alias and merge
  expansion is counted and capped, which covers the billion-laughs case
  of GHSA-gmv7-hhm8-cxj5.
- The emitter writes the bytes libyaml 0.2.5 writes for the same events.
- Benchmarks against libyaml on Kubernetes, GitHub Actions, shard and
  Amber configuration files (`bench/yaml/`), and a linkage check: a
  Mica YAML program links no libyaml (`scripts/check_linkage.sh`).

Adds Inflate (compression milestone Z1): `Mica::Deflate`, `Mica::Zlib` and
`Mica::Gzip` decode raw DEFLATE (RFC 1951), zlib (RFC 1950) and gzip
(RFC 1952) in pure Crystal.

- One-shot (`decode`) and streaming (`Reader`, an `IO`) APIs. Every decode
  takes required `limits:` (`DecodeLimits`: `max_output_bytes`,
  `max_ratio`, `max_window_bytes`, `max_members`, `max_metadata_bytes` and
  the work budget; presets `REQUEST_BODY`, `HTTP_CLIENT_RESPONSE`,
  `WEBSOCKET_MESSAGE`, `TRUSTED_ASSET`) and a required `timeout:`. Limits
  raise `DecodeLimitError` before the bytes they guard are written.
- Stored, fixed and dynamic blocks; zlib FCHECK, CINFO, preset
  dictionaries and Adler-32; gzip multi-member, FEXTRA, FNAME, FCOMMENT,
  FHCRC, CRC-32 and ISIZE. Malformed streams raise
  `MalformedStreamError`, `TruncatedStreamError` or `ChecksumError` with
  the byte offset.
- Differential fuzzing against system zlib, a zip-bomb and malformed
  corpus, a port of zlib's `test/infcover.c`, and benchmarks against zlib
  (`bench/deflate/`).
- A Mica Inflate program links no libz (`scripts/check_linkage.sh`).
- Decoder speed: a spare decoder (tables and buffers) is reused by the next
  decode; Huffman tables are two-level 32-bit entries built in canonical
  order; the fast loop keeps 64 bits of input and looks the next entry up
  before each refill and each copy; CRC-32 uses the ARMv8 CRC instructions
  in three streams; a `Reader` decodes straight into a slice of 32 KiB or
  more; a one-shot result over 160 KiB is sized from the ratio the stream
  has shown. Every limit is enforced where it was. Numbers against zlib:
  `docs/benchmarks.md`, "Inflate".

Adds the Deflate encoders (compression milestone Z2): `Mica::Deflate`,
`Mica::Zlib` and `Mica::Gzip` encode raw DEFLATE, zlib and gzip in pure
Crystal, so a program that compresses with Mica links no libz.

- One-shot (`encode(input, level: 6)`) and streaming (`Writer`, an `IO`
  with `write`, `flush` for a sync flush, `full_flush` and `close`) APIs at
  levels 0 to 9. `Zlib.encode` and `Zlib::Writer` take a preset
  `dictionary:`; `Gzip.encode` and `Gzip::Writer` take a `header:`
  (default: modification time 0 and operating system 255, so the output is
  reproducible).
- zlib's algorithm and level table: a 32 KiB history, hash chains, greedy
  matching at levels 1 to 3 and lazy matching at 4 to 9, blocks of 16,383
  symbols written as the smallest of stored, fixed and dynamic Huffman.
  Against system zlib 1.2.12 over 31 files (Canterbury, Silesia and HTTP
  bodies), the corpus total is 0.9998, 0.9996 and 0.9995 times zlib's size
  at levels 1, 6 and 9, and the geometric-mean speed is 1.46, 1.30 and
  1.21 times zlib's one-shot and 1.27, 1.21 and 1.13 times streaming.
  Bodies of about 1 KiB are slower than zlib (0.58 to 0.84 times its
  speed); `docs/benchmarks.md` lists every slower case.
- A streaming encoder holds 294,992 bytes (288 KiB) at any level from 1 to
  9, however long the stream is.
- Round-trip fuzzing through system zlib and Mica's decoder
  (`fuzz/deflate_encode_campaign.cr`), a block-level reader in the specs
  that checks what was written, and benchmarks against system zlib at
  levels 1, 6 and 9 (`bench/deflate_encode/`; results in
  `docs/benchmarks.md`).
- `scripts/check_linkage.sh` also checks a minimal encoder program.

Adds `scripts/check_regex_literals.cr`, which checks every regex in a tree
of Crystal source against the Crystal dialect and exits 1 when a pattern
uses a construct Mica leaves out (lookaround, backreferences, atomic
groups, possessive quantifiers, `\K` and the others in docs/regex.md,
"Excluded constructs"). It reads literals, interpolated literals,
`Regex.new` with a string literal, literals in macro expressions and the
text of macro bodies, including code no spec reaches. Libraries run it in
CI so a pattern that stops a build on a Mica-default compiler is caught
before release.

## 0.2.0 (2026-11-21)

Adds `Mica::Regex`, a regular expression engine in pure Crystal. XML parsing
is unchanged from 0.1.1.

- Every search runs in time linear in the haystack, under a work budget
  (`SearchLimits`) and an optional deadline. Backreferences, lookaround and
  the other backtracking-only constructs are refused by name at compile time.
- The Crystal dialect reads patterns as Crystal's stdlib `Regex` does
  (PCRE2 10.49 syntax with `UTF | UCP | DUPNAMES`), with Unicode 17 classes
  and case folding.
- Engines: Pike VM, bounded backtracker, forward and reverse lazy DFAs,
  one-pass DFA, and literal prefilters, chosen per pattern.
- `Mica::Regex::Expression` follows stdlib `Regex` method for method, with
  required compile and search limits; allocation-free `search_span`,
  `search_groups` and `each_span`.
- `Mica::Regex.static` compiles a pattern while the application builds; its
  tables are read-only data and its searches allocate nothing.
- `CachePool` caps lazy-DFA caches and Pike VM workspaces process-wide
  (64 MiB by default) and keeps its member list bounded.
- A Mica::Regex program links no PCRE2 (`scripts/check_linkage.sh`).
  Crystal's stdlib `Regex` still uses PCRE2; Mica is used through its own API.
- `Mica::VERSION` reads 0.2.0.

Merged in #5, which carries #2 to #4, #7 to #12 and #14 to #16.

## 0.1.1 (2026-11-06)

- First CI: formatting and the full spec suite.
- Assistant docs: `minecart install` copies the README and format guide into
  an application.
- `Mica::VERSION` is a literal, so Mica compiles on a machine that has only
  Minecart.

## 0.1.0 (2026-11-01)

- First release: XML 1.0 and 1.1 with Namespaces, a streaming reader, DOM,
  builder and XPath 1.0.
