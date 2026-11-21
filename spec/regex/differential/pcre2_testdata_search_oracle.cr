# The PCRE2 oracle of the testdata search replay (milestone R3): searches
# every in-scope subject of the PCRE2 10.49 testinput files
# (spec/regex/support/pcre2_search_corpus.cr scopes them) with libpcre2-8,
# as Crystal's stdlib Regex compiles patterns (UTF | UCP | DUPNAMES plus the
# mapped options), and records each outcome in
# spec/regex/fixtures/pcre2_testdata_search_verdicts.json. The replay spec
# compares every Mica engine path with these outcomes.
#
# A standalone program, never compiled by `crystal-alpha spec`; run it by
# hand when the corpus or the mapping changes:
#
#     crystal-alpha run spec/regex/differential/pcre2_testdata_search_oracle.cr
#
# It refuses to run against any PCRE2 other than the one
# conformance/regex/pcre2/manifest.json pins.
require "../support/pcre2_search_corpus"
require "./pcre2_search_runner"

version = PCRE2SearchOracle.pcre2_version
pinned = PCRE2SearchOracle.pinned_version
unless version.starts_with?(pinned)
  abort "PCRE2 #{version} is linked, but the PCRE2 manifest pins #{pinned}; install that version first."
end
list_of_outcomes = [] of SearchCorpus::Outcome
PCRE2SearchCorpus.scoped.each do |_id, _pattern, scoped|
  if job = scoped.job
    list_of_outcomes << PCRE2SearchOracle.outcome_for(job)
  end
end
file = SearchCorpus::VerdictFile.new(version, list_of_outcomes)
File.write(PCRE2SearchCorpus::VERDICTS_PATH, file.to_pretty_json + "\n")
STDOUT.puts "PCRE2 #{version}: #{list_of_outcomes.size} in-scope subjects -> #{PCRE2SearchCorpus::VERDICTS_PATH}"
