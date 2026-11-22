require "./support"

# Replays the cases recorded from libyaml 0.2.5 by
# fuzz/yaml_record_fixture.cr through Mica's libyaml dialect: the same
# events (kinds, marks, anchors, tags, styles, implicit flags and scalar
# bytes), or the same error text and marks. The spec binary links no
# libyaml; fuzz/yaml_campaign.cr runs the live comparison.
describe "Mica::YAML libyaml dialect" do
  it_satisfies "YAML-LIBYAML-DIALECT", "gives libyaml's events, marks and errors on the recorded cases" do
    rows = 0
    File.each_line(File.join(__DIR__, "fixtures", "libyaml_events.tsv")) do |line|
      next if line.starts_with?('#')
      hex, outcome, expected = line.split('\t', 3)
      input = hex.hexbytes
      rows += 1
      begin
        parser = Mica::YAML::PullParser.new(input, limits: Mica::YAML::ParseLimits::LIBYAML, timeout: nil,
          dialect: Mica::YAML::Dialect::LibYAML)
        actual = YAMLEvents.describe(parser).join(" | ")
        {outcome, actual}.should eq({"ok", expected}), "for input #{String.new(input).inspect}"
      rescue error : Mica::Error
        {outcome, YAMLEvents.describe_error(error)}.should eq({"error", expected}), "for input #{String.new(input).inspect}"
      end
    end
    rows.should eq 800
  end

  it "keeps libyaml's reading where YAML 1.2 differs" do
    libyaml = Mica::YAML::Dialect::LibYAML
    # NEL, LS and PS end a line in YAML 1.1.
    yaml_events("b\u0085 c\n", libyaml).should contain %(Scalar "b c")
    yaml_events("b\u0085 c\n").should contain "Scalar #{"b\u0085 c".inspect}"
    # libyaml reads anchors up to the first character that is not a word character.
    yaml_events("&a: b\n", libyaml).should contain %(Scalar &a "")
    yaml_events("&a: b\n").should contain %(Scalar &a: "b")
    # libyaml's tags are C strings: a %00 escape ends a prefix or a suffix.
    yaml_events("%TAG !e! tag:example.com,%000:app/\n--- !e!x a\n", libyaml).should contain %(Scalar <tag:example.com,x> "a")
    yaml_events("--- !<tag:a%00b> c\n", libyaml).should contain %(Scalar <tag:a> "c")
    yaml_events("--- !<tag:a%00b> c\n").should contain "Scalar <#{"tag:a\u0000b"}> #{"c".inspect}"
    # libyaml rejects what YAML 1.2 allows, and allows what it rejects.
    yaml_error { yaml_events("%FOO bar\n--- a\n", libyaml) }.message.to_s.should contain "found unknown directive name"
    yaml_events("[a]#b\n", libyaml).should contain %(Scalar "a")
  end
  # libyaml 0.2.6 (2026-11-20) changed two readings. The libyaml dialect
  # stays on 0.2.5, the version it states; docs/yaml.md lists both changes.
  it "keeps libyaml 0.2.5's reading where libyaml 0.2.6 changed it" do
    libyaml = Mica::YAML::Dialect::LibYAML
    # An explicit key closed by ']': 0.2.5 swallows the ']' and fails,
    # 0.2.6 reads a single-pair mapping with an empty key, as YAML 1.2 does.
    yaml_error { yaml_events("[? ]\n", libyaml) }.message.to_s.should contain "did not find expected ',' or ']'"
    yaml_events("[? ]\n").should eq ["StreamStart", "DocumentStart", "SequenceStart", "MappingStart",
                                     %(Scalar ""), %(Scalar ""), "MappingEnd", "SequenceEnd", "DocumentEnd", "StreamEnd"]
    # Nesting: 0.2.6 stops at 1000 levels by default, 0.2.5 has no cap of
    # its own. Mica's cap is `max_depth`, which every preset but LIBYAML sets.
    deep = "[" * 1001 + "]" * 1001
    yaml_events(deep, libyaml, Mica::YAML::ParseLimits::LIBYAML).count("SequenceStart").should eq 1001
    yaml_error { yaml_events(deep, libyaml) }.as(Mica::YAML::ParseLimitError).limit.should eq "max_depth"
  end
end
