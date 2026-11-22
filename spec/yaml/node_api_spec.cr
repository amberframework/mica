require "./support"

describe Mica::YAML do
  it_satisfies "YAML-API-NODES", "parses a document into values" do
    config = yaml_parse("server:\n  port: 3000\n  hosts: [a, b]\n  tls: ~\n  ratio: 0.5\n  debug: true\n")
    config["server"]["port"].as_i.should eq 3000
    config["server"]["hosts"][1].as_s.should eq "b"
    config["server"]["hosts"].size.should eq 2
    config["server"]["tls"].raw.should be_nil
    config["server"]["ratio"].as_f.should eq 0.5
    config["server"]["debug"].as_bool.should be_true
    config["server"]["missing"]?.should be_nil
    config["server"]["port"].as_s?.should be_nil
    expect_raises(Mica::Error, "Expected a string, not an integer") { config["server"]["port"].as_s }
    expect_raises(KeyError) { config["nope"] }
    yaml_parse("").raw.should be_nil
  end

  it_satisfies "YAML-API-NODES", "parses every document of a stream" do
    list_of_values = Mica::YAML.parse_all("a: 1\n---\n- 2\n--- three\n", limits: YAML_LIMITS, timeout: nil)
    list_of_values.map(&.raw.class).should eq [Hash(Mica::YAML::Any, Mica::YAML::Any), Array(Mica::YAML::Any), String]
  end

  it_satisfies "YAML-API-NODES", "composes a node graph where an alias is the node it names" do
    root = Mica::YAML.compose("base: &b {x: 1}\ncopy: *b\nlist: [*b, !!str 2]\n", limits: YAML_LIMITS, timeout: nil)
    root.should be_a(Mica::YAML::Mapping)
    if root.is_a?(Mica::YAML::Mapping)
      base = root.list_of_pairs[0][1]
      root.list_of_pairs[1][1].should be(base)
      base.anchor.should eq "b"
      base.position.line.should eq 1
      list = root.list_of_pairs[2][1]
      list.should be_a(Mica::YAML::Sequence)
      if list.is_a?(Mica::YAML::Sequence)
        list.list_of_items[0].should be(base)
        list.list_of_items[1].tag.should eq "tag:yaml.org,2002:str"
        list.style.should eq Mica::YAML::SequenceStyle::Flow
      end
    end
    Mica::YAML.compose("", limits: YAML_LIMITS, timeout: nil).should be_nil
    Mica::YAML.compose_all("a\n--- b\n", limits: YAML_LIMITS, timeout: nil).size.should eq 2
    values = yaml_parse("a: &x [1]\nb: *x\n")
    values["a"].as_a.should be(values["b"].as_a)
  end

  it_satisfies "YAML-7.1-aliases", "rejects undefined aliases and aliases to the node that contains them" do
    yaml_error { yaml_parse("a: *nope\n") }.should be_a(Mica::YAML::UnknownAnchorError)
    yaml_error { yaml_parse("a: &x [*x]\n") }.message.to_s.should contain "contains it"
    yaml_parse("- &a 1\n- &a 2\n- *a\n")[2].as_i.should eq 2
    # Anchors do not carry over to the next document.
    yaml_error { Mica::YAML.parse_all("&a 1\n--- *a\n", limits: YAML_LIMITS, timeout: nil) }.should be_a(Mica::YAML::UnknownAnchorError)
  end

  it_satisfies "YAML-10-schemas", "resolves plain scalars under the core schema" do
    {"null" => nil, "~" => nil, "" => nil, "Null" => nil, "NULL" => nil, "true" => true, "True" => true,
     "FALSE" => false, "0" => 0_i64, "-12" => -12_i64, "+7" => 7_i64, "0o17" => 15_i64, "0x1F" => 31_i64,
     "0xff" => 255_i64, "1.5" => 1.5, "-.5" => -0.5, "1." => 1.0, "1e3" => 1000.0, "1.5E-2" => 0.015,
     ".inf" => Float64::INFINITY, "-.INF" => -Float64::INFINITY, "+.Inf" => Float64::INFINITY,
     "yes" => "yes", "on" => "on", "nUll" => "nUll", "1_000" => "1_000", "0o8" => "0o8", "0x" => "0x",
     "1.2.3" => "1.2.3", "e3" => "e3", "." => ".", "+.nan" => "+.nan", "1e" => "1e",
     "99999999999999999999" => "99999999999999999999", "2026-11-22" => "2026-11-22"}.each do |text, expected|
      yaml_parse("- #{text}\n")[0].raw.should eq(expected), "for #{text.inspect}"
    end
    value = yaml_parse(".nan").raw
    value.is_a?(Float64) && value.nan?.should be_true
    yaml_parse("- '1'\n- \"true\"\n- |\n  3\n").as_a.map(&.raw).should eq ["1", "true", "3\n"]
  end

  it_satisfies "YAML-10-schemas", "resolves under the JSON and failsafe schemas and honors tags" do
    yaml_parse("[1, 1.5, true, null, ~, 0x1F, True, 01, .5, -3]", schema: Mica::YAML::Schema::JSON).as_a.map(&.raw).should eq(
      [1_i64, 1.5, true, nil, "~", "0x1F", "True", "01", ".5", -3_i64])
    yaml_parse("[1, true, null]", schema: Mica::YAML::Schema::FailSafe).as_a.map(&.raw).should eq ["1", "true", "null"]
    yaml_parse("[!!str 1, !!int '2', !!float 3, !!bool 'true', !!null '', ! 4, !custom 5]").as_a.map(&.raw).should eq(
      ["1", 2_i64, 3.0, true, nil, "4", "5"])
    yaml_error { yaml_parse("!!int abc") }.message.to_s.should contain "does not match its tag"
  end

  it_satisfies "YAML-MERGE-KEYS", "merges mappings under << with the mapping's own keys winning" do
    config = yaml_parse("base: &base {adapter: pg, pool: 5}\nextra: &extra {pool: 9, ssl: true}\n" \
                        "dev:\n  pool: 1\n  <<: *base\ntest:\n  <<: [*base, *extra]\n  adapter: sqlite\n")
    config["dev"].as_h.transform_keys(&.as_s).transform_values(&.raw).should eq({"pool" => 1_i64, "adapter" => "pg"})
    config["test"].as_h.transform_keys(&.as_s).transform_values(&.raw).should eq(
      {"adapter" => "sqlite", "pool" => 5_i64, "ssl" => true})
    yaml_parse("a: {'<<': 1}\n")["a"]["<<"].as_i.should eq 1
    yaml_parse("b: &b {x: 1}\na: {<<: *b}\n", merge_keys: false)["a"]["<<"]["x"].as_i.should eq 1
    yaml_parse("a: {<<: 3}\n")["a"]["<<"].as_i.should eq 3
  end

  it "keeps the last of two equal keys, or rejects them when asked" do
    yaml_parse("a: 1\na: 2\n")["a"].as_i.should eq 2
    error = yaml_error { yaml_parse("a: 1\nb: 2\na: 3\n", duplicate_keys: Mica::YAML::DuplicateKeys::Reject) }
    error.message.to_s.should contain "found duplicate key"
    error.as(Mica::ParseError).line_number.should eq 3
  end

  it "uses collections as keys once they are complete" do
    value = yaml_parse("? [a, {b: c}]\n: 1\n? {d: [e]}\n: 2\n")
    value.as_h.values.map(&.raw).should eq [1_i64, 2_i64]
    value.as_h.keys[0].as_a[1]["b"].as_s.should eq "c"
  end
end
