module Mica::Form
  # Proves that a `Pair`'s pre-replacement byte count came from Mica's own
  # decoding. Only code inside `Mica::Form` can name it, so callers of the
  # public API cannot build a pair that claims fewer bytes than it holds.
  # (Code that reopens `Mica::Form` is inside the library's privacy
  # boundary and can change any check, so the seal does not try to stop
  # it.)
  private class ReplacementSeal
  end

  private REPLACEMENT_SEAL = ReplacementSeal.new

  # One name and value pair from a form, with the 0-based byte offset of
  # its first byte in the original input (0 for pairs built in code).
  #
  # ```
  # pair = Mica::Form::Pair.new("city", "Paris")
  # pair.has_replaced_invalid_bytes? # => false
  # ```
  struct Pair
    getter field_name : String
    getter field_value : String
    getter byte_offset : Int64
    # The decoded size in bytes of the name and value before U+FFFD
    # replacement, which is what limits count, or nil when nothing was
    # replaced. Only Mica's decoding sets it.
    getter byte_size_before_replacement : Int64?

    def initialize(@field_name : String, @field_value : String, @byte_offset : Int64 = 0_i64)
      @byte_size_before_replacement = nil
    end

    # :nodoc:
    # Builds a pair whose invalid UTF-8 Mica replaced. *seal* must be
    # Mica's own `REPLACEMENT_SEAL`.
    def initialize(@field_name : String, @field_value : String, @byte_offset : Int64,
                   *, byte_size_before_replacement : Int64, seal : Reference)
      raise ArgumentError.new("Only Mica's form decoding builds replaced pairs") unless seal.same?(REPLACEMENT_SEAL)
      @byte_size_before_replacement = byte_size_before_replacement
    end

    # Returns true when invalid UTF-8 in this pair's name or value was
    # replaced with U+FFFD (under `invalid_utf8: :replace_like_browsers`).
    def has_replaced_invalid_bytes? : Bool
      !@byte_size_before_replacement.nil?
    end
  end

  # The ordered name and value pairs of an `application/x-www-form-urlencoded`
  # body or a URL query string, parsed by the WHATWG URL Standard's
  # urlencoded parser (section 5.1) and written by its serializer
  # (section 5.2).
  #
  # Parsing splits the input on `&`, skips empty sequences, splits each
  # sequence at its first `=`, turns `+` into a space and decodes `%XX`
  # escapes (a `%` not followed by two hex digits stays as it is). Names
  # and values repeat freely and keep their order.
  #
  # Invalid UTF-8 in the decoded bytes follows the `invalid_utf8:`
  # argument (see `InvalidUTF8Handling`). By default (`:reject`) Mica
  # raises `Mica::EncodingError` at the byte where the invalid sequence
  # starts (the `%` of its first escape), so a form never carries silently
  # altered text. With `invalid_utf8: :replace_like_browsers` each invalid
  # sequence becomes U+FFFD exactly as WHATWG and browsers do, and
  # `has_replaced_invalid_bytes?` reports that it happened.
  #
  # ```
  # pairs = Mica::Form::Pairs.parse("a=1&b=x+y&a=%C3%A9", limits: Mica::Form::Limits::REQUEST_BODY)
  # pairs.fetch_all("a") # => ["1", "é"]
  # pairs["b"]?          # => "x y"
  # pairs.to_s           # => "a=1&b=x+y&a=%C3%A9"
  #
  # legacy = Mica::Form::Pairs.parse("city=M%FCnchen", limits: Mica::Form::Limits::REQUEST_BODY, invalid_utf8: :replace_like_browsers)
  # legacy["city"]                     # => "M\uFFFDnchen"
  # legacy.has_replaced_invalid_bytes? # => true
  # ```
  class Pairs
    include Enumerable(Pair)

    # Bytes read from an IO at a time.
    READ_CHUNK = 64 * 1024

    # Operations charged per byte for each pass over a name or value:
    # decoding, UTF-8 validation and the copy into a `String`.
    DECODE_PASSES = 3

    # Operations charged per decoded byte when a name or value is rebuilt
    # with U+FFFD replacements: one read and up to three bytes written.
    REPLACEMENT_PASSES = 4

    getter list_of_pairs : Array(Pair)

    def initialize(@list_of_pairs : Array(Pair) = [] of Pair)
    end

    # Parses *source* into pairs. *meter* lets the parse share a work
    # budget with other operations; without it the parse starts a meter
    # from `limits.work_budget`.
    #
    # *invalid_utf8* says what happens to decoded bytes that are not valid
    # UTF-8 (see `InvalidUTF8Handling`): `:reject` (the default) raises
    # `Mica::EncodingError`; `:replace_like_browsers` turns each invalid
    # sequence into U+FFFD the way browsers do and marks the pair (see
    # `has_replaced_invalid_bytes?`). Limits count the input bytes before
    # any replacement.
    #
    # Raises `Mica::LimitExceededError` when the input is longer than
    # `max_input_bytes` or holds more than `max_pairs` pairs,
    # `Mica::EncodingError` for invalid UTF-8 under `:reject`, and
    # `Mica::WorkBudgetExceededError` or `Mica::DeadlineExceededError` when
    # the budget or deadline runs out.
    def self.parse(source : String | Bytes | IO, *, limits : Limits, meter : Core::WorkMeter? = nil,
                   invalid_utf8 : InvalidUTF8Handling = InvalidUTF8Handling::Reject) : Pairs
      list_of_pairs = [] of Pair
      each(source, limits: limits, meter: meter, invalid_utf8: invalid_utf8) { |pair| list_of_pairs << pair }
      new(list_of_pairs)
    end

    # Parses *source* like `parse` and yields each pair in order instead of
    # collecting them. Under `invalid_utf8: :replace_like_browsers`, check
    # each pair's `Pair#has_replaced_invalid_bytes?`.
    def self.each(source : String | Bytes | IO, *, limits : Limits, meter : Core::WorkMeter? = nil,
                  invalid_utf8 : InvalidUTF8Handling = InvalidUTF8Handling::Reject, & : Pair ->) : Nil
      meter ||= Core::WorkMeter.new(limits.work_budget)
      meter.enforce_deadline { Core::Position.new(0_i64) }
      bytes = read_input(source, limits, meter)
      Scanner.new(bytes, limits, meter, invalid_utf8).each { |pair| yield pair }
      meter.enforce_deadline { Core::Position.new(bytes.size.to_i64) }
    end

    # Writes *text* with the urlencoded percent-encode set: ASCII letters,
    # digits and `*-._` stay, a space becomes `+`, and every other byte of
    # its UTF-8 encoding becomes `%XX` (uppercase hex).
    #
    # Raises `Mica::EncodingError` (at the offending byte of *text*) when
    # *text* is not valid UTF-8: the serializer takes scalar-value strings
    # (WHATWG URL, section 5.2), and Mica's parser would reject the output.
    #
    # ```
    # Mica::Form::Pairs.encode("a b&c", io = IO::Memory.new)
    # io.to_s # => "a+b%26c"
    # ```
    def self.encode(text : String, io : IO) : Nil
      if invalid = Core::UTF8.first_invalid_offset(text.to_slice)
        raise EncodingError.new("Invalid UTF-8 in a form string to serialize", Core::Position.new(invalid.to_i64))
      end
      text.each_byte do |byte|
        if byte == 0x20
          io << '+'
        elsif unreserved?(byte)
          io.write_byte(byte)
        else
          io << '%'
          io << HEX_DIGITS[byte >> 4] << HEX_DIGITS[byte & 0x0F]
        end
      end
    end

    private HEX_DIGITS = "0123456789ABCDEF"

    private def self.unreserved?(byte : UInt8) : Bool
      (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2A || byte == 0x2D || byte == 0x2E || byte == 0x5F
    end

    # Reads all of *source*, raising the input-size limit error at byte
    # `max_input_bytes` when there is more. An IO is read into a buffer
    # that doubles up to `max_input_bytes` plus one byte, so a stream never
    # holds more than that.
    private def self.read_input(source : String | Bytes | IO, limits : Limits, meter : Core::WorkMeter) : Bytes
      if source.is_a?(IO)
        read_stream(source, limits, meter)
      else
        bytes = source.is_a?(String) ? source.to_slice : source
        check_input_size(bytes.size.to_i64, limits)
        meter.add_units(bytes.size)
        bytes
      end
    end

    private def self.read_stream(io : IO, limits : Limits, meter : Core::WorkMeter) : Bytes
      capacity = Math.min(limits.max_input_bytes, Int32::MAX.to_i64 - 1).to_i32 + 1
      buffer = Bytes.new(Math.min(READ_CHUNK, capacity))
      size = 0
      loop do
        if size == buffer.size
          if size == capacity
            # Only unbounded limits get here: the input does not fit in
            # one buffer.
            raise LimitExceededError.new("Form input exceeds #{size} bytes", Core::Position.new(size.to_i64))
          end
          Metering.charge(meter, size) { Core::Position.new(size.to_i64) }
          grown = Bytes.new(Math.min(size.to_i64 * 2, capacity.to_i64).to_i32)
          grown.copy_from(buffer)
          buffer = grown
        end
        count = io.read(buffer[size, buffer.size - size])
        break if count == 0
        size += count
        meter.add_units(count)
        meter.enforce_deadline { Core::Position.new(size.to_i64) }
        check_input_size(size.to_i64, limits)
      end
      buffer[0, size]
    end

    private def self.check_input_size(size : Int64, limits : Limits) : Nil
      return if size <= limits.max_input_bytes
      raise LimitExceededError.new(
        "Form input exceeds max_input_bytes (#{limits.max_input_bytes})",
        Core::Position.new(limits.max_input_bytes))
    end

    # Yields each pair in order.
    def each(& : Pair ->) : Nil
      @list_of_pairs.each { |pair| yield pair }
    end

    # Returns the number of pairs.
    def size : Int32
      @list_of_pairs.size
    end

    # Returns true when there are no pairs.
    def empty? : Bool
      @list_of_pairs.empty?
    end

    # Returns true when any pair had invalid UTF-8 replaced with U+FFFD,
    # which only happens under `invalid_utf8: :replace_like_browsers`. Use
    # it to log, flag or refuse input a browser would have altered.
    #
    # ```
    # pairs = Mica::Form::Pairs.parse("q=caf%E9", limits: Mica::Form::Limits::QUERY_STRING, invalid_utf8: :replace_like_browsers)
    # pairs.has_replaced_invalid_bytes? # => true
    # ```
    def has_replaced_invalid_bytes? : Bool
      @list_of_pairs.any?(&.has_replaced_invalid_bytes?)
    end

    # Returns the value of the first pair named *name*, or nil.
    def []?(name : String) : String?
      match = @list_of_pairs.find { |pair| pair.field_name == name }
      match ? match.field_value : nil
    end

    # Returns the value of the first pair named *name*. Raises `KeyError`
    # when there is none.
    def [](name : String) : String
      self[name]? || raise KeyError.new("Missing form name #{Core.quote(name)}")
    end

    # Returns the values of every pair named *name*, in order.
    def fetch_all(name : String) : Array(String)
      @list_of_pairs.compact_map { |pair| pair.field_value if pair.field_name == name }
    end

    # Writes the pairs with the WHATWG urlencoded serializer: each name and
    # value through `encode`, joined by `=` and `&`.
    def to_s(io : IO) : Nil
      @list_of_pairs.each_with_index do |pair, index|
        io << '&' if index > 0
        Pairs.encode(pair.field_name, io)
        io << '='
        Pairs.encode(pair.field_value, io)
      end
    end

    # Splits urlencoded bytes into pairs, one sequence at a time.
    private struct Scanner
      def initialize(@bytes : Bytes, @limits : Limits, @meter : Core::WorkMeter, @invalid_utf8 : InvalidUTF8Handling)
        @pair_count = 0
      end

      def each(& : Pair ->) : Nil
        start = 0
        size = @bytes.size
        while start <= size
          stop = find(0x26_u8, start, size) || size
          yield scan_sequence(start, stop) if stop > start
          start = stop + 1
        end
      end

      private def scan_sequence(start : Int32, stop : Int32) : Pair
        @pair_count += 1
        if @pair_count > @limits.max_pairs
          raise LimitExceededError.new("Form has more than max_pairs (#{@limits.max_pairs}) pairs", position(start))
        end
        equals = find(0x3D_u8, start, stop)
        name, name_size, has_replaced_in_name = decode(start, equals || stop, "name")
        value, value_size, has_replaced_in_value = equals ? decode(equals + 1, stop, "value") : {"", 0, false}
        if has_replaced_in_name || has_replaced_in_value
          Pair.new(name, value, start.to_i64, byte_size_before_replacement: name_size.to_i64 + value_size, seal: REPLACEMENT_SEAL)
        else
          Pair.new(name, value, start.to_i64)
        end
      end

      # Returns the index of the first *byte* in `@bytes[from...limit]`, or
      # nil. Searches one `Metering::SCAN_CHUNK` window at a time and
      # charges the bytes each window read, so a long run cannot outrun the
      # meter by more than one window.
      private def find(byte : UInt8, from : Int32, limit : Int32) : Int32?
        index = from
        while index < limit
          window = Math.min(Metering::SCAN_CHUNK, limit - index)
          found = @bytes[index, window].index(byte)
          charge(found ? found + 1 : window, index)
          return index + found if found
          index += window
        end
        nil
      end

      # Decodes `@bytes[start, stop - start]`: `+` to space and `%XX` to
      # its byte, then checks the result is UTF-8. Returns the text, its
      # decoded size before any replacement, and whether invalid sequences
      # in it were replaced with U+FFFD.
      private def decode(start : Int32, stop : Int32, part : String) : {String, Int32, Bool}
        length = stop - start
        return {"", 0, false} if length == 0
        charge(DECODE_PASSES.to_i64 * length, start)
        decoded = Bytes.new(length)
        written = 0
        index = start
        while index < stop
          byte = @bytes[index]
          if byte == 0x2B
            decoded[written] = 0x20
            index += 1
          elsif byte == 0x25 && escape?(index, stop)
            decoded[written] = (hex_value(@bytes[index + 1]) << 4) | hex_value(@bytes[index + 2])
            index += 3
          else
            decoded[written] = byte
            index += 1
          end
          written += 1
        end
        text = decoded[0, written]
        if invalid = Core::UTF8.first_invalid_offset(text)
          raise_invalid_utf8(start, stop, invalid, text, part) if @invalid_utf8.reject?
          charge(REPLACEMENT_PASSES.to_i64 * written, start)
          return {Core::UTF8.replace_invalid_sequences_like_browsers(text), written, true}
        end
        {String.new(text), written, false}
      end

      private def escape?(index : Int32, stop : Int32) : Bool
        index + 2 < stop && hex_digit?(@bytes[index + 1]) && hex_digit?(@bytes[index + 2])
      end

      private def hex_digit?(byte : UInt8) : Bool
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
      end

      private def hex_value(byte : UInt8) : UInt8
        if byte <= 0x39
          byte - 0x30
        elsif byte <= 0x46
          byte - 0x37
        else
          byte - 0x57
        end
      end

      # Maps the decoded offset *invalid* back to the input byte that
      # produced it and raises there. Runs once, on the failing field.
      private def raise_invalid_utf8(start : Int32, stop : Int32, invalid : Int32, text : Bytes, part : String) : NoReturn
        index = start
        written = 0
        while written < invalid
          index += @bytes[index] == 0x25 && escape?(index, stop) ? 3 : 1
          written += 1
        end
        code, _ = Core::UTF8.decode(text, invalid, text.size)
        problem = Core::UTF8.problem(code)
        raise EncodingError.new(
          "Invalid UTF-8 in form #{part} at byte #{index} (#{problem.describe}); #{INVALID_UTF8_REJECTION_HINT}",
          position(index))
      end

      private def charge(count : Int, offset : Int32) : Nil
        Metering.charge(@meter, count) { position(offset) }
      end

      private def position(offset : Int32) : Core::Position
        Core::Position.new(offset.to_i64)
      end
    end
  end
end
