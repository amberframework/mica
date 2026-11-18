# Mica::Regex

`Mica::Regex` is a regular expression engine in pure Crystal, built in the
RE2 and Rust regex family: every search will run in time linear in the
haystack, and nothing links a C regex library. It is the engine that will
let Crystal programs, Amber applications included, run with no PCRE2 at all.

This document covers milestone **R1, the compile front half**: the
Crystal-dialect parser, compile limits and the allocation ledger, the size
preflight, the high-level intermediate representation (`Hir`) with Unicode
classes and per-dialect case folding, and `Mica::Regex::Syntax.check`. The
matching engines (Pike VM, DFA, bounded backtracker) arrive in R2 and R3.

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
| `:crystal` | R1 | PCRE2 10.49 with `UTF \| UCP \| DUPNAMES`, the options Crystal's stdlib `Regex` compiles with |
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
| `max_pike_bytes` | 4 MiB | 64 MiB | when compilation finishes (R2) |
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
| `{n,}` | child x max(n, 1) + 1 |
| whole pattern | root + 3 + the unanchored `(?s:.)*?` prefix |

Class counts come from `Utf8Sequences`, the same splitter the compiler
uses, so `((a{100}){100}){100}` is refused at its outer group before
anything is expanded. The compiler (R2) will check its emitted count
against the same limit.

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

- `\R` is atomic in PCRE2; the compiler (R2) must not let a later failure
  split `\r\n`.
- `max_pike_bytes` and the emitted-state check land with the compiler (R2).
- Multiline `^` (`Hir::Look` with `StartOfLine`) matches at the start and
  after each newline except a newline that ends the subject, as in PCRE2;
  the R2 matcher must keep that meaning.
- Roadmap 6.5's `conformance/regex/exclusions.tsv` and the three frozen ID
  lists (excluded, divergent, eligible) are built before R2's denominator
  gates; `census.tsv` stands in for them in R1.
- The ECMA-262 and XSD parsers (R6, R7) and `\X` (R9).
