# Mica::Regex

`Mica::Regex` is a regular expression engine in pure Crystal, built in the
RE2 and Rust regex family: every search runs in time linear in the
haystack, and nothing links a C regex library. It is the engine that will
let Crystal programs, Amber applications included, run with no PCRE2 at all.

This document covers milestones **R1, the compile front half** (the
Crystal-dialect parser, compile limits and the allocation ledger, the size
preflight, the high-level intermediate representation (`Hir`) with Unicode
classes and per-dialect case folding, and `Mica::Regex::Syntax.check`) and
**R2, the engines and the native API** (the NFA compiler, the Pike VM, the
bounded backtracker, and `Mica::Regex::Expression`, whose methods follow
Crystal's `Regex`). The lazy DFA and literal acceleration arrive in R3.

```crystal
require "mica"

limits = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN
report = Mica::Regex::Syntax.check("(?<year>\\d{4})-(?i:k)+", dialect: :crystal, compile_limits: limits)
report.capture_count       # => 1
report.list_of_group_names # => [Mica::Regex::Ast::GroupName(@group_name="year", @capture_index=1)]
report.state_estimate      # => program states the compiler may emit (an upper bound)

Mica::Regex::Syntax.error?("a(?=b)", dialect: :crystal, compile_limits: limits).try(&.message)
# => "lookahead is outside the Mica::Regex dialect (see docs/regex.md, \"Excluded constructs\") (byte 1)"

hir = Mica::Regex::Syntax.translate("(?i)k+", dialect: :crystal, compile_limits: limits)
hir.root.to_s # => "[Kk\\x{212A}]{1,}"
```

## Dialects

| Dialect | Status | Reads patterns as |
|---|---|---|
| `:crystal` | R1 (parser), R2 (engines) | PCRE2 10.49 with `UTF \| UCP \| DUPNAMES`, the options Crystal's stdlib `Regex` compiles with |
| `:ecma262` | parser in R6 | JavaScript `u`-mode patterns (JSON Schema) |
| `:xsd` | parser in R7 | XML Schema regular expressions |

`Hir` and class lowering already take the dialect, because case folding
differs between them (see "Case folding").

## Syntax (Crystal dialect)

The Crystal dialect is PCRE2's syntax, read by a front end that follows
PCRE2's own `parse_regex` and `check_escape` rule for rule, so a pattern is
accepted, or rejected at the same byte offset, exactly as PCRE2 would treat
it. Everything below is accepted:

- **Literals and escapes:** any character; `\a \e \f \n \r \t`; `\xhh`,
  `\x{h...}`, `\o{o...}`, `\0` and up to three octal digits, `\ddd` when no
  group of that number can exist yet; `\cX`; `\N{U+hhhh}`; `\Q...\E`;
  a backslash before any non-alphanumeric character.
- **Classes:** `[...]`, `[^...]`, ranges, `]` first as a literal, `-` at an
  edge as a literal; POSIX classes `[:alpha:]` and `[:^alpha:]`; class
  escapes `\d \D \s \S \w \W \h \H \v \V`; `\p{...}` and `\P{...}` with
  PCRE2's loose property names (general categories and groups, `L&`,
  scripts, `sc:`/`scx:`, Bidi classes, Boolean properties, `Any`, `Xan`,
  `Xps`, `Xsp`, `Xwd`, `Xuc`).
- **Anchors and assertions:** `^ $ \A \z \Z \b \B \G`, `[[:<:]]` and
  `[[:>:]]`.
- **Other atoms:** `.`, `\N`, `\R`.
- **Quantifiers:** `* + ? {n} {n,} {n,m} {,m}` (spaces allowed inside the
  braces), each with a lazy `?` suffix; counts up to 65535.
- **Groups:** `(...)`, `(?:...)`, `(?<name>...)`, `(?'name'...)`,
  `(?P<name>...)`, branch reset `(?|...)`, comments `(?#...)`.
- **Options:** inline `(?imnrsxxJU)`, `(?-...)`, `(?^...)`, `(?a)`,
  `(?aD)`, `(?aS)`, `(?aW)`, `(?aP)`, `(?aT)`, scoped to the enclosing
  group and carried across `|` as in PCRE2; start-of-pattern settings
  `(*UTF)`, `(*UTF8)`, `(*UCP)`, `(*NO_AUTO_POSSESS)`,
  `(*NO_DOTSTAR_ANCHOR)`, `(*NO_JIT)`, `(*NO_START_OPT)`, `(*LIMIT_...=n)`
  (read and ignored: Mica applies its own limits), `(*LF)`,
  `(*BSR_UNICODE)`, `(*BSR_ANYCRLF)` and `(*CASELESS_RESTRICT)`.

`CompileOptions` carries the options Crystal's `Regex::CompileOptions` can
set (`IgnoreCase`, `Multiline`, `DotAll`, `Extended`, `Anchored`,
`DollarEndOnly`, `FirstLine`, `EndAnchored`, `MatchInvalidUtf`) plus the
PCRE2 options that have inline forms, so the stdlib shim can map Crystal's
options one for one.

The pattern itself must be valid UTF-8; an invalid byte is a `SyntaxError`
at its offset.

## Excluded constructs

These constructs do not fit an engine whose searches are linear in the
haystack. They raise `Mica::Regex::UnsupportedConstructError`, a
`SyntaxError` whose `construct` names the construct and whose
`byte_offset` is where it starts. The census below counts how often each
appears in the PCRE2 test corpus.

| Construct | Rewrite |
|---|---|
| Backreferences `\1`, `\g{n}`, `\k<name>`, `(?P=name)` | Capture both parts and compare them in Crystal |
| Lookahead `(?=` `(?!`, lookbehind `(?<=` `(?<!`, `(*pla:` and the other alpha assertions | Match the wider text and check the context in Crystal, or capture the context as a group |
| Atomic groups `(?>...)`, possessive quantifiers `a++` | Drop them: the engine never backtracks, so they only change which match is found in rare cases |
| Recursion and subroutine calls `(?R)`, `(?1)`, `(?&name)`, `\g<1>` | Use a parser for nested structure |
| Conditional groups `(?(1)...\|...)` | Use alternation, or two patterns |
| Callouts `(?C...)` | None |
| Backtracking verbs `(*FAIL)`, `(*ACCEPT)`, `(*COMMIT)`, `(*PRUNE)`, `(*SKIP)`, `(*THEN)`, `(*MARK)` | None |
| `\K` | Capture the part after `\K` as a group |
| `\C` (one code unit) | `.` (Mica works on code points) |
| `\X` (extended grapheme cluster) | Arrives in milestone R9 |
| `(*CR)`, `(*CRLF)`, `(*ANY)`, `(*ANYCRLF)`, `(*NUL)` newline conventions | Crystal uses LF; match `\r?$` explicitly |
| `(*NOTEMPTY)`, `(*NOTEMPTY_ATSTART)`, `(*TURKISH_CASING)` | None |
| Extended classes `(?[...])` | Ordinary classes |

## Unicode

The tables in `src/mica/regex/unicode/tables.cr` are generated by
`scripts/unicode/generate_tables.rb` from the Unicode 17.0.0 UCD (the
version Crystal 1.21 uses), downloaded at the URL in
`scripts/unicode/manifest.json` and checked against its sha256 before use.
The generator mirrors PCRE2's own table builders, and its loose property
names were checked against PCRE2 10.49's `pcre2_ucptables_inc.h` (518 of
518 match). Sets are sorted, disjoint range lists.

In UCP mode `\d` is `\p{Nd}`, `\s` is PCRE2's `Xsp`, `\w` is `Xwd`
(`L`, `N`, `Mn`, `Pc`), and the POSIX classes use PCRE2's substitutions
(`[:alpha:]` is `\p{L}`, `[:graph:]` is PCRE2's `PXgraph`, and so on).
`(?aD)`, `(?aS)`, `(?aW)`, `(?aP)` and `(?aT)` switch them to ASCII.

## Case folding

Case-insensitive matching closes a class over its simple case folding
orbits (Unicode `CaseFolding.txt`, statuses C and S). What gets closed
depends on the dialect:

- **Crystal (PCRE2):** literal characters and literal ranges only. Class
  escapes and properties are not folded, except that `\p{Lu}`, `\p{Ll}` and
  `\p{Lt}` become `\p{L&}`. `(?r)` (`CaselessRestrict`) keeps ASCII and
  non-ASCII apart, so `(?ir)k` does not match U+212A KELVIN SIGN.
- **ECMA-262:** every member of the class, escapes included, so `/[\w]/iu`
  matches U+017F and U+212A.
- **XSD:** no case-insensitive mode.

A negated class is folded first and negated afterwards.

## Limits

`CompileLimits` is a required argument of every compile entry point; there
is no default and no global switch.

| Limit | `UNTRUSTED_PATTERN` | `TRUSTED_PATTERN` | Checked |
|---|---|---|---|
| `max_pattern_bytes` | 4 KiB | 64 KiB | before parsing |
| `max_nest_depth` | 64 | 250 | at each `(` |
| `max_captures` | 64 | 1024 | at each capturing group |
| `max_class_ranges` | 4096 | 65536 | while a class is merged, before its range list grows past the limit |
| `max_program_states` | 100,000 | 1,000,000 | by the size preflight, before `Hir` exists |
| `max_pike_bytes` | 4 MiB | 64 MiB | when compilation finishes, against the Pike VM workspace with every slot |
| `max_compile_bytes` | 4 MiB | 64 MiB | by the allocation ledger, before each allocation |

A limit that trips raises `Mica::Regex::CompileLimitError`, a
`Mica::LimitExceededError` whose `limit_name` and `limit_value` name the
limit. Compile work is also charged to a `Mica::Core::WorkMeter`
(`Syntax::COMPILE_WORK_BUDGET` by default, or the caller's meter), so a
deadline or work budget applies to compiling too.

**The size preflight** bounds the program states the compiler will emit,
with saturating arithmetic over the syntax tree:

| Node | States |
|---|---|
| literal | its UTF-8 length |
| class, `.`, `\N`, case-folded literal | byte ranges of its UTF-8 sequences + (sequences - 1) splits; 1 for an empty class |
| `\R` | 2 (`\r\n`) + the other line breaks as a class + 1 split |
| assertion | 1 |
| concatenation | the sum |
| alternation of k branches | the sum + (k - 1) |
| capturing group | child + 2 |
| `{n,m}` | child x m + (m - n) |
| `{n,}` | child x max(n, 1) + 1, plus one more child when the child can match the empty string (see "Engines") |
| whole pattern | root + 3 + the unanchored `(?s:.)*?` prefix |

Class counts come from `Utf8Sequences`, the same splitter the compiler
uses, so `((a{100}){100}){100}` is refused at its outer group before
anything is expanded. The compiler checks its emitted count against the
same limit, and never emits more than the bound.

**The allocation ledger** (`AllocationLedger`) is charged before every
object, array, string and table entry the front half allocates, with an
upper bound on what the garbage collector really hands out: objects with
the collector's extra byte and 16-byte rounding, arrays of known size
exactly, growing arrays at 7 times the element size per element (stdlib
growth allocates at most 6.24 times over a run of appends), and hash
entries with their index. Passing `max_compile_bytes` raises at the
offending byte offset. The front half keeps no transient lists: each
case-folded literal is lowered once (to `Ast::Literal#folded_set`) and
shared by the preflight and the translator, and the traversal and value
stacks are allocated once, sized by the node count. Every traversal of the
tree uses an explicit stack, so nesting never consumes machine stack.

`spec/regex/compile_complexity_spec.cr` checks the bound against the
process: for the worst accepted families at `max_pattern_bytes` under both
presets (`(?i)k`, `\Q a`, `a`, `a|`, `(?:)`, `\R`, `^`, `(?i)[a-z]` and
`a{2}` repeated), `GC.stats` allocation stays within `max_compile_bytes`
and within the ledger total plus 64 KiB (the collector counts a thread's
free list when it refills it). Measured, the process allocates 51% to 97%
of the ledger total for those families; under `TRUSTED_PATTERN`,
`(?i)` followed by 64,996 `k`s allocates 18.6 MB against a ledger of
19.2 MB.

Group names are checked against three tables (first entry per name,
first entry per number, and the name-number pairs), so each name costs
constant work, and a class merges one range stream per distinct member,
so repeating `\p{L}` inside a class costs no more merge work than writing
it once; each merge step is charged with the heap's depth.

## Hir

`Mica::Regex::Hir` is what every dialect lowers to: `Literal`, `Class`
(a sorted `CodePointSet`, folding already applied), `Look` (assertions),
`LineBreak` (`\R`, kept as its own node because PCRE2 matches it atomically:
`\r\n` is never split by backtracking), `Repetition` with explicit counts,
`Capture`, `Concatenation`, `Alternation` and `Empty`. Non-capturing groups
and option settings are gone.

## Native API

`Mica::Regex::Expression` is Mica's counterpart of Crystal's `Regex`, and
`Mica::Regex::MatchData` of `Regex::MatchData`. Method names, arguments and
return types follow stdlib, so moving code to Mica is mostly a type rename
plus the limits:

```crystal
limits = Mica::Regex::SearchLimits::REQUEST
date = Mica::Regex::Expression.new("(?<year>\\d{4})-(?<month>\\d{2})",
  compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)

date.match("due 2026-11", limits: limits).try(&.["year"]) # => "2026"
date.matches?("no date", limits: limits)                  # => false
date.scan("2026-11 2027-01", limits: limits).map(&.to_s)  # => ["2026-11", "2027-01"]
date.gsub("2026-11", "\\k<month>/\\k<year>", limits: limits) # => "11/2026"
Mica::Regex::Expression.new(",\\s*", compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  .split("a, b,c", limits: limits) # => ["a", "b", "c"]
```

| stdlib | Mica |
|---|---|
| `Regex.new(source, options)` | `Expression.new(source, options, compile_limits:)` (also `Mica::Regex.compile(source, dialect:, compile_limits:)`) |
| `regex.match(str, pos, options)`, `match!`, `match_at_byte_index`, `matches?`, `matches_at_byte_index?` | the same, plus a required `limits:` and an optional `timeout:` |
| `str.scan(regex)`, `str.gsub(regex, ...)`, `str.sub(regex, ...)`, `str.split(regex, ...)` | `expression.scan(str, ...)`, `gsub`, `sub`, `split` (every form: string with backreferences, hash, block), plus `each_match` |
| `regex.source`, `options`, `capture_count`, `name_table`, `to_s`, `==`, `hash` | the same |
| `Regex.escape`, `Regex.needs_escape?`, `Regex.union` | `Mica::Regex.escape`, `needs_escape?`, `union_source` (returns the source; compile it with the limits that fit) |
| `MatchData#[]`, `[]?` (index, name, range), `begin`, `end`, `byte_begin`, `byte_end`, `pre_match`, `post_match`, `captures`, `named_captures`, `to_a`, `to_h`, `size`, `group_size`, `string`, `regex` | the same, with the same rules: `nil` for a group that did not take part, `""` for an empty one, `IndexError` and `KeyError` as stdlib raises them, and duplicate names resolved as stdlib's PCRE2 binding resolves them |

Differences, all deliberate:

- Limits are required: `compile_limits:` when compiling and `limits:` on
  every search. There is no default and no global switch.
- The native API does not set `$~` (so no `$1`); use the returned
  `MatchData`. `=~` and `===` are left out because an operator cannot take
  the required limits. The stdlib shim (R4) keeps both.
- The haystack must be valid UTF-8: invalid bytes raise
  `Mica::EncodingError` at their offset. `CompileOptions::MatchInvalidUtf`
  raises `ArgumentError` until milestone R4 implements it.
- A byte index inside a character raises `ArgumentError`.
- After an empty match in `gsub`, the next search starts one character past
  the match (stdlib measures the character at the previous offset instead;
  roadmap 6.7 item 5).

## Search limits

`SearchLimits` bounds one call. The work allowance grows with the program
(m states) and the haystack (n bytes):

    max_work = min(work_ceiling, 64·m + 4,096 + 4,096·n)

| Limit | `REQUEST` | `TRUSTED_INPUT` |
|---|---|---|
| `work_ceiling` | 10^8 operations | 10^9 operations |
| `work_per_byte`, `work_per_state`, `base_work` | 4,096, 64, 4,096 | the same |
| `max_output_bytes` (`gsub`, `sub`, `split`) | 16 MiB | 256 MiB |

Work is charged where the bounds below count it: one operation per
haystack byte validated, per state a closure visits and per thread
stepped, c per capture slot vector copied, and one per backtracker visit
and undo entry. An iteration call (`each_match`, `scan`, `gsub`, `sub`,
`split`) draws every search from one allowance, so a run of matches cannot
reset it; its block, and the output it builds, are not regex work (output
is bounded by `max_output_bytes` instead). A call that runs out raises
`Mica::Regex::SearchLimitError` (a `Mica::LimitExceededError`) whose
`limit_name` is `max_work` or `max_output_bytes` and whose `limit_value`
is the value for that call; a `timeout:` that passes raises
`Mica::DeadlineExceededError`. A search never returns a partial or wrong
result.

## Engines

`Compiler` turns `Hir` into a `Program`: a byte-level Thompson NFA in which
every class and literal is a UTF-8 automaton (classes share their leading
byte ranges in a trie, so a class emits at most the byte ranges the size
preflight counted for it). The compiler expands repetitions, never
recurses on the pattern (it keeps a task stack), charges every allocation
to the ledger, checks `max_program_states` as it emits and `max_pike_bytes`
when it finishes, and never emits more states than the preflight bound.
There is no unanchored `.*?` prefix: the engines start a thread at each
character boundary instead.

A search runs in two phases (roadmap 6.2.1, without the lazy DFA that R3
adds):

1. A **Pike VM** tracking only group 0 finds the leftmost-first span
   `[s, e)`. Time O(m·(n + 1)).
2. Only when captures are asked for, a second engine runs anchored at s
   and reading no byte at or after e (cutting bytes only removes matches,
   so the highest-priority match from s still ends at e; assertions still
   see the whole haystack):
   - the **bounded backtracker** when m × (L + 1) ≤ 256 Ki bits, for
     L = e − s: a depth-first search in priority order that visits each
     (state, position) pair once. Time O(m·(L + 1) + c); memory m·(L + 1)/8
     bytes of bitset plus at most m·(L + 1) jobs and c slots;
   - otherwise a **Pike VM** with every slot. Time O(m·c·(L + 1)); memory
     16·m·c + 32·m + 8·c bytes in one pointer-free buffer (two slot tables,
     two sparse sets, the closure stack of m frames, one scratch vector).

`max_pike_bytes` is checked at compile time against that workspace with
every slot (c = 2 × (groups + 1)), so at the untrusted limit of 4 MiB a
program without groups can have about 65,000 states.

**Semantics** are PCRE2's leftmost-first priority, including two rules an
automaton has to build in:

- **An empty iteration ends a group repetition.** PCRE2 stops repeating
  `(X)*` when an iteration matched the empty string, and keeps that
  iteration's captures: `(a*)+` on `"b"` gives group 1 = `""`, and
  `(a*|b)*` on `"ab"` matches `"a"`. When the body of an unbounded
  repetition can match the empty string, the compiler emits it twice: each
  iteration starts in a *fresh* copy whose byte edges lead into the
  *consumed* copy and whose end leaves the loop, while the consumed copy's
  end returns to the loop. Whether the iteration consumed anything is part
  of the state number, so the engines' one-visit-per-(state, position) rule
  stays exact. The size preflight counts the second copy (`{n,}` row).
- **`\R` is atomic:** `\r` alone is `\r` not followed by `\n`, so a later
  failure never splits `\r\n` (`\R\n` does not match `"\r\n"`).

Multiline `^` does not match after a newline that ends the haystack, `$`
and `\Z` match before a final newline, and the word assertions use PCRE2's
UCP word set (or ASCII under `(?aW)`), all as in PCRE2 with Crystal's
options.

## Search complexity

`spec/regex/search_complexity_spec.cr` measures the work each search
charges (never wall time) at four sizes, x1, x2, x4 and x8, varying one
quantity while the others stay fixed. Every measurement must stay under
C x its bound, and growth from x1 to x8 must stay under 8 x 1.25.

| Family | Varies | Bound | C | x1 to x8 growth |
|---|---|---|---|---|
| `(a+)+$`, `(a\|a)*b`, `(a\|aa)*c`, `(x+x+)+y`, `(.*a){20}`, `^(\w+\s?)*$`, the OWASP e-mail pattern, the Cloudflare 2019 pattern, the Stack Overflow 2016 pattern | n = 500 to 4,000 bytes | m·(c + 1)·(n + 1) | 4 | 7.97 to 8.02 on the forced Pike VM path, and at least 8 / 1.25 (the counter really counts) |
| alternation of k 8-byte literals, `a{k}`, `[\p{L}\p{N}]{1,k}` over 64 KiB | m (k = 8 to 64) | m·(c + 1)·(n + 1) | 4 | 7.86, 1.19, 1.01 |
| `x{64}` + k empty groups, padded so m is identical | c (k = 8 to 64) | m·c·(L + 1) | 2 | 6.86, and more than 3 (slot copies are charged) |
| `(a\|b)*(c)` on the backtracker | L = 16 to 128 | 2·m·(L + 1) + c + n | 1 | |

Set `MICA_COMPLEXITY_REPORT=path` to write every measurement.

## Conformance

`spec/regex/search_conformance_spec.cr` runs two pinned corpora with fixed
denominators (roadmap 6.5):

- **RE2 search tests:** `re2-search.txt` as Go vendors it
  (`golang/go` commit `9dd31ba8`, sha256 `b6876d87...c9d`, in
  `conformance/regex/re2/manifest.json`), converted by
  `conformance/regex/re2/convert_search.rb`. One case per pattern,
  haystack and result column. RE2's `$` is `\z` and its `\d \s \w \b` and
  POSIX classes are ASCII, so these cases compile with `DollarEndOnly` and
  the `(?a)` options.
- **Rust regex tests:** the 26 `testdata/*.toml` files of
  `rust-lang/regex` commit `80b9d14e` (each sha256 in
  `conformance/regex/rust/manifest.json`), converted by
  `conformance/regex/rust/convert_toml.rb`, which reads the TOML subset
  the files use. Rust's `$` is `\z`, so these compile with `DollarEndOnly`;
  iteration follows `String#scan`.

Every case lands in exactly one list. **Excluded** cases are outside the
Crystal dialect's search semantics (`excluded.tsv`, with the reason).
**Divergent** cases are those where the corpus engine expects one result
and PCRE2 10.49 gives exactly Mica's result, so the difference is the
dialect's meaning, not a Mica defect (`divergences.tsv`; PCRE2's results
come from `spec/regex/differential/pcre2_search_oracle.cr`, a standalone
program run by hand, recorded in
`spec/regex/fixtures/pcre2_search_verdicts.json`). Every other case is
**eligible** and must pass, on every engine path that applies (two-phase,
Pike VM, and the backtracker when the haystack fits). The lists must
partition the corpus and match the files exactly, and `denominator.json`
pins the counts. `MICA_REGEX_CONFORMANCE_WRITE=1` rewrites the files from
a run, so any change shows in review.

| Corpus | Total | Passed | Failed | Excluded | Divergent |
|---|---|---|---|---|---|
| RE2 search | 7,552 | 3,616 | 0 | 3,936 | 0 |
| Rust regex | 1,203 | 566 | 0 | 529 | 108 |

RE2 exclusions: 3,776 leftmost-longest (POSIX) columns and 160 uses of
`\C`. Rust exclusions: 117 `utf8 = false` and 101 `unicode = false`
(byte-oriented and ASCII-only modes), 94 using Rust's CRLF flag `(?R)`
(recursion in the Crystal dialect), 91 patterns PCRE2 rejects too (Rust-only
syntax such as class set operations), 59 regex sets, 32 `match-kind = all`,
16 earliest or overlapping searches, 10 custom line terminators, 7 search
end bounds and 2 search starts inside a character.

Rust divergences, each confirmed against PCRE2:

| Reason | Cases |
|---|---|
| Rust's `\b{start}`/`\b{end}` syntax; PCRE2 reads `\b` followed by literal text | 40 |
| PCRE2 ends a group repetition after an empty iteration and keeps its captures (`(a*)*` on `"a"` gives group 1 = `1-1`; Rust gives `0-1`) | 37 |
| `String#scan` reports an empty match that starts where the previous match ended; Rust regex skips it | 21 |
| `regex-lite` is ASCII-only; the Crystal dialect is Unicode-aware | 6 |
| Multiline `^` does not match after a newline that ends the haystack | 3 |
| The Crystal dialect accepts `(?)` | 1 |

Every divergence row says "pending CODEOWNERS review" until a code owner
approves it.

## Engine differential

`fuzz/regex_engine_differential.cr` generates small patterns (atoms,
classes, assertions, `\R`, groups, named groups, every quantifier, inline
flags) and searches each one over every string up to length 6 over the
alphabet `a`, `b`, `é`, newline (5,461 strings) on every engine path: the
two-phase search with and without captures, a Pike VM with every slot, the
bounded backtracker, and `matches?`. All must agree on every case.
`spec/regex/engine_differential_spec.cr` runs 12 patterns; the release
campaign runs two million cases:

```sh
crystal-alpha build --release fuzz/regex_engine_campaign.cr -o bin/regex_engine_campaign
bin/regex_engine_campaign 20261118 400   # 2,184,400 cases, 0 disagreements
```

`spec/regex/differential/pcre2_match_differential.cr` (standalone, links
PCRE2) runs the same patterns and strings through stdlib `Regex` and
compares every group's span with Mica's `match`: 2,184,400 cases with 0
differences for seed 20261118 and for seed 7. Milestone R4 makes that
comparison a gate at ten million cases.

## PCRE2 census

`spec/regex/pcre2_syntax_census_spec.cr` classifies every pattern in the
PCRE2 10.49 testinput files (9,383 patterns), pinned by commit and archive
sha256 in `conformance/regex/pcre2/manifest.json` and converted to
`spec/regex/fixtures/pcre2_syntax_cases.json` by
`conformance/regex/pcre2/convert_testdata.rb`. PCRE2's own verdicts are
recorded by `spec/regex/differential/pcre2_syntax_oracle.cr`, the only file
that links PCRE2; it is a standalone program run by hand
(`crystal-alpha run spec/regex/differential/pcre2_syntax_oracle.cr`), never
part of `crystal-alpha spec`.

| Category | Patterns |
|---|---|
| Accepted by both, with equal capture counts and group names | 5,870 |
| Refused by Mica as an excluded construct (named, with offset; PCRE2 accepts or rejects at the same or a later byte) | 2,339 |
| Rejected by both as invalid at the same byte offset (a different offset fails the gate) | 314 |
| Refused by Mica by a named compile limit | 6 |
| Outside the dialect: needs a pcre2test option Crystal cannot set | 850 |
| Rejected by pcre2test itself before compiling | 4 |
| Unexplained mismatches | 0 |
| Approved divergences (`conformance/regex/pcre2/divergences.tsv`) | 0 |

The per-case table is `conformance/regex/pcre2/census.tsv`; set
`MICA_REGEX_CENSUS=path` to regenerate it.

## Fuzzing

`fuzz/regex_fuzz.cr` alternates byte-level mutations of seed patterns
(hostile UTF-8, regex tokens) with patterns generated from the grammar.
`spec/regex/fuzz_spec.cr` runs 20,000 cases in the suite; the release
campaign runs a million:

```sh
crystal-alpha build --release fuzz/regex_campaign.cr -o bin/regex_campaign
bin/regex_campaign 20261118 1000000
```

Every case must end in a result or a `Mica::Error`, never another
exception, within the work budget, deterministically.

## Open items for later milestones

- The lazy DFA (forward and reverse), the one-pass DFA, guarded literal
  accelerators and the `CachePool` (R3), which take phase 1 from
  O(m·n) Pike VM steps to one DFA transition per byte.
- The invalid-UTF paths (`MatchInvalidUtf`, `NO_UTF_CHECK`) and the stdlib
  adapters with the 6.7 adapter matrix and the PCRE2 differential gate of
  ten million cases (R4).
- The PCRE2 testdata corpus (`testinput1`/`testoutput1`) as a search
  corpus, restricted to valid UTF-8 (R3).
- Code owner approval of the Rust divergence rows ("pending CODEOWNERS
  review").
- The ECMA-262 and XSD parsers (R6, R7) and `\X` (R9).
