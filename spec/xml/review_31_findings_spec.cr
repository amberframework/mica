require "../spec_helper"

# An IO that returns at most one byte per read, so every token crosses
# buffer refills.
private class TrickleIO < IO
  def initialize(@bytes : Bytes)
    @pos = 0
  end

  def read(slice : Bytes) : Int32
    return 0 if @pos >= @bytes.size || slice.empty?
    slice[0] = @bytes[@pos]
    @pos += 1
    1
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

# Regression specs for the thirty-first Codex code review of 2026-10-24.
describe "Codex review 31 findings" do
  it "3: points a duplicate attribute at its name across buffer refills" do
    # Comment lengths that place the tag across the end of the first
    # buffers, so a refill moves it while its attributes are scanned.
    (Mica::Core::ByteInput::INITIAL_BUFFER_SIZE - 24..Mica::Core::ByteInput::INITIAL_BUFFER_SIZE + 8).each do |length|
      prefix = "<!--#{"c" * (length - 7)}-->"
      xml = "#{prefix}<r a='1' a='2'/>"
      error = expect_raises(Mica::ParseError, /appears twice/) { Mica::XML.parse(TrickleIO.new(xml.to_slice)) }
      error.byte_offset.should eq(prefix.bytesize + 9)
    end
  end

  it "6: keeps a limit error from checking a builder's internal subset" do
    subset = "<!ENTITY #{"n" * 60_000} 'x'>"
    expect_raises(Mica::LimitExceededError, /max_name_bytes/) do
      Mica::XML.build(&.dtd("r", nil, nil, subset))
    end
    expect_raises(Mica::XML::BuilderError, /Invalid internal DTD subset/) do
      Mica::XML.build(&.dtd("r", nil, nil, "<!ENTITY"))
    end
  end
end
