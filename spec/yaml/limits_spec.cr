require "./support"

private alias Limits = Mica::YAML::ParseLimits

private def limit_error(source : String | Bytes, limits : Limits, timeout : Time::Span? = nil) : Mica::Error
  yaml_error { Mica::YAML.parse(source, limits: limits, timeout: timeout) }
end

# A "billion laughs" document: *levels* anchors, each a sequence of
# *width* aliases to the one before.
private def billion_laughs(levels : Int32, width : Int32) : String
  String.build do |io|
    io << "l0: &l0 [" << (["lol"] * width).join(", ") << "]\n"
    (1..levels).each do |level|
      io << 'l' << level << ": &l" << level << " [" << (["*l#{level - 1}"] * width).join(", ") << "]\n"
    end
  end
end

describe Mica::YAML::ParseLimits do
  it "has no default: every parse names its limits and its timeout" do
    Limits::CONFIG_FILE.max_input_bytes.should eq 1_048_576
    Limits.custom(max_depth: 8).max_depth.should eq 8
    Limits.custom(max_depth: 8).max_nodes.should eq Limits::CONFIG_FILE.max_nodes
    expect_raises(ArgumentError) { Limits.custom(max_depth: 0) }
    expect_raises(ArgumentError) { Limits.custom(max_input_bytes: -1_i64) }
  end

  it_satisfies "YAML-LIMIT-INPUT", "stops input larger than max_input_bytes, from memory and from an IO" do
    limits = Limits.custom(max_input_bytes: 16_i64)
    Mica::YAML.parse("a: 1234567890123", limits: limits, timeout: nil)["a"].as_i64.should eq 1234567890123
    error = limit_error("a: 12345678901234", limits)
    error.should be_a(Mica::YAML::ParseLimitError)
    error.as(Mica::YAML::ParseLimitError).limit.should eq "max_input_bytes"
    error = yaml_error { Mica::YAML.parse(IO::Memory.new("x" * 100_000), limits: limits, timeout: nil) }
    error.as(Mica::YAML::ParseLimitError).limit.should eq "max_input_bytes"
  end

  it_satisfies "YAML-LIMIT-DEPTH", "stops nesting deeper than max_depth, in flow and in block style" do
    limits = Limits.custom(max_depth: 10)
    Mica::YAML.parse("[" * 10 + "]" * 10, limits: limits, timeout: nil).size.should eq 1
    limit_error("[" * 11 + "]" * 11, limits).as(Mica::YAML::ParseLimitError).limit.should eq "max_depth"
    limit_error("{a: " * 11 + "1" + "}" * 11, limits).as(Mica::YAML::ParseLimitError).limit.should eq "max_depth"
    block = String.build { |io| 11.times { |level| io << " " * level << "- \n" } }
    limit_error(block, limits).as(Mica::YAML::ParseLimitError).limit.should eq "max_depth"
    limit_error("- " * 11 + "x", limits).as(Mica::YAML::ParseLimitError).limit.should eq "max_depth"
    # A million open brackets cost nothing past the limit.
    error = limit_error("[" * 1_000_000, Limits.custom(max_depth: 64, max_input_bytes: 2_000_000_i64))
    error.as(Mica::ParseError).byte_offset.should eq 64
  end

  it_satisfies "YAML-LIMIT-NODES", "stops a document with more than max_nodes nodes" do
    limits = Limits.custom(max_nodes: 100_i64)
    Mica::YAML.parse("[" + (["x"] * 99).join(",") + "]", limits: limits, timeout: nil).size.should eq 99
    limit_error("[" + (["x"] * 100).join(",") + "]", limits).as(Mica::YAML::ParseLimitError).limit.should eq "max_nodes"
  end

  it_satisfies "YAML-LIMIT-ALIAS-EXPANSION", "stops a billion-laughs document before it expands (GHSA-gmv7-hhm8-cxj5)" do
    # Nine levels of nine aliases: 813 bytes that expand to 9^10 nodes.
    bomb = billion_laughs(9, 9)
    before = GC.stats.total_bytes
    error = limit_error(bomb, Limits::UNTRUSTED)
    error.should be_a(Mica::YAML::ParseLimitError)
    error.as(Mica::YAML::ParseLimitError).limit.should eq "max_alias_expansion"
    # It is stopped at the level that would pass 100,000 nodes (the fifth),
    # having built only the nodes written in the document.
    error.as(Mica::ParseError).line_number.should eq 6
    (GC.stats.total_bytes - before).should be < 1_000_000
    # The same document inside the limit parses, and shares its nodes.
    small = Mica::YAML.parse(billion_laughs(3, 9), limits: Limits::UNTRUSTED, timeout: nil)
    small["l3"][0].as_a.should be(small["l2"].as_a)
  end

  it_satisfies "YAML-LIMIT-ALIAS-EXPANSION", "stops quadratic alias fan-out and merge-key copying" do
    # One large node referred to many times: 2,000 items times 2,000
    # aliases is four million nodes from about 20 KiB.
    fan_out = "big: &big [" + (["x"] * 2_000).join(",") + "]\nrefs: [" + (["*big"] * 2_000).join(",") + "]\n"
    limit_error(fan_out, Limits::CONFIG_FILE).as(Mica::YAML::ParseLimitError).limit.should eq "max_alias_expansion"
    merges = "base: &base {" + (0...500).map { |index| "k#{index}: v" }.join(", ") + "}\n" +
             (0...400).map { |index| "m#{index}: {<<: *base}\n" }.join
    limit_error(merges, Limits::UNTRUSTED).as(Mica::YAML::ParseLimitError).limit.should eq "max_alias_expansion"
    # Aliases to scalars are cheap and allowed in any number.
    many = "a: &a x\nrefs: [" + (["*a"] * 5_000).join(",") + "]\n"
    Mica::YAML.parse(many, limits: Limits::UNTRUSTED, timeout: nil)["refs"].size.should eq 5_000
  end

  it_satisfies "YAML-LIMIT-WORK", "stops a parse that passes its work budget or its deadline" do
    source = "key: value\n" * 2_000
    tight = Limits.custom(work_per_unit: 0_i64, base_work: 1_000_i64)
    error = limit_error(source, tight)
    error.should be_a(Mica::WorkBudgetExceededError)
    error.as(Mica::ParseError).line_number.should be > 1
    error = limit_error(source, Limits::CONFIG_FILE, timeout: Time::Span.zero)
    error.should be_a(Mica::DeadlineExceededError)
    # The pull parser shares a caller's meter.
    meter = Mica::Core::WorkMeter.new(Limits::CONFIG_FILE.work_budget(nil))
    parser = Mica::YAML::PullParser.new(source, limits: Limits::CONFIG_FILE, timeout: nil, meter: meter)
    until parser.kind.stream_end?
      parser.read_next
    end
    meter.units.should eq source.bytesize
    meter.operations.should be > source.bytesize
    meter.operations.should be < 8_i64 * source.bytesize
  end
end
