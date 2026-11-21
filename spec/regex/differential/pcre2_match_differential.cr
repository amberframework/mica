# The match differential against PCRE2: the engine differential's
# generated patterns (fuzz/regex_engine_differential.cr), each searched over
# every string up to length 6 over its 4-letter alphabet, with
# Mica::Regex::Expression#match and with stdlib Regex (libpcre2-8), comparing
# the span of every group.
#
# Milestone R4 gates Mica against PCRE2 with ten million cases; this run
# is the early check of R2's engines. Like the oracles next to it, it is a
# standalone program, never compiled by `crystal-alpha spec`:
#
#     crystal-alpha build --release spec/regex/differential/pcre2_match_differential.cr -o bin/pcre2_match_differential
#     bin/pcre2_match_differential SEED PATTERNS
require "../../../fuzz/regex_engine_differential"

module PCRE2MatchDifferential
  alias Spans = Array({Int32, Int32}?)

  def self.spans_of(match : Mica::Regex::MatchData?) : Spans?
    return nil unless match
    (0..match.group_size).map { |group| match[group]? ? {match.byte_begin(group), match.byte_end(group)} : nil }
  end

  def self.spans_of(match : Regex::MatchData?) : Spans?
    return nil unless match
    (0..match.group_size).map { |group| match[group]? ? {match.byte_begin(group), match.byte_end(group)} : nil }
  end

  def self.run(seed : Int64, count : Int32) : Nil
    strings = EngineDifferential.haystacks
    cases = 0_i64
    list_of_differences = [] of String
    count.times do |index|
      random = Random::PCG32.new(seed.to_u64, index.to_u64)
      source = EngineDifferential.pattern(random)
      mica = Mica::Regex::Expression.new(source, compile_limits: EngineDifferential::COMPILE_LIMITS)
      pcre2 = Regex.new(source)
      strings.each do |haystack|
        cases += 1
        mine = spans_of(mica.match(haystack, limits: EngineDifferential::SEARCH_LIMITS))
        theirs = spans_of(pcre2.match(haystack))
        next if mine == theirs
        list_of_differences << "#{seed}:#{index} #{source.inspect} on #{haystack.inspect}: Mica #{mine}, PCRE2 #{theirs}"
      end
    end
    STDOUT.puts "seed=#{seed} patterns=#{count} cases=#{cases} differences=#{list_of_differences.size}"
    list_of_differences.first(50).each { |line| STDOUT.puts "  #{line}" }
    exit(list_of_differences.empty? ? 0 : 1)
  end
end

usage = "usage: pcre2_match_differential SEED PATTERNS"
PCRE2MatchDifferential.run((ARGV[0]? || abort(usage)).to_i64, (ARGV[1]? || abort(usage)).to_i)
