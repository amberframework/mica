# Changelog

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
