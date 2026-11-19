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
Crystal's `Regex`), and **R3, the fast paths** (the forward and reverse
lazy DFAs, the one-pass DFA, literal extraction with memchr-style,
rare-byte and packed prefilters, the process-wide `CachePool`, and engine
selection; see "Engine selection" and "Benchmarks").

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
  `[[:>:]]`. As in PCRE2, which reads them as `\b(?=\w)` and
  `\b(?<=\w)`, each is two items: a quantifier after one repeats the
  lookaround alone, and the `\b` stays (`a[[:<:]]*` does not match `ab`).
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
| `max_pike_bytes` | 4 MiB | 64 MiB | when compilation finishes, against the one Pike VM workspace a search holds (span layout without groups, capture layout with them); the bounded backtracker gets what is left |
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
and option settings are gone. Adjacent branches of the pattern's top-level
alternation that start with the same literal share it: `,|,\s` becomes `,(?:|\s)` and `sam|samwise`
`sam(?:|wise)`. Leftmost-first matching tries the same paths in the same
order either way, so every match and group is unchanged, and the one-pass
DFA can read the factored form, where the shared first byte made the
branches ambiguous. An alternation inside a larger pattern is left as
written: made one-pass there, its one-pass DFA can cost more to build
than the first searches it would serve.

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
| `Regex.new(source, options)` | `Expression.new(source, options, compile_limits:)` (also `Mica::Regex.compile(source, dialect:, compile_limits:)`), with an optional `cache_pool:` (see "Cache memory") |
| `regex.match(str, pos, options)`, `match!`, `match_at_byte_index`, `matches?`, `matches_at_byte_index?` | the same, plus a required `limits:` and an optional `timeout:`; `search(haystack, byte_offset, limits:, deadline:)` is `match_at_byte_index` under the name roadmap 6.2.6 gives it |
| `str.scan(regex)`, `str.gsub(regex, ...)`, `str.sub(regex, ...)`, `str.split(regex, ...)` | `expression.scan(str, ...)`, `gsub`, `sub`, `split` (every form: string with backreferences, hash, block), plus `each_match` |
| `regex.source`, `options`, `capture_count`, `name_table`, `to_s`, `==`, `hash` | the same |
| `Regex.escape`, `Regex.needs_escape?`, `Regex.union` | `Mica::Regex.escape`, `needs_escape?`, `union_source` (returns the source; compile it with the limits that fit). Each expression member keeps every option with an inline form, `n`, `r`, `U`, `xx` and `(?aD)` to `(?aT)` included, so the union matches exactly what the member matches; a member with `Anchored`, `FirstLine`, `DollarEndOnly` or `EndAnchored` raises `ArgumentError` |
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
  roadmap 6.7 item 5). So `gsub` agrees with `scan` and with PCRE2's match
  positions, and can differ from `String#gsub` after multibyte text: `\b`
  replaced by `<>` in `"héllo wörld"` gives `"<>héllo<> <>wörld<>"` in
  Mica and `"<>héllo<> wörld<>"` in stdlib (milestone R5 fixes the stdlib
  side).

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
is bounded by `max_output_bytes` instead). Under `CompileOptions::FirstLine`
the search for the first line feed is charged one operation per byte, and
an iteration call scans each byte for it at most once; the Pike VM and the
bounded backtracker stop once no thread is live and no start is allowed
past that line feed, so they read past the first line only while a
thread that started on it is live. `split` meters and
validates the haystack on every path, the empty pattern (one operation per
character) and `limit <= 1` included.

`gsub` and `sub` charge `max_output_bytes` before each piece is written:
each literal run of the haystack, each literal run and each group of a
replacement string, and the `to_s` of a block's value. Memory for the
result is therefore bounded by the cap: the buffer starts at the smaller
of the haystack size and the cap and doubles, so it allocates at most about
four times the cap in all, plus a few bytes per match. A call that runs out raises
`Mica::Regex::SearchLimitError` (a `Mica::LimitExceededError`) whose
`limit_name` is `max_work` or `max_output_bytes` and whose `limit_value`
is the value for that call; a `timeout:` that passes raises
`Mica::DeadlineExceededError`. The clock is read at the start of every
call, before the haystack is validated, and then at work checkpoints, so a
timeout that has already passed fails any call before it reads the
haystack, while a running search notices its deadline at the next
checkpoint. Validation, every scan that reads ahead of an engine (the literal
accelerators, the final-byte skip, the `FirstLine` line feed search), the
stepping loops of the lazy DFAs (forward, reverse and from each start) and
of the one-pass DFA, and the character index conversion of `match` and
`matches?` with a `pos` other than 0 read in windows the call's meter
allows before each is read (`SearchMeter#readable`; a validation window
ends before a lead byte, so no character is split): a window never
passes the next checkpoint, so the budget and the clock are checked before
a byte the call cannot pay for, not after. A loop that builds a DFA state
inside a window charges what it has read first and has the rest of the
window allowed again, since building charges the meter too. The character
index conversion runs inside the call's searcher, after the deadline is
read and the haystack validated, under the same allowance as the search.
A search never returns a partial or wrong result.

## Engines

`Compiler` turns `Hir` into a `Program`: a byte-level Thompson NFA in which
every class and literal is a UTF-8 automaton (classes share their leading
byte ranges in a trie, so a class emits at most the byte ranges the size
preflight counted for it). A large class (16 ranges or more, such as `\w`
or `\p{L}`, or any class reaching three-byte sequences, such as `.` or
`[^"']`) is built once per process as a minimal automaton, its equal
suffixes sharing states. The automata of `\w`, `\W`, `\d`, `\D`, `\p{L}`,
`\P{L}`, `\p{Lowercase}` and `\p{Uppercase}` are built ahead of time by
scripts/generate_class_blocks.cr into `ClassMemo::Prebuilt`, static data
a process decodes in one pass the first time a pattern uses the class,
where building `\w` from its trie takes about 70 us and 150 KiB of
short-lived allocation; a spec checks each against the block its set
builds. A program copies only its states (one memory
copy, relocated in place): their `Sparse` states read the class's
transitions from one table shared by every program and copy
(`Program#list_of_shared_tables`, targets relative to the reading state),
so a copy of `\w` adds 354 states and no transitions. The preflight
counts its exact states.
A counted class whose copies stand for at least 32 states, a large
class or an ASCII one (`\p{L}{256}`: 256 copies of 300 states;
`[0-9A-Za-z_]{256}`; `\w{25,}`: the 24 copies before its loop), is not
even copied: the program holds the copies as one `Program::ClassRun`
(the first state, the count, and the class's memoized block or, for an
ASCII class, its one byte state with its ranges in a table of the
program's own) and numbers its states as the copies would be numbered,
so compiling `\p{L}{256}` takes about as long as `\p{L}`, and
`\b\w{25,}\b` about as long as `\b\w+\b`. A first search reads the run's
states through `Program#state_at` (or `Program#each_state`), which
works each one out from the block: it finds the run by a binary search
over the runs, and the engines charge the call's meter one operation for
each run a read looks at, before it looks (at most
`Program#run_reads_per_state`, the bit length of the run count plus
one), so `max_work` and the deadline bound the lookups as they bound the
visits. The plan writes `list_of_states`
out (for a large class, the program the copies written out compile to,
state for state) when it is first built. The bytes the written-out
states take are charged to the compilation as the preflight bound.
A class of one escape or property lowers to a set shared by the process,
and so does every written class of up to 32 items (`[0-9a-f]`, kept for
up to 512 classes, the table emptied and refilled when full), each ASCII
character under `IgnoreCase`, and `.`; an ASCII class compiles straight
to its one byte state. The case folding table is decoded once per
process. An alternation of classes and
single characters around a large class compiles as their union, and a
repeated small class is built once and copied; a counted literal or class
(`[\w.%+-]{1,256}`) is emitted in one loop rather than one task round per
copy. The compiler expands
repetitions, never recurses on the pattern (it keeps a task stack),
charges every allocation to the ledger, checks `max_program_states` as
it emits and `max_pike_bytes` when it finishes, and never emits more
states than the preflight bound.
There is no unanchored `.*?` prefix: the engines start a thread at each
character boundary instead.

A search runs in two phases (roadmap 6.2.1). Milestone R3 puts the lazy
DFAs, the literal search and the one-pass DFA in front (see "Engine
selection"); the R2 engines below remain the fallback for everything the
fast paths leave alone, and `Engine::TwoPhase` still runs them as R2 did:

1. A **Pike VM** tracking only group 0 finds the leftmost-first span
   `[s, e)`: each thread carries only the position where it started.
   Time O(m·(n + 1)); memory 32·m bytes (two sparse sets, a one-word
   closure stack and two start tables).
2. Only when captures are asked for, a second engine runs anchored at s
   and reading no byte at or after e (cutting bytes only removes matches,
   so the highest-priority match from s still ends at e; assertions still
   see the whole haystack):
   - the **bounded backtracker** when m × (L + 1) ≤ 256 Ki bits, for
     L = e − s: a depth-first search in priority order that visits each
     (state, position) pair once (a greedy loop of one byte state, such as
     `.*`, is followed in a tight loop that pushes the loop's exits at
     every position it passes as one job, the visits and charges being
     the same). Time O(m·(L + 1) + c); memory m·(L + 1)/8
     bytes of bitset, a job stack of at most m·(L + 1) + 1 entries (grown
     in doubling chunks as the search needs them, never copied) and c
     slots, used only when that fits what the Pike VM workspace leaves of
     `max_pike_bytes` (`Program#backtracker_allowance`);
   - otherwise a **Pike VM** with every slot. Time O(m·c·(L + 1)); memory
     16·m·c + 32·m + 8·c bytes in one pointer-free buffer (two slot tables,
     two sparse sets, the closure stack of m frames, one scratch vector).

A search holds one Pike VM workspace. A program without groups only
ever needs the 32·m-byte span layout. A program with groups gets the
capture layout (c = 2 × (groups + 1)) the first time captures are asked
for, and runs phase 1 in it as well, so the span and capture workspaces
are never alive together. `max_pike_bytes` is checked at compile time
against that workspace's charge (`PikeVM.workspace_charge`: the buffer and
its header object, each rounded to the collector's granule), and the
bounded backtracker only runs within what remains, so everything a search
holds stays within the limit. At the untrusted limit of 4 MiB a program
without groups can have about 131,000 states (more than
`max_program_states` allows), and `\A(a){14000}` (42,004 states, 4
slots) fits while `\A(a){15000}` does not.

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

## Engine selection

`SearchPlan` (built on a program's first search, so compiling costs what
it did in R2) picks the fastest correct path for each search:

| Phase | Path | When | Cost |
|---|---|---|---|
| 1 | **Required bytes**: no engine when the haystack lacks a byte every match reads (see "Required bytes") | `Auto` | one `memchr` pass per required byte, at most once per call |
| 1 | **Literal search** | the pattern is a finite set of literals with no assertion (`LiteralSet#exact?`), and the search is not anchored | O(n) prefilter scan plus the literal bytes compared at each candidate |
| 1 | **One-pass search**: span and groups in one pass | the pattern is one-pass and the search is anchored with groups wanted (once a search built the one-pass DFA, or when the forward DFA has read max(4096, 64·m) bytes undecided; a DFA with no left-out paths then reads to the match end), or the pattern has prefix literals: tried at each prefilter candidate (see "Short searches") | one transition per byte read |
| 1 | **Lazy DFAs**: forward for `e`, reverse for `s` | every program without `\G`, unless `FirstLine` or `EndAnchored` is set | one table read per byte; O(m) per state built |
| 1 | **Forward DFA from each start** ("Short matches"): finds `s` for a program whose matches span at most 512 bytes while its reverse cache thrashes, and searches it while its forward cache thrashes | the program has a match bound | at most `longest` + 1 table reads per start |
| 1 | **Pike VM**, span layout | otherwise, and whenever a lazy DFA gives up | O(m·(n + 1)) |
| 2 | **One-pass DFA** | captures asked for and the pattern is one-pass | O(L + c) |
| 2 | Bounded backtracker, then Pike VM | as in R2 | as in R2 |

While the forward DFA sits in its start state, the prefilter (when the
pattern has prefix literals) skips to the next position where a literal
starts. A DFA state that loops to itself (`.*`, `[^"]*`, and the start
state of a pattern without literals) is stepped in a run whose table
loads do not wait on each other; after a run shorter than 32 bytes the
forward DFA steps byte by byte for the next 1,024, so the letters of a
word under `\w+` cost nothing extra. The one-pass DFA steps such states
the same way. A pattern whose every match starts at `\A` is searched anchored,
with no reverse DFA. A lazy DFA gives up, and the search runs on the Pike
VM, when its cache thrashes or when the `CachePool` has no room. Once a DFA gives up in a call, the
call's later searches go straight to the Pike VM, so the work a thrashing
cache wastes is spent once per call. An unanchored forward DFA whose
program has a match bound gives up at the first cache clear that finds it
thrashing and goes on from each start in the same call, rather than
after `LazyDFA::MAX_CLEARS` clears: a program's first search over a long
haystack builds one cache's worth of states, not four
(`[a-q][^u-z]{80}x` over 16 MB went from about 15 to 4.7 ms cold). Every path charges its work to the
call's `SearchMeter` and reads the deadline at the same checkpoints, so
the work budget and the deadline hold on every path.

`Engine` (internal, for specs, fuzzers and benchmarks) forces a path:
`Auto` (all of the above), `NoAccelerators` (the lazy DFAs and the
one-pass DFA without the literal search and prefilters), `EachStart` (as
`NoAccelerators`, with every unanchored search and every match start of a
program whose matches are short made from each start; see "Short
matches"), `ReversedClasses` (as `NoAccelerators`, with every match start
found by the reverse DFA reading classes backward; see "Lazy DFA"),
`BacktrackedStarts` (as `NoAccelerators`, with every match start found by
the backtracker over the span up to the match end when it fits; see
"First searches"),
`TwoPhase` (R2's two phases), `PikeVM` and `Backtracker`.

**Calls reuse their workspaces.** A program keeps one *hot lease*: the
lazy-DFA caches, the Pike VM and backtracker workspaces and the searcher
of the call that finished last, taken back with one atomic swap by the
next call. Idle leases beyond it keep only their DFA caches (at most 8 per
program). A lease also remembers the last `String` it validated (strings
are immutable), so separate calls over one haystack, as `String#scan` and
`gsub` make through `match_at_byte_index`, validate it once. It holds
that string (as the parked searcher does), so its address cannot be
reused while identity is compared. The lease is the `CachePool` member, so taking it and
handing it back is one atomic operation each (see "Short searches").

## First searches

An expression compiled and searched once (a pattern built per request, a
validator run on one field) should pay for what that search reads and no
more. Building a plan costs more than a search of a short haystack does
on the bounded backtracker: the byte classes, the start filter and the
reverse NFA of a pattern with `\w` come to tens of microseconds, the
backtracker's search to well under one. So a program's first
`FirstSearch::SEARCHES` (2) single searches (`match`,
`match_at_byte_index`, `search`, `matches?`) run on the bounded
backtracker alone, with no `SearchPlan`, no lease and no lazy-DFA cache
reserved from the `CachePool`, when:

- the span from the offset to the end is at most 256 bytes (64 when the
  pattern has prefix literals, whose plan is cheap and whose prefilter
  skips to them faster than the backtracker tries each start), or any
  length for a *large* program without prefix literals (at least
  `FirstSearch::LARGE_PROGRAM_STATES`, 2,048 states, as `\p{L}{50}`'s
  15,000), and the backtracker fits it (`BoundedBacktracker.fits_capped?`,
  below);
- validation, the required-byte scans (below) and the backtracker's most
  work over that span (one operation per visit and one per slot write, at
  most one of each per (state, position) pair) fit the call's work
  allowance, checked before the haystack is read.

The deadline is read and the haystack validated before the search, as on
every path. The search is O(m·(L + 1) + c) and finds the span and the
groups in one pass. A pattern that backtracks hard over the haystack
(`(a|a)*$` over a run of a's) could make the backtracker cost more than
the plan, so a first search makes at most `FirstSearch.visit_limit`
visits (512 plus 8 per state, about what building the plan costs: a
small program's plan takes about 4 us, over a thousand visits); one
still undecided then goes on in the same call, under the same meter and
deadline, on the plan's engines, having spent at most about what the plan
costs. Later searches, iteration calls (`scan`, `gsub`, `split`) and
longer haystacks build the plan, whose automata pay for themselves over
many searches.

A first search, and a backtracked start (below), marks the pairs it has
visited in the backtracker's bitset when m × (L + 1) fits its 256 Ki bits.
A large program's bitset would not fit (`\p{L}{256}` over 512 bytes needs
about 39 M bits), so such a search marks them in a hash set instead,
which holds at most `BoundedBacktracker::SPARSE_VISITS` (16,384) pairs:
the search makes at most that many visits, then hands over as above, and
its memory (the set at its largest and a job stack of that many entries)
is checked against the backtracker allowance before it starts. It visits
the same pairs in the same order as with the bitset. Its plan costs in
proportion to the program's states, at least what that many visits cost,
so a first search of a large program without prefix literals reads a span
of up to `FirstSearch::MAX_LARGE_BYTES` (64 KiB); past it, the validation
and scans every path makes cost more than the plan would save. A
backtracked start reads at most `FirstSearch::MAX_BYTES` (256) bytes, so
a long match end goes to the reverse DFA.

While a program's runs are pending, the backtracker reads a `ClassRun`'s
states from the run's block rather than through `Program#state_at`: once
it has found the run (the binary search, charged as before), it follows
the copies one byte at a time, reading each copy's lead byte from the
block's `ClassMemo::Block#entry_targets` (one load for a large class) and
the other bytes from its shared table. A copy is a deterministic
automaton over one UTF-8 sequence, entered only at its entry, so a pair
inside a copy can be reached from one entry pair alone: the search marks
only the entry pairs, which keeps every pair visited at most once, and
charges one operation and one visit per state it steps through, with no
run lookup per state. Outside runs, `Program#sparse_target` reads the
entry state of a large class's block (`.`, `\w`, `[^A-Z]`) the same way,
with one load per byte. `\p{L}{256}` over 256 letters went from about 13
to 4 us cold, and `[0-9A-Za-z_]{256}` from about 6.6 to 2.5 us.

A first search has no lease, so its backtracker would allocate a bitset
and a job stack every time. The `CachePool` keeps one spare backtracker
instead (`CachePool#take_spare_backtracker`, one atomic exchange): a
first search takes it, points it at its program, and gives it back when
the call finishes, detached from the program and trimmed to
`BoundedBacktracker.spare_retained_bytes` (60 KiB: the largest bitset,
the first job chunks and a small hash set). Like the backtracker a lease
keeps, it is outside the pool's cap.

The plan itself builds what a search reads when it first reads it: the
start filter (read only by short searches) on first use, and the reverse
DFA only once the plan has found `FirstSearch::SEARCHES` match starts
without it. Until then, when the forward DFA has found a match end `e`,
the bounded backtracker finds the start over `offset...e` (when the span
would suit a first search, its most work fits the call's remaining
allowance, and the backtracker decides within its visit limit): the
leftmost-first match of that span ends at `e`, as cutting bytes off after
the match only removes matches.

## Required bytes

`Program#list_of_required_bytes` holds up to three ASCII bytes every match
reads (`c` in `(a|aa)*c`, `H`, `m` and `l` in `\w+\s+Holmes`), the rarest
first, found once per program in one pass over the NFA (assertions taken
as passing, so the set never claims too much). Before any engine runs, an
`Auto` search whose plan has no literal prefilter looks for the rarest
with `memchr` from its offset and returns no match when it is missing (a
prefilter already skips to where a match can start, and each extra byte
would read the haystack again): a ReDoS pattern over a haystack with no
possible match costs one scan, not a DFA pass. The scan reads in the
windows the meter allows and charges each byte it reads. A call remembers
where it found each byte, so an iteration call, whose next search starts
after a match that contains the byte, reads the haystack at most once
per required byte. A first search checks them too when finding them is
cheap next to the span (the program's states and sparse transitions at
most 256 plus 4 per byte).

## Short searches

Many searches read a short haystack (a route segment, a form field, one
log line) or find a short match, so the fixed cost of a call matters as
much as the cost per byte:

- **No engine for a short haystack that cannot match.** A program's
  `StartFilter` (built on its first use) holds the fewest bytes a match spans,
  the bytes a match can start with, and up to three ASCII bytes every
  match contains (`:` in `.*:(\d+)`), read from the NFA with every
  assertion taken as passing. `match`, `match_at_byte_index`, `search` and
  `matches?` over a haystack of at most 256 bytes return no match at once,
  with no lease and no engine, when too few bytes remain or none of them
  can start a match (only the first, when the search is anchored), or the
  a required byte is missing. They do so only where the searcher would also return no match without raising:
  the haystack is valid UTF-8 and its validation and the filter's scans
  (`StartFilter#scan_work`) fit the work allowance, checked before the
  first scan,
  the offset is a character boundary, and no timeout is set.
- **Short haystacks on the one-pass DFA.** Once a one-pass program has had
  a few short searches (`ShortSearch::BUILD_AFTER`, so a pattern searched
  once does not pay to build it), a single search of at most 256 bytes runs
  the one-pass DFA alone, anchored at each position where the start
  filter allows a match: span and groups with no lease, no searcher and
  no allocation for the slots, which live on the stack. It answers under
  the same conditions as the shortcut above and within a few passes over
  the haystack (`4n + 64` steps), and otherwise declines to the searcher.
  The one-pass DFA keeps, per table cell, the next state's row offset
  with flags for an edge that has assertions or slots and for a target
  with a match path, so one load per byte finds the next state. A match
  path that asserts `\z` is checked only at the end. A failed match path
  hands the search to another engine only in a state that left a
  lower-ranked byte path out (a lazy repeat); in `\A[a-z0-9]+\z` the bytes
  rank above the match, so the one-pass DFA decides alone.
  An unanchored short search finds each start with `memchr` when every
  match starts with one byte, and declines after `ShortSearch::MAX_TRIES`
  (8) failed tries; once a program has had `MAX_DECLINES` (16) such
  declines, its unanchored searches go straight to the searcher, whose DFA
  reads a haystack with no match nearby faster. The plan remembers the
  last haystack a short search validated, so iterating over one haystack
  validates it once. A call takes its program's hot lease with one
  atomic exchange and puts it back with one compare-and-set. Who holds a
  lease is decided by where it sits: in the hot slot or the idle list it is
  idle, and whoever takes it out (a search, or the pool evicting it) holds
  it alone. The pool's least-recently-used clock advances with a relaxed
  load and store, so two threads that hand back at once may tie.
- **No allocation for up to four groups.** `MatchData` holds the match's
  span, and the spans of up to four groups read with the match
  (`MatchData::INLINE_GROUP_SLOTS`), in the value itself, so such a
  pattern allocates nothing per call; more groups, or groups read on first
  use, live in a buffer every copy of the match shares. The
  work budget of a repeated call reuses the one the searcher built last.
- **One pass for a prefix-literal match.** Every match of a pattern with
  prefix literals starts with one of them, so the first prefilter
  candidate where an anchored match exists starts the leftmost match.
  When the pattern is one-pass, the searcher runs the one-pass DFA as a
  whole anchored search at each candidate, which finds the span and the
  groups at once: no reverse DFA and no separate capture pass; otherwise
  it runs the forward lazy DFA anchored at each candidate, which finds the
  end, and still needs no reverse DFA. An anchored search that wants
  groups runs the one-pass DFA alone at its offset once an earlier capture
  pass has built it. The one-pass DFA
  leaves out the paths that rank below a match path; when that match path
  does not hold (its `$` or `\b` fails) and nothing matches later, a
  left-out path could still match, so the search hands over to the lazy
  DFAs. The bytes a try reads that no match keeps (a failed try, or bytes
  read past a match end while looking for a longer one) are counted per
  call; past the haystack's size, or once the prefilter proves
  ineffective, the call stops trying, so the one-pass search adds at most
  O(n) to a call. A single try stops after `Searcher::MAX_TRY_BYTES`
  (64) undecided bytes and turns the search at starts off for the call,
  so a long failure such as `(?:a+)+b` over a run of a's costs at most
  that much extra.
- **Candidate searches over a long haystack.** A single search
  (`match`, `match_at_byte_index`, `search`) over more than 256 bytes of a
  haystack the plan remembers as valid UTF-8 (the searcher that validated
  it, or a short search, records it) runs the one-pass DFA anchored at
  each *candidate* start, with no lease, no searcher and no meter
  (`CandidateSearch`): `memchr` finds the next byte of the prefilter's one
  literal, or a scan finds the next byte a match can start with
  (`StartFilter#starts?`) and whose next byte one can have second
  (`StartFilter#second?`, when every match spans two bytes or more:
  `([a-z\d])([A-Z])` is tried only where a capital follows), and the
  first try that matches gives the span and the groups. Its work is bounded before it reads a byte: the scan
  reads each byte from the offset once, the failed tries read at most the
  remaining bytes plus room for `MAX_TRIES` (16) tries of
  `TRY_REACH` (64), and the try that matches at most the remaining
  bytes, so at most `3n + (MAX_TRIES + 1)(TRY_REACH + 1) + 2`
  operations, which must fit the call's allowance (checked without a
  multiplication, as for short searches). It applies only with no
  timeout, at a character boundary, on a one-pass program with at most
  16 slots and neither `FirstLine` nor `EndAnchored`. It declines after
  `MAX_TRIES` failed tries, past its byte bound, or when the one-pass DFA
  cannot decide; the searcher then takes over and is charged the work the
  candidate search spent first, so the call stays within its allowance. A
  program with `MAX_DECLINES` (16) declines and fewer than
  `MATCHES_PER_DECLINE` (32) matches per decline leaves its searches to
  the searcher, trying one in `RETRY_INTERVAL` (256) to see whether that
  changed. `,\s*`, `[^a-z0-9]+` and `\s+` iterated by separate calls over
  a 1 MiB haystack cost about as much per match as PCRE2-JIT does.
- **Scan positions kept across calls over one haystack.** A call that
  searches the very `String` the call before it searched (separate calls
  iterating, as `String#scan` makes them) keeps where the prefilter found
  each needle and where each required byte was found: a needle that is
  rare, or absent, is not looked for again past where it was found
  (`>[^\n]*\n|\n` over a FASTA file no longer scans to the next `>` once
  per line). Those bytes were read and charged once, by the call that
  found them; strings are immutable and the parked searcher holds the last
  one, so identity proves it is the same text.
- **Groups read on first use.** When only the bounded backtracker or the
  Pike VM can read a pattern's groups (the first capture pass found the
  pattern is not one-pass),
  `match`, `match_at_byte_index` and `search` find the span alone and leave
  the groups to be read the first time one is asked for: a capture pass
  over the match alone, anchored at its start, cut at its end, searched
  from the original offset (so look-behind and `\b` see the same bytes),
  under the limits and timeout of the call that found it. The groups are
  stored once in a buffer every copy of the `MatchData` shares. A caller
  that only asks whether and where a validator matched never pays for
  them. Once any caller reads the groups of such a match, the program
  reads groups with the match again, as a caller that reads them pays
  more for a later pass. When the one-pass DFA can read the groups (O(L)), they are read
  with the match. The iteration methods (`each_match`, `scan`, `gsub`,
  `sub`, `split`) read groups with each match through the call's own
  searcher.
- **Groups read with the span.** When groups are wanted from a program
  that is not one-pass and the forward DFA finds a match end at most
  `Searcher::GROUPS_WITH_SPAN_BYTES` (64) bytes past the offset, the
  backtracker runs anchored at the offset over that span. A match that
  starts at the offset is the leftmost one, so that one pass gives the
  start and the groups, with no reverse DFA and no second capture pass
  (`.*:(\d+)` over a `host:port` line). When no match starts there, the
  search goes on with the reverse DFA. The pass stays within the bitset
  gate, the call's remaining allowance and `FirstSearch.visit_limit`
  visits, each charged before it is read.
- **Capture passes of a large program.** A program of thousands of
  states (alternatives of `\p{L}{14}`, about 28,500 states) is too large
  for the backtracker's bitset over even a short span, so its capture
  pass would run on the Pike VM, which steps every live thread through
  its closure at each byte. The pass first runs the backtracker marking
  visited pairs in a hash set (see "Capped searches" in
  `BoundedBacktracker`), capped at `BoundedBacktracker::SPARSE_VISITS`
  visits: it visits the pairs the bitset would, so it reads the same
  groups. When it reaches the cap the Pike VM runs instead and the call
  stops trying it, so a call spends at most that many extra visits. The
  hash set starts a new generation for each search rather than clearing
  its table.
- **Alternatives too long for the span.** A capture pass, and the
  groups-with-span pass, must end at the match end. A program of at most
  `Program::MIN_BYTES_MAX_STATES` (1024) states finds, the 16th time it
  is asked (`Program::MIN_BYTES_AFTER`, so a pattern read once never pays
  for it), the fewest bytes a match reads from each state, in one 0-1
  breadth-first pass over its reversed edges. The backtracker drops a
  pair whose state cannot reach a match before the bound, in its tight
  greedy-loop path and the loop's job of exits as in its general loop, so
  `([A-Za-z]{14})|…|([A-Za-z]{5})` over a seven-letter word tries the
  longer alternatives without reading them.
- **Fixed-length starts.** When every match of a program spans the same
  number of bytes (its longest match, `ShortMatch.longest_match`, is as
  long as its shortest, `StartFilter#minimum_bytes`; worked out once for a
  program of at most `SearchPlan::FIXED_LENGTH_STATES` (2,048) states), a
  match's start is that many bytes before the end the forward DFA found,
  and the reverse DFA is not run (`[a-z]{5}`).
- **A small match value.** A `MatchData` is 88 bytes: a match whose groups
  are read on first use keeps its `GroupReader` and the shared offsets in
  one pointer-free buffer and holds only its address, so every return of a
  match copies little. A short search reads the program's plan once, and
  a searcher that takes over from a short search of the same `String`
  charges the haystack's validation without reading it again.

## Lazy DFA

`LazyDFA` builds DFA states on demand from the NFA, as RE2 and Rust regex
do, into a `DFACache` leased for the search:

- **Forward**, a state is the ordered list of NFA states the Pike VM would
  hold, so priority is kept: reaching the match state drops every
  lower-priority thread, and the last match end the scan records before
  the DFA dies is the leftmost-first end. A new thread starts at every
  character boundary until the first match.
- **Reverse**, over `ReverseNFA` (the NFA with every edge turned around,
  starting at the match state), a state is a sorted set (priority plays no
  part), and the scan from `e` back to the search start records every
  position where `[s, e)` matches; the smallest is the start, because the
  forward match starts where the leftmost match starts.
- **Classes read backward.** A class compiles to a trie of UTF-8
  sequences sharing their leading bytes; turned around, a continuation
  byte read backward fits the last byte of every sequence that allows it,
  so a reverse state for `\w` or `\p{L}` next to Cyrillic text held about
  1,100 to 1,800 NFA states. The compiler records each class of more than
  one state (`Program::ClassBlock`), and once a reverse cache has built 16
  states wider than 256 NFA states, the plan widens its reverse DFA
  (once): each class nothing else leads into is read through its
  `ReversedClass`, the trie of its reversed sequences made deterministic
  by the subset construction and then minimized (as Rust regex compiles
  its reverse NFA), so a byte read backward reaches one node. The plan
  does not widen when the widened DFA's builder scratch would take more
  than half of the per-cache ceiling (`\p{L}{256}`). Reverse states then
  hold a few NFA states (`\b\w{12,}\b` over Russian subtitles: about 7),
  and that search goes
  from 56 ms to 0.5 ms. Reversing a class costs a few milliseconds the
  first time; the result is memoized process-wide by the class's shape
  (at most 256 classes), so only programs that meet wide reverse states
  pay, once. A class whose reversed form would pass 8 nodes per forward
  state keeps its turned-around edges.
- **Assertions** are decided when a transition is built: a state carries
  what the bytes already read say (start or end of text, previous byte a
  line feed, an ASCII word character, a continuation byte, not ASCII), and
  the next byte is the transition's input, so the closure that reaches a
  match runs one byte late. The end of the haystack is an extra input, and
  so is a line feed that ends it (for `$` and `\Z`). `\G` is left to the
  Pike VM.
- **Unicode word assertions** (`\b`, `\B`, `\<`, `\>` in UCP mode): each
  byte of a non-ASCII character is read as its class or as its class
  marked "part of a word character", chosen by decoding the character
  once in the search loop (the UCP word set is a bitmap below U+10000).
  The transition into a character then knows whether it is a word
  character, and the state after it records whether the previous one
  was, so these assertions never send a search to the Pike VM. ASCII
  word assertions (`(?aW)`) in the same pattern keep their own
  previous-word bit, since a non-ASCII letter is a word character for
  one kind and not for the other.
- **Byte classes** (`ByteClasses`) group bytes no state can tell apart, so
  a state has one transition per class.
- **ASCII loops.** Once every ASCII byte's transition out of a forward
  state is built and leads back to it, and the state is neither a match,
  dead nor a start state (the loop of `(?s:.)*`), the entries of its own
  row carry a flag, and the search steps over a run of ASCII bytes there
  eight at a time without reading the table, within the bytes the meter
  has allowed. `(?s)^((.*)()()($))` over 7 MB of source goes from about
  14 ms to 1 ms. A row offset is a multiple of 8, which leaves the flag
  its bit.
- **Cost:** every byte read, every NFA state a new state's closure visits,
  and every state a cache clear discards is charged one operation. A cache
  that would pass `CachePool#max_cache_bytes` is cleared, and no
  reservation step takes a cache past that ceiling (a DFA whose fixed
  parts do not fit under it runs the search on the Pike VM); one that has
  been cleared more than 3 times with fewer than 10 bytes read per state
  built since the last clear is thrashing, and the DFA gives up. So a
  search stays O(m·(n + 1)).

## Short matches

`ShortMatch` (built on a program's first need of it) bounds how many
bytes a match can span, by one depth-first pass over the program: a loop
that reads input, or a bound over 512 bytes, means no bound. It also
collects the bytes a match can end with (the bytes read just before the
match state is reached through steps that read nothing), when they are at
most three and the program cannot match the empty string. A program with
a bound uses it twice:

- **Match starts.** Once the forward DFA has found the end `e` of the
  leftmost-first match, the start is the first position, from
  `max(offset, e − longest)`, where the forward DFA run anchored reaches
  any match: no earlier position starts one, since the match is leftmost,
  and the match is at most `longest` bytes long. This takes the reverse
  DFA's place while the reverse cache thrashes (with the same periodic,
  backed-off retries as below) and when the reverse DFA gives up, so such
  a search never falls back to the Pike VM. The alternation of
  `\p{L}{14}` down to `\p{L}{5}` over Russian text goes from 1.9 s to
  37 ms.
- **Searching from each start** (`LazyDFA#find_from_each_start`). A
  forward cache that is cleared with fewer than 10 bytes read per state
  built since its last clear is marked thrashing, and the unanchored
  searches of a program with a bound then run the DFA anchored at each
  character start in turn. The anchored DFA has one thread per pattern
  position, so it builds few states where the unanchored one, with a
  thread for every live start, has up to 2^k (`[a-q][^u-z]{13}x`). Each
  start reads at most `longest` + 1 bytes, and `longest` is below the
  program's state count, so the search stays O(m·(n + 1)). With final
  bytes, each is found with `memchr`, and the starts more than `longest`
  bytes before the next one are skipped. Every 256 such searches one
  retries the unanchored DFA; a retry that builds at least 32 states at
  fewer than 10 bytes each marks the cache thrashing again and doubles the
  interval (up to 2^20 searches). `[a-q][^u-z]{13}x` over leipzig-3200
  goes from 2.5 s to 18 ms (PCRE2-JIT: 127 ms), and `\p{L}{100}` over
  every code point from 1.15 s to 41 ms.

`Engine::EachStart` forces both paths on every unanchored search of a
program with a bound, for the differential fuzzers and the conformance
replay.

## One-pass DFA

`OnePassDFA` (RE2's OnePass) reads captures in one pass for a pattern
where the next byte always decides the way: each DFA state stands for one
NFA state a byte transition leads to, each byte class has at most one path
(with the slots it saves and the assertions it passes), and the match
state at most one path. Paths after the match state in priority order are
dropped. A pattern where two paths meet the same byte class, NFA state or
match is not one-pass, and its captures come from the backtracker or the
Pike VM. It is built on the first capture search, for programs of at most
1,500 states and 64 slots, and runs only over the span phase 1 found.
In a state that every ASCII byte leads back to with no slot and no
assertion (the loop of `(?s:.)*` or `[^\n]*`), the capture pass, and the
one-pass search of a long anchored match, step
over a run of ASCII bytes eight at a time without reading its table,
within the bytes the meter has allowed.

## Literal acceleration

At compile time `LiteralSet.extract` walks `Hir` for the literals every
match starts with (at most 64 of at most 32 bytes; small classes and
case-insensitive letters expand; a large class, an optional start or an
empty match ends extraction). An alternation whose branches come to more
than 64 is gathered again with each branch cut to an even share of what
the branches before it left, as prefixes of at least three bytes, so
`(?i)sherlock|holmes|watson` keeps every case of `she`, `holm` and
`wats`; one that cannot keep three bytes per branch has no set. When the
set is the whole pattern (every
literal exact, no assertion, no anchoring option), the literal search
alone finds matches, in priority order at the leftmost candidate.

`Prefilter` chooses one of four searchers:

| Searcher | When | How |
|---|---|---|
| Rare byte | one literal | `memchr` for its least common byte by a fixed frequency rank (non-ASCII lead bytes rank as common, continuation bytes as rare), then the literal is compared around it. When that byte is still common (the space or one of the eleven most common letters), it looks for a pair instead: the two least common bytes at their distance in the literal, eight positions per step in one 64-bit word and the least common of the rest as a third (`e` for `the`). When the byte turns out dense in the haystack (32 candidates less than 8 bytes apart on average, as a run of `b` makes for `b{30}a`), the scan switches to that pair for the rest of the haystack |
| First bytes | at most three distinct first bytes, none of them common (the space, the eleven most common letters, a non-ASCII byte) | `memchr` for each, keeping where each was last found so no byte is read twice |
| Packed pairs | at most three distinct first bytes, one of them common, and literals that at most 8 pair tests cover | Each test is two bytes at fixed offsets from the start, each compared up to one bit: the ASCII case bit 0x20, or for a Cyrillic letter 0x20 in the continuation byte and 0x01 in the lead byte, so one test covers every case of `(?i)twain` or `(?i)шерлок` (`ſ` and `K`, two and three bytes long, take a test of their own). The tests are chosen per uncovered literal for the most literals per expected candidate, by a fixed per-byte weight; a pair common enough by that weight (`t` and `h` of `(?i)the`) takes a third byte, the least common of the rest, and the scan then loads three words per test. Eight positions per step in one 64-bit word; a flagged lane that fails verification leaves the scan in its word |
| Packed (Teddy style) | up to 64 literals | three 256-entry masks, one per leading byte, a bit per literal; a position is a candidate when the masks share a bit, and only those literals are compared |

Every candidate is verified before it is returned. The accelerators follow
roadmap 6.2.2: they are consulted only while the forward DFA is in its
start state and only move forward, so no byte is read twice by them, and
every byte read and every literal byte compared is charged before it is
read. **The guard:**
once 32 candidates have been verified and they came less than 8 bytes
apart on average, a prefilter that is only an accelerator stops at the
candidate it holds (no match starts before it), and the call stops using
it. The reverse-suffix and reverse-inner optimizations are not built (see
"Open items").

## Cache memory

`CachePool` (roadmap 6.2.1 and 6.2.4) caps the bytes that lazy-DFA caches
and Pike VM workspaces hold together, process wide, with an atomic
counter: 64 MiB by default, each cache at most 2 MiB. A cache reserves
64 KiB at a time before it grows; a Pike VM workspace reserves its exact
charge (`PikeVM.workspace_charge`, bounded by `max_pike_bytes`) before its
buffer is allocated. When a reservation does not fit, idle members are
evicted, least recently used first; an evicted lease drops its caches and
reserves new ones when it is next used. A lease's forward and reverse
caches build their states in one shared scratch space, sized for the DFA
with the most nodes; a reverse DFA widened to read classes backward gets a
larger one, and each cache still reserves the scratch space as its own, so
the pool's count stays an upper bound. The scratch space is made only
after its cache's reservation succeeds, and a lease drops one that no
cache it holds uses, so a refused cache leaves nothing allocated outside
the pool. When none is idle, a lazy DFA gives
up and the search runs on the Pike VM; a Pike VM workspace the pool still
cannot supply raises `SearchLimitError` naming `cache_pool_max_bytes`, so
nothing is allocated past the cap and no wrong answer is returned. A call
that fails as it starts (invalid UTF-8, a deadline already passed) hands
its lease back first, so its caches stay evictable. The default pool is the
one deliberate piece of global state; an application sets it once at its
boundary, and callers that need isolation pass their own pool to
`Expression.new(..., cache_pool:)`:

```crystal
Mica::Regex.configure_cache_pool(max_bytes: 32_i64 * 1024 * 1024)
```

A cache or workspace is freed with its lease; the bytes it reserved go back
to the pool then (a finalizer on a small reservation object, so collection needs no
cycle through the program). A process that makes and drops expressions faster than the
collector runs could fill the pool with bytes no live lease holds, so a
reservation that finds freed members and still has no room after
evicting collects garbage once (running those finalizers) and tries again
before it gives up.

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

`spec/regex/accelerated_complexity_spec.cr` adds the R3 families (roadmap
6.8), on the default path:

| Family | Varies | Bound | C | Checked |
|---|---|---|---|---|
| Each prefilter on a candidate-dense haystack: rare byte `ab[0-9]{3}x`, rare pair `ea[0-9]{3}x` over `"eaz"`·k and `eaea` over `"eae"`·k, and first bytes `(?:zb\|xb\|qb)[0-9]` over `"zbq"`·k, packed `(?:ab\|bc\|cd\|de\|ef)[0-9]` over `"abzbczcdzdezefz"`·k, the literal search `zzzb\|zzzc\|zzzd` over `"z"`·n, the pair tests `(?i)ea[0-9]{3}x` over `"eAz"`·k and `(?i)eaea` over `"EaE"`·k, the cut alternation `(?i)sherlock\|holmes\|watson` over `"SheHolWat"`·k, and the dense rare byte `b{30}a` over `"b"`·n | n = 4,000 to 32,000 bytes | m·(n + 1) | 16 | linear growth; the guard turns a dense prefilter off and leaves a sparse one on |
| Cache thrash: `(a\|b)*a(a\|b){20}c` over random `a`/`b` with a 96 KiB cache | n = 8,000 to 64,000 | m·(n + 1) | 8 | the DFA gives up and the Pike VM keeps growth linear |
| From each start: `[a-q][^u-z]{13}[u-z]` over `"a"`·n on `Engine::EachStart`, where every start reads 14 bytes and none matches | n = 4,000 to 32,000 | m·(n + 1) | 2 | linear growth |
| Iteration: `\w+` over words, one searcher for the whole scan | n = 5,000 to 40,000 | m·(n + 1) | 4 | linear growth over the whole call |
| Iteration: `[a-z]+X\|[a-z]` over `"a"`·20,000 with a 10^7 ceiling | | | | the call's cumulative budget trips with `SearchLimitError` naming `max_work` |

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
**eligible** and must pass, on every engine path that applies: the
default path (literal search, prefilters, lazy DFAs, one-pass DFA), the
same without the literal accelerators, R2's two phases, the Pike VM, and
the backtracker when the haystack fits. The lists must
partition the corpus and match the files exactly, and `denominator.json`
pins the counts. `MICA_REGEX_CONFORMANCE_WRITE=1` rewrites the files from
a run, so any change shows in review.

| Corpus | Total | Passed | Failed | Excluded | Divergent |
|---|---|---|---|---|---|
| RE2 search | 7,552 | 3,616 | 0 | 3,936 | 0 |
| Rust regex | 1,203 | 566 | 0 | 529 | 108 |
| PCRE2 10.49 testdata subjects (valid UTF-8) | 14,916 | 7,735 | 0 | 7,174 | 7 |

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

Every divergence row ends in an approval column. `.github/CODEOWNERS`
gives `/conformance/regex/` (and the gates that read it) to the project
lead, so a change to these lists needs the owner's approving review, and
the RE2, Rust and PCRE2 census gates fail on any divergence row whose
approval column is not `approved by @login` for an owner of that path. A
regenerated list keeps the approval of every row that stays and marks a
new row `pending CODEOWNERS review`. The 108 Rust rows are pending the
owner's review, so the Rust gate fails until they are approved.

**PCRE2 testdata (milestone R3).** `conformance/regex/pcre2/convert_testdata.rb`
also writes every subject line of the PCRE2 10.49 testinput files
(`spec/regex/fixtures/pcre2_search_subjects.json`, escapes decoded as
pcre2test decodes them; `\=` comment lines skipped, data modifiers kept by
name). `spec/regex/pcre2_search_replay_spec.cr` pairs each subject with
its pattern and replays it on every engine path; the expected result is
PCRE2's own, recorded by `spec/regex/differential/pcre2_testdata_search_oracle.cr`
(standalone, links PCRE2) with Crystal's compile options: the first match,
or every match by `String#scan`'s rule when the pattern has `global`.
Excluded (`search_excluded.tsv`): 3,162 subjects whose pattern uses an
excluded construct, 1,744 whose pattern needs an option outside the
dialect, 1,247 with data modifiers and 708 whose pattern has a modifier
that changes how pcre2test searches (`replace`, `use_offset_limit`,
`match_invalid_utf` and the like), 147 invalid UTF-8 subjects (milestone
R4), 122 lines pcre2test itself cannot read, and a few patterns that are
not valid UTF-8, that both engines reject, or that pass a compile limit. The 7
divergences (`search_divergences.tsv`, pending the owner's review) are all
patterns that set their own match, depth or heap limit with
`(*LIMIT_...)`: PCRE2 stops there, while Mica reads and ignores those
settings and answers within its own limits. Every engine path agrees on
all 7,735 eligible subjects.

The replay also found an R2 defect: `\p{Cs}` (surrogates only, which no
UTF-8 haystack holds) crashed the compiler; it now compiles to a state
that never matches.

## Engine differential

`fuzz/regex_engine_differential.cr` generates small patterns (atoms,
classes, assertions, `\R`, groups, named groups, every quantifier, inline
flags, and since R3 multi-character literals and literal alternations, so
the prefilters and the literal search take part) and searches each one
over every string up to length 6 over the alphabet `a`, `b`, `é`, newline
(5,461 strings) on every engine path: the default path with and without
captures (accelerators on), the same with the literal accelerators off,
the path from each start (`Engine::EachStart`, also iterated), the
reverse DFA reading classes backward (`Engine::ReversedClasses`, also
iterated),
R2's two phases, a Pike VM with every slot, the bounded backtracker,
`matches?` on the default, unaccelerated and Pike VM paths, and a whole
`String#scan`-style iteration on one searcher (later searches start inside
the haystack and reuse the prefilter's progress and the warm caches),
default path against R2's. All must agree on every case.
`spec/regex/engine_differential_spec.cr` runs 12 patterns; the release
campaign runs two million cases:

```sh
crystal-alpha build --release fuzz/regex_engine_campaign.cr -o bin/regex_engine_campaign
for seed in 20261118 7 42 99; do bin/regex_engine_campaign $seed 100; done   # 2,184,400 cases, 0 disagreements
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

- R3's performance bar is not met yet (the benchmark reports in the R3
  evidence folder list the per-group geometric means against PCRE2-JIT
  and every losing case). The main gaps: compile time for patterns with
  large Unicode classes (each class is a UTF-8 automaton of hundreds of
  states; PCRE2 tests a code point against static property tables),
  bounded repetitions of such classes (`\p{L}{100}`: the DFA cache
  thrashes and the Pike VM runs over tens of thousands of states), and
  the per-call cost of very short searches. DFA blowups such as
  `[a-q][^u-z]{13}x` are searched from each start ("Short matches").
  Reversing a class (see "Lazy DFA") costs a few milliseconds once per
  process; building it from the code point set rather than by subset
  construction over the trie would cut that. A code-point-level class state, shared by every engine, is
  the design change that closes the first two.
- The reverse-suffix and reverse-inner literal optimizations (roadmap
  6.2.2, with the 2·n reverse-byte budget), which would skip to a required
  literal that is not a prefix.
- Compile time for repeated large classes (`\p{L}{100}`, `\b\w{25,}\b`):
  shared transition tables leave one class (`\w`, `\p{L}`) at or under
  PCRE2's compile time, but each copy still emits the class's hundreds of
  states, where PCRE2 emits one opcode and a count; a code-point-level
  class state is what brings repetitions to PCRE2's.
- The invalid-UTF paths (`MatchInvalidUtf`, `NO_UTF_CHECK`) and the stdlib
  adapters with the 6.7 adapter matrix and the PCRE2 differential gate of
  ten million cases (R4).
- Code owner approval of the 7 PCRE2 testdata divergence rows (the
  patterns' own `(*LIMIT_...)` settings).
- Code owner approval of the 108 Rust divergence rows (the Rust gate
  fails until each row says `approved by @crimson-knight`).
- Program size under nested nullable unbounded loops: each such loop gets
  a fresh copy of its body, so `(?:(?:...a?)*)*` grows exponentially with
  nesting depth (770 states at depth 8, 196,610 at depth 16, refused at
  depth 20 with 3.1 million states, which PCRE2 accepts). The size
  preflight counts the copies, so compiling stays bounded and safe, but
  compile size is not linear in pattern size for this shape.
- `split` charges output bytes but not a per-piece overhead: an empty
  piece costs one array entry. Pieces number at most n + 1, so this is
  linear.
- The ECMA-262 and XSD parsers (R6, R7) and `\X` (R9).
