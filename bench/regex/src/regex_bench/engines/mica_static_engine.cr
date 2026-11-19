module RegexBench
  # The adapter for `Mica::Regex.static` patterns (the GC-free study, see
  # docs/benchmarks.md): the patterns are compiled while the runner builds,
  # so its "compile" is a table lookup. A runner holds the patterns
  # bench/regex/gc_study/write_static_patterns.rb listed for it; any other
  # pattern reports "unsupported".
  class MicaStaticEngine < Engine
    def initialize(@table : Hash({String, Bool}, CompiledPattern))
    end

    def name : String
      "mica-static"
    end

    def version : String
      "Mica #{Mica::VERSION} Mica::Regex.static (tables built at compile time, #{@table.size} patterns)"
    end

    def compile(pattern : String, case_insensitive : Bool, policy : SearchPolicy) : CompiledPattern
      compiled = @table[{pattern, case_insensitive}]?
      raise UnsupportedCaseError.new("the pattern is not compiled into this runner") unless compiled
      return compiled unless policy.untrusted_input || policy.deadline
      raise UnsupportedCaseError.new("the static runner measures trusted-input cases without a deadline")
    end
  end

  # One static pattern (a `Mica::Regex::StaticPattern` or, for a pattern the
  # static path refused, a `Mica::Regex::StaticFallback`) behind the
  # harness's interface, searched under `SearchLimits::TRUSTED_INPUT`.
  class CompiledStaticPattern(P) < CompiledPattern
    def initialize(@pattern : P)
    end

    def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : Span?
      limits = Mica::Regex::SearchLimits::TRUSTED_INPUT
      if count_groups
        @pattern.search_groups(haystack, byte_offset, limits: limits, validated: !first_search) do |groups|
          groups_matched = 0
          groups.size.times { |group| groups_matched += 1 if groups.matched?(group) }
          Span.new(groups.byte_begin(0), groups.byte_end(0), groups_matched)
        end
      else
        span = if first_search
                 @pattern.search(haystack, byte_offset, limits: limits)
               else
                 @pattern.search_validated(haystack, byte_offset, limits, nil)
               end
        span ? Span.new(span.byte_begin, span.byte_end, 1) : nil
      end
    rescue error : Mica::LimitExceededError
      raise LimitReachedError.new("mica-#{error.class.name.split("::").last}", error.message || "limit")
    rescue error : Mica::EncodingError
      raise UnsupportedCaseError.new("Mica::Regex rejects the haystack: #{error.message}")
    end
  end
end
