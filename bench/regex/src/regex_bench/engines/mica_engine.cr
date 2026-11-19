module RegexBench
  # The adapter for Mica::Regex, written against the native API the design
  # specifies (followup-17 section 6.2.6):
  #
  #   regex = Mica::Regex.compile(pattern, dialect: :crystal, compile_limits: limits)
  #   regex.search(haystack, byte_offset, limits: search_limits, deadline: span)
  #
  # It compiles to a "pending" engine until `Mica::Regex.compile` exists on
  # the branch being measured, so the harness builds and runs on every
  # branch. When the engine lands with a different signature, this file is
  # the one place to change.
  #
  # Throughput cases search with `SearchLimits::TRUSTED_INPUT`; ReDoS cases
  # with `SearchLimits::REQUEST` and the case's deadline, so a search there
  # must return a result or raise Mica's named limit error in time.
  {% if Mica.has_constant?("Regex") && Mica::Regex.class.has_method?("compile") %}
    class MicaEngine < Engine
      def name : String
        "mica"
      end

      def version : String
        "Mica #{Mica::VERSION} Mica::Regex (pure Crystal)"
      end

      def compile(pattern : String, case_insensitive : Bool, policy : SearchPolicy) : CompiledPattern
        options = case_insensitive ? Mica::Regex::CompileOptions::IgnoreCase : Mica::Regex::CompileOptions::None
        regex = Mica::Regex.compile(pattern, dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: options)
        search_limits = policy.untrusted_input ? Mica::Regex::SearchLimits::REQUEST : Mica::Regex::SearchLimits::TRUSTED_INPUT
        CompiledMicaRegex.new(regex, search_limits, policy.deadline)
      rescue error : Mica::Regex::SyntaxError | Mica::Regex::CompileLimitError
        raise UnsupportedCaseError.new("Mica::Regex rejects the pattern: #{error.message}")
      end
    end

    class CompiledMicaRegex(R, L) < CompiledPattern
      def initialize(@regex : R, @search_limits : L, @deadline : Time::Span?)
      end

      def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : Span?
        match = @regex.search(haystack, byte_offset, limits: @search_limits, deadline: @deadline)
        return unless match
        groups_matched = 1
        if count_groups
          groups_matched = 0
          match.size.times { |group_number| groups_matched += 1 if match[group_number]? }
        end
        Span.new(match.byte_begin(0), match.byte_end(0), groups_matched)
      rescue error : Mica::LimitExceededError
        raise LimitReachedError.new("mica-#{error.class.name.split("::").last}", error.message || "limit")
      rescue error : Mica::EncodingError
        raise UnsupportedCaseError.new("Mica::Regex rejects the haystack: #{error.message}")
      end
    end
  {% end %}

  # Stands in for `MicaEngine` while the branch has no matching engine.
  class PendingMicaEngine < Engine
    def initialize(@pending_reason : String)
    end

    def name : String
      "mica"
    end

    def version : String
      "Mica #{Mica::VERSION} (#{@pending_reason})"
    end

    def ready? : Bool
      false
    end

    def pending_reason : String
      @pending_reason
    end

    def compile(pattern : String, case_insensitive : Bool, policy : SearchPolicy) : CompiledPattern
      raise UnsupportedCaseError.new(@pending_reason)
    end
  end

  # Returns the Mica engine when the branch has one, else a pending stand-in.
  def self.build_mica_engine : Engine
    {% if Mica.has_constant?("Regex") && Mica::Regex.class.has_method?("compile") %}
      MicaEngine.new
    {% elsif Mica.has_constant?("Regex") %}
      PendingMicaEngine.new("Mica::Regex.compile is not defined on this branch (milestone R2 has not landed)")
    {% else %}
      PendingMicaEngine.new("Mica::Regex is not defined on this branch")
    {% end %}
  end
end
