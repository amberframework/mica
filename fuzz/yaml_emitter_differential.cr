# Release-build differential campaign of Mica::YAML::Emitter against
# libyaml's emitter, driven through the standard library's YAML::Builder.
#
#   crystal-alpha build --release fuzz/yaml_emitter_differential.cr -o bin/yaml_emitter_differential
#   bin/yaml_emitter_differential SEED ITERATIONS [FIRST]
#
# Every case is one sequence of emitter events built from a seed and an
# iteration number, so it replays as SEED:ITERATION
# (`yaml_emitter_differential SEED 1 ITERATION`). The sequence goes to both
# emitters; the case passes when both write the same bytes, or both raise
# at the same event with the same libyaml problem text after writing the
# same bytes.
#
# Half of the cases use only what YAML::Builder's public methods can say
# (a scalar's implicit flags and a collection's implicit flag follow from
# its tag, and a document always ends implicitly). The other half sets
# every flag freely through the same libyaml calls the Builder makes. One
# case in 25 is an event sequence in an invalid order, and a few percent of
# all anchors and tags are ones libyaml rejects, to compare the errors.
#
# Anchors, tags and values always pass libyaml's UTF-8 check: its event
# initializers reject anything else, YAML::Builder ignores their return
# value and then emits whatever its event struct held before, so that
# input has no defined libyaml output to compare with.
#
# Prints `cases=N identical=N both_raised=N disagreements=N` and one
# `FAIL seed:iteration` line per disagreement with both results inspected.
# Exits 1 when any disagreement was found.
require "yaml"
require "../src/mica/yaml/emitter"

module YAMLEmitterDifferential
  enum OpKind
    StreamStart
    StreamEnd
    DocumentStart
    DocumentEnd
    Scalar
    SequenceStart
    SequenceEnd
    MappingStart
    MappingEnd
    Alias
  end

  # One emitter call. *implicit* is the document's, the collection's or the
  # scalar's plain implicit flag; *style* is the value of the scalar,
  # sequence or mapping style enum (they are numbered alike in the standard
  # library and in Mica).
  record Op,
    kind : OpKind,
    value : String = "",
    anchor : String? = nil,
    tag : String? = nil,
    implicit : Bool = true,
    quoted_implicit : Bool = true,
    style : Int32 = 0

  # What one emitter did with a case: the bytes it wrote, and the problem
  # and the index of the event it raised on, if it raised.
  record Outcome, output : String, problem : String?, failed_at : Int32

  # YAML::Builder plus the libyaml calls its public methods leave out: a
  # scalar or collection whose implicit flags do not follow from its tag,
  # and an explicit document end.
  class Oracle < ::YAML::Builder
    def raw_scalar(op : Op) : Nil
      anchor = op.anchor
      tag = op.tag
      LibYAML.yaml_scalar_event_initialize(pointerof(@event),
        anchor ? anchor.to_unsafe : Pointer(UInt8).null,
        tag ? tag.to_unsafe : Pointer(UInt8).null,
        op.value, op.value.bytesize, op.implicit ? 1 : 0, op.quoted_implicit ? 1 : 0,
        ::YAML::ScalarStyle.from_value(op.style))
      yaml_emit("scalar")
    end

    def raw_start_sequence(op : Op) : Nil
      anchor = op.anchor
      tag = op.tag
      LibYAML.yaml_sequence_start_event_initialize(pointerof(@event),
        anchor ? anchor.to_unsafe : Pointer(UInt8).null,
        tag ? tag.to_unsafe : Pointer(UInt8).null,
        op.implicit ? 1 : 0, ::YAML::SequenceStyle.from_value(op.style))
      yaml_emit("sequence_start")
    end

    def raw_start_mapping(op : Op) : Nil
      anchor = op.anchor
      tag = op.tag
      LibYAML.yaml_mapping_start_event_initialize(pointerof(@event),
        anchor ? anchor.to_unsafe : Pointer(UInt8).null,
        tag ? tag.to_unsafe : Pointer(UInt8).null,
        op.implicit ? 1 : 0, ::YAML::MappingStyle.from_value(op.style))
      yaml_emit("mapping_start")
    end

    def raw_end_document(implicit : Bool) : Nil
      LibYAML.yaml_document_end_event_initialize(pointerof(@event), implicit ? 1 : 0)
      yaml_emit("document_end")
    end

    # STREAM-END without the flush `end_stream` adds.
    def raw_end_stream : Nil
      LibYAML.yaml_stream_end_event_initialize(pointerof(@event))
      yaml_emit("stream_end")
    end

    # Writes libyaml's buffer to the IO, also after an error.
    def flush_emitter : Nil
      LibYAML.yaml_emitter_flush(@emitter)
    end
  end

  WORDS = %w[
    a b foo bar baz yaml mica lorem ipsum dolor sit amet consectetur
    adipiscing elit true false null Null NULL ~ yes no on off y n True FALSE
    0 1 123 -1 +2 3.14 1e3 0x1F 0o17 .inf -.inf .nan 1_000 2001-01-01 12:30:45
    << = key value x-y x_y a.b http://example.com/path?q=1 a:b a#b
  ]

  ATOMS = [
    " ", " ", " ", "  ", "   ", "\t", "\n", "\n", "\n\n", "\r", "\r\n", "\n ", " \n",
    "\u0085", "\u2028", "\u2029", "\uFEFF", "\u00A0",
    "#", " #", "# ", ": ", ":", " :", "- ", "-", "? ", "?", "---", "...", "--- ", "... ",
    "'", "''", "\"", "\\", "\\n", "[", "]", "{", "}", ",", ", ", "&", "*", "!", "!!", "|", ">", "%", "@", "`",
    "é", "ü", "ß", "日本語", "한", "😀", "𝄞", "\u{10000}", "\u{10FFFF}",
    "\u0000", "\u0001", "\u0007", "\b", "\v", "\f", "\u001B", "\u007F", "\u0080", "\u009F",
    "\uD7FF", "\uE000", "\uFFFD", "\uFFFE", "\uFFFF",
  ]

  # Code point ranges around the edges of libyaml's printable, line break
  # and escape classes.
  CLASS_EDGES = [
    0x00..0x20, 0x7E..0xA1, 0x2027..0x202A, 0xD7FE..0xD7FF, 0xE000..0xE001, 0xFEFE..0xFF00,
    0xFFFC..0xFFFF, 0x10000..0x10001, 0x10FFFE..0x10FFFF,
  ]

  # Byte sequences libyaml's `yaml_check_utf8` accepts although they are
  # not UTF-8: an encoded surrogate and values above U+10FFFF.
  LENIENT_SEQUENCES = [
    String.new(Bytes[0xED, 0xA0, 0x80]), String.new(Bytes[0xED, 0xBF, 0xBF]),
    String.new(Bytes[0xF4, 0x90, 0x80, 0x80]), String.new(Bytes[0xF7, 0xBF, 0xBF, 0xBF]),
  ]

  EDGES = [
    " ", "  ", "\t", "\n", "\n\n", "\r\n", "\r", "\u0085", "\u2028", "\u2029", "\uFEFF", "- ", "? ", ": ", "# ", " #",
    "---", "...", "-", "?", ":", "'", "\"", "!", "&", "*", "|", ">", "%", "@", "`", "[", "{", ",", "\u0000",
  ]

  # The ways a generated line ends, weighted toward LF.
  LINE_ENDS = [
    "\n", "\n", "\n", "\n", "\n", "\n", "\n", "\n", "\n\n", "\n\n", "\r\n", "\r", "\u0085", "\u2028", "\u2029", "",
  ]

  ANCHORS = %w[a b anchor A1 x-y x_y 0 node-1 a-rather-long-anchor-name-that-keeps-going-and-going-and-going-on]

  ODD_ANCHORS = ["", " ", "a b", "é", "a.b", "a*", "a\u0000b", "\u0000", "a\n", "日本", "😀"]

  TAGS = [
    "!local", "!", "!!", "!!str", "!!int", "!!map", "!!seq", "tag:yaml.org,2002:str", "tag:yaml.org,2002:",
    "tag:yaml.org,2002:int", "tag:yaml.org,2002:a b", "tag:example.com,2000:app/foo", "!a!b", "!e!tag%21",
    "foo", "foo bar", "!é", "!日本", "!😀", "!a b", "!<x>", "!{x}", "!#", "!a,b[c]", "!~*'()", "!\t", "!\n",
    "x", "-", "!a\u0000b", "!tag-" + "long" * 40, "tag:yaml.org,2002:" + "x" * 130,
  ]

  ODD_TAGS = ["", "\u0000", "\u0000abc"]

  # Builds the event sequence of one case.
  class Generator
    def initialize(@random : Random, @stdlib_shaped : Bool)
      @ops = [] of Op
    end

    # Generates a whole stream. *invalid* shuffles the result into an
    # order, or toward names, the emitters reject.
    def generate(invalid : Bool) : Array(Op)
      shape = @random.rand(300)
      @ops << Op.new(OpKind::StreamStart)
      if shape == 0
        large_document
      else
        depth_limit = shape < 6 ? 20 + @random.rand(30) : 1 + @random.rand(6)
        document_count = pick_weighted({0 => 4, 1 => 70, 2 => 18, 3 => 8})
        document_count.times { document(depth_limit) }
      end
      @ops << Op.new(OpKind::StreamEnd)
      spoil if invalid
      @ops
    end

    private def pick_weighted(weights : Hash(Int32, Int32)) : Int32
      roll = @random.rand(weights.each_value.sum)
      weights.each do |value, weight|
        return value if roll < weight
        roll -= weight
      end
      weights.first_key
    end

    private def chance(percent : Int32) : Bool
      @random.rand(100) < percent
    end

    private def document(depth_limit : Int32) : Nil
      @ops << Op.new(OpKind::DocumentStart, implicit: chance(40))
      node(depth_limit)
      @ops << Op.new(OpKind::DocumentEnd, implicit: @stdlib_shaped || chance(65))
    end

    # A document large enough to pass the 16 KiB output buffer several
    # times, with multi-byte characters landing on its boundary.
    private def large_document : Nil
      @ops << Op.new(OpKind::DocumentStart, implicit: chance(40))
      flow = chance(30)
      @ops << Op.new(OpKind::SequenceStart, style: flow ? 2 : 0)
      (300 + @random.rand(900)).times do
        if chance(15)
          node(2)
        else
          scalar
        end
      end
      @ops << Op.new(OpKind::SequenceEnd)
      @ops << Op.new(OpKind::DocumentEnd, implicit: @stdlib_shaped || chance(65))
    end

    private def node(depth_left : Int32) : Nil
      roll = @random.rand(100)
      if depth_left <= 0 || roll < 52
        scalar
      elsif roll < 57
        @ops << Op.new(OpKind::Alias, anchor: anchor_name)
      elsif roll < 79
        sequence(depth_left)
      else
        mapping(depth_left)
      end
    end

    private def anchor_name : String
      chance(2) ? ODD_ANCHORS.sample(@random) : ANCHORS.sample(@random)
    end

    private def optional_anchor : String?
      chance(12) ? anchor_name : nil
    end

    private def optional_tag : String?
      return nil unless chance(14)
      chance(3) ? ODD_TAGS.sample(@random) : TAGS.sample(@random)
    end

    private def child_count(depth_left : Int32) : Int32
      return 1 if depth_left > 8
      pick_weighted({0 => 16, 1 => 26, 2 => 26, 3 => 16, 4 => 8, 6 => 5, 12 => 3})
    end

    private def collection_implicit(tag : String?) : Bool
      return tag.nil? if @stdlib_shaped
      chance(50)
    end

    private def sequence(depth_left : Int32) : Nil
      tag = optional_tag
      @ops << Op.new(OpKind::SequenceStart, anchor: optional_anchor, tag: tag,
        implicit: collection_implicit(tag), style: @random.rand(3))
      child_count(depth_left).times { node(depth_left - 1) }
      @ops << Op.new(OpKind::SequenceEnd)
    end

    private def mapping(depth_left : Int32) : Nil
      tag = optional_tag
      @ops << Op.new(OpKind::MappingStart, anchor: optional_anchor, tag: tag,
        implicit: collection_implicit(tag), style: @random.rand(3))
      child_count(depth_left).times do
        # Keys are any node, but lean toward the short scalars real
        # mappings use.
        if chance(60)
          scalar
        else
          node(depth_left - 1)
        end
        node(depth_left - 1)
      end
      @ops << Op.new(OpKind::MappingEnd)
    end

    private def scalar : Nil
      tag = optional_tag
      plain_implicit = tag.nil?
      quoted_implicit = tag.nil?
      unless @stdlib_shaped
        roll = @random.rand(100)
        if roll < 60
          plain_implicit = quoted_implicit = true
        elsif roll < 75
          plain_implicit = true
          quoted_implicit = false
        elsif roll < 90
          plain_implicit = false
          quoted_implicit = true
        elsif tag || chance(4)
          plain_implicit = quoted_implicit = false
        end
      end
      @ops << Op.new(OpKind::Scalar, value: scalar_value, anchor: optional_anchor, tag: tag,
        implicit: plain_implicit, quoted_implicit: quoted_implicit, style: @random.rand(6))
    end

    # A fixed atom, or a character from around the edges of libyaml's
    # character classes, or any character at all.
    private def atom : String
      roll = @random.rand(100)
      return ATOMS.sample(@random) if roll < 80
      return LENIENT_SEQUENCES.sample(@random) if roll < 82
      range = roll < 94 ? CLASS_EDGES.sample(@random) : (0..0x10FFFF)
      code_point = @random.rand(range)
      code_point = 0xFFFD if 0xD800 <= code_point <= 0xDFFF
      code_point.chr.to_s
    end

    private def word : String
      WORDS.sample(@random)
    end

    private def separator : String
      roll = @random.rand(100)
      if roll < 70
        " "
      elsif roll < 80
        "  "
      elsif roll < 88
        "\n"
      elsif roll < 91
        ""
      else
        atom
      end
    end

    private def scalar_value : String
      roll = @random.rand(100)
      text =
        if roll < 6
          ""
        elsif roll < 18
          chance(50) ? word : atom
        elsif roll < 60
          phrase(1 + @random.rand(6))
        elsif roll < 80
          phrase(10 + @random.rand(50))
        elsif roll < 88
          unbroken_run
        else
          lines
        end
      text = EDGES.sample(@random) + text if chance(12)
      text += EDGES.sample(@random) if chance(12)
      text
    end

    private def phrase(length : Int32) : String
      String.build do |io|
        length.times do |index|
          io << separator unless index == 0
          io << (chance(85) ? word : atom)
        end
      end
    end

    # A run with no space to fold at, usually longer than the line width.
    private def unbroken_run : String
      String.build do |io|
        (5 + @random.rand(60)).times do
          io << (chance(92) ? word : atom.strip(' '))
        end
      end
    end

    private def lines : String
      String.build do |io|
        (1 + @random.rand(6)).times do
          io << " " * @random.rand(4) if chance(20)
          io << phrase(@random.rand(25)) unless chance(15)
          io << " " * @random.rand(3) if chance(10)
          io << LINE_ENDS.sample(@random)
        end
      end
    end

    # Turns the valid sequence into one that is likely rejected: an event
    # removed, repeated, moved or added, or a name the emitters refuse.
    private def spoil : Nil
      (1 + @random.rand(2)).times do
        index = @random.rand(@ops.size)
        case @random.rand(6)
        when 0
          @ops.delete_at(index)
        when 1
          @ops.insert(index, @ops[index])
        when 2
          other = @random.rand(@ops.size)
          @ops.swap(index, other)
        when 3
          @ops.insert(index, Op.new(OpKind.from_value(@random.rand(OpKind.values.size)), anchor: "a"))
        when 4
          @ops.insert(index, Op.new(OpKind::Alias, anchor: ODD_ANCHORS.sample(@random)))
        else
          @ops.insert(index, Op.new(OpKind::Scalar, value: word, anchor: ODD_ANCHORS.sample(@random),
            tag: ODD_TAGS.sample(@random), implicit: false, quoted_implicit: false))
        end
        break if @ops.empty?
      end
    end
  end

  # Returns the events of case *seed*:*iteration*.
  def self.build_case(seed : UInt64, iteration : UInt64) : Array(Op)
    random = Random::PCG32.new(seed, iteration)
    stdlib_shaped = random.rand(2) == 0
    invalid = random.rand(25) == 0
    Generator.new(random, stdlib_shaped).generate(invalid)
  end

  # Returns true when YAML::Builder's public method for *op* passes
  # libyaml the same flags *op* carries.
  private def self.builder_can_say?(op : Op) : Bool
    follows_tag = op.implicit == op.tag.nil?
    case op.kind
    when .scalar?                          then follows_tag && op.quoted_implicit == op.implicit
    when .sequence_start?, .mapping_start? then follows_tag
    when .document_end?                    then op.implicit
    else                                        true
    end
  end

  private def self.apply(oracle : Oracle, op : Op, stream_started : Bool) : Nil
    public_call = builder_can_say?(op)
    case op.kind
    in .stream_start?   then oracle.start_stream
    in .stream_end?     then stream_started ? oracle.end_stream : oracle.raw_end_stream
    in .document_start? then oracle.start_document(implicit_start_indicator: op.implicit)
    in .document_end?   then public_call ? oracle.end_document : oracle.raw_end_document(op.implicit)
    in .scalar?
      if public_call
        oracle.scalar(op.value, op.anchor, op.tag, ::YAML::ScalarStyle.from_value(op.style))
      else
        oracle.raw_scalar(op)
      end
    in .sequence_start?
      if public_call
        oracle.start_sequence(op.anchor, op.tag, ::YAML::SequenceStyle.from_value(op.style))
      else
        oracle.raw_start_sequence(op)
      end
    in .sequence_end? then oracle.end_sequence
    in .mapping_start?
      if public_call
        oracle.start_mapping(op.anchor, op.tag, ::YAML::MappingStyle.from_value(op.style))
      else
        oracle.raw_start_mapping(op)
      end
    in .mapping_end? then oracle.end_mapping
    in .alias?       then oracle.alias(op.anchor || "")
    end
  end

  private def self.apply(emitter : Mica::YAML::Emitter, op : Op) : Nil
    case op.kind
    in .stream_start?   then emitter.stream_start
    in .stream_end?     then emitter.stream_end
    in .document_start? then emitter.document_start(implicit: op.implicit)
    in .document_end?   then emitter.document_end(implicit: op.implicit)
    in .scalar?
      emitter.scalar(op.value, anchor: op.anchor, tag: op.tag, plain_implicit: op.implicit,
        quoted_implicit: op.quoted_implicit, style: Mica::YAML::ScalarStyle.from_value(op.style))
    in .sequence_start?
      emitter.sequence_start(anchor: op.anchor, tag: op.tag, implicit: op.implicit,
        style: Mica::YAML::SequenceStyle.from_value(op.style))
    in .sequence_end? then emitter.sequence_end
    in .mapping_start?
      emitter.mapping_start(anchor: op.anchor, tag: op.tag, implicit: op.implicit,
        style: Mica::YAML::MappingStyle.from_value(op.style))
    in .mapping_end? then emitter.mapping_end
    in .alias?       then emitter.alias(op.anchor || "")
    end
  end

  # Runs *ops* through libyaml and returns what it wrote, stopping at the
  # first event it rejects.
  def self.run_libyaml(ops : Array(Op)) : Outcome
    io = IO::Memory.new
    oracle = Oracle.new(io)
    oracle.max_nesting = Int32::MAX
    problem = nil
    failed_at = -1
    # libyaml asserts on a flush before it has processed STREAM-START, and
    # YAML::Builder#end_stream flushes. A stream that opens with
    # DOCUMENT-START, SEQUENCE-START or MAPPING-START sits in the look-ahead
    # queue unprocessed, so such a case is run without flushes.
    first = ops.first?
    stream_started = !first.nil? && first.kind.stream_start?
    ops.each_with_index do |op, index|
      apply(oracle, op, stream_started)
    rescue error : ::YAML::Error
      message = error.message || ""
      separator = message.index(": ")
      problem = separator ? message[(separator + 2)..] : message
      failed_at = index
      break
    end
    oracle.flush_emitter if stream_started
    oracle.close
    Outcome.new(io.to_s, problem, failed_at)
  end

  # Runs *ops* through Mica and returns what it wrote, stopping at the
  # first event it rejects.
  def self.run_mica(ops : Array(Op)) : Outcome
    io = IO::Memory.new
    emitter = Mica::YAML::Emitter.new(io)
    problem = nil
    failed_at = -1
    ops.each_with_index do |op, index|
      apply(emitter, op)
    rescue error : Mica::YAML::EmitError
      problem = error.message || ""
      failed_at = index
      break
    end
    emitter.flush
    Outcome.new(io.to_s, problem, failed_at)
  end
end

usage = "usage: yaml_emitter_differential SEED ITERATIONS [FIRST]"
seed = (ARGV[0]? || abort(usage)).to_u64
iterations = (ARGV[1]? || abort(usage)).to_u64
first = (ARGV[2]? || "0").to_u64

show_events = !ENV["YAML_EMITTER_SHOW_EVENTS"]?.nil?
identical = 0_u64
problems = Hash(String, UInt64).new(0_u64)
both_raised = 0_u64
disagreements = 0_u64
output_bytes = 0_u64
started = Time.instant

iterations.times do |offset|
  iteration = first + offset
  ops = YAMLEmitterDifferential.build_case(seed, iteration)
  ops.each { |op| STDERR.puts "  #{op}" } if show_events && iterations == 1
  expected = YAMLEmitterDifferential.run_libyaml(ops)
  actual = YAMLEmitterDifferential.run_mica(ops)
  output_bytes += expected.output.bytesize
  if expected == actual
    if problem = expected.problem
      both_raised += 1
      problems[problem] += 1
    else
      identical += 1
    end
  else
    disagreements += 1
    if disagreements <= 50
      puts "FAIL #{seed}:#{iteration}"
      puts "  events:  #{ops.size}"
      puts "  libyaml: #{expected.output.inspect} problem=#{expected.problem.inspect} at=#{expected.failed_at}"
      puts "  mica:    #{actual.output.inspect} problem=#{actual.problem.inspect} at=#{actual.failed_at}"
    end
  end
end

puts "cases=#{iterations} identical=#{identical} both_raised=#{both_raised} disagreements=#{disagreements}"
STDERR.puts "seed=#{seed} first=#{first} output_bytes=#{output_bytes} seconds=#{(Time.instant - started).total_seconds.round(1)}"
if ENV["YAML_EMITTER_SHOW_PROBLEMS"]?
  problems.to_a.sort_by { |(_, count)| count }.reverse_each { |(problem, count)| STDERR.puts "#{count}\t#{problem}" }
end
exit 1 if disagreements > 0
