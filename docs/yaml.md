# YAML (milestone M4)

`Mica::YAML` reads and writes YAML in pure Crystal: a pull parser that
yields events, a node API that returns the node graph or plain values, and
an emitter. A program that uses it links no libyaml
(`scripts/check_linkage.sh` checks this).

It reads two dialects:

- `Dialect::YAML12` (the default): YAML 1.2.2. It passes every case of the
  official yaml-test-suite (402 of 402, release `data-2022-01-17`).
- `Dialect::LibYAML`: what libyaml 0.2.5 reads, event for event, mark for
  mark and error message for error message, including the places where
  libyaml departs from YAML 1.2. The crystal-alpha fork's standard library
  uses this dialect when an application is built with `-Duse_mica`, so
  `YAML.parse`, `YAML::Serializable` and `from_yaml` behave as they do on
  libyaml.

## Reading

```crystal
require "mica/core"
require "mica/yaml"

limits = Mica::YAML::ParseLimits::CONFIG_FILE

# Values under the core schema (nil, Bool, Int64, Float64, String, Array, Hash).
config = Mica::YAML.parse(File.read("config/environments/production.yml"), limits: limits, timeout: 2.seconds)
config["server"]["port"].as_i # => 3000

# Every document of a stream.
list_of_documents = Mica::YAML.parse_all(io, limits: limits, timeout: 2.seconds)

# The node graph: scalars with their style and tag, sequences, mappings,
# positions, and aliases resolved to the one node they name.
root = Mica::YAML.compose(source, limits: limits, timeout: nil)

# Events, one at a time.
parser = Mica::YAML::PullParser.new(source, limits: limits, timeout: nil)
until parser.kind.stream_end?
  puts parser.value if parser.kind.scalar?
  parser.read_next
end
```

`parse` and `parse_all` take `schema:` (`Schema::Core`, `Schema::JSON` or
`Schema::FailSafe`), `merge_keys:` (the `<<` merge key, on by default; a
mapping's own keys win over merged ones, and earlier merged mappings win
over later ones) and `duplicate_keys:` (`DuplicateKeys::LastWins` or
`DuplicateKeys::Reject`). Every entry point takes `dialect:`.

A source is a `String`, `Bytes` or an `IO`. An `IO` is read to its end
before scanning starts (the size cap applies while it is read), so all
three give identical events and positions. Input may be UTF-8, UTF-16 or
UTF-32, detected as the YAML specification describes.

## Limits

Every parse takes required `limits:` and a required `timeout:` (a
`Time::Span`, or nil for none); there is no default. `ParseLimits` holds:

| Limit | Guards | `CONFIG_FILE` | `UNTRUSTED` | `TRUSTED_FILE` |
|---|---|---|---|---|
| `max_input_bytes` | bytes read, all documents together | 1 MiB | 1 MiB | 256 MiB |
| `max_depth` | nested sequences and mappings, block and flow | 128 | 64 | 1,024 |
| `max_nodes` | nodes per document | 1,000,000 | 100,000 | 100,000,000 |
| `max_alias_expansion` | nodes per document once every alias is counted as a copy of what it names | 1,000,000 | 100,000 | 100,000,000 |
| work budget | operations: `base_work + work_per_unit * bytes` | 100,000 + 64 per byte | the same | the same |

`ParseLimits.custom(max_depth: 32)` starts from `CONFIG_FILE` and changes
the values given. A limit raises `ParseLimitError` (its `limit` names the
limit) before the memory it guards is used; the work budget raises
`Core::WorkBudgetExceededError` and the deadline
`Core::DeadlineExceededError`, each with a position.

**Alias expansion (GHSA-gmv7-hhm8-cxj5).** The node API never copies what
an alias names: an alias is the same node object. It still counts what
the copies would cost, so a "billion laughs" document (nine levels of
nine aliases, a few hundred bytes that expand to 3.9 * 10^8 nodes) stops
at the alias that would pass `max_alias_expansion`, after a few hundred
operations. Merge keys are counted the same way, a recursive alias is
rejected, and `spec/yaml/limits_spec.cr` holds the advisory's case.

**Work.** Scanning charges one operation per byte read plus one per token
moved in the token queue, and composing one per node and alias. The
differential campaigns below peak at 4.6 operations per input byte, so
the default of 64 per byte leaves real documents far from the budget and
stops only input built to make the scanner repeat work.
`spec/yaml/complexity_spec.cr` measures the work of adversarial shapes
(deep flow nesting, many and long simple keys, long scalars, alias
fan-out) at growing sizes and requires linear growth.

## Errors

All errors descend from `Mica::Error`:

- `Mica::YAML::SyntaxError` (a `Mica::ParseError`): what was wrong
  (`detail`), where (`position`, `line_number`, `column_number`), and what
  was being read (`context`, `context_position`).
- `Mica::YAML::UnknownAnchorError`: an alias with no anchor before it.
- `Mica::YAML::InvalidCharacterError` (a `Mica::EncodingError`): invalid
  UTF-8, UTF-16 or UTF-32, or a character YAML forbids.
- `Mica::YAML::ParseLimitError`, `Core::WorkBudgetExceededError` and
  `Core::DeadlineExceededError`: see Limits.
- `Mica::YAML::EmitError`: an event the emitter cannot write in its
  current state.

## Writing

`Mica::YAML::Emitter` is a port of libyaml 0.2.5's emitter and writes the
same bytes for the same events (2,400,000 differential cases, none
different):

```crystal
emitter = Mica::YAML::Emitter.new(io)
emitter.stream_start
emitter.document_start
emitter.mapping_start
emitter.scalar("name")
emitter.scalar("mica")
emitter.mapping_end
emitter.document_end
emitter.stream_end
emitter.flush
```

## The libyaml dialect and libyaml versions

The libyaml dialect follows **libyaml 0.2.5**, the version Amber
applications link. Where it differs from YAML 1.2 it keeps libyaml's
reading: NEL, LS and PS end a line; a tab may follow a block indicator; an
anchor name ends at the first character that is not a word character;
unknown directives are errors; a comment may touch the token before it;
and the documents libyaml rejects although YAML 1.2 allows them stay
rejected (72 of the suite's 402 cases, the same 72 that libyaml itself
fails).

libyaml 0.2.6 (released 2026-11-20) changed two readings. Its other
source changes are spelling in comments; the reader, emitter and API files
are byte-identical.

| Input | libyaml 0.2.5 | libyaml 0.2.6 | Mica libyaml dialect | Mica YAML 1.2 dialect |
|---|---|---|---|---|
| An explicit key closed by the end of a flow sequence: `[? ]`, `[?]`, `[a, ? ]` | swallows the `]`, then fails with "did not find expected ',' or ']'" | a single-pair mapping with an empty key and value | as 0.2.5 | as 0.2.6 |
| More than 1,000 nested collections (block levels plus flow levels) | read; no cap of its own | scanner error "exceeded maximum nesting depth" (CVE-2026-44842; the cap is settable with `yaml_set_max_nest_level`) | `max_depth` of the limits in use; unbounded only under `ParseLimits::LIBYAML` | `max_depth` (128 for `CONFIG_FILE`) |

A 100,000-case campaign run against a libyaml 0.2.6 build (release
tarball sha256
`43b393a117bd4fe39812fddc94e3d654359a3ae05653dcf0110a1122d1747e61`) found
no disagreement, since the generators rarely produce either input;
`spec/yaml/libyaml_replay_spec.cr` pins both rows of the table. The
standard-library compatibility layer reports libyaml version 0.2.5 and
keeps the standard library's own nesting and alias guards, so the nesting
cap an application sees does not depend on the engine.

## How it is built

The scanner and the parser are a Crystal port of libyaml 0.2.5's
`scanner.c` and `parser.c` (MIT, copyright 2006-2016 Kirill Simonov and
2017-2020 Ingy döt Net; the notice is at the top of each ported file), working on the whole input in
memory: a token queue, the simple-key table and the indentation stack,
with every loop iterative. The YAML 1.2 dialect adds the rules libyaml
lacks (tabs as separation, flow indentation, multi-line implicit keys in
flow mappings, `:` adjacent to a JSON-like key, empty keys, YAML 1.2
directives and document markers, block scalar indentation rules). Stale
simple keys are found from a moving low-water mark, so the scan is linear
where libyaml's is quadratic in the number of open flow levels.

Plain scalars resolve under the core schema with hand-written matchers
(no regular expressions). The composer builds nodes with an explicit
stack; the resolver turns nodes into values iteratively and memoizes
shared nodes, so alias-heavy documents resolve each node once.

## Testing and measurement

- Specs: `crystal-alpha spec spec/yaml`. Requirement catalog:
  `spec/requirements/yaml.tsv`. `spec/yaml/libyaml_replay_spec.cr`
  replays 800 inputs recorded from libyaml 0.2.5 (events, marks and error
  text) without linking it.
- yaml-test-suite: `/usr/bin/ruby conformance/yaml/fetch_suite.rb` fetches
  release `data-2022-01-17` (commit
  `6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f`, tarball sha256
  `cc4a08f9ccc1cb2e66f32b3f1192bf1f07b3175682bbb715bf709bafa70322d4`);
  `crystal-alpha run --release conformance/run_yaml.cr -- yaml12 results.tsv`
  writes a verdict per case, `run_yaml_values.cr` compares the node API's
  values with the suite's `in.json`, and `run_yaml_libyaml.cr` scores
  libyaml itself for comparison. With the suite fetched,
  `spec/yaml/test_suite_spec.cr` runs every case in the spec suite.
- Differential fuzzing against libyaml 0.2.5: `fuzz/yaml_campaign.cr`
  (events, marks and errors, three generator families) and
  `fuzz/yaml_emitter_differential.cr`.
  `scripts/libyaml_oracle_identity.sh` prints the version and sha256 of
  the library the oracle links and fails when it is not 0.2.5.
- Benchmarks against libyaml on real configuration files:
  `bench/yaml/run.sh` (see [benchmarks.md](benchmarks.md)).
- Linkage: `scripts/check_linkage.sh`.
