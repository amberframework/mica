require "../spec_helper"

# Findings of the third R3 review: every haystack scan a search makes
# before an engine runs (the short-search start filter, the literal
# accelerators, the final-byte skip and the FirstLine line feed search) is
# paid for before it reads, so max_work and the deadline stop it, and a
# quantified POSIX word assertion repeats only the lookaround PCRE2
# lowers it to.
private UNTRUSTED = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN
private TRUSTED   = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private REQUEST   = Mica::Regex::SearchLimits::REQUEST
private ENGINES   = {Mica::Regex::Engine::Auto, Mica::Regex::Engine::NoAccelerators, Mica::Regex::Engine::EachStart, Mica::Regex::Engine::ReversedClasses, Mica::Regex::Engine::TwoPhase,
                     Mica::Regex::Engine::PikeVM, Mica::Regex::Engine::Backtracker}

# Every non-overlapping match of *program* in *haystack* on *engine*, as
# byte spans.
private def scan(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine) : Array({Int64, Int64})
  list_of_spans = [] of {Int64, Int64}
  searcher = Mica::Regex::Searcher.new(program, haystack, REQUEST, nil, engine)
  offset = 0
  while found = searcher.find(offset, Mica::Regex::MatchOptions::None, false)
    list_of_spans << {found[0], found[1]}
    offset = found[1] > found[0] ? found[1].to_i32 : found[1].to_i32 + 1
    while offset < haystack.bytesize && haystack.byte_at(offset) & 0xC0 == 0x80
      offset += 1
    end
    break if offset > haystack.bytesize
  end
  searcher.finish
  list_of_spans
end

# The operations a search had charged when it raised *error*.
private def operations_of(error : Mica::Regex::SearchLimitError) : Int64
  error.message.to_s[/A search of (\d+) operations/, 1].to_i64
end

describe "Mica::Regex R3 third review findings" do
  it_satisfies "REGEX-R3-short-search", "declines a short search whose start filter scans would not fit max_work" do
    # Validation fits the allowance; the filter scan after it does not, so
    # the short search leaves the call to the searcher, which raises.
    expression = Mica::Regex::Expression.new("z", compile_limits: TRUSTED)
    haystack = "a" * 256
    limits = Mica::Regex::SearchLimits.custom(work_ceiling: 256_i64, base_work: 256_i64, work_per_byte: 0_i64,
      work_per_state: 0_i64)
    expect_raises(Mica::Regex::SearchLimitError, "max_work") { expression.match(haystack, limits: limits) }
    expect_raises(Mica::Regex::SearchLimitError, "max_work") { expression.matches?(haystack, limits: limits) }
    pike = Mica::Regex::Searcher.new(expression.program, haystack, limits, nil, Mica::Regex::Engine::PikeVM)
    expect_raises(Mica::Regex::SearchLimitError, "max_work") { pike.find(0, Mica::Regex::MatchOptions::None, false) }

    one = Mica::Regex::SearchLimits.custom(work_ceiling: 1_i64)
    {"z", "\\Az", "[xyz]q"}.each do |source|
      compiled = Mica::Regex::Expression.new(source, compile_limits: TRUSTED)
      expect_raises(Mica::Regex::SearchLimitError, "max_work") { compiled.match("a", limits: one) }
      expect_raises(Mica::Regex::SearchLimitError, "max_work") { compiled.matches?("a", limits: one) }
    end
  end

  it_satisfies "REGEX-R3-accelerators", "pays for every byte an accelerator reads before reading it" do
    haystack = "abcdefghij" * 10_000
    ceiling = haystack.bytesize.to_i64 + 1_000
    limits = Mica::Regex::SearchLimits.custom(work_ceiling: ceiling, work_per_byte: 1_000_i64)
    # The memchr literal search, the packed search and the rare-byte
    # prefilter, each over a haystack with no candidate: the search stops
    # one operation past the allowance, before the byte it could not pay
    # for.
    {"zzzq", "zq|yq|xq|wq", "q[a-z]+"}.each do |source|
      expression = Mica::Regex::Expression.new(source, compile_limits: TRUSTED)
      error = expect_raises(Mica::Regex::SearchLimitError) { expression.match(haystack, limits: limits) }
      error.limit_name.should eq("max_work")
      {source, operations_of(error)}.should eq({source, ceiling + 1})
    end

    # The final-byte skip of the search from each start.
    program = Mica::Regex::Expression.new("[a-q][^u-z]{13}x", compile_limits: TRUSTED).program
    searcher = Mica::Regex::Searcher.new(program, haystack, limits, nil, Mica::Regex::Engine::EachStart)
    error = expect_raises(Mica::Regex::SearchLimitError) { searcher.find(0, Mica::Regex::MatchOptions::None, false) }
    operations_of(error).should eq(ceiling + 1)

    # The FirstLine line feed search.
    first_line = Mica::Regex::Expression.new("x", Mica::Regex::CompileOptions::FirstLine, compile_limits: TRUSTED)
    error = expect_raises(Mica::Regex::SearchLimitError) { first_line.match(haystack, limits: limits) }
    operations_of(error).should eq(ceiling + 1)
  end

  it_satisfies "REGEX-R2-limits", "reads a deadline that has already passed before it reads the haystack" do
    # An invalid haystack: validation would raise EncodingError, but the
    # deadline is read first.
    invalid = String.new(Bytes[0x61, 0xff, 0x62])
    {"b", "\\Ab", "[ab]+"}.each do |source|
      expression = Mica::Regex::Expression.new(source, compile_limits: TRUSTED)
      expect_raises(Mica::DeadlineExceededError) { expression.match(invalid, limits: REQUEST, timeout: -1.second) }
      expect_raises(Mica::DeadlineExceededError) { expression.matches?(invalid, limits: REQUEST, timeout: -1.second) }
    end
  end

  it_satisfies "REGEX-R3-conformance", "repeats only the lookaround of a quantified POSIX word assertion, as PCRE2 does" do
    # PCRE2 lowers [[:<:]] to \b(?=\w) and [[:>:]] to \b(?<=\w): a
    # quantifier repeats the lookaround and the \b stays. The spans are
    # PCRE2 10.49's (Crystal stdlib Regex, UTF and UCP).
    {
      {"a[[:<:]]*", "ab", [] of {Int64, Int64}},
      {"a[[:<:]]*", "a b", [{0_i64, 1_i64}]},
      {"a[[:<:]]*", "aσ", [] of {Int64, Int64}},
      {"a[[:<:]]*", "σa b", [{2_i64, 3_i64}]},
      {"a[[:<:]]*", "x xa", [{3_i64, 4_i64}]},
      {"a[[:<:]]*", "b ab", [] of {Int64, Int64}},
      {"a[[:>:]]*", "ab", [] of {Int64, Int64}},
      {"a[[:>:]]*", "a b", [{0_i64, 1_i64}]},
      {"a[[:>:]]*", "aσ", [] of {Int64, Int64}},
      {"a[[:>:]]*", "σa b", [{2_i64, 3_i64}]},
      {"a[[:>:]]*", "x xa", [{3_i64, 4_i64}]},
      {"a[[:>:]]*", "b ab", [] of {Int64, Int64}},
      {"a[[:<:]]?", "ab", [] of {Int64, Int64}},
      {"a[[:<:]]?", "a b", [{0_i64, 1_i64}]},
      {"a[[:<:]]?", "aσ", [] of {Int64, Int64}},
      {"a[[:<:]]?", "σa b", [{2_i64, 3_i64}]},
      {"a[[:<:]]?", "x xa", [{3_i64, 4_i64}]},
      {"a[[:<:]]?", "b ab", [] of {Int64, Int64}},
      {"a[[:<:]]+", "ab", [] of {Int64, Int64}},
      {"a[[:<:]]+", "a b", [] of {Int64, Int64}},
      {"a[[:<:]]+", "aσ", [] of {Int64, Int64}},
      {"a[[:<:]]+", "σa b", [] of {Int64, Int64}},
      {"a[[:<:]]+", "x xa", [] of {Int64, Int64}},
      {"a[[:<:]]+", "b ab", [] of {Int64, Int64}},
      {"[[:>:]]*b", "ab", [] of {Int64, Int64}},
      {"[[:>:]]*b", "a b", [{2_i64, 3_i64}]},
      {"[[:>:]]*b", "aσ", [] of {Int64, Int64}},
      {"[[:>:]]*b", "σa b", [{4_i64, 5_i64}]},
      {"[[:>:]]*b", "x xa", [] of {Int64, Int64}},
      {"[[:>:]]*b", "b ab", [{0_i64, 1_i64}]},
      {"[[:<:]]{0}a", "ab", [{0_i64, 1_i64}]},
      {"[[:<:]]{0}a", "a b", [{0_i64, 1_i64}]},
      {"[[:<:]]{0}a", "aσ", [{0_i64, 1_i64}]},
      {"[[:<:]]{0}a", "σa b", [] of {Int64, Int64}},
      {"[[:<:]]{0}a", "x xa", [] of {Int64, Int64}},
      {"[[:<:]]{0}a", "b ab", [{2_i64, 3_i64}]},
      {"[[:<:]]{2,3}a", "ab", [{0_i64, 1_i64}]},
      {"[[:<:]]{2,3}a", "a b", [{0_i64, 1_i64}]},
      {"[[:<:]]{2,3}a", "aσ", [{0_i64, 1_i64}]},
      {"[[:<:]]{2,3}a", "σa b", [] of {Int64, Int64}},
      {"[[:<:]]{2,3}a", "x xa", [] of {Int64, Int64}},
      {"[[:<:]]{2,3}a", "b ab", [{2_i64, 3_i64}]},
      {"x[[:>:]]{0}", "ab", [] of {Int64, Int64}},
      {"x[[:>:]]{0}", "a b", [] of {Int64, Int64}},
      {"x[[:>:]]{0}", "aσ", [] of {Int64, Int64}},
      {"x[[:>:]]{0}", "σa b", [] of {Int64, Int64}},
      {"x[[:>:]]{0}", "x xa", [{0_i64, 1_i64}]},
      {"x[[:>:]]{0}", "b ab", [] of {Int64, Int64}},
      {"(?:a|[[:<:]]*)b", "ab", [{0_i64, 2_i64}]},
      {"(?:a|[[:<:]]*)b", "a b", [{2_i64, 3_i64}]},
      {"(?:a|[[:<:]]*)b", "aσ", [] of {Int64, Int64}},
      {"(?:a|[[:<:]]*)b", "σa b", [{4_i64, 5_i64}]},
      {"(?:a|[[:<:]]*)b", "x xa", [] of {Int64, Int64}},
      {"(?:a|[[:<:]]*)b", "b ab", [{0_i64, 1_i64}, {2_i64, 4_i64}]},
      {"[[:<:]]*?a", "ab", [{0_i64, 1_i64}]},
      {"[[:<:]]*?a", "a b", [{0_i64, 1_i64}]},
      {"[[:<:]]*?a", "aσ", [{0_i64, 1_i64}]},
      {"[[:<:]]*?a", "σa b", [] of {Int64, Int64}},
      {"[[:<:]]*?a", "x xa", [] of {Int64, Int64}},
      {"[[:<:]]*?a", "b ab", [{2_i64, 3_i64}]},
      {"a[[:>:]]{0,2}b", "ab", [] of {Int64, Int64}},
      {"a[[:>:]]{0,2}b", "a b", [] of {Int64, Int64}},
      {"a[[:>:]]{0,2}b", "aσ", [] of {Int64, Int64}},
      {"a[[:>:]]{0,2}b", "σa b", [] of {Int64, Int64}},
      {"a[[:>:]]{0,2}b", "x xa", [] of {Int64, Int64}},
      {"a[[:>:]]{0,2}b", "b ab", [] of {Int64, Int64}},
      {"(?aW)a[[:<:]]*", "ab", [] of {Int64, Int64}},
      {"(?aW)a[[:<:]]*", "a b", [{0_i64, 1_i64}]},
      {"(?aW)a[[:<:]]*", "aσ", [{0_i64, 1_i64}]},
      {"(?aW)a[[:<:]]*", "σa b", [{2_i64, 3_i64}]},
      {"(?aW)a[[:<:]]*", "x xa", [{3_i64, 4_i64}]},
      {"(?aW)a[[:<:]]*", "b ab", [] of {Int64, Int64}},
      {"[[:>:]]?\\b", "ab", [{0_i64, 0_i64}, {2_i64, 2_i64}]},
      {"[[:>:]]?\\b", "a b", [{0_i64, 0_i64}, {1_i64, 1_i64}, {2_i64, 2_i64}, {3_i64, 3_i64}]},
      {"[[:>:]]?\\b", "aσ", [{0_i64, 0_i64}, {3_i64, 3_i64}]},
      {"[[:>:]]?\\b", "σa b", [{0_i64, 0_i64}, {3_i64, 3_i64}, {4_i64, 4_i64}, {5_i64, 5_i64}]},
      {"[[:>:]]?\\b", "x xa", [{0_i64, 0_i64}, {1_i64, 1_i64}, {2_i64, 2_i64}, {4_i64, 4_i64}]},
      {"[[:>:]]?\\b", "b ab", [{0_i64, 0_i64}, {1_i64, 1_i64}, {2_i64, 2_i64}, {4_i64, 4_i64}]},
      {"(?:[[:<:]][[:>:]])*a", "ab", [{0_i64, 1_i64}]},
      {"(?:[[:<:]][[:>:]])*a", "a b", [{0_i64, 1_i64}]},
      {"(?:[[:<:]][[:>:]])*a", "aσ", [{0_i64, 1_i64}]},
      {"(?:[[:<:]][[:>:]])*a", "σa b", [{2_i64, 3_i64}]},
      {"(?:[[:<:]][[:>:]])*a", "x xa", [{3_i64, 4_i64}]},
      {"(?:[[:<:]][[:>:]])*a", "b ab", [{2_i64, 3_i64}]},
    }.each do |source, haystack, expected|
      program = Mica::Regex::Expression.new(source, compile_limits: UNTRUSTED).program
      ENGINES.each do |engine|
        {source, haystack, engine, scan(program, haystack, engine)}.should eq({source, haystack, engine, expected})
      end
    end
  end
  it_satisfies "REGEX-R3-conformance", "reads the lookaround of a POSIX word assertion with Unicode \\w under (?aW), as PCRE2 does" do
    # Under (?aW) PCRE2 makes the \b of [[:<:]] and [[:>:]] ASCII, while the
    # lookaround still reads its UCP word set (\p{Xwd}): "aé" has a word
    # start after "a". The spans are PCRE2 10.49's (Crystal stdlib Regex,
    # UTF and UCP).
    {
      {"a(?aW:[[:<:]])", "aé", [{0_i64, 1_i64}]},
      {"a(?aW:[[:<:]])", "éa", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]])", "a é", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]])", "é a", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]])", "éab", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]])", "_é_", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]])", "b", [] of {Int64, Int64}},
      {"é(?aW:[[:>:]])", "aé", [] of {Int64, Int64}},
      {"é(?aW:[[:>:]])", "éa", [{0_i64, 2_i64}]},
      {"é(?aW:[[:>:]])", "a é", [] of {Int64, Int64}},
      {"é(?aW:[[:>:]])", "é a", [] of {Int64, Int64}},
      {"é(?aW:[[:>:]])", "éab", [{0_i64, 2_i64}]},
      {"é(?aW:[[:>:]])", "_é_", [{1_i64, 3_i64}]},
      {"é(?aW:[[:>:]])", "b", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]]+)", "aé", [{0_i64, 1_i64}]},
      {"a(?aW:[[:<:]]+)", "éa", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]]+)", "a é", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]]+)", "é a", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]]+)", "éab", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]]+)", "_é_", [] of {Int64, Int64}},
      {"a(?aW:[[:<:]]+)", "b", [] of {Int64, Int64}},
      {"é(?aW:[[:>:]]?)", "aé", [] of {Int64, Int64}},
      {"é(?aW:[[:>:]]?)", "éa", [{0_i64, 2_i64}]},
      {"é(?aW:[[:>:]]?)", "a é", [] of {Int64, Int64}},
      {"é(?aW:[[:>:]]?)", "é a", [] of {Int64, Int64}},
      {"é(?aW:[[:>:]]?)", "éab", [{0_i64, 2_i64}]},
      {"é(?aW:[[:>:]]?)", "_é_", [{1_i64, 3_i64}]},
      {"é(?aW:[[:>:]]?)", "b", [] of {Int64, Int64}},
      {"(?aW)[[:<:]]{2}é", "aé", [{1_i64, 3_i64}]},
      {"(?aW)[[:<:]]{2}é", "éa", [] of {Int64, Int64}},
      {"(?aW)[[:<:]]{2}é", "a é", [] of {Int64, Int64}},
      {"(?aW)[[:<:]]{2}é", "é a", [] of {Int64, Int64}},
      {"(?aW)[[:<:]]{2}é", "éab", [] of {Int64, Int64}},
      {"(?aW)[[:<:]]{2}é", "_é_", [{1_i64, 3_i64}]},
      {"(?aW)[[:<:]]{2}é", "b", [] of {Int64, Int64}},
      {"(?aW)[[:>:]]*b", "aé", [] of {Int64, Int64}},
      {"(?aW)[[:>:]]*b", "éa", [] of {Int64, Int64}},
      {"(?aW)[[:>:]]*b", "a é", [] of {Int64, Int64}},
      {"(?aW)[[:>:]]*b", "é a", [] of {Int64, Int64}},
      {"(?aW)[[:>:]]*b", "éab", [] of {Int64, Int64}},
      {"(?aW)[[:>:]]*b", "_é_", [] of {Int64, Int64}},
      {"(?aW)[[:>:]]*b", "b", [{0_i64, 1_i64}]},
      {"(?aW)é[[:>:]]+a", "aé", [] of {Int64, Int64}},
      {"(?aW)é[[:>:]]+a", "éa", [{0_i64, 3_i64}]},
      {"(?aW)é[[:>:]]+a", "a é", [] of {Int64, Int64}},
      {"(?aW)é[[:>:]]+a", "é a", [] of {Int64, Int64}},
      {"(?aW)é[[:>:]]+a", "éab", [{0_i64, 3_i64}]},
      {"(?aW)é[[:>:]]+a", "_é_", [] of {Int64, Int64}},
      {"(?aW)é[[:>:]]+a", "b", [] of {Int64, Int64}},
      {"(?i)(?<g0>[[:>:]]{0,2}[[:alpha:]])((?aW:[[:<:]]))", "aé", [{0_i64, 1_i64}]},
      {"(?i)(?<g0>[[:>:]]{0,2}[[:alpha:]])((?aW:[[:<:]]))", "éa", [{0_i64, 2_i64}]},
      {"(?i)(?<g0>[[:>:]]{0,2}[[:alpha:]])((?aW:[[:<:]]))", "a é", [] of {Int64, Int64}},
      {"(?i)(?<g0>[[:>:]]{0,2}[[:alpha:]])((?aW:[[:<:]]))", "é a", [] of {Int64, Int64}},
      {"(?i)(?<g0>[[:>:]]{0,2}[[:alpha:]])((?aW:[[:<:]]))", "éab", [{0_i64, 2_i64}]},
      {"(?i)(?<g0>[[:>:]]{0,2}[[:alpha:]])((?aW:[[:<:]]))", "_é_", [] of {Int64, Int64}},
      {"(?i)(?<g0>[[:>:]]{0,2}[[:alpha:]])((?aW:[[:<:]]))", "b", [] of {Int64, Int64}},
      {"(([[:<:]]){0,2}(?<g0>(?aW:[[:>:]]))){1,3}?", "aé", [{1_i64, 1_i64}]},
      {"(([[:<:]]){0,2}(?<g0>(?aW:[[:>:]]))){1,3}?", "éa", [{2_i64, 2_i64}, {3_i64, 3_i64}]},
      {"(([[:<:]]){0,2}(?<g0>(?aW:[[:>:]]))){1,3}?", "a é", [{1_i64, 1_i64}]},
      {"(([[:<:]]){0,2}(?<g0>(?aW:[[:>:]]))){1,3}?", "é a", [{4_i64, 4_i64}]},
      {"(([[:<:]]){0,2}(?<g0>(?aW:[[:>:]]))){1,3}?", "éab", [{2_i64, 2_i64}, {4_i64, 4_i64}]},
      {"(([[:<:]]){0,2}(?<g0>(?aW:[[:>:]]))){1,3}?", "_é_", [{1_i64, 1_i64}, {3_i64, 3_i64}, {4_i64, 4_i64}]},
      {"(([[:<:]]){0,2}(?<g0>(?aW:[[:>:]]))){1,3}?", "b", [{1_i64, 1_i64}]},
      {"\\w(?aW:[[:>:]])", "aé", [{0_i64, 1_i64}]},
      {"\\w(?aW:[[:>:]])", "éa", [{0_i64, 2_i64}, {2_i64, 3_i64}]},
      {"\\w(?aW:[[:>:]])", "a é", [{0_i64, 1_i64}]},
      {"\\w(?aW:[[:>:]])", "é a", [{3_i64, 4_i64}]},
      {"\\w(?aW:[[:>:]])", "éab", [{0_i64, 2_i64}, {3_i64, 4_i64}]},
      {"\\w(?aW:[[:>:]])", "_é_", [{0_i64, 1_i64}, {1_i64, 3_i64}, {3_i64, 4_i64}]},
      {"\\w(?aW:[[:>:]])", "b", [{0_i64, 1_i64}]},
      {"(?aW:[[:<:]][[:>:]])", "aé", [{1_i64, 1_i64}]},
      {"(?aW:[[:<:]][[:>:]])", "éa", [{2_i64, 2_i64}]},
      {"(?aW:[[:<:]][[:>:]])", "a é", [] of {Int64, Int64}},
      {"(?aW:[[:<:]][[:>:]])", "é a", [] of {Int64, Int64}},
      {"(?aW:[[:<:]][[:>:]])", "éab", [{2_i64, 2_i64}]},
      {"(?aW:[[:<:]][[:>:]])", "_é_", [{1_i64, 1_i64}, {3_i64, 3_i64}]},
      {"(?aW:[[:<:]][[:>:]])", "b", [] of {Int64, Int64}},
    }.each do |source, haystack, expected|
      program = Mica::Regex::Expression.new(source, compile_limits: UNTRUSTED).program
      ENGINES.each do |engine|
        {source, haystack, engine, scan(program, haystack, engine)}.should eq({source, haystack, engine, expected})
      end
    end
  end
end
