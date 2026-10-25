require "../spec_helper"
require "json"

private LIMITS = Mica::Form::Limits::REQUEST_BODY

private def pairs_of(input : String | Bytes | IO, limits : Mica::Form::Limits = LIMITS) : Array({String, String})
  Mica::Form::Pairs.parse(input, limits: limits).map { |pair| {pair.field_name, pair.field_value} }
end

# The outcome of parsing *input*, as a comparable string: the pairs, or
# the error class, message and offset.
private def outcome_of(input : String | Bytes | IO, limits : Mica::Form::Limits = LIMITS) : String
  pairs_of(input, limits).inspect
rescue error : Mica::ParseError
  "#{error.class} #{error.message} @#{error.byte_offset}"
end

# The offset of the first invalid UTF-8 sequence in *bytes*, by stdlib's
# Char::Reader (an oracle independent of Mica::Core::UTF8), or nil.
private def oracle_invalid_offset(bytes : Bytes) : Int32?
  reader = Char::Reader.new(String.new(bytes))
  while reader.has_next?
    return reader.pos if reader.error
    reader.next_char
  end
  nil
end

private def percent_encoded(bytes : Bytes) : String
  String.build { |io| bytes.each { |byte| io << '%' << byte.to_s(16, upcase: true).rjust(2, '0') } }
end

private struct WptFixture
  include JSON::Serializable

  getter source : String
  getter sha256 : String
  @[JSON::Field(key: "vectors")]
  getter list_of_vectors : Array(WptVector)
end

private struct WptVector
  include JSON::Serializable

  getter input : String
  # The expected pairs, each a [name, value] array.
  @[JSON::Field(key: "output")]
  getter list_of_expected_pairs : Array(Array(String))
end

describe Mica::Form::Pairs do
  describe ".parse" do
    it_satisfies "WHATWG-URL-5.1-split", "splits on & into sequences" do
      pairs_of("a=1&b=2&c=3").should eq([{"a", "1"}, {"b", "2"}, {"c", "3"}])
    end

    it_satisfies "WHATWG-URL-5.1-skip-empty", "skips empty sequences" do
      pairs_of("&&a=1&&&b=2&").should eq([{"a", "1"}, {"b", "2"}])
      pairs_of("").should be_empty
      pairs_of("&").should be_empty
    end

    it_satisfies "WHATWG-URL-5.1-first-equals", "splits at the first = only, and treats a sequence without = as a name" do
      pairs_of("a==b=c").should eq([{"a", "=b=c"}])
      pairs_of("flag").should eq([{"flag", ""}])
      pairs_of("=v").should eq([{"", "v"}])
      pairs_of("a=").should eq([{"a", ""}])
    end

    it_satisfies "WHATWG-URL-5.1-plus", "turns + into a space in names and values, and leaves an encoded + alone" do
      pairs_of("a+b=c+d+%2B").should eq([{"a b", "c d +"}])
    end

    it_satisfies "WHATWG-URL-5.1-percent-decode", "decodes %XX in either case and keeps a % without two hex digits" do
      pairs_of("%61%4d%4D=%7e").should eq([{"aMM", "~"}])
      pairs_of("a=%").should eq([{"a", "%"}])
      pairs_of("a=%4").should eq([{"a", "%4"}])
      pairs_of("a=%zz%%41").should eq([{"a", "%zz%A"}])
      pairs_of("a=%2%2a").should eq([{"a", "%2*"}])
    end

    it_satisfies "WHATWG-URL-5.1-utf8", "decodes UTF-8, keeps a leading BOM, and rejects invalid UTF-8 at its first byte" do
      pairs_of("caf%C3%A9=%F0%9F%98%80").should eq([{"café", "😀"}])
      pairs_of("%EF%BB%BFa=1").should eq([{"﻿a", "1"}])
      error = expect_raises(Mica::EncodingError, /Invalid UTF-8 in form value/) { pairs_of("ok=1&bad=x%C3%28") }
      error.byte_offset.should eq(10)
    end

    it_satisfies "WHATWG-URL-5.1-order", "keeps order and repeated names" do
      pairs = Mica::Form::Pairs.parse("a=1&b=2&a=3", limits: LIMITS)
      pairs.map(&.field_name).should eq(["a", "b", "a"])
      pairs.fetch_all("a").should eq(["1", "3"])
      pairs["a"].should eq("1")
      pairs["missing"]?.should be_nil
      expect_raises(KeyError) { pairs["missing"] }
      pairs.map(&.byte_offset).should eq([0_i64, 4_i64, 8_i64])
    end

    it_satisfies "WPT-URL-urlencoded-parser", "passes every web-platform-tests urlencoded vector, rejecting the U+FFFD ones at the predicted byte" do
      fixture = WptFixture.from_json(File.read(File.join(__DIR__, "../../conformance/form/wpt_urlencoded.json")))
      fixture.sha256.should eq("9d3514f33a6bce8ab4d0163a77d79f0231ef30239ca237cf75f9e206a8b0c3e8")
      fixture.list_of_vectors.size.should eq(35)
      rejected = {} of String => Int64
      fixture.list_of_vectors.each do |vector|
        expected = vector.list_of_expected_pairs.map { |pair| {pair[0], pair[1]} }
        if vector.list_of_expected_pairs.any?(&.any?(&.includes?('�')))
          error = expect_raises(Mica::EncodingError) { pairs_of(vector.input) }
          rejected[vector.input] = error.byte_offset
        else
          pairs_of(vector.input).should eq(expected)
        end
      end
      rejected.should eq({
        "%FE%FF"                           => 0_i64,
        "%FF%FE"                           => 0_i64,
        "%C2"                              => 0_i64,
        "%C2x"                             => 0_i64,
        "_charset_=windows-1252&test=%C2x" => 28_i64,
      })
    end
  end

  describe "limits" do
    it_satisfies "MICA-FORM-REQUIRED-LIMITS", "needs a non-blank reason for unbounded limits" do
      expect_raises(ArgumentError, "reason") { Mica::Form::Limits.unbounded(reason: " ") }
      limits = Mica::Form::Limits.unbounded(reason: "trusted fixture")
      limits.unbounded?.should be_true
      limits.unbounded_reason.should eq("trusted fixture")
      Mica::Form::Limits::REQUEST_BODY.unbounded?.should be_false
      pairs_of("a=1", limits).should eq([{"a", "1"}])
      expect_raises(ArgumentError, "max_pairs must not be negative") { Mica::Form::Limits.new(max_pairs: -1) }
      expect_raises(ArgumentError, "max_key_depth must be at least 1") { Mica::Form::Limits.new(max_key_depth: 0) }
    end

    it_satisfies "MICA-FORM-LIMIT-INPUT", "rejects input longer than max_input_bytes at that byte, from bytes and from a stream" do
      limits = Mica::Form::Limits.new(max_input_bytes: 10_i64)
      pairs_of("a=123456789", Mica::Form::Limits.new(max_input_bytes: 11_i64)).should eq([{"a", "123456789"}])
      input = "a=1234567890"
      [input, input.to_slice, IO::Memory.new(input), TrickleIO.new(input.to_slice, 3)].each do |source|
        error = expect_raises(Mica::LimitExceededError, "max_input_bytes (10)") { pairs_of(source, limits) }
        error.byte_offset.should eq(10)
      end
      large = "k=" + "v" * 150_000
      big_limits = Mica::Form::Limits.new(max_input_bytes: 100_000_i64)
      error = expect_raises(Mica::LimitExceededError, "max_input_bytes (100000)") { pairs_of(TrickleIO.new(large.to_slice, 4096), big_limits) }
      error.byte_offset.should eq(100_000)
      pairs_of(TrickleIO.new(large.to_slice, 4096)).should eq(pairs_of(large))
    end

    it_satisfies "MICA-FORM-LIMIT-PAIRS", "rejects more than max_pairs pairs at the first extra pair, not counting empty sequences" do
      limits = Mica::Form::Limits.new(max_pairs: 2)
      pairs_of("a=1&&&b=2&&", limits).size.should eq(2)
      error = expect_raises(Mica::LimitExceededError, "max_pairs (2)") { pairs_of("a=1&b=2&c=3", limits) }
      error.byte_offset.should eq(8)
    end

    it_satisfies "MICA-FORM-BUDGET", "stops at the work budget with a positioned WorkBudgetExceededError" do
      budget = Mica::Core::WorkBudget.new(operations_per_unit: 1, base_operations: 10)
      limits = Mica::Form::Limits.new(work_budget: budget)
      error = expect_raises(Mica::WorkBudgetExceededError) { pairs_of("a=b&" * 50, limits) }
      error.allowance.should be < error.operations
      pairs_of("a=b&" * 50).size.should eq(50)
    end

    it_satisfies "MICA-FORM-DEADLINE", "stops at an expired deadline" do
      limits = Mica::Form::Limits.new(work_budget: Mica::Core::WorkBudget.new(timeout: Time::Span.zero))
      expect_raises(Mica::DeadlineExceededError) { pairs_of("a=1", limits) }
    end
  end

  describe "hostile bytes" do
    it_satisfies "MICA-FORM-ENCODING-POSITION", "rejects every invalid hostile class at the byte an independent oracle predicts, raw or percent-encoded, in names and values" do
      checked = 0
      Mica::Testing::ByteMutator::HOSTILE.each do |label, list_of_sequences|
        list_of_sequences.each do |sequence|
          invalid = oracle_invalid_offset(sequence)
          raw_sequence = String.new(sequence)
          {
            {"x=1&n" + raw_sequence + "=v", 5, 1},
            {"x=1&n=v" + raw_sequence, 7, 1},
            {"x=1&n" + percent_encoded(sequence) + "=v", 5, 3},
            {"x=1&n=v" + percent_encoded(sequence), 7, 3},
          }.each do |input, start, width|
            # Raw & and = bytes would split the pair; none of the classes
            # holds one.
            if invalid
              error = expect_raises(Mica::EncodingError) { pairs_of(input) }
              {label, error.byte_offset}.should eq({label, start + invalid * width})
            else
              pairs_of(input).size.should eq(2)
            end
            checked += 1
          end
        end
      end
      checked.should be > 200
    end

    it_satisfies "MICA-FORM-STREAM-EQUIVALENCE", "gives identical results from a String, Bytes and a trickling IO for every prefix" do
      inputs = ["user%5Bname%5D=Ad%C3%A9+L&tags[]=a&&b=%zz%2", "a=%F0%9F%98%80&b=\xC3\x28&c=1", "x=" + "%41" * 30]
      inputs.each do |input|
        bytes = input.to_slice
        (0..bytes.size).each do |length|
          prefix = bytes[0, length]
          expected = outcome_of(prefix)
          outcome_of(String.new(prefix)).should eq(expected)
          (1..4).each { |chunk| outcome_of(TrickleIO.new(prefix, chunk)).should eq(expected) }
        end
      end
    end
  end

  describe "#to_s" do
    it_satisfies "WHATWG-URL-5.2-serialize", "serializes with the urlencoded percent-encode set" do
      pairs = Mica::Form::Pairs.new([Mica::Form::Pair.new("a b", "c&d=e"), Mica::Form::Pair.new("*-._~", "é\n")])
      pairs.to_s.should eq("a+b=c%26d%3De&*-._%7E=%C3%A9%0A")
      round_trip = Mica::Form::Pairs.parse(pairs.to_s, limits: LIMITS)
      round_trip.map { |pair| {pair.field_name, pair.field_value} }.should eq([{"a b", "c&d=e"}, {"*-._~", "é\n"}])
    end

    it_satisfies "WPT-URL-urlsearchparams-stringifier", "meets the web-platform-tests stringifier expectations" do
      serialize = ->(list : Array({String, String})) { Mica::Form::Pairs.new(list.map { |name, value| Mica::Form::Pair.new(name, value) }).to_s }
      reparse = ->(input : String) { Mica::Form::Pairs.parse(input, limits: LIMITS).to_s }
      serialize.call([{"a", "b c"}]).should eq("a=b+c")
      serialize.call([{"a b", "c"}]).should eq("a+b=c")
      serialize.call([{"a", ""}, {"a", ""}, {"", "b"}, {"", ""}, {"", ""}]).should eq("a=&a=&=b&=&=")
      serialize.call([{"", "b"}, {"", "b"}]).should eq("=b&=b")
      serialize.call([{"", ""}, {"", ""}]).should eq("=&=")
      serialize.call([{"a", "b+c"}]).should eq("a=b%2Bc")
      serialize.call([{"a+b", "c"}]).should eq("a%2Bb=c")
      serialize.call([{"=", "a"}, {"b", "="}]).should eq("%3D=a&b=%3D")
      serialize.call([{"&", "a"}, {"b", "&"}]).should eq("%26=a&b=%26")
      serialize.call([{"a", "*-._"}, {"*-._", "c"}]).should eq("a=*-._&*-._=c")
      serialize.call([{"a", "b%c"}, {"a%b", "c"}]).should eq("a=b%25c&a%25b=c")
      reparse.call("id=0&value=%").should eq("id=0&value=%25")
      serialize.call([{"a", "b\0c"}, {"a\0b", "c"}]).should eq("a=b%00c&a%00b=c")
      serialize.call([{"a", "b\u{1F4A9}c"}, {"a\u{1F4A9}b", "c"}]).should eq("a=b%F0%9F%92%A9c&a%F0%9F%92%A9b=c")
      reparse.call("a=b&c=d&&e&&").should eq("a=b&c=d&e=")
      reparse.call("a = b &a=b&c=d%20").should eq("a+=+b+&a=b&c=d+")
      reparse.call("a=&a=b").should eq("a=&a=b")
      reparse.call("b=%2sf%2a").should eq("b=%252sf*")
      reparse.call("b=%2%2af%2a").should eq("b=%252*f*")
      reparse.call("b=%%2a").should eq("b=%25*")
      reparse.call("a=b,c").should eq("a=b%2Cc")
      serialize.call([{"a\nb", "c\rd"}, {"e\n\rf", "g\r\nh"}]).should eq("a%0Ab=c%0Dd&e%0A%0Df=g%0D%0Ah")
    end
  end
end
