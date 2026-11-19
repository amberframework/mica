require "json"

module RegexBench
  # One benchmark case: a pattern, the haystack it searches and the model
  # that says what "one iteration" of work is. rebar's converted definitions
  # (corpus/rebar.json) parse straight into this type; the Amber and ReDoS
  # corpora are expanded into it by `Corpus`.
  #
  # Models (rebar's, plus one): `compile`, `count`, `count-spans`,
  # `count-captures`, `grep`, `grep-captures`, and `first-match` (one search
  # from the start of the haystack, used by the ReDoS set).
  struct BenchmarkCase
    include JSON::Serializable

    NO_EXPECTED_COUNT = -1_i64

    getter id : String
    getter corpus : String = "rebar"
    getter group : String
    getter subgroup : String = ""
    getter model : String
    getter pattern : String
    getter? case_insensitive : Bool = false
    getter? unicode : Bool = true
    getter haystack : HaystackSpec
    # rebar's expected count for pcre2/jit, or NO_EXPECTED_COUNT.
    getter expected_count : Int64 = NO_EXPECTED_COUNT
    # Where the pattern comes from (file and line for the Amber set).
    getter source : String = ""
    getter note : String = ""
    # ReDoS family name, or "".
    getter family : String = ""
    # The size this case runs at: repetitions n for ReDoS, target bytes for
    # the Amber set, 0 for rebar.
    getter size_units : Int64 = 0
    # The per-search deadline in milliseconds, or 0 for none.
    getter deadline_ms : Int64 = 0

    def initialize(*, @id, @corpus, @group, @subgroup, @model, @pattern, @case_insensitive, @haystack,
                   @unicode = true, @expected_count = NO_EXPECTED_COUNT, @source = "", @note = "",
                   @family = "", @size_units = 0_i64, @deadline_ms = 0_i64)
    end

    def has_expected_count? : Bool
      @expected_count != NO_EXPECTED_COUNT
    end

    def has_a_deadline? : Bool
      @deadline_ms > 0
    end

    def belongs_to_the_redos_set? : Bool
      @corpus == "redos"
    end

    # Returns the deadline as a span, or nil when the case has none.
    def deadline : Time::Span?
      @deadline_ms.milliseconds if has_a_deadline?
    end

    # The metric this case's ratios compare: compile time for the `compile`
    # model, warm search time for every other model.
    def primary_metric : String
      @model == "compile" ? "compile" : "warm_search"
    end
  end
end
