require "../spec_helper"

private LIMITS = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def program_of(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN).program
end

# Every match of *program* in *haystack* on one searcher of *engine*.
private def scan(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine) : Array(Array(Int64))
  searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, engine)
  list_of_spans = [] of Array(Int64)
  offset = 0
  while found = searcher.find(offset, Mica::Regex::MatchOptions::None, false)
    list_of_spans << found.to_a
    offset = found[1] > found[0] ? found[1].to_i32 : found[1].to_i32 + 1
  end
  searcher.finish
  list_of_spans
end

private RUSSIAN = "Съешь же ещё этих мягких французских булок, да выпей чаю. Достопримечательность " \
                  "и человеконенавистничество — длинные слова; café naïve 12345 ünïcödé"

describe "Mica::Regex reversed classes" do
  it_satisfies "REGEX-R3-reversed-classes", "records each class of more than one state as a block" do
    program = program_of("\\w{3}")
    program.list_of_class_blocks.size.should eq(3)
    program.list_of_class_blocks.each do |block|
      (block.first_state <= block.entry < block.end_state).should be_true
    end
    program_of("[ab]").list_of_class_blocks.should be_empty
  end

  it_satisfies "REGEX-R3-reversed-classes", "reads a class backward one node per byte: every node's edges are disjoint" do
    program = program_of("\\p{L}")
    block = program.list_of_class_blocks.first
    reversed = Mica::Regex::ReversedClass.for(program, block, 1 << 20).should_not be_nil
    reversed.list_of_edges.group_by(&.[0]).each_value do |edges|
      # The edges to the class's entry may overlap the others (a sequence
      # can end there or go on); among the rest no byte is covered twice.
      inner = edges.reject { |edge| edge[3] == Mica::Regex::ReversedClass::ENTRY }.sort_by(&.[1])
      inner.each_cons_pair { |left, right| (left[2] < right[1]).should be_true }
    end
  end

  it_satisfies "REGEX-R3-reversed-classes", "keeps reverse DFA states small next to non-ASCII text" do
    program = program_of("\\b\\w{12,}\\b")
    plain = Mica::Regex::ReverseNFA.new(program)
    widened = Mica::Regex::ReverseNFA.new(program, reverse_classes: true)
    widened.node_count.should be > plain.node_count
    expected = scan(program, RUSSIAN, Mica::Regex::Engine::PikeVM)
    expected.size.should eq(2)
    scan(program, RUSSIAN, Mica::Regex::Engine::ReversedClasses).should eq(expected)
    scan(program, RUSSIAN, Mica::Regex::Engine::Auto).should eq(expected)
    lease = program.plan.lease(Mica::Regex::CachePool.default)
    reverse = program.plan.reverse.should_not be_nil
    reverse.with_reversed_classes?.should be_true
    lease.reverse_cache(reverse).should_not(be_nil).widest_key.should be <= Mica::Regex::SearchPlan::WIDE_REVERSE_KEY
    program.plan.give_back(lease)
  end

  it_satisfies "REGEX-R3-reversed-classes", "agrees with the Pike VM on classes, case folding and word assertions" do
    ["\\w+", "\\p{L}+\\s+\\d*", "(?i)[à-ÿ]+", "[^a-z ]+", "\\b\\w+\\b", "\\B\\w+", "(?:\\p{Cyrillic}|\\d)+", ".+?;", "\\W+"].each do |source|
      program = program_of(source)
      scan(program, RUSSIAN, Mica::Regex::Engine::ReversedClasses).should eq(scan(program, RUSSIAN, Mica::Regex::Engine::PikeVM))
    end
  end
end
