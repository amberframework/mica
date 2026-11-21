module RegexBench
  # Maps PCRE2's error text to a stable limit name.
  module Pcre2LimitName
    def self.from_message(message : String) : String
      text = message.downcase
      if text.includes?("match limit")
        "pcre2-match-limit"
      elsif text.includes?("depth limit") || text.includes?("recursion")
        "pcre2-depth-limit"
      elsif text.includes?("heap limit")
        "pcre2-heap-limit"
      elsif text.includes?("jit stack")
        "pcre2-jit-stack-limit"
      else
        "pcre2-error"
      end
    end

    def self.from_code(code : Int32) : String
      case code
      when LibPCRE2::Error::MATCHLIMIT.value     then "pcre2-match-limit"
      when LibPCRE2::Error::DEPTHLIMIT.value     then "pcre2-depth-limit"
      when LibPCRE2::Error::HEAPLIMIT.value      then "pcre2-heap-limit"
      when LibPCRE2::Error::JIT_STACKLIMIT.value then "pcre2-jit-stack-limit"
      else                                            "pcre2-error"
      end
    end
  end
end
