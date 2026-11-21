require "../spec_helper"

# The static differential: every pattern of the benchmark corpora (Amber,
# ReDoS and rebar, written by scripts/write_static_corpus.rb into
# fixtures/static_corpus.cr and compiled while this spec builds) that the
# static path holds is searched over the haystacks below on
# `Mica::Regex.static`, on the runtime engine, and on PCRE2 through
# Crystal's `Regex`. Every match of a `String#scan` style iteration, with
# every group's span, must agree, and the static searches allocate
# nothing.
module StaticCorpus
  LIMITS = Mica::Regex::SearchLimits::TRUSTED_INPUT
  # The most distinct characters a pattern's short haystacks are made of.
  MAX_ALPHABET = 14
  # Every string of up to this many of those characters is searched.
  MAX_SHORT_LENGTH = 3
  # Random haystacks per pattern, built from its characters and literals.
  RANDOM_HAYSTACKS =         64
  SEED             = 20_261_119

  # One match: the begin and end byte of each group, -1 for a group that
  # did not take part.
  alias Match = Array(Int32)

  # One corpus pattern behind a common interface.
  abstract class Entry
    getter id : String
    getter source : String
    getter? ignore_case : Bool
    getter list_of_haystacks : Array(String)

    def initialize(@id : String, @source : String, @ignore_case : Bool, @list_of_haystacks : Array(String))
    end

    abstract def static? : Bool
    # Every match of *haystack* with its groups, read by `search_groups`.
    abstract def matches_with_groups(haystack : String) : Array(Match)
    # Every match's span, read by `search_span`.
    abstract def spans(haystack : String) : Array(Mica::Regex::Span)
    # Every match's span, read by `each_span`.
    abstract def spans_by_each(haystack : String) : Array(Mica::Regex::Span)
    abstract def matches?(haystack : String) : Bool
    # The searches above without collecting anything, returning a checksum
    # (for the allocation check).
    abstract def search_without_collecting(haystack : String) : Int64
  end

  class Pattern(P) < Entry
    def initialize(id : String, source : String, ignore_case : Bool, @pattern : P, list_of_haystacks : Array(String))
      super(id, source, ignore_case, list_of_haystacks)
    end

    def static? : Bool
      @pattern.static?
    end

    def matches_with_groups(haystack : String) : Array(Match)
      list_of_matches = [] of Match
      StaticCorpus.each_offset(haystack) do |offset|
        @pattern.search_groups(haystack, offset, limits: LIMITS) do |groups|
          match = Match.new(groups.size * 2) { |index| index.even? ? groups.byte_begin(index // 2) : groups.byte_end(index // 2) }
          list_of_matches << match
          Mica::Regex::Span.new(match[0], match[1])
        end
      end
      list_of_matches
    end

    def spans(haystack : String) : Array(Mica::Regex::Span)
      list_of_spans = [] of Mica::Regex::Span
      StaticCorpus.each_offset(haystack) do |offset|
        span = @pattern.search_span(haystack, offset, limits: LIMITS)
        list_of_spans << span if span
        span
      end
      list_of_spans
    end

    def spans_by_each(haystack : String) : Array(Mica::Regex::Span)
      list_of_spans = [] of Mica::Regex::Span
      @pattern.each_span(haystack, limits: LIMITS) { |span| list_of_spans << span }
      list_of_spans
    end

    def matches?(haystack : String) : Bool
      @pattern.matches?(haystack, limits: LIMITS)
    end

    def search_without_collecting(haystack : String) : Int64
      sum = 0_i64
      sum += 1 if @pattern.matches?(haystack, limits: LIMITS)
      if span = @pattern.search_span(haystack, limits: LIMITS)
        sum += span.byte_end
      end
      sum += @pattern.search_groups(haystack, limits: LIMITS) { |groups| groups.byte_end(groups.size - 1) } || 0
      @pattern.each_span(haystack, limits: LIMITS) { |span| sum += span.bytesize }
      sum
    end
  end

  # Yields each search offset of a `String#scan` style iteration; the
  # block returns the match found from that offset, or nil to stop.
  def self.each_offset(haystack : String, & : Int32 -> Mica::Regex::Span?) : Nil
    offset = 0
    while offset <= haystack.bytesize
      span = yield offset
      break unless span
      offset = next_offset(haystack, span.byte_begin, span.byte_end)
    end
  end

  def self.next_offset(haystack : String, match_begin : Int32, match_end : Int32) : Int32
    return match_end if match_end > match_begin
    return haystack.bytesize + 1 if match_end >= haystack.bytesize
    match_end + Mica::Core::UTF8.sequence_length(haystack.to_slice[match_end])
  end

  # Every match of *haystack* on the runtime engine, read through
  # `Expression#search` (and its `MatchData`).
  def self.runtime_matches(expression : Mica::Regex::Expression, haystack : String) : Array(Match)
    list_of_matches = [] of Match
    each_offset(haystack) do |offset|
      found = expression.search(haystack, offset, limits: LIMITS)
      next nil unless found
      list_of_matches << Match.new(found.size * 2) do |index|
        group = index // 2
        found[group]? ? (index.even? ? found.byte_begin(group) : found.byte_end(group)) : -1
      end
      Mica::Regex::Span.new(found.byte_begin(0), found.byte_end(0))
    end
    list_of_matches
  end

  PCRE2_WORD = ::Regex.new("\\A\\w\\z")
  MICA_WORD  = Mica::Regex.compile("\\A\\w\\z", dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)

  # True when the PCRE2 this spec links reads `\w` differently from Mica
  # on a character of *haystack*. Mica follows PCRE2 10.43 and later, where
  # `\w` also matches nonspacing marks (Mn) and connector punctuation (Pc);
  # older libraries (10.42 on Ubuntu 24.04) do not, so on such haystacks
  # only the runtime engine is compared.
  def self.pcre2_word_table_differs?(haystack : String) : Bool
    return false if haystack.ascii_only?
    haystack.each_char.any? do |char|
      text = char.to_s
      PCRE2_WORD.matches?(text) != MICA_WORD.matches?(text, limits: Mica::Regex::SearchLimits::TRUSTED_INPUT)
    end
  end

  # Every match of *haystack* on PCRE2, or nil when PCRE2 stops at one of
  # its own limits.
  def self.pcre2_matches(regex : ::Regex, haystack : String) : Array(Match)?
    list_of_matches = [] of Match
    each_offset(haystack) do |offset|
      found = regex.match_at_byte_index(haystack, offset)
      next nil unless found
      list_of_matches << Match.new(found.size * 2) do |index|
        group = index // 2
        found[group]? ? (index.even? ? found.byte_begin(group) : found.byte_end(group)) : -1
      end
      Mica::Regex::Span.new(found.byte_begin(0), found.byte_end(0))
    end
    list_of_matches
  rescue ::Regex::Error
    nil
  end

  # The random stream of *source*: an FNV-1a hash of its bytes, the same in
  # every process (`String#hash` is seeded per process, which made the
  # haystacks, and so the cases PCRE2 stops at its limits on, vary by run).
  def self.stream_for(source : String) : UInt64
    source.each_byte.reduce(0xcbf29ce484222325_u64) { |hash, byte| (hash ^ byte) &* 0x100000001b3_u64 }
  end

  # The haystacks a pattern is searched over: its corpus haystacks, every
  # string of up to `MAX_SHORT_LENGTH` characters of its alphabet, and
  # `RANDOM_HAYSTACKS` random strings of its characters and literal runs.
  def self.haystacks_for(entry : Entry) : Array(String)
    random = Random::PCG32.new(SEED.to_u64, stream_for(entry.source))
    list_of_characters = ['a', 'Z', '0', ' ', '\n', 'é', '_', '-', ':', '.']
    entry.source.each_char do |char|
      list_of_characters << char if char.ascii? && char.printable? && char != '\\'
      list_of_characters << char.upcase << char.downcase if entry.ignore_case? && char.ascii_letter?
    end
    list_of_characters.uniq!
    list_of_characters = list_of_characters.first(4) + list_of_characters[4..].shuffle(random).first(MAX_ALPHABET - 4)
    list_of_haystacks = entry.list_of_haystacks.dup
    list_of_haystacks << ""
    current = [""]
    MAX_SHORT_LENGTH.times do
      current = current.flat_map { |prefix| list_of_characters.map { |char| prefix + char } }
      list_of_haystacks.concat(current)
    end
    list_of_tokens = list_of_characters.map(&.to_s) + entry.source.scan(/[A-Za-z0-9]{2,}/).map(&.[0])
    RANDOM_HAYSTACKS.times do
      length = random.rand(1..256)
      list_of_haystacks << String.build { |io| length.times { io << list_of_tokens.sample(random) } }
    end
    list_of_haystacks
  end
end

require "./fixtures/static_corpus"

describe "Mica::Regex.static over the benchmark corpora" do
  list_of_static = STATIC_CORPUS.select(&.static?)

  it "holds most corpus patterns statically" do
    list_of_static.size.should be >= 150
    STATIC_CORPUS.select(&.id.starts_with?("amber/")).count(&.static?).should be >= 20
  end

  it "finds every match and group the runtime engine and PCRE2 find, on every pattern it holds" do
    list_of_disagreements = [] of String
    # Cases PCRE2 stopped at its own backtracking limit (no answer to
    # compare): only the ReDoS patterns and rebar's exponential-backtracking
    # case may do that.
    list_of_pcre2_limited = [] of String
    # Haystacks the linked PCRE2 reads with an older `\w` table (see
    # `StaticCorpus.pcre2_word_table_differs?`); none with PCRE2 10.43+.
    list_of_older_word_tables = [] of String
    StaticCorpus::PCRE2_WORD.matches?("a").should be_true
    StaticCorpus.pcre2_word_table_differs?("a_1 ").should be_false
    cases = 0
    list_of_static.each do |entry|
      options = entry.ignore_case? ? Mica::Regex::CompileOptions::IgnoreCase : Mica::Regex::CompileOptions::None
      expression = Mica::Regex.compile(entry.source, dialect: :crystal,
        compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: options)
      regex = ::Regex.new(entry.source, entry.ignore_case? ? ::Regex::CompileOptions::IGNORE_CASE : ::Regex::CompileOptions::None)
      StaticCorpus.haystacks_for(entry).each do |haystack|
        cases += 1
        found = entry.matches_with_groups(haystack)
        expected = StaticCorpus.runtime_matches(expression, haystack)
        list_of_spans = found.map { |match| Mica::Regex::Span.new(match[0], match[1]) }
        agrees = found == expected && entry.spans(haystack) == list_of_spans &&
                 entry.spans_by_each(haystack) == list_of_spans && entry.matches?(haystack) == !found.empty?
        if StaticCorpus.pcre2_word_table_differs?(haystack)
          list_of_older_word_tables << entry.id
        elsif pcre2 = StaticCorpus.pcre2_matches(regex, haystack)
          agrees &&= pcre2 == found
        else
          list_of_pcre2_limited << entry.id
        end
        list_of_disagreements << "#{entry.id} #{haystack.inspect}" unless agrees
      end
    end
    {list_of_disagreements.size, list_of_disagreements.first(10)}.should eq({0, [] of String})
    cases.should be > 450_000
    list_of_pcre2_limited.reject { |id| id.starts_with?("redos/") || id == "rebar/imported/rsc/no-exponential" }.should be_empty
    list_of_pcre2_limited.size.should be < 100
    list_of_older_word_tables.size.should be < 100
  end

  it "allocates nothing per static search" do
    list_of_static.each do |entry|
      list_of_haystacks = StaticCorpus.haystacks_for(entry).first(200)
      checksum = 0_i64
      before = GC.stats.total_bytes
      list_of_haystacks.each { |haystack| checksum &+= entry.search_without_collecting(haystack) }
      {entry.id, GC.stats.total_bytes - before}.should eq({entry.id, 0_u64})
      checksum.should be >= 0
    end
  end
end
