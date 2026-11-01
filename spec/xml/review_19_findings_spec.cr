require "../spec_helper"

# An IO that returns one byte per read, so refills split every line end.
private class ByteAtATime < IO
  def initialize(@bytes : Bytes)
    @index = 0
  end

  def read(slice : Bytes) : Int32
    return 0 if @index >= @bytes.size || slice.empty?
    slice[0] = @bytes[@index]
    @index += 1
    1
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

# Regression specs for the nineteenth Codex code review of 2026-10-24.
describe "Codex review 19 findings" do
  it "1: positions an input-size error after a CR LF split across refills" do
    options = Mica::XML::ParserOptions.new(max_input_bytes: 6_i64)
    error = expect_raises(Mica::LimitExceededError) do
      Mica::XML.parse(ByteAtATime.new("<r>ab\r\n</r>".to_slice), options)
    end
    error.byte_offset.should eq(6)
    error.position.line.should eq(2)
    error.position.column.should eq(1)
  end

  it "2: charges the walk to the first byte past the input limit" do
    text = "t" * 100_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    expect_raises(Mica::LimitExceededError) do
      Mica::XML.parse("<r>#{text}</r>", Mica::XML::ParserOptions.new(max_input_bytes: 90_000_i64), meter)
    end
    meter.operations.should be >= 90_000
  end

  it "4: keeps the byte mutator's mutation count small" do
    expect_raises(ArgumentError) { Mica::Testing::ByteMutator.new([Bytes[1]], max_mutations: 1_000) }
  end
end
