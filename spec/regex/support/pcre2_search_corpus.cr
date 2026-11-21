# The PCRE2 10.49 testdata search replay (milestone R3, roadmap 6.5): every
# subject line of the testinput files (spec/regex/fixtures/pcre2_search_subjects.json,
# converted by conformance/regex/pcre2/convert_testdata.rb) paired with its
# pattern from the syntax corpus, mapped onto the Crystal dialect.
#
# A pair is in scope when the pattern is (its pcre2test modifiers map onto
# Crystal's compile options and leave matching alone), the subject is valid
# UTF-8 with no data modifiers, and Mica compiles the pattern. Invalid UTF-8
# subjects join at milestone R4, with the invalid-UTF paths.
#
# The expected result is PCRE2's own, recorded by
# spec/regex/differential/pcre2_testdata_search_oracle.cr with the options
# Crystal's stdlib Regex compiles with: the first match, or every match by
# String#scan's rule when the pattern has the `global` modifier.
#
# Shared by the default spec suite (which never links PCRE2) and that oracle.
require "./pcre2_corpus"
require "./search_corpus"

module PCRE2SearchCorpus
  SUBJECTS_PATH = File.join(__DIR__, "..", "fixtures", "pcre2_search_subjects.json")
  VERDICTS_PATH = File.join(__DIR__, "..", "fixtures", "pcre2_testdata_search_verdicts.json")
  DIRECTORY     = File.join(SearchCorpus::CONFORMANCE, "pcre2")

  # The subjects whose pattern sets PCRE2's own match-time limit (see
  # spec/regex/pcre2_search_replay_spec.cr and spec/regex/bail_early_spec.cr).
  RESOURCE_LIMITS_PATH = File.join(DIRECTORY, "search_resource_limits.tsv")

  # The pattern settings that give PCRE2 its own match-time limits.
  LIMIT_SETTINGS = {"(*LIMIT_MATCH=", "(*LIMIT_DEPTH=", "(*LIMIT_HEAP="}

  # Returns true when *pattern* sets one of PCRE2's match-time limits.
  def self.sets_a_resource_limit?(pattern : String) : Bool
    LIMIT_SETTINGS.any? { |setting| pattern.includes?(setting) }
  end

  # One subject line.
  struct Subject
    include JSON::Serializable

    getter id : String = ""
    getter pattern_id : String = ""
    getter subject : String? = nil
    getter subject_hex : String? = nil
    @[JSON::Field(key: "data_modifiers")]
    getter list_of_data_modifiers : Array(String) = [] of String
    getter problem : String? = nil
  end

  struct SubjectFile
    include JSON::Serializable

    getter subject_count : Int32 = 0
    @[JSON::Field(key: "subjects")]
    getter list_of_subjects : Array(Subject) = [] of Subject
  end

  # pcre2test pattern modifiers that change how pcre2test searches (not
  # how the pattern compiles), which this replay does not reproduce.
  SEARCH_MODIFIERS = {
    "altglobal", "notbol", "noteol", "notempty", "notempty_atstart", "partial_hard", "partial_soft", "ph", "ps",
    "dfa", "dfa_restart", "dfa_shortest", "offset", "offset_limit", "use_offset_limit", "startoffset", "replace",
    "substitute_callout", "substitute_case_callout", "substitute_extended", "substitute_literal",
    "substitute_matched", "substitute_overflow_length", "substitute_replacement_only", "substitute_skip",
    "substitute_stop", "substitute_subject", "substitute_unknown_unset", "substitute_unset_empty",
    "null_subject", "null_replacement", "null_substitute_match_data", "callout_capture", "callout_data",
    "callout_error", "callout_extra", "callout_fail", "callout_info", "callout_no_where", "callout_none",
    "depth_limit", "heap_limit", "match_limit", "recursion_limit", "find_limits", "find_limits_noheap",
    "match_invalid_utf",
  }

  # Scopes every subject: a job, or the reason it is left out.
  def self.scoped : Array({String, String, SearchCorpus::Scoped})
    cases = PCRE2Corpus.load.cases.to_h { |test_case| {test_case.id, test_case} }
    SubjectFile.from_json(File.read(SUBJECTS_PATH)).list_of_subjects.map do |subject|
      test_case = cases[subject.pattern_id]? || raise "#{subject.id}: no pattern #{subject.pattern_id}"
      pattern = test_case.pattern || ""
      {subject.id, pattern, scope(subject, test_case)}
    end
  end

  def self.scope(subject : Subject, test_case : PCRE2Corpus::Case) : SearchCorpus::Scoped
    scope, modifier = PCRE2Corpus.scope_of(test_case)
    return excluded("pcre2test rejects the case: #{modifier}") if scope.harness_rejected?
    return excluded("outside the Crystal dialect: modifier #{modifier}") if scope.outside_dialect?
    return excluded("pattern bytes are not valid UTF-8") unless test_case.pattern
    names = test_case.active_modifiers.map(&.split('=', 2).first)
    if search_modifier = names.find { |name| SEARCH_MODIFIERS.includes?(name) }
      return excluded("search modifier #{search_modifier}")
    end
    return excluded("pcre2test cannot read the line: #{subject.problem}") if subject.problem
    unless subject.list_of_data_modifiers.empty?
      return excluded("data modifiers #{subject.list_of_data_modifiers.join(',')}")
    end
    haystack = subject.subject
    return excluded("invalid UTF-8 subject (milestone R4)") unless haystack
    pattern = String.new(test_case.pattern_bytes)
    return excluded("pattern bytes are not valid UTF-8") unless pattern.valid_encoding?
    iterate = names.includes?("global")
    placeholder = SearchCorpus::Outcome.new(subject.id, true, "", "", [] of SearchCorpus::Spans)
    job = SearchCorpus::Job.new(subject.id, pattern, haystack, PCRE2Corpus.options_of(test_case),
      Mica::Regex::MatchOptions::None, 0, iterate, nil, placeholder, nil)
    SearchCorpus::Scoped.new(job, nil)
  end

  private def self.excluded(reason : String) : SearchCorpus::Scoped
    SearchCorpus::Scoped.new(nil, reason)
  end

  # PCRE2's outcomes.
  def self.load_verdicts : Hash(String, SearchCorpus::Outcome)
    return {} of String => SearchCorpus::Outcome unless File.exists?(VERDICTS_PATH)
    SearchCorpus::VerdictFile.from_json(File.read(VERDICTS_PATH)).outcomes.to_h { |outcome| {outcome.id, outcome} }
  end
end
