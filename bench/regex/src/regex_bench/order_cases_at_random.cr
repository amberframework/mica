module RegexBench
  # When a run starts, then its cases are put in an order shuffled by
  # *seed*, so no case is always the first one any runner binary meets and
  # a recorded seed replays the same order. The sizes of each ReDoS family
  # keep their ascending order among the positions the family drew, because
  # the driver skips a family's larger sizes once a smaller one timed out.
  class OrderCasesAtRandom
    def initialize(@list_of_cases : Array(BenchmarkCase), @seed : UInt64)
    end

    def perform : Array(BenchmarkCase)
      shuffled = @list_of_cases.shuffle(Random::PCG32.new(@seed))
      redos_positions = Hash(String, Array(Int32)).new { |hash, family| hash[family] = [] of Int32 }
      shuffled.each_with_index do |benchmark_case, position|
        redos_positions[benchmark_case.family] << position if benchmark_case.belongs_to_the_redos_set?
      end
      redos_positions.each_value do |list_of_positions|
        list_of_family_cases = list_of_positions.map { |position| shuffled[position] }.sort_by!(&.size_units)
        list_of_positions.each_with_index { |position, index| shuffled[position] = list_of_family_cases[index] }
      end
      shuffled
    end
  end
end
