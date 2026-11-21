# The PCRE2 search oracle: runs every in-scope case of the RE2 and Rust
# regex search corpora (spec/regex/support/search_corpus.cr maps them onto
# the Crystal dialect) through libpcre2-8, with the options Crystal's stdlib
# Regex compiles with (UTF | UCP | DUPNAMES plus the case's mapped options)
# and String#scan's iteration rule, and records each outcome in
# spec/regex/fixtures/pcre2_search_verdicts.json.
#
# The conformance spec reads those outcomes to tell a Mica defect from a
# difference between the corpus engine (RE2, Rust regex) and the Crystal
# dialect: a case whose corpus expectation differs from Mica's result can
# be an approved divergence only when PCRE2 gives exactly Mica's result.
#
# Like the syntax oracle next to it, this is a standalone program, never
# compiled by `crystal-alpha spec`; run it by hand when a corpus or the
# mapping changes:
#
#     crystal-alpha run spec/regex/differential/pcre2_search_oracle.cr
#
# It refuses to run against any PCRE2 other than the one
# conformance/regex/pcre2/manifest.json pins.
require "./pcre2_search_runner"

PCRE2SearchOracle.run
