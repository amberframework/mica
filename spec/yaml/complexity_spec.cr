require "./support"

# Work (meter operations, not wall time) must grow linearly with the
# input for every shape that is quadratic in some YAML parser.
private LINEAR_LIMITS = Mica::YAML::ParseLimits.custom(max_input_bytes: 64_000_000_i64, max_depth: 1_000_000,
  max_nodes: Int64::MAX, max_alias_expansion: Int64::MAX, work_per_unit: 1_000_000_i64)

private def operations_for(source : String, dialect : Mica::YAML::Dialect, compose : Bool = false) : Int64
  meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
  parser = Mica::YAML::PullParser.new(source, limits: LINEAR_LIMITS, timeout: nil, dialect: dialect, meter: meter)
  if compose
    composer = Mica::YAML::Composer.new(parser, LINEAR_LIMITS)
    while composer.next_document
    end
  else
    until parser.kind.stream_end?
      parser.read_next
    end
  end
  meter.operations
rescue Mica::YAML::SyntaxError
  # A shape that ends in a syntax error still counts: the work up to the
  # error is what is measured.
  meter ? meter.operations : 0_i64
end

private def expect_linear(name : String, size : Int32, compose : Bool = false, & : Int32 -> String) : Nil
  Mica::YAML::Dialect.each do |dialect|
    result = Mica::Testing::Complexity.measure("yaml #{dialect} #{name}", size) do |count|
      operations_for(yield(count), dialect, compose)
    end
    COMPLEXITY_RESULTS << result
    result.linear?.should be_true, result.to_s
  end
end

describe "Mica::YAML complexity" do
  it_satisfies "MICA-LINEAR-YAML-FLOW-NESTING", "scans deep flow nesting in linear work" do
    expect_linear("nested flow sequences", 20_000) { |count| "[" * count + "]" * count }
    expect_linear("nested flow sequences on separate lines", 5_000) { |count| "[\n" * count + "]\n" * count }
    expect_linear("nested flow mappings", 10_000) { |count| "{a: " * count + "1" + "}" * count }
    expect_linear("unclosed flow sequences with entries", 20_000) { |count| "[a," * count }
  end

  it_satisfies "MICA-LINEAR-YAML-SIMPLE-KEYS", "scans many keys, long keys and candidate keys in linear work" do
    expect_linear("many short keys", 20_000) { |count| "k: v\n" * count }
    expect_linear("keys at the length limit", 200) { |count| ("k" * 1_000 + ": v\n") * count }
    expect_linear("candidate keys that never get a colon", 20_000) { |count| "- [a, b, c]\n" * count }
    expect_linear("a flow sequence used as a key, repeated", 2_000) { |count| ("[" + "a," * 200 + "b]: v\n") * count }
    expect_linear("explicit keys", 20_000) { |count| "? k\n: v\n" * count }
  end

  it_satisfies "MICA-LINEAR-YAML-SCALARS", "scans long scalars, comments and indentation in linear work" do
    expect_linear("one long plain scalar", 200_000) { |count| "a " * count }
    expect_linear("one long folded plain scalar", 50_000) { |count| "a\n " * count }
    expect_linear("one long double-quoted scalar with escapes", 50_000) { |count| "\"" + "\\n\\x41 a" * count + "\"" }
    expect_linear("one long literal scalar", 50_000) { |count| "|\n" + " line\n" * count }
    expect_linear("blank lines in a block scalar", 50_000) { |count| "|\n" + " \n" * count + " x\n" }
    expect_linear("comment lines", 50_000) { |count| "# comment\n" * count + "a\n" }
    expect_linear("an indentation staircase", 2_000) { |count| (0...count).map { |level| " " * (level % 50) + "- a\n" }.join }
    expect_linear("multi-byte text on one line", 50_000) { |count| "k: " + "é " * count }
  end

  it_satisfies "MICA-LINEAR-YAML-ALIASES", "composes alias fan-out in linear work" do
    expect_linear("many aliases to one node", 20_000, compose: true) do |count|
      "a: &a [1, 2, 3]\nb: [" + (["*a"] * count).join(",") + "]\n"
    end
    expect_linear("many anchors", 20_000, compose: true) { |count| (0...count).map { |index| "- &a#{index} x\n" }.join }
  end

  it "has an honest counter: a quadratic workload fails the linear check" do
    result = Mica::Testing::Complexity.measure("quadratic probe", 200) do |count|
      (0...count).sum { |index| operations_for("k: v\n" * index, Mica::YAML::Dialect::YAML12) }
    end
    result.linear?.should be_false
  end
end
