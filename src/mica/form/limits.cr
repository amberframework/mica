module Mica::Form
  # The safety limits and work budget for one form parse. Every entry point
  # that reads form bytes takes them as a required `limits:` argument, so a
  # caller always states which limits apply.
  #
  # Pick a preset (`REQUEST_BODY`, `QUERY_STRING`), build a custom set with
  # `new`, or turn every limit off with `unbounded`, which requires a
  # reason:
  #
  # ```
  # limits = Mica::Form::Limits.new(max_pairs: 200, max_array_index: 99)
  # Mica::Form.parse("tags[]=a&tags[]=b", limits: limits)
  # Mica::Form.parse(trusted, limits: Mica::Form::Limits.unbounded(reason: "fixture loader"))
  # ```
  #
  # Each tripped limit raises `Mica::LimitExceededError` whose message
  # names the limit and its value.
  struct Limits
    # The default work budget: 80 operations per input byte plus 1,000,000
    # (which covers the nil slots of sparse arrays), with a 5 second
    # deadline. A 1,000,000-case fuzz campaign (seed 20261025) measured at
    # most 7.13 operations per byte, so this is over ten times that.
    DEFAULT_WORK_BUDGET = Core::WorkBudget.new(
      operations_per_unit: 80,
      base_operations: 1_000_000,
      timeout: 5.seconds,
    )

    # Limits for an `application/x-www-form-urlencoded` request body.
    REQUEST_BODY = new

    # Limits for a URL query string.
    QUERY_STRING = new(max_input_bytes: 64_i64 * 1024, max_pairs: 256)

    # Maximum size in bytes of the whole input.
    getter max_input_bytes : Int64
    # Maximum number of name and value pairs (empty sequences between `&`
    # separators are not pairs and do not count).
    getter max_pairs : Int32
    # Maximum number of segments in one key: `a[b][c]` and `a.b.c` have 3.
    getter max_key_depth : Int32
    # Largest array index a key may name (`items[1000]`). An append
    # (`items[]`) that would go past it trips the limit too.
    getter max_array_index : Int32
    # Maximum number of array slots in the whole result, counting the nil
    # slots that fill gaps between sparse indices. Cumulative over every
    # array, so many sparse arrays cannot multiply into a large result.
    getter max_array_slots : Int32
    # The work budget and deadline the parse runs under.
    getter work_budget : Core::WorkBudget
    # Why the limits were turned off, for limits built by `unbounded`.
    getter unbounded_reason : String?

    def initialize(
      @max_input_bytes : Int64 = 2_i64 * 1024 * 1024,
      @max_pairs : Int32 = 1_000,
      @max_key_depth : Int32 = 32,
      @max_array_index : Int32 = 1_000,
      @max_array_slots : Int32 = 10_000,
      @work_budget : Core::WorkBudget = DEFAULT_WORK_BUDGET,
    )
      check_limit("max_input_bytes", @max_input_bytes)
      check_limit("max_pairs", @max_pairs)
      check_limit("max_key_depth", @max_key_depth)
      check_limit("max_array_index", @max_array_index)
      check_limit("max_array_slots", @max_array_slots)
      raise ArgumentError.new("max_key_depth must be at least 1") if @max_key_depth < 1
      @unbounded_reason = nil
    end

    # Returns limits that never trip and an unlimited work budget, for
    # trusted input. *reason* says why and must not be blank; it is kept
    # in `unbounded_reason` and is greppable at every call site.
    def self.unbounded(reason : String) : self
      raise ArgumentError.new("Limits.unbounded needs a reason") if reason.blank?
      limits = new(
        max_input_bytes: Int64::MAX,
        max_pairs: Int32::MAX,
        max_key_depth: Int32::MAX,
        max_array_index: Int32::MAX - 1,
        max_array_slots: Int32::MAX,
        work_budget: Core::WorkBudget.unlimited,
      )
      limits.unbounded_reason = reason
      limits
    end

    # Returns true when these limits came from `unbounded`.
    def unbounded? : Bool
      !@unbounded_reason.nil?
    end

    protected setter unbounded_reason : String?

    private def check_limit(name : String, value : Int) : Nil
      raise ArgumentError.new("#{name} must not be negative") if value < 0
    end
  end
end
