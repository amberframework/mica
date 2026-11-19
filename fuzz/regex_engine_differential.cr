# The engine-internal differential of milestone R2 (roadmap 6.5, the
# RE2-style exhaustive method): generated small patterns, each searched over
# every string up to length 6 over a 4-letter alphabet (a, b, é, newline:
# 5,461 strings, multibyte and line-break positions included), on every
# engine path:
#
# - the default path with captures and without (literal search or the
#   lazy DFAs with the prefilter, then the one-pass DFA, the backtracker
#   or a Pike VM over the span), accelerators on;
# - the same with the literal accelerators off (`Engine::NoAccelerators`);
# - R2's two-phase search (Pike VM span, then the backtracker or a Pike
#   VM over the span);
# - one Pike VM pass with every slot;
# - one bounded backtracker pass with every slot;
# - `matches?` on the default path (the forward DFA or the literal search
#   stopping at the first match) and on the R2 path (the Pike VM);
# - iteration as `String#scan` does it, one searcher for the whole call
#   (so later searches start inside the haystack, reuse the prefilter's
#   progress and the warm DFA caches), default path against R2's.
#
# Every path must report the same match (span and captures) for every
# case. Shared by spec/regex/engine_differential_spec.cr and
# fuzz/regex_engine_campaign.cr (the release run of two million cases).
require "../src/mica"

module EngineDifferential
  ALPHABET       = ["a", "b", "é", "\n"]
  MAX_LENGTH     = 6
  COMPILE_LIMITS = Mica::Regex::CompileLimits::TRUSTED_PATTERN
  SEARCH_LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

  ATOMS = ["a", "b", "é", ".", "[ab]", "[^a]", "\\n", "(?:)", "^", "$", "\\b", "\\B", "\\A", "\\z", "\\Z", "\\w",
           "\\W", "\\s", "\\R", "\\N", "(?i:A)", "[[:alpha:]]", "\\p{L}", "ab", "bé", "(?:aa|ba|é\\n)", "(?i:ab)",
           "[[:<:]]", "[[:>:]]", "(?aW:\\b)", "(?aW:\\B)", "(?aW:[[:<:]])", "(?aW:[[:>:]])", "(?aW:\\w)"]
  QUANTIFIERS = ["*", "+", "?", "*?", "+?", "??", "{2}", "{0,2}", "{1,3}?", "{2,}", "{0,}?"]
  FLAGS       = ["", "", "", "", "(?m)", "(?s)", "(?i)", "(?ms)", "(?U)"]

  # Every string up to MAX_LENGTH characters over ALPHABET.
  def self.haystacks : Array(String)
    list_of_strings = [""]
    frontier = [""]
    MAX_LENGTH.times do
      frontier = frontier.flat_map { |prefix| ALPHABET.map { |letter| prefix + letter } }
      list_of_strings.concat(frontier)
    end
    list_of_strings
  end

  # A random pattern of at most *depth* levels of nesting.
  def self.pattern(random : Random, depth : Int32 = 3) : String
    FLAGS.sample(random) + node(random, depth)
  end

  private def self.node(random : Random, depth : Int32) : String
    return ATOMS.sample(random) if depth == 0
    case random.rand(10)
    when 0, 1
      ATOMS.sample(random)
    when 2, 3
      node(random, depth - 1) + node(random, depth - 1)
    when 4
      node(random, depth - 1) + "|" + node(random, depth - 1)
    when 5, 6
      "(" + node(random, depth - 1) + ")" + (random.rand(2) == 0 ? QUANTIFIERS.sample(random) : "")
    when 7
      "(?:" + node(random, depth - 1) + ")" + QUANTIFIERS.sample(random)
    when 8
      "(?<g" + random.rand(3).to_s + ">" + node(random, depth - 1) + ")" + (random.rand(2) == 0 ? QUANTIFIERS.sample(random) : "")
    else
      "(" + node(random, depth - 1) + "|" + node(random, depth - 1) + ")" + QUANTIFIERS.sample(random)
    end
  end

  record Report, patterns : Int32, refused : Int32, cases : Int64, list_of_disagreements : Array(String)

  # Generates *count* patterns from *seed* (starting at *first*) and
  # checks each over every haystack.
  def self.run(seed : Int64, count : Int32, first : Int32 = 0) : Report
    strings = haystacks
    disagreements = [] of String
    cases = 0_i64
    refused = 0
    count.times do |offset|
      index = first + offset
      random = Random::PCG32.new(seed.to_u64, index.to_u64)
      source = pattern(random)
      expression = begin
        Mica::Regex::Expression.new(source, compile_limits: COMPILE_LIMITS)
      rescue Mica::Regex::SyntaxError | Mica::Regex::CompileLimitError
        refused += 1
        next
      end
      strings.each do |haystack|
        cases += 1
        problem = check(expression, haystack)
        disagreements << "#{seed}:#{index} #{source.inspect} on #{haystack.inspect}: #{problem}" if problem
        break if disagreements.size >= 100
      end
    end
    Report.new(count, refused, cases, disagreements)
  end

  # Returns how the engine paths disagree on *haystack*, or nil.
  def self.check(expression : Mica::Regex::Expression, haystack : String) : String?
    program = expression.program
    default = find(program, haystack, Mica::Regex::Engine::Auto, true)
    span_only = find(program, haystack, Mica::Regex::Engine::Auto, false)
    unaccelerated = find(program, haystack, Mica::Regex::Engine::NoAccelerators, true)
    unaccelerated_span = find(program, haystack, Mica::Regex::Engine::NoAccelerators, false)
    two_phase = find(program, haystack, Mica::Regex::Engine::TwoPhase, true)
    pike = find(program, haystack, Mica::Regex::Engine::PikeVM, true)
    backtracker = find(program, haystack, Mica::Regex::Engine::Backtracker, true)
    matches = matches?(program, haystack, Mica::Regex::Engine::Auto)
    unaccelerated_matches = matches?(program, haystack, Mica::Regex::Engine::NoAccelerators)
    pike_matches = matches?(program, haystack, Mica::Regex::Engine::TwoPhase)
    return "Pike VM #{pike} vs two-phase #{two_phase}" unless pike == two_phase
    return "backtracker #{backtracker} vs Pike VM #{pike}" unless backtracker == pike
    return "default path #{default} vs two-phase #{two_phase}" unless default == two_phase
    return "no accelerators #{unaccelerated} vs two-phase #{two_phase}" unless unaccelerated == two_phase
    return "span-only #{span_only} vs two-phase #{two_phase}" unless span_only == two_phase.try(&.first(2))
    unless unaccelerated_span == two_phase.try(&.first(2))
      return "span-only without accelerators #{unaccelerated_span} vs two-phase #{two_phase}"
    end
    return "matches? #{matches} vs #{two_phase}" unless matches == !two_phase.nil?
    return "matches? without accelerators #{unaccelerated_matches} vs #{two_phase}" unless unaccelerated_matches == !two_phase.nil?
    return "Pike VM matches? #{pike_matches} vs #{two_phase}" unless pike_matches == !two_phase.nil?
    iterated = scan(program, haystack, Mica::Regex::Engine::Auto)
    iterated_two_phase = scan(program, haystack, Mica::Regex::Engine::TwoPhase)
    return "scan #{iterated} vs two-phase scan #{iterated_two_phase}" unless iterated == iterated_two_phase
    nil
  end

  # Every match of a `String#scan`-style iteration, with captures.
  private def self.scan(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine) : Array(Array(Int64))
    searcher = Mica::Regex::Searcher.new(program, haystack, SEARCH_LIMITS, nil, engine)
    list_of_matches = [] of Array(Int64)
    offset = 0
    while slots = searcher.find(offset, Mica::Regex::MatchOptions::None, true)
      list_of_matches << slots.to_a
      first = slots[0].to_i32
      last = slots[1].to_i32
      offset = last > first ? last : first + (first < haystack.bytesize ? Char::Reader.new(haystack, first).current_char.bytesize : 1)
    end
    searcher.finish
    list_of_matches
  end

  private def self.matches?(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine) : Bool
    searcher = Mica::Regex::Searcher.new(program, haystack, SEARCH_LIMITS, nil, engine)
    searcher.matches?(0, Mica::Regex::MatchOptions::None)
  ensure
    searcher.try(&.finish)
  end

  private def self.find(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine,
                        captures : Bool) : Array(Int64)?
    searcher = Mica::Regex::Searcher.new(program, haystack, SEARCH_LIMITS, nil, engine)
    slots = searcher.find(0, Mica::Regex::MatchOptions::None, captures)
    return nil unless slots
    captures ? slots.to_a : slots.to_a.first(2)
  ensure
    searcher.try(&.finish)
  end
end
