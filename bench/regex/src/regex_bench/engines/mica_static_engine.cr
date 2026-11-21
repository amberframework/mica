module RegexBench
  # The adapter for `Mica::Regex.static` patterns: the patterns are
  # compiled while the runner builds (bench/regex/scripts/write_static_patterns.rb
  # lists them), so its "compile" is a table lookup that wraps the
  # pattern's constant, and the first read of that constant (its
  # initializer: a struct over read-only tables) is part of the
  # process-cold search, as it is in an application.
  #
  # Throughput cases search under `SearchLimits::TRUSTED_INPUT`; ReDoS cases
  # under `SearchLimits::REQUEST` and the case's deadline, as the mica
  # adapter does. A pattern outside the static limits (a
  # `Mica::Regex::StaticFallback`, which runs on the runtime engine) reports
  # "unsupported", so this engine's row holds static searches only.
  class MicaStaticEngine < Engine
    # Builds the runner's index of patterns before any case is timed: the
    # index is the harness's (an application names its constant directly),
    # so it stays out of the process-cold search.
    def initialize
      StaticPatterns::INDEX.size
    end

    def name : String
      "mica-static"
    end

    def version : String
      "Mica #{Mica::VERSION} Mica::Regex.static (tables built at compile time, " \
      "#{StaticPatterns::INDEX.size} patterns)"
    end

    def compile(pattern : String, case_insensitive : Bool, policy : SearchPolicy) : CompiledPattern
      limits = policy.untrusted_input ? Mica::Regex::SearchLimits::REQUEST : Mica::Regex::SearchLimits::TRUSTED_INPUT
      compiled = StaticPatterns.compile(pattern, case_insensitive, limits, policy.deadline)
      raise UnsupportedCaseError.new("the pattern is not compiled into this runner") unless compiled
      compiled
    end
  end

  # One static pattern behind the harness's interface.
  class CompiledStaticPattern(P) < CompiledPattern
    # Wraps *pattern*; raises `UnsupportedCaseError` when the static path
    # did not hold it.
    def self.build(pattern, limits : Mica::Regex::SearchLimits, deadline : Time::Span?) : CompiledPattern
      if pattern.is_a?(Mica::Regex::StaticFallback)
        raise UnsupportedCaseError.new("outside the static limits (#{pattern.reason})")
      end
      new(pattern, limits, deadline)
    end

    def initialize(@pattern : P, @limits : Mica::Regex::SearchLimits, @deadline : Time::Span?)
    end

    def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : Span?
      if count_groups
        if first_search
          @pattern.search_groups(haystack, byte_offset, limits: @limits, deadline: @deadline) { |groups| span_of(groups) }
        else
          @pattern.search_groups_unchecked(haystack, byte_offset, @limits, @deadline) { |groups| span_of(groups) }
        end
      else
        span = if first_search
                 @pattern.search_span(haystack, byte_offset, limits: @limits, deadline: @deadline)
               else
                 @pattern.search_span_unchecked(haystack, byte_offset, @limits, @deadline)
               end
        span ? Span.new(span.byte_begin, span.byte_end, 1) : nil
      end
    rescue error : Mica::LimitExceededError
      raise LimitReachedError.new("mica-#{error.class.name.split("::").last}", error.message || "limit")
    rescue error : Mica::EncodingError
      raise UnsupportedCaseError.new("Mica::Regex rejects the haystack: #{error.message}")
    end

    private def span_of(groups : Mica::Regex::Groups) : Span
      groups_matched = 0
      groups.size.times { |group| groups_matched += 1 if groups.matched?(group) }
      Span.new(groups.byte_begin(0), groups.byte_end(0), groups_matched)
    end
  end
end
