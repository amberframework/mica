require "./support"

describe Mica::YAML::PullParser do
  it_satisfies "YAML-API-PULL", "reads events one at a time" do
    parser = Mica::YAML::PullParser.new("name: mica\n", limits: YAML_LIMITS, timeout: 1.second)
    parser.kind.should eq Mica::YAML::EventKind::StreamStart
    parser.read_next.should eq Mica::YAML::EventKind::DocumentStart
    parser.implicit?.should be_true
    parser.read_next.should eq Mica::YAML::EventKind::MappingStart
    parser.mapping_style.should eq Mica::YAML::MappingStyle::Block
    parser.read_next.should eq Mica::YAML::EventKind::Scalar
    parser.value.should eq "name"
    parser.start_line.should eq 1
    parser.start_column.should eq 1
    parser.end_column.should eq 5
    parser.read_next
    parser.value.should eq "mica"
    parser.scalar_style.should eq Mica::YAML::ScalarStyle::Plain
    parser.start_position.byte_offset.should eq 6
    parser.read_next.should eq Mica::YAML::EventKind::MappingEnd
    parser.read_next.should eq Mica::YAML::EventKind::DocumentEnd
    parser.read_next.should eq Mica::YAML::EventKind::StreamEnd
    parser.read_next.should eq Mica::YAML::EventKind::None
  end

  it_satisfies "YAML-API-PULL", "gives the same events from a String, Bytes and an IO that trickles" do
    source = "a: [1, 'two', \"th\\tree\"]\nb: |\n  text\n  more\nc: &x {k: v}\nd: *x\n--- >-\n folded\n text\n"
    expected = yaml_events(source)
    yaml_events(source.to_slice).should eq expected
    yaml_events(TrickleIO.new(source.to_slice, 1)).should eq expected
    yaml_events(IO::Memory.new(source)).should eq expected
  end

  it "skips a whole node" do
    parser = Mica::YAML::PullParser.new("- [a, {b: c}]\n- d\n", limits: YAML_LIMITS, timeout: nil)
    parser.read_next # document start
    parser.read_next # sequence start
    parser.read_next # the nested sequence
    parser.skip.should eq Mica::YAML::EventKind::Scalar
    parser.value.should eq "d"
  end

  it "raises Mica::Error when a value is read from an event that is not a scalar" do
    parser = Mica::YAML::PullParser.new("[]", limits: YAML_LIMITS, timeout: nil)
    expect_raises(Mica::Error, "Expected a scalar event") { parser.value }
  end

  it_satisfies "YAML-7.3-flow-scalars", "unescapes double-quoted scalars and folds lines" do
    yaml_events(%("a\\x41\\u00e9\\U0001F600\\n\\\n  b c\n\n  d")).should contain %(Scalar "aAé😀\\nb c\\nd")
    yaml_events("'it''s\n  folded'").should contain %(Scalar "it's folded")
    yaml_events("plain\n  text\n\n  here").should contain %(Scalar "plain text\\nhere")
  end

  it_satisfies "YAML-8.1-block-scalars", "reads literal and folded scalars with their indicators" do
    yaml_events("|\n a\n b\n\n").should contain %(Scalar "a\\nb\\n")
    yaml_events("|-\n a\n b\n\n").should contain %(Scalar "a\\nb")
    yaml_events("|+\n a\n b\n\n").should contain %(Scalar "a\\nb\\n\\n")
    yaml_events(">\n a\n b\n\n c\n").should contain %(Scalar "a b\\nc\\n")
    yaml_events("- |2\n   a\n  b\n").should contain %(Scalar " a\\nb\\n")
    yaml_events("--- |\nzero\nindent\n").should contain %(Scalar "zero\\nindent\\n")
  end

  it_satisfies "YAML-8.2-block-collections", "reads block collections, compact nesting and explicit keys" do
    yaml_events("- a\n- - b\n  - c\n- k: v\n  l: w\n").should eq [
      "StreamStart", "DocumentStart", "SequenceStart", %(Scalar "a"), "SequenceStart", %(Scalar "b"), %(Scalar "c"),
      "SequenceEnd", "MappingStart", %(Scalar "k"), %(Scalar "v"), %(Scalar "l"), %(Scalar "w"), "MappingEnd",
      "SequenceEnd", "DocumentEnd", "StreamEnd",
    ]
    yaml_error { yaml_events("- a\n? x\n") }.should be_a(Mica::YAML::SyntaxError)
    yaml_events("? a\n: b\n? [c]\n: d\n: e\n").should eq [
      "StreamStart", "DocumentStart", "MappingStart", %(Scalar "a"), %(Scalar "b"), "SequenceStart", %(Scalar "c"),
      "SequenceEnd", %(Scalar "d"), %(Scalar ""), %(Scalar "e"), "MappingEnd", "DocumentEnd", "StreamEnd",
    ]
  end

  it_satisfies "YAML-7.4-flow-collections", "reads flow collections, single pairs and empty nodes" do
    yaml_events(%([a, b: c, {d: , : e}, "f":g, ::h])).should eq [
      "StreamStart", "DocumentStart", "SequenceStart", %(Scalar "a"), "MappingStart", %(Scalar "b"), %(Scalar "c"),
      "MappingEnd", "MappingStart", %(Scalar "d"), %(Scalar ""), %(Scalar ""), %(Scalar "e"), "MappingEnd",
      "MappingStart", %(Scalar "f"), %(Scalar "g"), "MappingEnd", %(Scalar "::h"), "SequenceEnd", "DocumentEnd",
      "StreamEnd",
    ]
    yaml_events("{ multi\n  line: value }").should contain %(Scalar "multi line")
  end

  it_satisfies "YAML-6.9-node-properties", "attaches anchors and tags and resolves tag handles" do
    events = yaml_events("%TAG !e! tag:example.com,2000:\n---\n- &a !!str x\n- !e!thing [y]\n- !local z\n- !<verbatim:tag> w\n- &b:c v\n")
    events.should contain %(Scalar &a <tag:yaml.org,2002:str> "x")
    events.should contain "SequenceStart <tag:example.com,2000:thing>"
    events.should contain %(Scalar <!local> "z")
    events.should contain %(Scalar <verbatim:tag> "w")
    events.should contain %(Scalar &b:c "v")
    error = yaml_error { yaml_events("!x!y z") }
    error.should be_a(Mica::YAML::SyntaxError)
    error.message.to_s.should contain "found undefined tag handle"
  end

  it_satisfies "YAML-6.8-directives", "reads %YAML and %TAG and ignores reserved directives" do
    parser = Mica::YAML::PullParser.new("%YAML 1.2\n%TAG !m! tag:mica,2026:\n%FOO bar\n--- a\n", limits: YAML_LIMITS, timeout: nil)
    parser.read_next
    parser.version_directive.should eq({1, 2})
    parser.list_of_tag_directives.should eq [{"!m!", "tag:mica,2026:"}]
    parser.implicit?.should be_false
    yaml_error { yaml_events("%YAML 1.2\n%YAML 1.2\n--- a\n") }.message.to_s.should contain "duplicate %YAML"
    yaml_error { yaml_events("%YAML 2.0\n--- a\n") }.message.to_s.should contain "incompatible"
    yaml_error { yaml_events("a: 1\n%YAML 1.2\n--- b\n") }.should be_a(Mica::YAML::SyntaxError)
  end

  it_satisfies "YAML-9-documents", "reads streams of documents, bare documents and markers" do
    yaml_events("a\n---\nb\n...\nc\n--- d\n").count("DocumentStart").should eq 4
    yaml_events("").should eq ["StreamStart", "StreamEnd"]
    yaml_events("# only a comment\n...\n").should eq ["StreamStart", "StreamEnd"]
    yaml_events("---\n").should eq ["StreamStart", "DocumentStart", %(Scalar ""), "DocumentEnd", "StreamEnd"]
    yaml_error { yaml_events("a\n... b\n") }.should be_a(Mica::YAML::SyntaxError)
  end

  it_satisfies "YAML-6.6-comments", "needs white space before a comment" do
    yaml_events("a: b # comment\n# line\nc: d#e\n").should contain %(Scalar "d#e")
    yaml_error { yaml_events(%(a: "b"# comment\n)) }.should be_a(Mica::YAML::SyntaxError)
    yaml_error { yaml_events("a: [b]#c\n") }.should be_a(Mica::YAML::SyntaxError)
  end

  it_satisfies "YAML-6.1-indentation", "takes tabs as separation and rejects them as indentation" do
    yaml_events("a:\t b\n").should contain %(Scalar "b")
    yaml_events("- a\n-\tb\n").should contain %(Scalar "b")
    yaml_error { yaml_events("a:\n\tb: c\n") }.should be_a(Mica::YAML::SyntaxError)
    yaml_error { yaml_events("-\t- a\n") }.should be_a(Mica::YAML::SyntaxError)
    yaml_error { yaml_events("a: [b,\nc]\n") }.message.to_s.should contain "indented less"
    yaml_error { yaml_events("a: \"b\nc\"\n") }.message.to_s.should contain "indented less"
  end

  it_satisfies "YAML-5.1-character-set", "rejects invalid UTF-8 and control characters where they stand" do
    error = yaml_error { yaml_events(Bytes[0x61, 0x3A, 0x20, 0xFF, 0x0A]) }
    error.should be_a(Mica::YAML::InvalidCharacterError)
    error.as(Mica::ParseError).byte_offset.should eq 3
    error = yaml_error { yaml_events("a: b\nc: \u0001\n") }
    error.should be_a(Mica::YAML::InvalidCharacterError)
    error.as(Mica::ParseError).line_number.should eq 2
    error.as(Mica::ParseError).column_number.should eq 4
    # Everything before the bad byte still parses.
    parser = Mica::YAML::PullParser.new("ok: 1\n---\n\u0007", limits: YAML_LIMITS, timeout: nil)
    5.times { parser.read_next }
    parser.kind.should eq Mica::YAML::EventKind::MappingEnd
  end

  it_satisfies "YAML-5.2-encodings", "reads UTF-16 and UTF-32 with and without a byte order mark" do
    expected = yaml_events("k: é😀\n")
    yaml_events(utf16("k: é😀\n", big_endian: true)).should eq expected
    yaml_events(utf16("k: é😀\n", big_endian: false)).should eq expected
    yaml_events(utf16("k: é😀\n", big_endian: false)[2..]).should eq expected
    mutator = Mica::Testing::ByteMutator.new(list_of_seeds: ["k: v".to_slice])
    yaml_events(mutator.utf32("k: é😀\n".to_slice, true)).should eq expected
    yaml_events(mutator.utf32("k: é😀\n".to_slice, false, with_mark: false)).should eq expected
    yaml_events(Bytes[0xEF, 0xBB, 0xBF, 0x61]).should contain %(Scalar "a")
  end

  it "reports where an error is and what was being read" do
    error = yaml_error { yaml_events("a:\n  b: 0\n  c: [1, 2\n") }
    error.should be_a(Mica::YAML::SyntaxError)
    syntax_error = error.as(Mica::YAML::SyntaxError)
    syntax_error.detail.should eq "did not find expected ',' or ']'"
    syntax_error.context.should eq "while parsing a flow sequence"
    syntax_error.line_number.should eq 4
    context_position = syntax_error.context_position
    context_position.should_not be_nil
    context_position.line.should eq 3 if context_position
  end

  it "rejects every proper prefix or accepts it, the same from bytes and from a trickling IO" do
    source = "a: &x [1, {b: \"c\\n\"}]\nd: |\n  e\nf: *x\n".to_slice
    (0...source.size).each do |length|
      prefix = source[0, length]
      from_bytes = begin
        yaml_events(prefix).join(',')
      rescue error : Mica::Error
        error.message.to_s
      end
      from_io = begin
        yaml_events(TrickleIO.new(prefix, 3)).join(',')
      rescue error : Mica::Error
        error.message.to_s
      end
      from_io.should eq from_bytes
    end
  end
end
