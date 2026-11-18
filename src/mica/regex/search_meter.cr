module Mica::Regex
  # Counts the work of one search call against its `SearchLimits`, on a
  # `Core::WorkMeter`. Created once per call, so an iteration call's
  # searches share one allowance.
  #
  # When the allowance runs out it raises `SearchLimitError` naming
  # `max_work`; when the call's timeout passes, `Mica::DeadlineExceededError`.
  #
  # WARNING: A meter belongs to one call and one fiber at a time (`restart`
  # begins the next call).
  class SearchMeter
    # The underlying meter (its `operations` are the work charged so far).
    getter work_meter : Core::WorkMeter

    def initialize(limits : SearchLimits, state_count : Int32, haystack_bytes : Int32, timeout : Time::Span?)
      @work_meter = Core::WorkMeter.new(limits.work_budget(state_count, timeout))
      @work_meter.add_units(haystack_bytes)
    end

    # Starts the meter over for a new call (see `Core::WorkMeter#restart`).
    def restart(limits : SearchLimits, state_count : Int32, haystack_bytes : Int32, timeout : Time::Span?) : Nil
      @work_meter.restart(limits.work_budget(state_count, timeout))
      @work_meter.add_units(haystack_bytes)
    end

    # Returns the operations charged so far.
    def operations : Int64
      @work_meter.operations
    end

    # Charges *count* operations for work at haystack byte *at*.
    @[AlwaysInline]
    def charge(count : Int, at : Int32) : Nil
      exceeded(at) if @work_meter.charge(count)
    end

    # Raises `Mica::DeadlineExceededError` when the timeout has passed,
    # reading the clock now (charges read it only at checkpoints).
    def enforce_deadline(at : Int32) : Nil
      @work_meter.enforce_deadline("while searching") { Core::Position.new(at.to_i64) }
    end

    private def exceeded(at : Int32) : Nil
      verdict = @work_meter.verdict
      return if verdict.within?
      if verdict.budget_exceeded?
        raise SearchLimitError.new("max_work", @work_meter.allowance,
          "A search of #{@work_meter.operations} operations", Core::Position.new(at.to_i64))
      end
      @work_meter.raise_exceeded(verdict, Core::Position.new(at.to_i64), "while searching")
    end
  end
end
