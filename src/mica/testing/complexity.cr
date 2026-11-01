module Mica::Testing
  # Proves a workload linear by its operation count (from a
  # `Core::WorkMeter`), never by wall time, so the result is the same on a
  # loaded machine.
  #
  # The workload runs at *size* and at *factor* times *size*. A linear
  # workload's operations grow by about *factor*; a quadratic one's by
  # *factor* squared. The bound allows *slack* for fixed costs and for
  # `n log n` steps (sorting).
  #
  # ```
  # result = Mica::Testing::Complexity.measure("many attributes", 2_000) do |n|
  #   xml = "<a " + (1..n).join(' ') { |i| %(a#{i}="1") } + "/>"
  #   Mica::XML.parse(xml).parse_operations
  # end
  # result.linear? # => true
  # ```
  module Complexity
    # Default multiplier between the two sizes.
    FACTOR = 4

    # Default allowance over a perfectly linear ratio.
    SLACK = 1.25

    # The operation counts at both sizes.
    record Result, name : String, size : Int32, factor : Int32, small : Int64, large : Int64, slack : Float64 do
      # Returns large / small.
      def ratio : Float64
        small > 0 ? large / small : Float64::INFINITY
      end

      # Returns the largest ratio accepted as linear.
      def bound : Float64
        factor * slack
      end

      # Returns true when the growth is within the linear bound.
      def linear? : Bool
        ratio <= bound
      end

      def to_s(io : IO) : Nil
        io << name << ": " << small << " ops at n=" << size << ", " << large << " ops at n=" << size * factor
        io << " (ratio " << ratio.round(2) << ", bound " << bound.round(2) << ')'
      end
    end

    # Runs the block at *size* and `size * factor` and returns both
    # operation counts. The block builds its input for the given size, runs
    # the workload and returns the operations it charged.
    def self.measure(name : String, size : Int32, factor : Int32 = FACTOR, slack : Float64 = SLACK, & : Int32 -> Int64) : Result
      small = yield size
      large = yield size * factor
      Result.new(name, size, factor, small, large, slack)
    end
  end
end
