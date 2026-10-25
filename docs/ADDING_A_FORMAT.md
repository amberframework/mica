# Adding a format to Mica

Mica is one library with many formats. Each format lives in its own
namespace (`Mica::XML` today; `Mica::JSON`, `Mica::YAML`, `Mica::CBOR`,
`Mica::COSE`, `Mica::HTTP1`, `Mica::URI`, `Mica::Multipart`, `Mica::CSV`,
`Mica::TOML` and `Mica::Markdown` later) and builds on `Mica::Core` for
everything that is not specific to its grammar. A new format needs no
change to `Mica::Core`: it includes the core modules, implements a few
hooks, and reuses the error types, the work budget and the test harnesses.

`spec/core/core_spec.cr` contains `ToyRecordReader`, a complete binary
format in about 60 lines. Read it next to this guide.

## Layout

```
src/mica.cr                  requires core and every format
src/mica/core.cr             shared machinery (no format code)
src/mica/<format>.cr         the format's entry point (Mica::<Format>.parse ...)
src/mica/<format>/...        its scanner, tree, writer, options
src/mica/testing.cr          opt-in test harnesses (not loaded by require "mica")
spec/<format>/...            the format's specs
spec/requirements/<format>.tsv   its requirement catalog
fuzz/<format>_fuzz.cr        its seeds, tokens and fuzz trial
```

Configuration lives in Crystal: a format's options are a struct or class of
constructor arguments with safe defaults (like `Mica::XML::ParserOptions`),
passed to its `parse` method. `shard.yml` stays a package manifest.

## Extension points in Mica::Core

### Input: `Core::ByteInput`

Include `Mica::Core::ByteInput` in the scanner class. It gives the scanner
`@buffer`, `@pos`, `@limit` and `@mark` as instance variables (so hot loops
pay no extra indirection) and handles both inputs:

- `setup_in_memory(bytes)`: scan a `Bytes` in place, no copy;
- `setup_stream(io)`: read an `IO` into one growable buffer.

The scanner sets `@mark` to the start of each token; `fill` keeps every
byte from `@mark` (and from `@pin` when set) and compacts or doubles the
buffer, so each streamed byte is copied O(1) times. Use `peek_byte`,
`peek_byte_at`, `ensure_bytes`, `at_source_end?`, `starts_with?` and
`skip_literal?` for lookahead. Offsets kept across a `fill` must be relative
to `@mark`.

The format implements five private hooks:

| Hook | Purpose |
|---|---|
| `input_token_limit : Int32` | largest token the buffer must hold |
| `input_size_limit : Int64?` | cap on total input bytes, or nil |
| `input_limit_error(message) : NoReturn` | raise the format's positioned `Mica::LimitExceededError` |
| `moving_input(count)` | charge the bytes compaction or buffer growth is about to copy |
| `input_size_exceeded(message, excess_index) : NoReturn` | raise the input-size `Mica::LimitExceededError` at buffer index *excess_index*, the first byte past `input_size_limit` |
| `discarding_input(keep : Int32)` | called before `@buffer[0, keep]` is dropped (fold line or column state) |
| `input_received(count : Int32)` | called as bytes arrive; call `meter.add_units(count)` here |

`source_offset_at(buffer, pos, base)` maps a scanner position to a byte
offset in the original input.

A binary format (CBOR, COSE) includes `ByteInput` alone.

### Text: `Core::TextInput`, `Core::LineTracking`, `Core::UTF8`

A text format includes `Mica::Core::TextInput` (which includes
`ByteInput`) and `Mica::Core::LineTracking`:

- `Core::UTF8.decode(bytes, offset, limit)` decodes strictly: overlong
  forms, surrogates, values above U+10FFFF, 5- and 6-byte forms, stray
  continuation bytes and truncated sequences fail with a `Problem`. Nothing
  is ever replaced with U+FFFD.
- `Core::Encoding.from_byte_order_mark` and `Core::Encoding.from_label`
  detect encodings; `setup_transcoded_stream` (after a byte order mark) or
  `switch_to_transcoder` (after an in-band declaration, as XML's
  `encoding="..."`) route the rest of the input through `Core::Transcoder`,
  which turns UTF-16, UTF-32 and ISO-8859-1 into UTF-8 in Crystal. Invalid
  code units arrive as marker bytes that are never valid UTF-8, so the
  scanner reports them at their exact source offset.
- `record_line_break(next_line_start)` after each line end the format
  defines (XML 1.1 adds NEL and LSEP; YAML and TOML have their own rules);
  `column_at(buffer, pos, base)` counts characters lazily with a cache, so
  asking for a position after every event stays linear.

### Errors: `Mica::Error` and `Core::Position`

Every error is a `Mica::Error`. Grammar errors are `Mica::ParseError`s
carrying a `Core::Position` (byte offset; line and column for text formats,
0 for binary formats). Use the shared subclasses before adding new ones:

| Class | Use |
|---|---|
| `Mica::ParseError` | input that breaks the grammar |
| `Mica::EncodingError` | bytes that are not valid in the input's encoding |
| `Mica::LimitExceededError` | a configured limit (depth, size, count) |
| `Mica::WorkBudgetExceededError` | the work budget |
| `Mica::DeadlineExceededError` | the wall-clock deadline |

A format-specific error (like `Mica::XML::NormalizationError`) subclasses
one of these inside the format's namespace. Errors that are not about
input (query or writer misuse) subclass `Mica::Error` directly, like
`Mica::XML::XPathError`.

### Work budget: `Core::WorkBudget`, `Core::WorkMeter`

Every operation runs under a `WorkMeter`:

1. Create it from the format's default budget, or accept one from the
   caller (`parse(source, options, meter)`), so several operations can
   share one budget.
2. Add units as input arrives (`meter.add_units` in `input_received`).
3. Charge work with `meter.charge(n)`: one operation per byte scanned, and
   one per step of every loop that does not advance through the input
   (hash probes, declaration lookups, tree walks, comparisons). Charging
   is an add and a compare; when it returns true, call
   `meter.enforce { position }`, which raises the positioned
   `Mica::WorkBudgetExceededError` or `Mica::DeadlineExceededError` when
   the budget or the deadline has run out (the block runs only then).
4. In long scanning loops, charge at least every 64 KiB (`SCAN_CHUNK` in
   the XML reader) so a single huge token cannot outrun the meter. Charge
   each further pass over input-derived bytes (a copy, a hash, a
   conversion, a buffer move) before it runs. A small fixed amount may be
   gathered first and charged within the same token (the XML reader
   gathers copies under 256 bytes, its in-token bookkeeping and the name
   work of a start tag with at most 16 attributes), and name interning is
   charged at the token's checkpoint, so a budget trip overshoots by at
   most the names of one narrow tag (17 names of up to `max_name_bytes`:
   the element and 16 attributes) or one 64 KiB chunk. Three more bounded
   steps are charged right after they run rather than before: comparing
   same-hash candidates in a name-table lookup (at most `MAX_RUN` + 1 of
   them, and only on a full 32-bit hash match under a per-table random
   seed), the geometric growth of a string builder, array or hash (its
   copies and rehashes total a constant multiple of the entries added,
   which are charged), and escaping at most 4 KiB before a metered write.
   A lookup or insert in a Crystal `Hash` or `Set` counts as one
   operation. This bound holds in expectation, not in the worst case:
   `Crystal::Hasher` seeds string and integer hashing from a secure
   random source once per process and Mica never exposes a hash value,
   so input cannot be built to collide without the seed, but Crystal's
   `Hash` does not cap its probe runs the way the name table does. Formatting an
   error message reads at most a fixed window of input (an excerpt of 120
   characters, at most 480 bytes) and is not charged. Work that follows a completed operation
   (settling an edit's name-table work) is recorded without raising; the
   next charge trips. Three kinds of work ride on a charge already made,
   because each is at most a small constant multiple of it: writing the
   output of a charged scan when it emits at most 4 bytes per charged
   byte or charged reference (line-end normalization and reference
   expansion into scratch, a DTD literal scanned into a builder, and a
   transcoder's conversion of source units whose decoded bytes the format
   charges as it reads them, at most one 64 KiB chunk ahead); clearing a
   collection whose entries were each charged when they were added; and
   an XPath syntax-tree constructor reading its own children, so each
   node, charged as at least one token, is read at most twice more.
5. Call `meter.enforce_deadline { position }` after each IO read (in the
   `input_received` hook, and for `TextInput` formats also in
   `source_read_returned`, which runs after each read a transcoder makes
   from the source), when an operation starts and before it reports
   success, and offer `renew_meter` for long-lived streams (giving the new
   meter the units of bytes already buffered).

Pick the default budget from measurement: run the format's corpus and its
fuzz campaign, read `max_ops_per_unit` from the report, and set
`operations_per_unit` to at least ten times that. XML measures at most
5.6 operations per byte (the maximum over 2,000,000 fuzz cases)
and uses 64, about eleven times that.

### Linear-time searching: `Core::ByteSearch`

`Core::ByteSearch.index(haystack, needle) { |steps| meter.charge(steps) }`
is Knuth-Morris-Pratt search with work accounting. Use it for any
caller-supplied pattern (stdlib `String#index(String)` can be made
quadratic).

## Rules every format follows

- **No Regex in `src/`.** `scripts/check_linkage.sh` enforces it, and a
  minimal program must link only libgc, libiconv and libSystem.
- **Linear time.** Before writing the scanner, list every loop and data
  structure whose cost can grow faster than the input (rescans, nested
  lookups, unbounded backtracking, repeated copying, hash flooding) and
  design it away. Prove each with a complexity spec.
- **Bounds-checked memory.** Read input through `Slice` indexing,
  `Slice#index` or `Slice#each`. For hot paths over byte runs, use
  `Core::ByteScan.skip_while`, `Core::ByteScan.matches?` and
  `Core::ByteScan.copy_into`, which check their whole window once and then
  work without per-byte checks; they are the only unchecked accesses in
  Mica. Raw pointers, `to_unsafe` and `unsafe_fetch` stay out of format
  code.
- **Iterative, bounded nesting.** Use explicit stacks with a depth limit,
  never recursion on input structure.
- **Exact positions.** Every error names the byte where the problem is.
- **Same result from bytes and from streams.** A `String`, a `Bytes` and a
  one-byte-at-a-time `IO` give identical events and identical errors.

## Testing a format

`require "mica/testing"` in specs and fuzz drivers.

### Complexity specs (`Mica::Testing::Complexity`)

```crystal
result = Mica::Testing::Complexity.measure("many keys", 10_000) do |count|
  meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
  Mica::JSON.parse(build_object_with(count), meter: meter)
  meter.operations
end
result.linear?.should be_true # operations at 4n within 4 x 1.25 of n
```

Write one per entry in the format's superlinear inventory, plus the shapes
of known CVEs in other parsers for the same format. Operation counts, not
wall time, decide the verdict, so the specs pass on a loaded machine. Add a
probe spec that the counter is honest: a deliberately quadratic workload
must fail `linear?`.

### Fuzzing (`Mica::Testing::ByteMutator`, `Mica::Testing::FuzzCampaign`)

Give `ByteMutator` the format's seed documents and grammar tokens. It mixes
structural mutations with every hostile byte class (invalid UTF-8 of each
kind, controls, noncharacters, misplaced byte order marks, re-encoding as
UTF-16, UTF-32 or ISO-8859-1). Every case is replayable as `seed:iteration`.

`FuzzCampaign#run` takes a block that parses one case and returns a
`Trial`. It reports crashes (any exception that is not a `Mica::Error`),
budget overruns (operations beyond the allowance plus the format's check
interval) and, with `check_determinism: true`, cases whose outcome differs
between two runs. Compare a `Bytes` parse with a trickling-IO parse inside
the trial. Run at least 2,000,000 cases in release mode before a release.

### Hostile-bytes matrix

Put every `ByteMutator::HOSTILE` class into every syntactic context of the
format (strings, keys, comments, numbers, names) and assert the exact error
class and byte offset an independent oracle predicts. Parse every proper
prefix of a few documents and assert each is rejected the same way from
bytes and from a stream. `spec/xml/hostile_bytes_spec.cr` is the model.

### Requirement traceability (`Mica::Testing::Traceability`)

List the specification's requirements in `spec/requirements/<format>.tsv`
(`id<TAB>section<TAB>summary`, for example
`RFC8949-3.1-major-types<TAB>RFC 8949 3.1<TAB>Major types`). Declare
coverage in specs:

```crystal
it_satisfies "RFC8949-3.1-major-types", "decodes every major type" do
  # ...
end
it_satisfies({"RFC8949-3.3-floats", "MICA-LINEAR-CBOR-FLOATS"}, "decodes half floats") do
  # ...
end
```

`spec/traceability_spec.cr` fails on unknown ids and, in the full suite, on
uncovered ones; `MICA_TRACEABILITY_REPORT=path` writes the coverage table.

### Conformance

When a public test suite exists (xmlconf for XML, JSONTestSuite for JSON,
yaml-test-suite for YAML, the CBOR appendix vectors), add a runner under
`conformance/` that verifies the suite archive's sha256 and reports pass
counts per category.

## Checklist for a new format

1. `src/mica/<format>.cr` with `Mica::<Format>.parse(source, options, meter)`.
2. Options with safe defaults and a measured default `WorkBudget`.
3. Scanner on `ByteInput` (binary) or `TextInput` + `LineTracking` (text).
4. Superlinear inventory and complexity specs.
5. Hostile-bytes matrix, truncation and stream-equivalence specs.
6. Seeds, tokens and a fuzz trial in `fuzz/<format>_fuzz.cr`; 2,000,000
   clean cases.
7. Requirement catalog and `it_satisfies` coverage.
8. Conformance runner and benchmarks against the reference implementation.
9. `scripts/check_linkage.sh`, `crystal-alpha tool format --check` and
   `bin/ameba` clean; zero compiler warnings.
