require "../spec_helper"
require "json"

private LIMITS = Mica::Form::Limits::REQUEST_BODY

private def browser_pairs_of(input : String | Bytes | IO, limits : Mica::Form::Limits = LIMITS) : Array({String, String})
  Mica::Form::Pairs.parse(input, limits: limits, invalid_utf8: :replace_like_browsers).map { |pair| {pair.field_name, pair.field_value} }
end

private def browser_outcome_of(input : String | Bytes | IO) : String
  pairs = Mica::Form::Pairs.parse(input, limits: LIMITS, invalid_utf8: :replace_like_browsers)
  "#{pairs.map { |pair| {pair.field_name, pair.field_value, pair.has_replaced_invalid_bytes?} }.inspect} #{pairs.has_replaced_invalid_bytes?}"
rescue error : Mica::ParseError
  "#{error.class} #{error.message} @#{error.byte_offset}"
end

private def percent_encoded(bytes : Bytes) : String
  String.build { |io| bytes.each { |byte| io << '%' << byte.to_s(16, upcase: true).rjust(2, '0') } }
end

private struct BrowserWptFixture
  include JSON::Serializable

  getter sha256 : String
  @[JSON::Field(key: "vectors")]
  getter list_of_vectors : Array(BrowserWptVector)
end

private struct BrowserWptVector
  include JSON::Serializable

  getter input : String
  @[JSON::Field(key: "output")]
  getter list_of_expected_pairs : Array(Array(String))

  def expects_replacement? : Bool
    list_of_expected_pairs.any?(&.any?(&.includes?('\u{FFFD}')))
  end
end

# The WHATWG Encoding Standard's UTF-8 decoder (section 9.1.1), written
# step for step as the standard gives it: an oracle independent of
# Mica::Core::UTF8's structure. It stays one method so it can be read
# against the standard line by line.
# ameba:disable Metrics/CyclomaticComplexity
private def whatwg_utf8_decode(bytes : Bytes) : String
  String.build do |io|
    code_point = 0
    bytes_seen = 0
    bytes_needed = 0
    lower_boundary = 0x80
    upper_boundary = 0xBF
    index = 0
    while index <= bytes.size
      if index == bytes.size
        io << '\u{FFFD}' if bytes_needed != 0
        break
      end
      byte = bytes[index].to_i32
      if bytes_needed == 0
        if byte <= 0x7F
          io << byte.chr
        elsif byte >= 0xC2 && byte <= 0xDF
          bytes_needed = 1
          code_point = byte & 0x1F
        elsif byte >= 0xE0 && byte <= 0xEF
          lower_boundary = 0xA0 if byte == 0xE0
          upper_boundary = 0x9F if byte == 0xED
          bytes_needed = 2
          code_point = byte & 0xF
        elsif byte >= 0xF0 && byte <= 0xF4
          lower_boundary = 0x90 if byte == 0xF0
          upper_boundary = 0x8F if byte == 0xF4
          bytes_needed = 3
          code_point = byte & 0x7
        else
          io << '\u{FFFD}'
        end
        index += 1
        next
      end
      unless byte >= lower_boundary && byte <= upper_boundary
        code_point = bytes_needed = bytes_seen = 0
        lower_boundary = 0x80
        upper_boundary = 0xBF
        io << '\u{FFFD}'
        # The byte is processed again as the start of a sequence.
        next
      end
      lower_boundary = 0x80
      upper_boundary = 0xBF
      code_point = (code_point << 6) | (byte & 0x3F)
      bytes_seen += 1
      index += 1
      next unless bytes_seen == bytes_needed
      io << code_point.chr
      code_point = bytes_needed = bytes_seen = 0
    end
  end
end

# Unicode 15 table 3-8 and the cases around each lead-byte range: the bytes
# and the text the WHATWG UTF-8 decoder (maximal subpart replacement)
# gives for them.
private MAXIMAL_SUBPART_CASES = [
  {Bytes[0x61, 0xF1, 0x80, 0x80, 0xE1, 0x80, 0xC2, 0x62, 0x80, 0x63, 0x80, 0xBF, 0x64],
   "a\u{FFFD}\u{FFFD}\u{FFFD}b\u{FFFD}c\u{FFFD}\u{FFFD}d"},
  {Bytes[0xC0, 0x80], "\u{FFFD}\u{FFFD}"},
  {Bytes[0xC1, 0xBF], "\u{FFFD}\u{FFFD}"},
  {Bytes[0xE0, 0x80, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}"},
  {Bytes[0xE0, 0xA0], "\u{FFFD}"},
  {Bytes[0xED, 0xA0, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}"},
  {Bytes[0xED, 0x9F, 0xBF], "\u{D7FF}"},
  {Bytes[0xF0, 0x80, 0x80, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"},
  {Bytes[0xF0, 0x9F, 0x98], "\u{FFFD}"},
  {Bytes[0xF0, 0x9F, 0x98, 0x41], "\u{FFFD}A"},
  {Bytes[0xF4, 0x8F, 0xBF, 0xBF], "\u{10FFFF}"},
  {Bytes[0xF4, 0x90, 0x80, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"},
  {Bytes[0xF5, 0x80], "\u{FFFD}\u{FFFD}"},
  {Bytes[0xFE, 0xFF], "\u{FFFD}\u{FFFD}"},
  {Bytes[0xE2, 0x82], "\u{FFFD}"},
  {Bytes[0xE2, 0x82, 0x41, 0xE2, 0x82, 0xAC], "\u{FFFD}A€"},
  {Bytes[0xC3, 0x28], "\u{FFFD}("},
  {Bytes[0xEF, 0xBB, 0xBF, 0x41], "\u{FEFF}A"},
  {Bytes[0xEF, 0xBF, 0xBD], "\u{FFFD}"},
]

describe Mica::Form::InvalidUTF8Handling do
  describe "default" do
    it_satisfies "MICA-FORM-INVALID-UTF8-DEFAULT", "rejects invalid UTF-8 by default with an error that gives the byte and names the opt-in" do
      error = expect_raises(Mica::EncodingError) { Mica::Form::Pairs.parse("ok=1&city=M%FCnchen", limits: LIMITS) }
      error.byte_offset.should eq(11)
      message = error.message.to_s
      message.should contain("Invalid UTF-8 in form value at byte 11")
      message.should contain("pass invalid_utf8: :replace_like_browsers to accept it the way browsers do (each invalid sequence becomes U+FFFD)")
      explicit = expect_raises(Mica::EncodingError) { Mica::Form::Pairs.parse("a=%FF", limits: LIMITS, invalid_utf8: :reject) }
      explicit.byte_offset.should eq(2)
      nested = expect_raises(Mica::EncodingError, /invalid_utf8: :replace_like_browsers/) { Mica::Form.parse("user[n%FF]=1", limits: LIMITS) }
      nested.byte_offset.should eq(6)
    end
  end

  describe "replace_like_browsers" do
    it_satisfies "WPT-URL-urlencoded-parser-browser-mode", "passes all 35 web-platform-tests urlencoded vectors, the 5 U+FFFD ones included" do
      fixture = BrowserWptFixture.from_json(File.read(File.join(__DIR__, "../../conformance/form/wpt_urlencoded.json")))
      fixture.sha256.should eq("9d3514f33a6bce8ab4d0163a77d79f0231ef30239ca237cf75f9e206a8b0c3e8")
      fixture.list_of_vectors.size.should eq(35)
      replaced = 0
      fixture.list_of_vectors.each do |vector|
        expected = vector.list_of_expected_pairs.map { |pair| {pair[0], pair[1]} }
        pairs = Mica::Form::Pairs.parse(vector.input, limits: LIMITS, invalid_utf8: :replace_like_browsers)
        {vector.input, pairs.map { |pair| {pair.field_name, pair.field_value} }}.should eq({vector.input, expected})
        {vector.input, pairs.has_replaced_invalid_bytes?}.should eq({vector.input, vector.expects_replacement?})
        if vector.expects_replacement?
          replaced += 1
          expect_raises(Mica::EncodingError) { Mica::Form::Pairs.parse(vector.input, limits: LIMITS) }
        end
      end
      replaced.should eq(5)
    end

    it_satisfies "WHATWG-URL-5.1-utf8-replace", "replaces each maximal subpart with one U+FFFD, raw or percent-encoded, in names and values" do
      MAXIMAL_SUBPART_CASES.each do |bytes, expected|
        Mica::Core::UTF8.replace_invalid_sequences_like_browsers(bytes).should eq(expected)
        browser_pairs_of("n=" + percent_encoded(bytes)).should eq([{"n", expected}])
        browser_pairs_of(percent_encoded(bytes) + "=v").should eq([{expected, "v"}])
        raw = Bytes.new(bytes.size + 2)
        raw[0] = 0x6E
        raw[1] = 0x3D
        bytes.copy_to(raw + 2)
        browser_pairs_of(raw).should eq([{"n", expected}]) unless bytes.includes?(0x26) || bytes.includes?(0x3D)
      end
    end

    it_satisfies "WHATWG-URL-5.1-utf8-replace", "agrees with the WHATWG UTF-8 decoder on every hostile byte class and on random bytes" do
      MAXIMAL_SUBPART_CASES.each { |bytes, expected| whatwg_utf8_decode(bytes).should eq(expected) }
      Mica::Testing::ByteMutator::HOSTILE.each do |label, list_of_sequences|
        list_of_sequences.each do |sequence|
          {label, Mica::Core::UTF8.replace_invalid_sequences_like_browsers(sequence)}.should eq({label, whatwg_utf8_decode(sequence)})
        end
      end
      random = Random.new(20261025)
      # Bytes drawn mostly from 0x80 to 0xFF, where the lead and
      # continuation ranges interact.
      20_000.times do
        bytes = Bytes.new(random.rand(1..8)) { random.rand(8) == 0 ? random.rand(0x80).to_u8 : (0x80 + random.rand(0x80)).to_u8 }
        {bytes, Mica::Core::UTF8.replace_invalid_sequences_like_browsers(bytes)}.should eq({bytes, whatwg_utf8_decode(bytes)})
      end
    end

    it_satisfies "MICA-FORM-INVALID-UTF8-PREDICATE", "reports replacement on the pair, the pairs, and every value node it reached" do
      pairs = Mica::Form::Pairs.parse("q=caf%E9&page=2", limits: LIMITS, invalid_utf8: :replace_like_browsers)
      pairs.has_replaced_invalid_bytes?.should be_true
      pairs.map(&.has_replaced_invalid_bytes?).should eq([true, false])
      clean = Mica::Form::Pairs.parse("q=caf%C3%A9&r=%EF%BF%BD", limits: LIMITS, invalid_utf8: :replace_like_browsers)
      clean.has_replaced_invalid_bytes?.should be_false
      clean["r"].should eq("\u{FFFD}")
      Mica::Form::Pairs.parse("q=1", limits: LIMITS).has_replaced_invalid_bytes?.should be_false

      value = Mica::Form.parse("user[city]=M%FCnchen&user[zip]=80331&page=2", limits: LIMITS, invalid_utf8: :replace_like_browsers)
      value.has_replaced_invalid_bytes?.should be_true
      value["user"].has_replaced_invalid_bytes?.should be_true
      value["user"]["city"].as_s.should eq("M\u{FFFD}nchen")
      value["user"]["city"].has_replaced_invalid_bytes?.should be_true
      value["user"]["zip"].has_replaced_invalid_bytes?.should be_false
      value["page"].has_replaced_invalid_bytes?.should be_false
      name_only = Mica::Form.parse("tags[]=a&t%FFg=b", limits: LIMITS, invalid_utf8: :replace_like_browsers)
      name_only.has_replaced_invalid_bytes?.should be_true
      name_only["t\u{FFFD}g"].has_replaced_invalid_bytes?.should be_true
      name_only["tags"].has_replaced_invalid_bytes?.should be_false
      Mica::Form.parse("a=1", limits: LIMITS, invalid_utf8: :replace_like_browsers).has_replaced_invalid_bytes?.should be_false
    end

    it "keeps equal values equal as hash keys whatever their marks" do
      replaced = Mica::Form.parse("a=%FF", limits: LIMITS, invalid_utf8: :replace_like_browsers)
      written = Mica::Form.parse("a=%EF%BF%BD", limits: LIMITS)
      replaced.should eq(written)
      replaced.hash.should eq(written.hash)
      {written => 1}[replaced]?.should eq(1)
    end

    it_satisfies "MICA-FORM-INVALID-UTF8-PREDICATE", "keeps the mark on a node once a replaced pair reached it, whichever value wins" do
      replaced_then_clean = Mica::Form.parse("u[a]=%FF&u[a]=ok", limits: LIMITS, invalid_utf8: :replace_like_browsers)
      replaced_then_clean["u"]["a"].as_s.should eq("ok")
      replaced_then_clean["u"]["a"].has_replaced_invalid_bytes?.should be_true
      replaced_then_clean["u"].has_replaced_invalid_bytes?.should be_true
      replaced_then_clean.has_replaced_invalid_bytes?.should be_true
      clean_then_replaced = Mica::Form.parse("u[a]=ok&u[a]=%FF", limits: LIMITS, invalid_utf8: :replace_like_browsers)
      clean_then_replaced["u"]["a"].as_s.should eq("\u{FFFD}")
      clean_then_replaced["u"]["a"].has_replaced_invalid_bytes?.should be_true
      clean_then_replaced["u"].has_replaced_invalid_bytes?.should be_true
    end

    it_satisfies "MICA-FORM-INVALID-UTF8-NESTED", "rejects invalid UTF-8 in pairs built in code by default and replaces it on request" do
      list_of_pairs = [Mica::Form::Pair.new("user[name]", String.new(Bytes[0x41, 0xFF]), 7_i64)]
      error = expect_raises(Mica::EncodingError, /value at byte 1 of the value; pass invalid_utf8: :replace_like_browsers/) do
        Mica::Form::NestedKeys.build(list_of_pairs, limits: LIMITS)
      end
      error.byte_offset.should eq(7)
      expect_raises(Mica::EncodingError, /form name/) do
        Mica::Form::NestedKeys.build([Mica::Form::Pair.new(String.new(Bytes[0xC3]), "v")], limits: LIMITS)
      end
      value = Mica::Form::NestedKeys.build(list_of_pairs, limits: LIMITS, invalid_utf8: :replace_like_browsers)
      value["user"]["name"].as_s.should eq("A\u{FFFD}")
      value.has_replaced_invalid_bytes?.should be_true
      value["user"]["name"].has_replaced_invalid_bytes?.should be_true
    end

    it_satisfies "MICA-FORM-INVALID-UTF8-LIMITS", "counts input bytes before replacement, in Pairs and in NestedKeys" do
      # Eight raw 0xFF bytes become 24 bytes of U+FFFD.
      input = Bytes.new(10, 0xFF_u8)
      input[0] = 0x61
      input[1] = 0x3D
      limits = Mica::Form::Limits.new(max_input_bytes: 10)
      value = Mica::Form.parse(input, limits: limits, invalid_utf8: :replace_like_browsers)
      value["a"].as_s.should eq("\u{FFFD}" * 8)
      pairs = Mica::Form::Pairs.parse(input, limits: limits, invalid_utf8: :replace_like_browsers)
      Mica::Form::NestedKeys.build(pairs, limits: limits)["a"].as_s.bytesize.should eq(24)
      longer = Bytes.new(11, 0xFF_u8)
      error = expect_raises(Mica::LimitExceededError, /max_input_bytes/) do
        Mica::Form.parse(longer, limits: limits, invalid_utf8: :replace_like_browsers)
      end
      error.byte_offset.should eq(10)
      # A pair without the replacement mark counts every byte it holds.
      expect_raises(Mica::LimitExceededError, /max_input_bytes/) do
        Mica::Form::NestedKeys.build([Mica::Form::Pair.new("a", "\u{FFFD}" * 4)], limits: limits)
      end
      # A truncated 4-byte sequence is 3 decoded bytes that become one
      # 3-byte U+FFFD: the pair counts its exact size before replacement.
      truncated = Mica::Form::Pairs.parse("a=\xF0\x9F\x98", limits: LIMITS, invalid_utf8: :replace_like_browsers)
      truncated.list_of_pairs.first.byte_size_before_replacement.should eq(4)
      Mica::Form::NestedKeys.build(truncated, limits: Mica::Form::Limits.new(max_input_bytes: 4))["a"].as_s.should eq("\u{FFFD}")
      expect_raises(Mica::LimitExceededError, /max_input_bytes/) do
        Mica::Form::NestedKeys.build(truncated, limits: Mica::Form::Limits.new(max_input_bytes: 3))
      end
      # Building from replaced pairs records their input units before it
      # charges the scan of the larger replaced text, so the default
      # budget holds.
      wide = Bytes.new(400_002, 0xFF_u8)
      wide[0] = 0x61
      wide[1] = 0x3D
      wide_pairs = Mica::Form::Pairs.parse(wide, limits: LIMITS, invalid_utf8: :replace_like_browsers)
      Mica::Form::NestedKeys.build(wide_pairs, limits: LIMITS)["a"].as_s.bytesize.should eq(1_200_000)
      # Code outside Mica cannot build a pair that claims a smaller size.
      expect_raises(ArgumentError, "Only Mica's form decoding") do
        Mica::Form::Pair.new("a", "x" * 11, 0_i64, byte_size_before_replacement: 1_i64, seal: Reference.new)
      end
    end

    it_satisfies "MICA-FORM-STREAM-EQUIVALENCE", "gives identical replaced results from a String, Bytes and a trickling IO for every prefix" do
      input = "a=%F0%9F%98&b=\xC3\x28&c=\xE2\x82&d=%FF%C3%A9"
      bytes = input.to_slice
      (0..bytes.size).each do |length|
        prefix = bytes[0, length]
        expected = browser_outcome_of(prefix)
        browser_outcome_of(String.new(prefix)).should eq(expected)
        (1..4).each { |chunk| browser_outcome_of(TrickleIO.new(prefix, chunk)).should eq(expected) }
      end
    end
  end
end
