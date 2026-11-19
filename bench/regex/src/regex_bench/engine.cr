module RegexBench
  # One match: the byte span of group 0 and how many groups (group 0
  # included) took part. `groups_matched` is 1 when the caller did not ask
  # for groups.
  record Span, start : Int32, finish : Int32, groups_matched : Int32

  # What a search may spend. PCRE2 engines have no deadline and ignore it;
  # the Mica adapter maps it onto Mica's search limits and deadline.
  record SearchPolicy, deadline : Time::Span?, untrusted_input : Bool

  # The adapter interface every engine under test implements. An engine
  # compiles a pattern; the compiled pattern finds the leftmost match at or
  # after a byte offset. `Workload` builds rebar's models on top of `find`,
  # identically for every engine.
  abstract class Engine
    # The engine's name in results, for example "pcre2-jit".
    abstract def name : String

    # The engine version and build facts, for example "PCRE2 10.47 (JIT)".
    abstract def version : String

    # Compiles *pattern*. Raises `UnsupportedCaseError` when the engine
    # rejects it.
    abstract def compile(pattern : String, case_insensitive : Bool, policy : SearchPolicy) : CompiledPattern

    # Returns false while the engine is not built on this branch (the Mica
    # adapter before the matching engine lands); every case then reports
    # "pending".
    def ready? : Bool
      true
    end

    # Says why the engine is not ready.
    def pending_reason : String
      ""
    end
  end

  abstract class CompiledPattern
    # Returns the leftmost match starting at or after *byte_offset*, or nil.
    # *first_search* is true for the first search over a haystack: an engine
    # may validate UTF-8 then and skip it on later searches of the same
    # haystack, as `String#scan` does. *count_groups* asks for
    # `Span#groups_matched`. Raises `LimitReachedError` when the engine stops
    # on one of its limits.
    abstract def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : Span?
  end
end
