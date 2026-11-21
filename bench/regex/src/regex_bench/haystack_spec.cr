require "json"

module RegexBench
  # What a case searches, in rebar's haystack vocabulary, plus a generated
  # form for the Amber set. Steps apply in rebar's order: read (`path` or
  # `contents`, or `generator`), `utf8_lossy`, `trim`, `line_start` and
  # `line_end`, `repeat`, then `prepend` and `append`.
  struct HaystackSpec
    include JSON::Serializable

    NO_LINE_LIMIT = -1_i64

    # A file under rebar's benchmarks/haystacks directory, or "".
    getter path : String = ""
    # Literal contents, used when `path` and `generator` are both empty.
    getter contents : String = ""
    getter? utf8_lossy : Bool = false
    getter? trim : Bool = false
    getter line_start : Int64 = NO_LINE_LIMIT
    getter line_end : Int64 = NO_LINE_LIMIT
    getter repeat : Int64 = 1
    getter prepend : String = ""
    getter append : String = ""
    # An Amber haystack generator name (see `HaystackGenerator`), or "".
    getter generator : String = ""
    # The size a generator fills to, in bytes.
    getter target_bytes : Int64 = 0

    def initialize(*, @path = "", @contents = "", @utf8_lossy = false, @trim = false,
                   @line_start = NO_LINE_LIMIT, @line_end = NO_LINE_LIMIT, @repeat = 1_i64,
                   @prepend = "", @append = "", @generator = "", @target_bytes = 0_i64)
    end

    def reads_a_file? : Bool
      !@path.empty?
    end

    def uses_a_generator? : Bool
      !@generator.empty?
    end

    def has_line_range? : Bool
      @line_start != NO_LINE_LIMIT || @line_end != NO_LINE_LIMIT
    end
  end
end
