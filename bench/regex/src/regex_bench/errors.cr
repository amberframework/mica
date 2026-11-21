module RegexBench
  # Base class of the errors the harness raises.
  class Error < Exception
  end

  # Raised when an engine cannot run a case at all: the pattern does not
  # compile, uses a construct the engine leaves out, or the haystack is not
  # valid UTF-8 for an engine that requires it.
  class UnsupportedCaseError < Error
  end

  # Raised when an engine stops a search on one of its own limits: PCRE2's
  # match, depth, heap or JIT stack limit, or Mica's work budget or deadline.
  # *limit_name* names the limit, for example "pcre2-match-limit".
  class LimitReachedError < Error
    getter limit_name : String

    def initialize(@limit_name : String, message : String)
      super("#{@limit_name}: #{message}")
    end
  end

  # Raised when a corpus or haystack file is missing or does not verify.
  class CorpusError < Error
  end
end
