module Mica::Testing
  # Runs seeded fuzz cases through a format and tallies what happened.
  #
  # The format's block parses one input and returns a `Trial`; anything the
  # block raises is caught here. A case is:
  #
  # - **accepted** when the block returns without an error,
  # - **rejected** when the trial carries a `Mica::Error` (the only
  #   acceptable failure),
  # - a **crash** when the block raises anything that is not a
  #   `Mica::Error`, or returns a trial with failed checks.
  #
  # Every case is also checked for:
  #
  # - **budget overruns**: operations above the allowance plus the
  #   format's check interval (the meter must stop work in time);
  # - **determinism** (when enabled): the same bytes give the same outcome
  #   twice.
  #
  # ```
  # campaign = Mica::Testing::FuzzCampaign.new(mutator, seed: 7_i64, overrun_slack: 70_000_i64)
  # report = campaign.run(10_000) do |bytes|
  #   meter = Mica::Core::WorkMeter.new
  #   begin
  #     Mica::XML.parse(bytes, meter: meter)
  #     Mica::Testing::FuzzCampaign::Trial.new("ok", nil, meter)
  #   rescue error : Mica::Error
  #     Mica::Testing::FuzzCampaign::Trial.new(error.message.to_s, error, meter)
  #   end
  # end
  # report.list_of_crashes # => [] of String
  # ```
  class FuzzCampaign
    # The result of one parse. *outcome* is a canonical description used for
    # determinism checks; *failures* lists format-specific check failures.
    record Trial, outcome : String, error : Mica::Error?, operations : Int64, allowance : Int64,
      units : Int64, failures : Array(String) = [] of String do
      def self.new(outcome : String, error : Mica::Error?, meter : Core::WorkMeter, failures : Array(String) = [] of String) : self
        new(outcome, error, meter.operations, meter.allowance, meter.units, failures)
      end
    end

    # Counts for a finished campaign. Lists hold replayable case ids
    # (`seed:iteration`) with a short reason.
    class Report
      # See `max_operations_per_unit`.
      RATIO_MIN_UNITS = 256

      getter cases = 0
      getter accepted = 0
      getter rejected = 0
      getter budget_trips = 0
      getter list_of_crashes = [] of String
      getter list_of_budget_overruns = [] of String
      getter list_of_nondeterministic_cases = [] of String
      getter errors_by_class = Hash(String, Int32).new(0)
      # The highest operations-per-unit ratio among cases of at least
      # `RATIO_MIN_UNITS` units (smaller inputs are dominated by fixed
      # per-parse costs, which the budget's base allowance covers).
      getter max_operations_per_unit = 0.0

      # :nodoc:
      def record(trial : Trial) : Nil
        @cases += 1
        if error = trial.error
          @rejected += 1
          @errors_by_class[error.class.name] += 1
          @budget_trips += 1 if error.is_a?(WorkBudgetExceededError) || error.is_a?(DeadlineExceededError)
        else
          @accepted += 1
        end
        if trial.units >= RATIO_MIN_UNITS
          ratio = trial.operations / trial.units
          @max_operations_per_unit = ratio if ratio > @max_operations_per_unit
        end
      end

      # :nodoc:
      def count_case : Nil
        @cases += 1
      end

      # Returns true when nothing crashed, overran or varied.
      def clean? : Bool
        @list_of_crashes.empty? && @list_of_budget_overruns.empty? && @list_of_nondeterministic_cases.empty?
      end

      def to_s(io : IO) : Nil
        io << "cases=" << @cases << " accepted=" << @accepted << " rejected=" << @rejected
        io << " crashes=" << @list_of_crashes.size << " budget_overruns=" << @list_of_budget_overruns.size
        io << " budget_trips=" << @budget_trips << " nondeterministic=" << @list_of_nondeterministic_cases.size
        io << " max_ops_per_unit=" << @max_operations_per_unit.round(2)
      end
    end

    getter report = Report.new

    # *overrun_slack* is the most work a format may do between two budget
    # checks; *check_determinism* runs every case twice.
    def initialize(@mutator : ByteMutator, @seed : Int64, @overrun_slack : Int64, @check_determinism : Bool = false)
    end

    # Runs cases *first* to `first + count - 1` and returns the report.
    def run(count : Int32, first : Int32 = 0, & : Bytes, Int32 -> Trial) : Report
      count.times do |offset|
        iteration = first + offset
        bytes = @mutator.case_bytes(@seed, iteration)
        id = "#{@seed}:#{iteration}"
        trial = attempt(id, bytes, iteration) { |input, index| yield input, index }
        next unless trial
        @report.record(trial)
        unless trial.failures.empty?
          @report.list_of_crashes << "#{id} #{trial.failures.first}"
        end
        if trial.operations > trial.allowance + @overrun_slack
          @report.list_of_budget_overruns << "#{id} #{trial.operations} ops > allowance #{trial.allowance}"
        end
        next unless @check_determinism
        again = attempt(id, bytes, iteration) { |input, index| yield input, index }
        if again && again.outcome != trial.outcome
          @report.list_of_nondeterministic_cases << "#{id} #{trial.outcome[0, 80]} vs #{again.outcome[0, 80]}"
        end
      end
      @report
    end

    private def attempt(id : String, bytes : Bytes, iteration : Int32, & : Bytes, Int32 -> Trial) : Trial?
      yield bytes, iteration
    rescue error : Exception
      @report.count_case
      @report.list_of_crashes << "#{id} #{error.class}: #{error.message.to_s[0, 160]}"
      nil
    end
  end
end
