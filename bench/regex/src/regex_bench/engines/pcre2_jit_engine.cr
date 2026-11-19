module RegexBench
  # The baseline: Crystal's stdlib `Regex` exactly as a Crystal program uses
  # it today. `Regex.new` compiles with UTF, UCP and DUPNAMES and then
  # JIT-compiles; searches go through `Regex#match_at_byte_index`, which
  # allocates a `Regex::MatchData` per match, and capture groups are read
  # with `MatchData#[]?`. Later searches over the same haystack pass
  # `NO_UTF_CHECK`, as `String#scan` does.
  class Pcre2JitEngine < Engine
    def name : String
      "pcre2-jit"
    end

    def version : String
      "PCRE2 #{Regex::PCRE2.version} via Crystal #{Crystal::VERSION} stdlib Regex (JIT #{Pcre2JitEngine.jit_available? ? "on" : "unavailable"})"
    end

    def self.jit_available? : Bool
      available = 0_u32
      LibPCRE2.config(LibPCRE2::CONFIG_JIT, pointerof(available))
      available == 1
    end

    def compile(pattern : String, case_insensitive : Bool, policy : SearchPolicy) : CompiledPattern
      options = case_insensitive ? Regex::CompileOptions::IGNORE_CASE : Regex::CompileOptions::None
      CompiledStdlibRegex.new(Regex.new(pattern, options))
    rescue error : ArgumentError
      raise UnsupportedCaseError.new("PCRE2 rejects the pattern: #{error.message}")
    end
  end

  class CompiledStdlibRegex < CompiledPattern
    def initialize(@regex : Regex)
    end

    def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : Span?
      options = first_search ? Regex::MatchOptions::None : Regex::MatchOptions::NO_UTF_CHECK
      match = @regex.match_at_byte_index(haystack, byte_offset, options)
      return unless match
      groups_matched = count_groups ? count_groups_in(match) : 1
      Span.new(match.byte_begin(0), match.byte_end(0), groups_matched)
    rescue error : Regex::Error
      raise LimitReachedError.new(Pcre2LimitName.from_message(error.message || ""), error.message || "PCRE2 error")
    rescue error : ArgumentError
      raise UnsupportedCaseError.new("PCRE2 rejects the haystack: #{error.message}")
    end

    private def count_groups_in(match : Regex::MatchData) : Int32
      groups_matched = 0
      match.size.times do |group_number|
        groups_matched += 1 if match[group_number]?
      end
      groups_matched
    end
  end
end
