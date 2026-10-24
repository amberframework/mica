require "spec"
require "../src/mica"
require "../src/mica/testing"

# Which spec covers which specification requirement (see
# Mica::Testing::Traceability and spec/requirements/).
REQUIREMENTS = Mica::Testing::Traceability::Registry.new

# Defines an example that covers the requirement *requirement_id* (an id
# from a catalog in spec/requirements/).
def it_satisfies(requirement_id : String, description : String, file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  REQUIREMENTS.record(requirement_id, "#{file.sub(Dir.current + "/", "")}:#{line}")
  it(description, file, line, end_line, tags: "requirement", &block)
end

# Records that the example being defined also covers *requirement_id*.
def satisfies(requirement_id : String, file = __FILE__, line = __LINE__) : Nil
  REQUIREMENTS.record(requirement_id, "#{file.sub(Dir.current + "/", "")}:#{line}")
end

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
def reader_events(reader : Mica::XML::Reader) : Array(String)
  events = [] of String
  while reader.read
    event = "#{reader.node_type}:#{reader.depth}:#{reader.name}"
    event += "=#{reader.value.inspect}" unless reader.value.empty?
    if reader.move_to_first_attribute
      loop do
        event += " @#{reader.name}=#{reader.value.inspect}"
        break unless reader.move_to_next_attribute
      end
      reader.move_to_element
    end
    events << event
  end
  events
end

def reader_events(xml : String, options : Mica::XML::ParserOptions = Mica::XML::ParserOptions.default) : Array(String)
  reader_events(Mica::XML::Reader.new(xml, options))
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

def root_of(document : Mica::XML::Document) : Mica::XML::Node
  document.root || raise "Document has no root element"
end

def node_at(context : Mica::XML::Document | Mica::XML::Node, path : String) : Mica::XML::Node
  context.xpath_node(path) || raise "No node matches #{path}"
end
