# The RE2 and Rust regex search corpora (spec/regex/fixtures/re2_search_cases.json
# and rust_regex_cases.json, converted by the Ruby scripts in
# conformance/regex/re2/ and conformance/regex/rust/), the rules that map
# each case onto the Crystal dialect, and the runner that searches with
# Mica::Regex.
#
# Shared by the default spec suite (which never links PCRE2) and the PCRE2
# search oracle in spec/regex/differential/ (which does).
require "json"
require "../../../src/mica/regex"

module SearchCorpus
  FIXTURES      = File.join(__DIR__, "..", "fixtures")
  CONFORMANCE   = File.join(__DIR__, "..", "..", "..", "conformance", "regex")
  VERDICTS_PATH = File.join(FIXTURES, "pcre2_search_verdicts.json")

  # The two corpora.
  enum Corpus
    RE2
    Rust

    def directory : String
      File.join(CONFORMANCE, re2? ? "re2" : "rust")
    end

    def fixture_path : String
      File.join(FIXTURES, re2? ? "re2_search_cases.json" : "rust_regex_cases.json")
    end
  end

  # One case from re2_search_cases.json.
  struct RE2Case
    include JSON::Serializable

    getter id : String = ""
    getter mode : String = ""
    getter pattern : String? = nil
    getter pattern_hex : String? = nil
    getter haystack : String? = nil
    getter haystack_hex : String? = nil
    getter expected : Array(Array(Int32)?)? = nil
  end

  # One case from rust_regex_cases.json.
  struct RustCase
    include JSON::Serializable

    getter id : String = ""
    getter pattern : String? = nil
    getter regex_set : Array(String)? = nil
    getter haystack : String? = nil
    getter haystack_hex : String? = nil
    # Each match as one span per listed group (nil: did not take part).
    getter matches : Array(Array(Array(Int32)?)) = [] of Array(Array(Int32)?)
    # True when every group is listed, false when only group 0 is.
    getter captures_listed : Bool = false
    @[JSON::Field(key: "match-limit")]
    getter match_limit : Int32? = nil
    getter anchored : Bool = false
    @[JSON::Field(key: "case-insensitive")]
    getter case_insensitive : Bool = false
    getter compiles : Bool = true
    getter unicode : Bool = true
    getter utf8 : Bool = true
    @[JSON::Field(key: "match-kind")]
    getter match_kind : String = "leftmost-first"
    @[JSON::Field(key: "search-kind")]
    getter search_kind : String = "leftmost"
    @[JSON::Field(key: "line-terminator")]
    getter line_terminator : String? = nil
    # The search span `[start, end]`, when not the whole haystack.
    getter bounds : Array(Int32)? = nil
  end

  struct RE2File
    include JSON::Serializable
    getter cases : Array(RE2Case)
  end

  struct RustFile
    include JSON::Serializable
    getter cases : Array(RustCase)
  end

  # A match: one span per group (nil for a group that did not take part).
  alias Spans = Array(Array(Int32)?)

  # What searching a case gives: a compile error, or the successive
  # matches.
  struct Outcome
    include JSON::Serializable

    getter id : String
    getter? compiled : Bool
    # For a compile error: "unsupported", "syntax" or "limit".
    getter error_kind : String
    getter error : String
    getter matches : Array(Spans)

    def initialize(@id : String, @compiled : Bool, @error_kind : String, @error : String, @matches : Array(Spans))
    end

    def self.compile_error(id : String, kind : String, message : String) : self
      new(id, false, kind, message, [] of Spans)
    end

    # Returns true when the results agree, comparing only the first
    # *groups* groups of each match when *groups* is given.
    def same_result?(other : Outcome, groups : Int32? = nil) : Bool
      return !other.compiled? if !compiled?
      return false unless other.compiled?
      return false unless matches.size == other.matches.size
      matches.zip(other.matches).all? do |mine, theirs|
        if groups
          mine.first(groups) == theirs.first(groups)
        else
          mine == theirs
        end
      end
    end

    def describe : String
      return "compile error (#{error_kind})" unless compiled?
      return "no match" if matches.empty?
      matches.map { |spans| spans.map { |span| span ? span.join('-') : "-" }.join(' ') }.join(" | ")
    end
  end

  # A case mapped onto the Crystal dialect: the pattern, the haystack, the
  # options, where the search starts, how many matches to take, and what
  # the corpus expects.
  record Job,
    id : String,
    pattern : String,
    haystack : String,
    compile_options : Mica::Regex::CompileOptions,
    match_options : Mica::Regex::MatchOptions,
    start : Int32,
    # Take every successive match (as `Expression#each_match`), or only the
    # first.
    iterate : Bool,
    # Stop after this many matches.
    match_limit : Int32?,
    # The corpus's expectation.
    expected : Outcome,
    # Compare only this many groups per match (nil: all of them).
    groups_compared : Int32?

  # The result of scoping a case: a job, or the reason it is outside the
  # Crystal dialect's search semantics.
  record Scoped, job : Job?, exclusion : String?

  # The options every RE2 case runs with: RE2's `$` is `\z`, and its `\d`,
  # `\s`, `\w`, `\b` and POSIX classes are ASCII-only.
  RE2_OPTIONS = Mica::Regex::CompileOptions::DollarEndOnly | Mica::Regex::CompileOptions::ASCII_ALL

  def self.load_re2 : Array(RE2Case)
    RE2File.from_json(File.read(Corpus::RE2.fixture_path)).cases
  end

  def self.load_rust : Array(RustCase)
    RustFile.from_json(File.read(Corpus::Rust.fixture_path)).cases
  end

  # Returns the bytes of a fixture field as a String (it may hold invalid
  # UTF-8 when the field was stored as hex).
  def self.text_of(plain : String?, hex : String?) : String
    return plain if plain
    String.new((hex || "").hexbytes)
  end

  def self.scope(test_case : RE2Case) : Scoped
    if test_case.mode.ends_with?("longest")
      return Scoped.new(nil, "leftmost-longest (POSIX) column: Mica::Regex implements leftmost-first only")
    end
    pattern = text_of(test_case.pattern, test_case.pattern_hex)
    haystack = text_of(test_case.haystack, test_case.haystack_hex)
    return Scoped.new(nil, "pattern is not valid UTF-8 (invalid-UTF paths arrive in R4)") unless pattern.valid_encoding?
    return Scoped.new(nil, "haystack is not valid UTF-8 (invalid-UTF paths arrive in R4)") unless haystack.valid_encoding?
    pattern = "\\A(?:#{pattern})\\z" if test_case.mode == "full"
    expected_matches = [] of Spans
    if spans = test_case.expected
      expected_matches << spans
    end
    expected = Outcome.new(test_case.id, true, "", "", expected_matches)
    job = Job.new(test_case.id, pattern, haystack, RE2_OPTIONS, Mica::Regex::MatchOptions::None, 0, false, nil,
      expected, nil)
    Scoped.new(job, nil)
  end

  def self.scope(test_case : RustCase) : Scoped
    return Scoped.new(nil, "regex set (several patterns searched at once): outside the Expression API") if test_case.regex_set
    unless test_case.match_kind == "leftmost-first"
      return Scoped.new(nil, "match kind #{test_case.match_kind}: Mica::Regex implements leftmost-first only")
    end
    unless test_case.search_kind == "leftmost"
      return Scoped.new(nil, "search kind #{test_case.search_kind}: Mica::Regex reports leftmost matches only")
    end
    return Scoped.new(nil, "utf8 = false: byte-oriented matching (invalid-UTF paths arrive in R4)") unless test_case.utf8
    return Scoped.new(nil, "unicode = false: Rust's ASCII-only mode is outside the Crystal dialect") unless test_case.unicode
    if terminator = test_case.line_terminator
      return Scoped.new(nil, "line terminator #{terminator.inspect}: the Crystal dialect's newline is LF")
    end
    haystack = text_of(test_case.haystack, test_case.haystack_hex)
    return Scoped.new(nil, "haystack is not valid UTF-8 (invalid-UTF paths arrive in R4)") unless haystack.valid_encoding?
    start = 0
    if bounds = test_case.bounds
      first, last = bounds[0], bounds[1]
      if last != haystack.bytesize
        return Scoped.new(nil, "search end bound #{last}: Crystal's Regex API has no end bound")
      end
      start = first
      if start < haystack.bytesize && haystack.to_slice[start] & 0xC0 == 0x80
        return Scoped.new(nil, "search start #{start} inside a UTF-8 character: the Crystal dialect raises ArgumentError (roadmap 6.2.5)")
      end
    end
    pattern = test_case.pattern || ""
    options = Mica::Regex::CompileOptions::DollarEndOnly
    options |= Mica::Regex::CompileOptions::IgnoreCase if test_case.case_insensitive
    match_options = test_case.anchored ? Mica::Regex::MatchOptions::Anchored : Mica::Regex::MatchOptions::None
    expected, groups = rust_expectation(test_case)
    job = Job.new(test_case.id, pattern, haystack, options, match_options, start, true, test_case.match_limit,
      expected, groups)
    Scoped.new(job, nil)
  end

  # The expected outcome of a Rust case and how many groups to compare:
  # every group when the test lists them, group 0 otherwise.
  private def self.rust_expectation(test_case : RustCase) : {Outcome, Int32?}
    return {Outcome.compile_error(test_case.id, "expected", "the test expects a compile error"), nil} unless test_case.compiles
    groups = test_case.captures_listed ? nil : 1
    {Outcome.new(test_case.id, true, "", "", test_case.matches), groups}
  end

  # The search limits the corpora run under (every case is small).
  LIMITS = Mica::Regex::SearchLimits::TRUSTED_INPUT

  # Searches *job* with Mica::Regex on *engine*. Iteration follows
  # `String#scan`: after an empty match the next search starts one
  # character later.
  def self.run_mica(job : Job, engine : Mica::Regex::Engine = Mica::Regex::Engine::Auto) : Outcome
    expression = begin
      Mica::Regex::Expression.new(job.pattern, job.compile_options,
        compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
    rescue error : Mica::Regex::UnsupportedConstructError
      return Outcome.compile_error(job.id, "unsupported", error.construct)
    rescue error : Mica::Regex::CompileLimitError
      return Outcome.compile_error(job.id, "limit", error.limit_name)
    rescue error : Mica::Regex::SyntaxError
      return Outcome.compile_error(job.id, "syntax", error.message || "")
    end
    searcher = Mica::Regex::Searcher.new(expression.program, job.haystack, LIMITS, nil, engine)
    list_of_matches = [] of Spans
    offset = job.start
    while slots = searcher.find(offset, job.match_options, true)
      list_of_matches << spans_of(slots, expression.capture_count)
      break unless job.iterate
      break if (limit = job.match_limit) && list_of_matches.size >= limit
      offset = next_offset(job.haystack, slots[0].to_i32, slots[1].to_i32)
    end
    searcher.finish
    Outcome.new(job.id, true, "", "", list_of_matches)
  rescue error : Mica::Regex::SearchLimitError
    # An engine path can need more work than the corpus limits allow (the
    # Pike VM with every slot, on a large program); the caller decides.
    Outcome.compile_error(job.id, "search-limit", error.limit_name)
  end

  # Returns true when *engine* can run *job* (the backtracker only when
  # the whole haystack fits its bitset).
  def self.engine_applies?(job : Job, program : Mica::Regex::Program, engine : Mica::Regex::Engine) : Bool
    return true unless engine.backtracker?
    Mica::Regex::BoundedBacktracker.fits?(program, job.haystack.bytesize - job.start)
  end

  def self.spans_of(slots : Slice(Int64), capture_count : Int32) : Spans
    (0..capture_count).map do |group|
      first = slots[group * 2]
      last = slots[group * 2 + 1]
      first < 0 || last < 0 ? nil : [first.to_i32, last.to_i32]
    end
  end

  # Where `String#scan` searches next after a match from *first* to
  # *last*.
  def self.next_offset(haystack : String, first : Int32, last : Int32) : Int32
    return last if last > first
    return first + 1 if first >= haystack.bytesize
    first + Mica::Core::UTF8.sequence_length(haystack.to_slice[first])
  end

  # Every job of a corpus, scoped, in fixture order.
  def self.scoped(corpus : Corpus) : Array({String, String, Scoped})
    if corpus.re2?
      load_re2.map { |test_case| {test_case.id, test_case.text_pattern, scope(test_case)} }
    else
      load_rust.map { |test_case| {test_case.id, test_case.pattern || "", scope(test_case)} }
    end
  end

  struct RE2Case
    def text_pattern : String
      SearchCorpus.text_of(pattern, pattern_hex)
    end
  end

  # PCRE2's outcomes, recorded by spec/regex/differential/pcre2_search_oracle.cr.
  struct VerdictFile
    include JSON::Serializable

    getter pcre2_version : String
    getter outcomes : Array(Outcome)

    def initialize(@pcre2_version : String, @outcomes : Array(Outcome))
    end
  end

  def self.load_verdicts : Hash(String, Outcome)
    return {} of String => Outcome unless File.exists?(VERDICTS_PATH)
    VerdictFile.from_json(File.read(VERDICTS_PATH)).outcomes.to_h { |outcome| {outcome.id, outcome} }
  end
end
