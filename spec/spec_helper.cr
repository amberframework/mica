require "spec"
require "../src/mica"

# An IO that returns at most a few bytes per read, to exercise the reader's
# buffer refill and compaction at every byte boundary.
class TrickleIO < IO
  def initialize(@bytes : Bytes, @chunk : Int32)
    @offset = 0
  end

  def read(slice : Bytes) : Int32
    count = Math.min(Math.min(@chunk, slice.size), @bytes.size - @offset)
    return 0 if count <= 0
    slice.copy_from(@bytes.to_unsafe + @offset, count)
    @offset += count
    count
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

# Returns the reader's events as readable strings.
def reader_events(reader : Mica::Reader) : Array(String)
  events = [] of String
  while reader.read
    event = "#{reader.node_type}:#{reader.depth}:#{reader.name}"
    event += "=#{reader.value.inspect}" unless reader.value.empty?
    if reader.move_to_first_attribute
      while true
        event += " @#{reader.name}=#{reader.value.inspect}"
        break unless reader.move_to_next_attribute
      end
      reader.move_to_element
    end
    events << event
  end
  events
end

def reader_events(xml : String, options : Mica::ParserOptions = Mica::ParserOptions.default) : Array(String)
  reader_events(Mica::Reader.new(xml, options))
end

def utf16(text : String, big_endian : Bool) : Bytes
  io = IO::Memory.new
  io.write(big_endian ? Bytes[0xFE, 0xFF] : Bytes[0xFF, 0xFE])
  text.each_char do |char|
    code = char.ord
    units = code >= 0x10000 ? [0xD800 + ((code - 0x10000) >> 10), 0xDC00 + ((code - 0x10000) & 0x3FF)] : [code]
    units.each do |unit|
      if big_endian
        io.write_byte((unit >> 8).to_u8)
        io.write_byte((unit & 0xFF).to_u8)
      else
        io.write_byte((unit & 0xFF).to_u8)
        io.write_byte((unit >> 8).to_u8)
      end
    end
  end
  io.to_slice
end
