# The static differential of the GC-free study (docs/benchmarks.md, "GC-free
# study"): every pattern in bench/data/regex/static_differential_patterns.cr
# (the Amber corpus patterns and a generated sample, compiled while this
# program builds) is searched over the engine differential's 5,461 short
# strings, plus generated Amber haystacks (Amber patterns) or random long
# ones (generated patterns), on three engines:
#
# - `Mica::Regex.static` (spans with groups, spans alone, and `matches?`);
# - the runtime engine (`Expression#match_at_byte_index`);
# - PCRE2 through Crystal's `Regex`.
#
# Each (pattern, haystack) pair is one case: every match of a `String#scan`
# style iteration, with every group's span, must agree. The heap bytes the
# static searches allocate are summed from `GC.stats` around each call.
#
#   /usr/bin/ruby bench/regex/gc_study/write_differential_patterns.rb PATTERNS.jsonl bench/data/regex/static_differential_patterns.cr
#   crystal-alpha build --release bench/regex/gc_study/static_differential.cr -o bench/bin/regex/static_differential
#   bench/bin/regex/static_differential
require "../../../src/mica"
require "../../../fuzz/regex_engine_differential"
require "../src/regex_bench"

module StaticDifferential
  LIMITS = Mica::Regex::SearchLimits::TRUSTED_INPUT
  # Words of the buffer the static results are written to, made once.
  BUFFER_WORDS = 1 << 20

  # One static pattern behind a common interface.
  abstract class AnyPattern
    abstract def static? : Bool
    abstract def capture_count : Int32
    # Writes the spans of every group of every match (iterating as
    # `String#scan` does) into *buffer* and returns the words written.
    abstract def collect_groups(haystack : String, buffer : Slice(Int32)) : Int32
    # Writes the span of every match into *buffer*; returns the words.
    abstract def collect_spans(haystack : String, buffer : Slice(Int32)) : Int32
    abstract def matches?(haystack : String) : Bool
  end

  class Adapter(P) < AnyPattern
    def initialize(@pattern : P)
    end

    def static? : Bool
      @pattern.static?
    end

    def capture_count : Int32
      @pattern.capture_count
    end

    def collect_groups(haystack : String, buffer : Slice(Int32)) : Int32
      written = 0
      offset = 0
      first = true
      while offset <= haystack.bytesize
        found = if first
                  @pattern.search_groups(haystack, offset, limits: LIMITS) { |groups| write_groups(groups, buffer, written) }
                else
                  @pattern.search_groups_unchecked(haystack, offset, LIMITS, nil) { |groups| write_groups(groups, buffer, written) }
                end
        written += found[2] if found
        first = false
        break unless found
        offset = StaticDifferential.next_offset(haystack, found[0], found[1])
      end
      written
    end

    def collect_spans(haystack : String, buffer : Slice(Int32)) : Int32
      written = 0
      offset = 0
      first = true
      while offset <= haystack.bytesize
        span = first ? @pattern.search_span(haystack, offset, limits: LIMITS) : @pattern.search_span_unchecked(haystack, offset, LIMITS, nil)
        first = false
        break unless span
        buffer[written] = span.byte_begin
        buffer[written + 1] = span.byte_end
        written += 2
        offset = StaticDifferential.next_offset(haystack, span.byte_begin, span.byte_end)
      end
      written
    end

    def matches?(haystack : String) : Bool
      @pattern.matches?(haystack, limits: LIMITS)
    end

    # Writes the spans of every group at *written* in *buffer*; returns the
    # match's span and the words written.
    private def write_groups(groups : Mica::Regex::Groups, buffer : Slice(Int32), written : Int32) : {Int32, Int32, Int32}
      groups.size.times do |group|
        buffer[written + group * 2] = groups.byte_begin(group)
        buffer[written + group * 2 + 1] = groups.byte_end(group)
      end
      {groups.byte_begin(0), groups.byte_end(0), groups.size * 2}
    end
  end

  record Entry, source : String, ignore_case : Bool, origin : String, pattern : AnyPattern

  # Where the next search of an iteration starts: after the match, or one
  # character on after an empty one.
  def self.next_offset(haystack : String, start : Int32, finish : Int32) : Int32
    return finish if finish > start
    return haystack.bytesize + 1 if finish >= haystack.bytesize
    finish + Mica::Core::UTF8.sequence_length(haystack.to_slice[finish])
  end

  # Every group span of every match on the runtime engine.
  def self.runtime_groups(expression : Mica::Regex::Expression, haystack : String) : Array(Int32)
    list = [] of Int32
    offset = 0
    while offset <= haystack.bytesize
      match = expression.match_at_byte_index(haystack, offset, limits: LIMITS)
      break unless match
      match.size.times do |group|
        if match[group]?
          list << match.byte_begin(group) << match.byte_end(group)
        else
          list << -1 << -1
        end
      end
      offset = next_offset(haystack, match.byte_begin(0), match.byte_end(0))
    end
    list
  end

  # Every group span of every match on PCRE2.
  def self.pcre2_groups(regex : ::Regex, haystack : String) : Array(Int32)
    list = [] of Int32
    offset = 0
    while offset <= haystack.bytesize
      match = regex.match_at_byte_index(haystack, offset)
      break unless match
      match.size.times do |group|
        if match[group]?
          list << match.byte_begin(group) << match.byte_end(group)
        else
          list << -1 << -1
        end
      end
      offset = next_offset(haystack, match.byte_begin(0), match.byte_end(0))
    end
    list
  end

  def self.span_list(list_of_groups : Array(Int32), group_count : Int32) : Array(Int32)
    spans = [] of Int32
    list_of_groups.each_slice(group_count * 2) { |match| spans << match[0] << match[1] }
    spans
  end

  # The haystacks a pattern is searched over.
  def self.haystacks_for(entry : Entry, short : Array(String), random : Random) : Array(String)
    list = short.dup
    if entry.origin.starts_with?("amber/")
      generator = entry.origin.split('/')[1]
      text = RegexBench::HaystackGenerator.new(generator, 16_384_i64).generate
      list.concat(text.lines(chomp: true))
      list << text
    else
      EngineDifferential::LONG_HAYSTACKS.times { list << EngineDifferential.long_haystack(random) }
    end
    list
  end

  def self.run : Nil
    short = EngineDifferential.haystacks
    buffer = Slice(Int32).new(BUFFER_WORDS)
    cases = 0_i64
    static_patterns = 0
    fallback_patterns = 0
    static_calls = 0_i64
    static_bytes = 0_u64
    runtime_disagreements = [] of String
    pcre2_disagreements = [] of String
    pcre2_mismatches = 0
    group_spans_compared = 0_i64
    pcre2_also_runtime = 0
    pcre2_refused = 0
    started = Time.instant
    list_of_entries.each_with_index do |entry, index|
      unless entry.pattern.static?
        fallback_patterns += 1
        next
      end
      static_patterns += 1
      options = entry.ignore_case ? Mica::Regex::CompileOptions::IgnoreCase : Mica::Regex::CompileOptions::None
      expression = Mica::Regex.compile(entry.source, dialect: :crystal,
        compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: options)
      pcre2 = begin
        ::Regex.new(entry.source, entry.ignore_case ? ::Regex::Options::IGNORE_CASE : ::Regex::Options::None)
      rescue ArgumentError
        pcre2_refused += 1
        nil
      end
      group_count = expression.capture_count + 1
      random = Random::PCG32.new(20261119_u64, index.to_u64)
      haystacks_for(entry, short, random).each do |haystack|
        cases += 1
        before = GC.stats.total_bytes
        written = entry.pattern.collect_groups(haystack, buffer)
        span_words = entry.pattern.collect_spans(haystack, buffer + written)
        matched = entry.pattern.matches?(haystack)
        static_bytes += GC.stats.total_bytes - before
        static_calls += written // (group_count * 2) + span_words // 2 + 3
        static_groups = buffer[0, written].to_a
        static_spans = buffer[written, span_words].to_a
        runtime = runtime_groups(expression, haystack)
        group_spans_compared += runtime.size // 2
        problem = nil
        problem = "groups #{static_groups} vs runtime #{runtime}" if static_groups != runtime
        problem ||= "spans #{static_spans} vs runtime #{span_list(runtime, group_count)}" if static_spans != span_list(runtime, group_count)
        problem ||= "matches? #{matched} vs runtime #{!runtime.empty?}" if matched != !runtime.empty?
        if problem && runtime_disagreements.size < 50
          runtime_disagreements << "#{entry.origin} #{entry.source.inspect} on #{haystack[0, 80].inspect}: #{problem}"
        end
        if pcre2
          pcre = pcre2_groups(pcre2, haystack)
          if pcre != static_groups
            pcre2_mismatches += 1
            pcre2_also_runtime += 1 if pcre != runtime
            if pcre2_disagreements.size < 50
              pcre2_disagreements << "#{entry.origin} #{entry.source.inspect} on #{haystack[0, 80].inspect}: static #{static_groups} pcre2 #{pcre}"
            end
          end
        end
      end
    end
    seconds = (Time.instant - started).total_seconds
    puts "patterns: #{static_patterns} static, #{fallback_patterns} on the fallback (not counted)"
    puts "cases: #{cases} (pattern, haystack) pairs, each checked with groups, spans and matches?"
    puts "group spans compared with the runtime engine: #{group_spans_compared}"
    puts "static search calls: #{static_calls}, heap bytes they allocated: #{static_bytes}"
    puts "static vs runtime disagreements: #{runtime_disagreements.size}"
    runtime_disagreements.each { |line| puts "  RUNTIME #{line}" }
    puts "static vs PCRE2 disagreements: #{pcre2_mismatches} " \
         "(of which the runtime engine also disagrees with PCRE2: #{pcre2_also_runtime}); PCRE2 refused #{pcre2_refused} patterns"
    pcre2_disagreements.first(20).each { |line| puts "  PCRE2 #{line}" }
    puts "seconds: #{seconds.round(1)}"
    exit(runtime_disagreements.empty? && static_bytes == 0 ? 0 : 1)
  end
end

require "../../data/regex/static_differential_patterns"

StaticDifferential.run
