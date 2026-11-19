# The Mica::Regex layer over Mica::Testing::ByteMutator and FuzzCampaign,
# shared by spec/regex/fuzz_spec.cr and fuzz/regex_campaign.cr.
#
# Even iterations mutate seed patterns byte by byte (hostile UTF-8, regex
# tokens spliced in); odd iterations build a random pattern from the
# grammar, so deep nesting, large counts and every escape are reached too.
require "../src/mica"
require "../src/mica/testing"

module RegexFuzz
  SEEDS = [
    "^(?<user>[a-z0-9._%+-]+)@(?<host>[a-z0-9.-]+\\.[a-z]{2,})$",
    "(?i)\\bk(?:elvin|\\x{212A})s?\\b",
    "[[:alpha:][:^digit:]\\p{Greek}\\P{Lu}-]+",
    "(?x) a (?# comment ) b # tail\n c{2,5}? | \\Qa.b\\E",
    "(?|(a)|(b)(c))\\d{1,3}\\s*\\w+\\h\\v\\R\\N",
    "(*UTF)(*UCP)(*BSR_ANYCRLF)(?m)^.*$",
    "\\x{1F600}\\o{101}\\101\\cA\\e\\N{U+263A}",
    "((a{100}){100}){100}",
    "(?<y>\\d{4})-(?'m'\\d\\d)-(?P<d>\\d\\d)T",
    "a(?=b)(?!c)(?<=d)(?<!e)(?>f)g++\\1\\k<y>(?R)(?(1)a|b)(*FAIL)\\K\\C\\X",
    "[\\]\\-^a-z\\x{100}-\\x{10FFFF}]{0,65535}",
    "(?ir)[k-s]|(?aP)[[:word:]]|(?aD)\\d",
    "été|日本|\u{1F600}+",
    "[[:<:]]word[[:>:]]",
  ].map(&.to_slice)

  TOKENS = ["(", ")", "(?:", "(?<n>", "(?i)", "(?-x)", "(*", "|", "[", "]", "[^", "-", "\\", "\\p{", "}", "{", "{,",
            "{2,3}", "{65535}", "*", "+", "?", "??", "*+", "\\Q", "\\E", "\\x{", "\\o{", "\\c", "\\N{U+", "[:",
            ":]", "#", "\n", " ", "^", "$", ".", "\\d", "\\1", "\\g{1}", "(?#", "(?|", "(?P", "(?R", "(?(",
            "\u{212A}", "\u{17F}"].map(&.to_slice)

  MUTATOR = Mica::Testing::ByteMutator.new(SEEDS, TOKENS)

  # Most work between two budget checks: one class lowering of `\p{Any}`
  # merged with its fold partners.
  OVERRUN_SLACK = 400_000_i64

  LIMITS = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN

  ATOMS = ["a", "b", "\\d", "\\w", "\\s", "\\h", "\\R", ".", "\\x{212A}", "k", "[a-z]", "[^\\W\\d]", "\\p{L}",
           "\\P{Greek}", "[[:alpha:]]", "\\N", "^", "$", "\\b", "\\B", "\\A", "\\z", "\\Z", "\\G", "é", "\\Qa+\\E",
           "\\1", "(?=a)", "\\K", "(*ACCEPT)", "\\X", "(?C)", "[\\x{0}-\\x{10FFFF}]", "\\cZ", "\\0", "\\o{777}",
           "[[:<:]]", "[[:>:]]"]
  QUANTIFIERS = ["", "", "", "*", "+", "?", "*?", "{2}", "{0,3}", "{3,}", "{,4}", "{1000}", "{65535}", "++"]
  OPENERS     = ["(", "(?:", "(?i:", "(?<g>", "(?|", "(?x)(?:", "(?ir:", "(?-s:", "(?aP:"]

  # A random pattern from the grammar, built with an explicit stack.
  def self.generate(random : Random) : Bytes
    io = IO::Memory.new
    depth = 0
    length = random.rand(1..60)
    length.times do
      case random.rand(10)
      when 0
        if depth < 80
          io << OPENERS.sample(random)
          depth += 1
        end
      when 1
        if depth > 0
          io << ')' << QUANTIFIERS.sample(random)
          depth -= 1
        end
      when 2
        io << '|'
      else
        io << ATOMS.sample(random) << QUANTIFIERS.sample(random)
      end
    end
    depth.times { io << ')' } if random.rand(4) != 0
    io.to_slice
  end

  # The pattern for one iteration: the campaign's mutation (*mutated*) on
  # even iterations, a generated pattern on odd ones. Replay a case with
  # `pattern_for(MUTATOR.case_bytes(seed, iteration), seed, iteration)`.
  def self.pattern_for(mutated : Bytes, seed : Int64, iteration : Int32) : Bytes
    return mutated if iteration.even?
    generate(Random.new(seed ^ iteration.to_i64))
  end

  # Checks one pattern. Anything but a result or a Mica::Error escapes and
  # the campaign records a crash; a result breaking an invariant is a
  # failure.
  def self.trial(mutated : Bytes, seed : Int64, iteration : Int32) : Mica::Testing::FuzzCampaign::Trial
    bytes = pattern_for(mutated, seed, iteration)
    meter = Mica::Core::WorkMeter.new(Mica::Regex::Syntax::COMPILE_WORK_BUDGET)
    failures = [] of String
    outcome = ""
    error = nil
    begin
      report = Mica::Regex::Syntax.check(bytes, dialect: :crystal, compile_limits: LIMITS, meter: meter)
      outcome = "ok captures=#{report.capture_count} states=#{report.state_estimate}"
      failures << "compile bytes #{report.compile_bytes} over the limit" if report.compile_bytes > LIMITS.max_compile_bytes
      failures << "state estimate #{report.state_estimate} over the limit" if report.state_estimate > LIMITS.max_program_states
      outcome += search_outcome(bytes, report, failures)
    rescue failure : Mica::Error
      error = failure
      offset = failure.is_a?(Mica::ParseError) ? failure.byte_offset : 0_i64
      outcome = "#{failure.class} #{offset}"
      if failure.is_a?(Mica::ParseError) && !(0 <= offset <= bytes.size)
        failures << "error offset #{offset} outside the pattern"
      end
    end
    Mica::Testing::FuzzCampaign::Trial.new(outcome, error, meter, failures)
  end

  # Haystacks every accepted pattern is searched over (milestone R2).
  HAYSTACKS = ["", "a", "aé\n Kk_1\r\n", "abcabc xyz 2026-11-18"]

  # Compiles an accepted pattern into the engines and searches each of
  # HAYSTACKS with captures. A Mica::Error here (a compile or search limit)
  # is a result; an internal error, or more states than the preflight
  # bound, is a failure.
  def self.search_outcome(bytes : Bytes, report : Mica::Regex::Syntax::Report, failures : Array(String)) : String
    expression = Mica::Regex::Expression.new(String.new(bytes), compile_limits: LIMITS)
    states = expression.program.state_count
    failures << "#{states} states over the preflight bound #{report.state_estimate}" if states > report.state_estimate
    String.build do |io|
      io << " states=" << states
      HAYSTACKS.each do |haystack|
        begin
          match = expression.match(haystack, limits: Mica::Regex::SearchLimits::REQUEST)
          io << ' ' << (match ? "#{match.byte_begin}-#{match.byte_end}" : "-")
        rescue error : Mica::Error
          failures << "internal error: #{error.message}" if error.message.try(&.includes?("internal error"))
          io << " !" << error.class
        end
      end
    end
  rescue error : Mica::Error
    failures << "internal error: #{error.message}" if error.message.try(&.includes?("internal error"))
    " compile !#{error.class}"
  end
end
