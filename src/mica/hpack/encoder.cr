module Mica::HPACK
  # Encodes the header lists one side sends on one connection, in order,
  # keeping the dynamic table they share. The same lists in the same order
  # always give the same bytes.
  #
  # Each field is sent as:
  # - an indexed field when a table holds the same name and value;
  # - a never-indexed literal when its name is in *never_indexed_names*
  #   (`NEVER_INDEXED_NAMES` unless given)
  #   (so secrets never enter a table where a compression oracle could
  #   probe them, RFC 7541 section 7.1) or the `Header` is marked
  #   `never_indexed`;
  # - otherwise a literal with incremental indexing, naming a table entry
  #   when one has the name.
  #
  # Strings are Huffman-coded when *huffman* is true and the code is no
  # longer than the string (as RFC 7541 Appendix C does).
  #
  # ```
  # encoder = Mica::HPACK::Encoder.new(huffman: false)
  # encoder.encode([Mica::HPACK::Header.new(":method", "GET")]) # => Bytes[0x82]
  # ```
  #
  # WARNING: An encoder is not concurrency-safe; one fiber owns it.
  class Encoder
    # Names whose fields are sent as never-indexed literals unless the
    # encoder is given others: credentials and cookies.
    NEVER_INDEXED_NAMES = {"authorization", "cookie", "proxy-authorization", "set-cookie"}

    # Whether strings are Huffman-coded when that is shorter.
    getter? huffman : Bool

    # Names whose fields this encoder sends as never-indexed literals.
    getter never_indexed_names : Set(String)

    @table : DynamicTable
    # Insertion numbers of the dynamic entries, by field and by name.
    @field_insertions = {} of {String, String} => Int64
    @name_insertions = {} of String => Int64
    # Size updates to send at the start of the next block.
    @pending_size_updates = [] of Int32

    # *max_table_size* is the peer's SETTINGS_HEADER_TABLE_SIZE (4,096
    # until its first SETTINGS frame says otherwise). Names in
    # *never_indexed_names* are lowercase, as HTTP/2 sends them.
    def initialize(*, max_table_size : Int32 = DEFAULT_TABLE_SIZE, @huffman : Bool = true,
                   never_indexed_names : Enumerable(String) = NEVER_INDEXED_NAMES)
      @never_indexed_names = never_indexed_names.to_set
      raise ArgumentError.new("max_table_size must not be negative") if max_table_size < 0
      @table = DynamicTable.new(max_table_size)
    end

    # Returns the dynamic table's maximum size.
    def max_table_size : Int32
      @table.capacity
    end

    # Changes the dynamic table's maximum size, when the peer's
    # SETTINGS_HEADER_TABLE_SIZE changes. The next block starts with the
    # size update(s) that tell the peer (the smallest size first when it
    # went down and up again, RFC 7541 section 4.2).
    def max_table_size=(size : Int32) : Int32
      raise ArgumentError.new("max_table_size must not be negative") if size < 0
      if pending = @pending_size_updates.first?
        @pending_size_updates = size < pending ? [size] : [pending, size]
      else
        @pending_size_updates << size
      end
      @table.resize(size) do |evicted, insertion|
        forget(evicted, insertion)
      end
      size
    end

    # Returns the bytes the dynamic table's entries take.
    def table_size : Int32
      @table.size
    end

    # Encodes *headers* as one header block.
    def encode(headers : Enumerable(Header)) : Bytes
      output = IO::Memory.new
      encode(headers, output)
      output.to_slice
    end

    # Encodes *headers* as one header block written to *output*.
    def encode(headers : Enumerable(Header), output : IO) : Nil
      @pending_size_updates.each { |size| PrefixInteger.encode(output, 0x20_u8, 5, size.to_i64) }
      @pending_size_updates.clear
      headers.each { |header| encode_field(header, output) }
    end

    private def encode_field(header : Header, output : IO) : Nil
      never_indexed = header.never_indexed? || @never_indexed_names.includes?(header.name)
      unless never_indexed
        if index = field_index(header)
          PrefixInteger.encode(output, 0x80_u8, 7, index.to_i64)
          return
        end
      end
      name_index = name_index(header.name)
      if never_indexed
        write_literal(output, 0x10_u8, 4, name_index, header)
      elsif header.size <= @table.capacity
        write_literal(output, 0x40_u8, 6, name_index, header)
        @table.add(header) { |evicted, insertion| forget(evicted, insertion) }
        @field_insertions[{header.name, header.value}] = @table.insertions
        @name_insertions[header.name] = @table.insertions
      else
        write_literal(output, 0x00_u8, 4, name_index, header)
      end
    end

    private def field_index(header : Header) : Int32?
      if index = StaticTable::FIELD_INDEX[{header.name, header.value}]?
        return index
      end
      if insertion = @field_insertions[{header.name, header.value}]?
        dynamic_index(insertion)
      end
    end

    private def name_index(name : String) : Int32
      if index = StaticTable::NAME_INDEX[name]?
        return index
      end
      if insertion = @name_insertions[name]?
        return dynamic_index(insertion)
      end
      0
    end

    private def dynamic_index(insertion : Int64) : Int32
      (StaticTable::SIZE + @table.insertions - insertion + 1).to_i32
    end

    private def forget(evicted : Header, insertion : Int64) : Nil
      key = {evicted.name, evicted.value}
      @field_insertions.delete(key) if @field_insertions[key]? == insertion
      @name_insertions.delete(evicted.name) if @name_insertions[evicted.name]? == insertion
    end

    private def write_literal(output : IO, pattern : UInt8, prefix : Int32, name_index : Int32, header : Header) : Nil
      PrefixInteger.encode(output, pattern, prefix, name_index.to_i64)
      write_string(output, header.name) if name_index == 0
      write_string(output, header.value)
    end

    private def write_string(output : IO, text : String) : Nil
      bytes = text.to_slice
      if @huffman
        coded_size = Huffman.encoded_size(bytes)
        if coded_size <= bytes.size
          PrefixInteger.encode(output, 0x80_u8, 7, coded_size.to_i64)
          Huffman.encode(bytes, output)
          return
        end
      end
      PrefixInteger.encode(output, 0x00_u8, 7, bytes.size.to_i64)
      output.write(bytes)
    end
  end
end
