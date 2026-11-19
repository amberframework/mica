module RegexBench
  # PCRE2's interpreter, called directly through the `LibPCRE2` binding
  # that ships with Crystal (this file is the only place the harness calls
  # it). Unlike `Regex.new`, compile here never JIT-compiles, so compile and
  # cold-search times are the interpreter's own. Compile options match
  # stdlib `Regex` (UTF, UCP, DUPNAMES, CASELESS when asked), and later
  # searches over a haystack pass NO_UTF_CHECK, as `String#scan` does. One
  # match-data block is reused per compiled pattern, and no `MatchData`
  # object is allocated per match.
  class Pcre2InterpreterEngine < Engine
    def name : String
      "pcre2-interpreter"
    end

    def version : String
      "PCRE2 #{Regex::PCRE2.version} interpreter (direct pcre2_compile_8 / pcre2_match_8, no JIT)"
    end

    def compile(pattern : String, case_insensitive : Bool, policy : SearchPolicy) : CompiledPattern
      options = LibPCRE2::UTF | LibPCRE2::UCP | LibPCRE2::DUPNAMES
      options |= LibPCRE2::CASELESS if case_insensitive
      code = LibPCRE2.compile(pattern, pattern.bytesize, options, out error_code, out error_offset, nil)
      if code.null?
        raise UnsupportedCaseError.new("PCRE2 rejects the pattern: #{error_text(error_code)} at #{error_offset}")
      end
      CompiledPcre2Interpreter.new(code)
    end

    private def error_text(error_code : Int32) : String
      String.new(256) do |buffer|
        bytesize = LibPCRE2.get_error_message(error_code, buffer, 256)
        {bytesize.clamp(0, 256), 0}
      end
    end
  end

  class CompiledPcre2Interpreter < CompiledPattern
    def initialize(@code : LibPCRE2::Code*)
      @match_data = LibPCRE2.match_data_create_from_pattern(@code, nil)
    end

    def finalize
      LibPCRE2.match_data_free(@match_data)
      LibPCRE2.code_free(@code)
    end

    def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : Span?
      options = first_search ? 0_u32 : LibPCRE2::NO_UTF_CHECK
      result = LibPCRE2.match(@code, haystack, haystack.bytesize, byte_offset, options, @match_data, nil)
      return if result == LibPCRE2::Error::NOMATCH.value
      raise_for(result) if result < 0

      ovector = LibPCRE2.get_ovector_pointer(@match_data)
      groups_matched = count_groups ? count_groups_in(ovector) : 1
      Span.new(ovector[0].to_i32, ovector[1].to_i32, groups_matched)
    end

    private def count_groups_in(ovector : LibC::SizeT*) : Int32
      pair_count = LibPCRE2.get_ovector_count(@match_data)
      groups_matched = 0
      pair_count.times do |group_number|
        groups_matched += 1 unless ovector[group_number * 2] == LibPCRE2::UNSET
      end
      groups_matched
    end

    private def raise_for(result : Int32) : NoReturn
      if LibPCRE2::Error.new(result).utf8_validity? || result == LibPCRE2::Error::BADUTFOFFSET.value
        raise UnsupportedCaseError.new("PCRE2 rejects the haystack: invalid UTF-8 (error #{result})")
      end
      raise LimitReachedError.new(Pcre2LimitName.from_code(result), "pcre2_match_8 returned #{result}")
    end
  end
end
