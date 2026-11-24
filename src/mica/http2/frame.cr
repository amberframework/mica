module Mica::HTTP2
  # The frame types of RFC 9113, section 6. A parser skips frames of any
  # other type (section 4.1), except inside a header block.
  enum FrameType : UInt8
    Data         = 0x0
    Headers      = 0x1
    Priority     = 0x2
    RstStream    = 0x3
    Settings     = 0x4
    PushPromise  = 0x5
    Ping         = 0x6
    Goaway       = 0x7
    WindowUpdate = 0x8
    Continuation = 0x9
  end

  # The flag bits frames use (RFC 9113, section 6). A parser ignores flags a
  # frame type does not define, and a frame never writes them.
  module Flags
    END_STREAM  = 0x01_u8
    ACK         = 0x01_u8
    END_HEADERS = 0x04_u8
    PADDED      = 0x08_u8
    PRIORITY    = 0x20_u8
  end

  # The stream dependency of a PRIORITY frame or a HEADERS frame with the
  # PRIORITY flag (RFC 9113, section 6.3; deprecated, still parsed).
  # *weight* is the wire value, 0 to 255, for a weight of 1 to 256.
  record Priority, stream_dependency : UInt32, weight : UInt8, exclusive : Bool = false do
    # Returns true for an exclusive dependency.
    def exclusive? : Bool
      @exclusive
    end
  end

  # One HTTP/2 frame. `to_slice` and `write` serialize it with the reserved
  # bit of every stream identifier cleared; a parsed frame serializes back
  # to the same frame.
  abstract struct Frame
    # Returns the frame's stream identifier (0 for the connection).
    abstract def stream_id : UInt32

    # Returns the frame's type.
    abstract def type : FrameType

    # Returns the flag bits the frame writes.
    abstract def flags : UInt8

    # Returns the payload's length in bytes.
    abstract def payload_size : Int32

    # Writes the payload.
    abstract def write_payload(io : IO) : Nil

    # Returns the frame's bytes: header and payload. Raises
    # `ArgumentError` when the payload is larger than *max_frame_size*, the
    # peer's SETTINGS_MAX_FRAME_SIZE.
    def to_slice(*, max_frame_size : Int32) : Bytes
      io = IO::Memory.new(FRAME_HEADER_SIZE + payload_size)
      write(io, max_frame_size: max_frame_size)
      io.to_slice
    end

    # Writes the frame's bytes to *io*, as `to_slice`.
    def write(io : IO, *, max_frame_size : Int32) : Nil
      size = payload_size
      if size > max_frame_size || size > LARGEST_MAX_FRAME_SIZE
        raise ArgumentError.new("#{type} frame payload of #{size} bytes is over the maximum frame size #{max_frame_size}")
      end
      io.write_byte((size >> 16).to_u8!)
      io.write_byte((size >> 8).to_u8!)
      io.write_byte(size.to_u8!)
      io.write_byte(type.value)
      io.write_byte(flags)
      io.write_bytes(stream_id & MAX_STREAM_ID, IO::ByteFormat::BigEndian)
      write_payload(io)
    end

    # :nodoc:
    def self.check_stream_id(name : String, value : UInt32) : Nil
      raise ArgumentError.new("#{name} must be at most #{MAX_STREAM_ID}") if value > MAX_STREAM_ID
    end

    private def write_padding(io : IO, padding : UInt8) : Nil
      padding.times { io.write_byte(0_u8) }
    end
  end

  # A DATA frame (RFC 9113, section 6.1). *padding* is the number of
  # padding bytes, or nil when the frame is not padded.
  struct DataFrame < Frame
    getter stream_id : UInt32
    getter data : Bytes
    getter? end_stream : Bool
    getter padding : UInt8?

    def initialize(@stream_id : UInt32, @data : Bytes, *, @end_stream : Bool = false, @padding : UInt8? = nil)
      Frame.check_stream_id("stream_id", @stream_id)
    end

    def type : FrameType
      FrameType::Data
    end

    def flags : UInt8
      (@end_stream ? Flags::END_STREAM : 0_u8) | (@padding ? Flags::PADDED : 0_u8)
    end

    def payload_size : Int32
      padding = @padding
      @data.size + (padding ? padding.to_i32 + 1 : 0)
    end

    def write_payload(io : IO) : Nil
      padding = @padding
      io.write_byte(padding) if padding
      io.write(@data)
      write_padding(io, padding) if padding
    end

    def_equals_and_hash @stream_id, @data, @end_stream, @padding
  end

  # A HEADERS frame (RFC 9113, section 6.2).
  struct HeadersFrame < Frame
    getter stream_id : UInt32
    getter field_block : Bytes
    getter? end_stream : Bool
    getter? end_headers : Bool
    getter priority : Priority?
    getter padding : UInt8?

    def initialize(@stream_id : UInt32, @field_block : Bytes, *, @end_stream : Bool = false,
                   @end_headers : Bool = true, @priority : Priority? = nil, @padding : UInt8? = nil)
      Frame.check_stream_id("stream_id", @stream_id)
      if priority = @priority
        Frame.check_stream_id("stream_dependency", priority.stream_dependency)
      end
    end

    def type : FrameType
      FrameType::Headers
    end

    def flags : UInt8
      (@end_stream ? Flags::END_STREAM : 0_u8) | (@end_headers ? Flags::END_HEADERS : 0_u8) |
        (@padding ? Flags::PADDED : 0_u8) | (@priority ? Flags::PRIORITY : 0_u8)
    end

    def payload_size : Int32
      padding = @padding
      @field_block.size + (padding ? padding.to_i32 + 1 : 0) + (@priority ? 5 : 0)
    end

    def write_payload(io : IO) : Nil
      padding = @padding
      io.write_byte(padding) if padding
      if priority = @priority
        PriorityFrame.write_priority(io, priority)
      end
      io.write(@field_block)
      write_padding(io, padding) if padding
    end

    def_equals_and_hash @stream_id, @field_block, @end_stream, @end_headers, @priority, @padding
  end

  # A PRIORITY frame (RFC 9113, section 6.3).
  struct PriorityFrame < Frame
    getter stream_id : UInt32
    getter priority : Priority

    def initialize(@stream_id : UInt32, @priority : Priority)
      Frame.check_stream_id("stream_id", @stream_id)
      Frame.check_stream_id("stream_dependency", @priority.stream_dependency)
    end

    def type : FrameType
      FrameType::Priority
    end

    def flags : UInt8
      0_u8
    end

    def payload_size : Int32
      5
    end

    def write_payload(io : IO) : Nil
      PriorityFrame.write_priority(io, @priority)
    end

    # Writes the 5 bytes of *priority*.
    def self.write_priority(io : IO, priority : Priority) : Nil
      dependency = priority.stream_dependency & MAX_STREAM_ID
      dependency |= 0x8000_0000_u32 if priority.exclusive?
      io.write_bytes(dependency, IO::ByteFormat::BigEndian)
      io.write_byte(priority.weight)
    end

    def_equals_and_hash @stream_id, @priority
  end

  # An RST_STREAM frame (RFC 9113, section 6.4).
  struct RstStreamFrame < Frame
    getter stream_id : UInt32
    # The error code as sent, which may be one RFC 9113 does not define.
    getter error_code_value : UInt32

    def initialize(@stream_id : UInt32, @error_code_value : UInt32)
      Frame.check_stream_id("stream_id", @stream_id)
    end

    def self.new(stream_id : UInt32, error_code : ErrorCode) : self
      new(stream_id, error_code.value)
    end

    # Returns the error code, or nil for a code RFC 9113 does not define.
    def error_code : ErrorCode?
      ErrorCode.from_value?(@error_code_value)
    end

    def type : FrameType
      FrameType::RstStream
    end

    def flags : UInt8
      0_u8
    end

    def payload_size : Int32
      4
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(@error_code_value, IO::ByteFormat::BigEndian)
    end

    def_equals_and_hash @stream_id, @error_code_value
  end

  # A SETTINGS frame (RFC 9113, section 6.5), always on stream 0. An
  # acknowledgment carries no settings.
  struct SettingsFrame < Frame
    getter? ack : Bool
    getter list_of_settings : Array(Setting)

    def initialize(@list_of_settings : Array(Setting) = [] of Setting, *, @ack : Bool = false)
      raise ArgumentError.new("A SETTINGS acknowledgment carries no settings") if @ack && !@list_of_settings.empty?
    end

    def stream_id : UInt32
      0_u32
    end

    def type : FrameType
      FrameType::Settings
    end

    def flags : UInt8
      @ack ? Flags::ACK : 0_u8
    end

    def payload_size : Int32
      @list_of_settings.size * 6
    end

    def write_payload(io : IO) : Nil
      @list_of_settings.each do |setting|
        io.write_bytes(setting.id.value, IO::ByteFormat::BigEndian)
        io.write_bytes(setting.value, IO::ByteFormat::BigEndian)
      end
    end

    def_equals_and_hash @ack, @list_of_settings
  end

  # A PUSH_PROMISE frame (RFC 9113, section 6.6).
  struct PushPromiseFrame < Frame
    getter stream_id : UInt32
    getter promised_stream_id : UInt32
    getter field_block : Bytes
    getter? end_headers : Bool
    getter padding : UInt8?

    def initialize(@stream_id : UInt32, @promised_stream_id : UInt32, @field_block : Bytes, *,
                   @end_headers : Bool = true, @padding : UInt8? = nil)
      Frame.check_stream_id("stream_id", @stream_id)
      Frame.check_stream_id("promised_stream_id", @promised_stream_id)
    end

    def type : FrameType
      FrameType::PushPromise
    end

    def flags : UInt8
      (@end_headers ? Flags::END_HEADERS : 0_u8) | (@padding ? Flags::PADDED : 0_u8)
    end

    def payload_size : Int32
      padding = @padding
      4 + @field_block.size + (padding ? padding.to_i32 + 1 : 0)
    end

    def write_payload(io : IO) : Nil
      padding = @padding
      io.write_byte(padding) if padding
      io.write_bytes(@promised_stream_id & MAX_STREAM_ID, IO::ByteFormat::BigEndian)
      io.write(@field_block)
      write_padding(io, padding) if padding
    end

    def_equals_and_hash @stream_id, @promised_stream_id, @field_block, @end_headers, @padding
  end

  # A PING frame (RFC 9113, section 6.7), always on stream 0.
  struct PingFrame < Frame
    getter opaque_data : UInt64
    getter? ack : Bool

    def initialize(@opaque_data : UInt64, *, @ack : Bool = false)
    end

    def stream_id : UInt32
      0_u32
    end

    def type : FrameType
      FrameType::Ping
    end

    def flags : UInt8
      @ack ? Flags::ACK : 0_u8
    end

    def payload_size : Int32
      8
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(@opaque_data, IO::ByteFormat::BigEndian)
    end

    def_equals_and_hash @opaque_data, @ack
  end

  # A GOAWAY frame (RFC 9113, section 6.8), always on stream 0.
  struct GoawayFrame < Frame
    getter last_stream_id : UInt32
    # The error code as sent, which may be one RFC 9113 does not define.
    getter error_code_value : UInt32
    getter debug_data : Bytes

    def initialize(@last_stream_id : UInt32, @error_code_value : UInt32, @debug_data : Bytes = Bytes.empty)
      Frame.check_stream_id("last_stream_id", @last_stream_id)
    end

    def self.new(last_stream_id : UInt32, error_code : ErrorCode, debug_data : Bytes = Bytes.empty) : self
      new(last_stream_id, error_code.value, debug_data)
    end

    # Returns the error code, or nil for a code RFC 9113 does not define.
    def error_code : ErrorCode?
      ErrorCode.from_value?(@error_code_value)
    end

    def stream_id : UInt32
      0_u32
    end

    def type : FrameType
      FrameType::Goaway
    end

    def flags : UInt8
      0_u8
    end

    def payload_size : Int32
      8 + @debug_data.size
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(@last_stream_id & MAX_STREAM_ID, IO::ByteFormat::BigEndian)
      io.write_bytes(@error_code_value, IO::ByteFormat::BigEndian)
      io.write(@debug_data)
    end

    def_equals_and_hash @last_stream_id, @error_code_value, @debug_data
  end

  # A WINDOW_UPDATE frame (RFC 9113, section 6.9).
  struct WindowUpdateFrame < Frame
    getter stream_id : UInt32
    getter increment : UInt32

    def initialize(@stream_id : UInt32, @increment : UInt32)
      Frame.check_stream_id("stream_id", @stream_id)
      Frame.check_stream_id("increment", @increment)
    end

    def type : FrameType
      FrameType::WindowUpdate
    end

    def flags : UInt8
      0_u8
    end

    def payload_size : Int32
      4
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(@increment & MAX_STREAM_ID, IO::ByteFormat::BigEndian)
    end

    def_equals_and_hash @stream_id, @increment
  end

  # A CONTINUATION frame (RFC 9113, section 6.10).
  struct ContinuationFrame < Frame
    getter stream_id : UInt32
    getter field_block : Bytes
    getter? end_headers : Bool

    def initialize(@stream_id : UInt32, @field_block : Bytes, *, @end_headers : Bool = true)
      Frame.check_stream_id("stream_id", @stream_id)
    end

    def type : FrameType
      FrameType::Continuation
    end

    def flags : UInt8
      @end_headers ? Flags::END_HEADERS : 0_u8
    end

    def payload_size : Int32
      @field_block.size
    end

    def write_payload(io : IO) : Nil
      io.write(@field_block)
    end

    def_equals_and_hash @stream_id, @field_block, @end_headers
  end
end
