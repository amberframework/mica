# Engine runner: Mica::Regex from this checkout. This program references no
# stdlib Regex, so it links no PCRE2. bench/regex/run.sh --mica-ref REF
# builds the same body against another ref's src/ through a generated entry
# file (see run.sh).
#   crystal-alpha build --release bench/regex/mica_runner.cr -o bench/bin/regex/mica_runner
require "../../src/mica"
require "./src/mica_runner_body"
