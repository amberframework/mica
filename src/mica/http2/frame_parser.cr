module Mica::HTTP2
  # Turns the bytes one peer sends into frames, without I/O: feed it chunks
  # of any size as they arrive and take the frames that are complete. A
  # stream fed one byte at a time gives the same frames as the same stream
  # fed at once.
  #
  # ```
  # parser = Mica::HTTP2::FrameParser.new(limits: Mica::HTTP2::FrameLimits::PUBLIC_SERVER, expect_preface: true)
  # parser.feed(chunk) { |frame| handle(frame) }
  # ```
  #
  # A server parser (*expect_preface* true) first checks the 24-byte
  # client preface, failing on the first byte that differs. A frame whose
  # header declares more than `FrameLimits#max_frame_size` fails as soon as
  # its header arrives. The parser holds the bytes it was fed but has not
  # yet turned into frames: at most one frame plus the last chunk.
  #
  # Every rule is described with the `FrameError` it raises; see
  # `FrameError` for what the parser does after one.
  #
  # WARNING: A parser is not concurrency-safe; one fiber owns it.
  class FrameParser
    # The limits this parser enforces.
    getter limits : FrameLimits

    @buffer : Bytes
    @start = 0
    @end = 0
    # Bytes consumed before `@buffer[@start]`, for error offsets.
    @consumed = 0_i64
    @preface_left : Int32
    # The stream whose header block is open (waiting for CONTINUATION),
    # or nil.
    @open_block_stream : UInt32? = nil
    @open_block_bytes = 0_i64
    @continuation_frames = 0
    @failure : Exception? = nil

    def initialize(*, @limits : FrameLimits, expect_preface : Bool)
      @preface_left = expect_preface ? PREFACE.size : 0
      @buffer = Bytes.new(FRAME_HEADER_SIZE + DEFAULT_MAX_FRAME_SIZE)
    end

    # Returns true once the client preface has arrived (always true for a
    # parser that does not expect one).
    def preface_received? : Bool
      @preface_left == 0
    end

    # Returns true while a header block waits for CONTINUATION frames.
    def inside_header_block? : Bool
      !@open_block_stream.nil?
    end

    # Adds *bytes* to the input.
    def feed(bytes : Bytes) : Nil
      return if bytes.empty?
      if @buffer.size - @end < bytes.size
        kept = @end - @start
        if @buffer.size < kept + bytes.size
          grown = Bytes.new(Math.max(@buffer.size * 2, kept + bytes.size))
          grown.copy_from(@buffer[@start, kept])
          @buffer = grown
        else
          @buffer.to_unsafe.move_from(@buffer.to_unsafe + @start, kept)
        end
        @start = 0
        @end = kept
      end
      @buffer[@end, bytes.size].copy_from(bytes)
      @end += bytes.size
    end

    # Adds *bytes* to the input and yields every frame now complete.
    def feed(bytes : Bytes, & : Frame ->) : Nil
      feed(bytes)
      while frame = next_frame
        yield frame
      end
    end

    # Returns the next complete frame, or nil when more bytes are needed.
    # Skips frames of unknown types.
    def next_frame : Frame?
      if failure = @failure
        raise failure
      end
      return nil unless check_preface
      loop do
        available = @end - @start
        return nil if available < FRAME_HEADER_SIZE
        header = @buffer[@start, FRAME_HEADER_SIZE]
        length = (header[0].to_i32 << 16) | (header[1].to_i32 << 8) | header[2].to_i32
        type_value = header[3]
        flags = header[4]
        stream_id = IO::ByteFormat::BigEndian.decode(UInt32, header[5, 4]) & MAX_STREAM_ID
        if length > @limits.max_frame_size
          connection_error(ErrorCode::FrameSizeError,
            "Frame of #{length} bytes is over SETTINGS_MAX_FRAME_SIZE (#{@limits.max_frame_size})")
        end
        return nil if available < FRAME_HEADER_SIZE + length
        payload = @buffer[@start + FRAME_HEADER_SIZE, length]
        type = FrameType.from_value?(type_value)
        check_header_block_sequence(type, stream_id)
        unless type
          advance(FRAME_HEADER_SIZE + length)
          next
        end
        frame = begin
          parse(type, flags, stream_id, payload)
        rescue error : FrameError
          if error.connection_error?
            @failure = error
          else
            advance(FRAME_HEADER_SIZE + length)
          end
          raise error
        end
        advance(FRAME_HEADER_SIZE + length)
        return frame
      end
    end

    private def advance(count : Int32) : Nil
      @start += count
      @consumed += count
      if @start == @end
        @start = 0
        @end = 0
      end
    end

    private def check_preface : Bool
      return true if @preface_left == 0
      offset = PREFACE.size - @preface_left
      count = Math.min(@preface_left, @end - @start)
      count.times do |index|
        next if @buffer[@start + index] == PREFACE[offset + index]
        @consumed += index
        error = FrameError.new("Connection preface does not match at byte #{offset + index}", position,
          ErrorCode::ProtocolError, true)
        @failure = error
        raise error
      end
      advance(count)
      @preface_left -= count
      @preface_left == 0
    end

    private def position : Core::Position
      Core::Position.new(@consumed)
    end

    private def connection_error(code : ErrorCode, detail : String) : NoReturn
      error = FrameError.new(detail, position, code, true)
      @failure = error
      raise error
    end

    # RFC 9113 section 6.10: a header block is one HEADERS or PUSH_PROMISE
    # frame followed only by CONTINUATION frames on its stream.
    private def check_header_block_sequence(type : FrameType?, stream_id : UInt32) : Nil
      if open_stream = @open_block_stream
        unless type == FrameType::Continuation && stream_id == open_stream
          connection_error(ErrorCode::ProtocolError,
            "Expected CONTINUATION on stream #{open_stream}, got #{type || "an unknown frame type"} on stream #{stream_id}")
        end
      elsif type == FrameType::Continuation
        connection_error(ErrorCode::ProtocolError, "CONTINUATION on stream #{stream_id} outside a header block")
      end
    end

    private def open_block(stream_id : UInt32, fragment_size : Int32, end_headers : Bool) : Nil
      @open_block_bytes = 0_i64
      @continuation_frames = 0
      add_block_bytes(fragment_size)
      @open_block_stream = end_headers ? nil : stream_id
    end

    private def add_block_bytes(count : Int32) : Nil
      @open_block_bytes += count
      if @open_block_bytes > @limits.max_header_block_bytes
        error = FrameLimitError.new("Header block of #{@open_block_bytes} bytes so far is over max_header_block_bytes " \
                                    "(#{@limits.max_header_block_bytes})", position, "max_header_block_bytes")
        @failure = error
        raise error
      end
    end

    private def parse(type : FrameType, flags : UInt8, stream_id : UInt32, payload : Bytes) : Frame
      case type
      in .data?          then parse_data(flags, stream_id, payload)
      in .headers?       then parse_headers(flags, stream_id, payload)
      in .priority?      then parse_priority(stream_id, payload)
      in .rst_stream?    then parse_rst_stream(stream_id, payload)
      in .settings?      then parse_settings(flags, stream_id, payload)
      in .push_promise?  then parse_push_promise(flags, stream_id, payload)
      in .ping?          then parse_ping(flags, stream_id, payload)
      in .goaway?        then parse_goaway(stream_id, payload)
      in .window_update? then parse_window_update(stream_id, payload)
      in .continuation?  then parse_continuation(flags, stream_id, payload)
      end
    end

    private def require_stream(type : FrameType, stream_id : UInt32) : Nil
      connection_error(ErrorCode::ProtocolError, "#{type} frame on stream 0") if stream_id == 0
    end

    private def require_connection(type : FrameType, stream_id : UInt32) : Nil
      connection_error(ErrorCode::ProtocolError, "#{type} frame on stream #{stream_id}, not 0") if stream_id != 0
    end

    # Splits off the pad length byte and the padding (RFC 9113, sections
    # 6.1, 6.2 and 6.6). *fixed* is the size of the fields between the pad
    # length and the content. Returns the content after those fields and the
    # padding length.
    private def unpad(type : FrameType, flags : UInt8, payload : Bytes, fixed : Int32) : {Bytes, UInt8?}
      unless flags & Flags::PADDED != 0
        if payload.size < fixed
          connection_error(ErrorCode::FrameSizeError, "#{type} frame of #{payload.size} bytes is too short")
        end
        return {payload, nil}
      end
      if payload.size < 1 + fixed
        connection_error(ErrorCode::FrameSizeError, "Padded #{type} frame of #{payload.size} bytes is too short")
      end
      padding = payload[0]
      if padding.to_i32 > payload.size - 1 - fixed
        connection_error(ErrorCode::ProtocolError,
          "#{type} frame padding of #{padding} bytes fills its #{payload.size}-byte payload")
      end
      {payload[1, payload.size - 1 - padding], padding}
    end

    private def parse_data(flags : UInt8, stream_id : UInt32, payload : Bytes) : Frame
      require_stream(FrameType::Data, stream_id)
      content, padding = unpad(FrameType::Data, flags, payload, 0)
      DataFrame.new(stream_id, content.dup, end_stream: flags & Flags::END_STREAM != 0, padding: padding)
    end

    private def parse_headers(flags : UInt8, stream_id : UInt32, payload : Bytes) : Frame
      require_stream(FrameType::Headers, stream_id)
      prioritized = flags & Flags::PRIORITY != 0
      content, padding = unpad(FrameType::Headers, flags, payload, prioritized ? 5 : 0)
      priority = nil
      if prioritized
        priority = read_priority(content)
        content = content[5, content.size - 5]
      end
      end_headers = flags & Flags::END_HEADERS != 0
      open_block(stream_id, content.size, end_headers)
      frame = HeadersFrame.new(stream_id, content.dup, end_stream: flags & Flags::END_STREAM != 0,
        end_headers: end_headers, priority: priority, padding: padding)
      if priority && priority.stream_dependency == stream_id
        raise FrameError.new("HEADERS frame makes stream #{stream_id} depend on itself", position,
          ErrorCode::ProtocolError, false, stream_id, frame)
      end
      frame
    end

    private def read_priority(bytes : Bytes) : Priority
      word = IO::ByteFormat::BigEndian.decode(UInt32, bytes[0, 4])
      Priority.new(word & MAX_STREAM_ID, bytes[4], word & 0x8000_0000_u32 != 0)
    end

    private def parse_priority(stream_id : UInt32, payload : Bytes) : Frame
      require_stream(FrameType::Priority, stream_id)
      if payload.size != 5
        raise FrameError.new("PRIORITY frame of #{payload.size} bytes, not 5", position,
          ErrorCode::FrameSizeError, false, stream_id)
      end
      priority = read_priority(payload)
      if priority.stream_dependency == stream_id
        raise FrameError.new("PRIORITY frame makes stream #{stream_id} depend on itself", position,
          ErrorCode::ProtocolError, false, stream_id)
      end
      PriorityFrame.new(stream_id, priority)
    end

    private def parse_rst_stream(stream_id : UInt32, payload : Bytes) : Frame
      require_stream(FrameType::RstStream, stream_id)
      if payload.size != 4
        connection_error(ErrorCode::FrameSizeError, "RST_STREAM frame of #{payload.size} bytes, not 4")
      end
      RstStreamFrame.new(stream_id, IO::ByteFormat::BigEndian.decode(UInt32, payload))
    end

    private def parse_settings(flags : UInt8, stream_id : UInt32, payload : Bytes) : Frame
      require_connection(FrameType::Settings, stream_id)
      if flags & Flags::ACK != 0
        connection_error(ErrorCode::FrameSizeError, "SETTINGS acknowledgment with a #{payload.size}-byte payload") unless payload.empty?
        return SettingsFrame.new(ack: true)
      end
      if payload.size % 6 != 0
        connection_error(ErrorCode::FrameSizeError, "SETTINGS frame of #{payload.size} bytes, not a multiple of 6")
      end
      list_of_settings = [] of Setting
      (payload.size // 6).times do |index|
        entry = payload[index * 6, 6]
        id = SettingId.from_value?(IO::ByteFormat::BigEndian.decode(UInt16, entry[0, 2]))
        next unless id
        value = IO::ByteFormat::BigEndian.decode(UInt32, entry[2, 4])
        check_setting(id, value)
        list_of_settings << Setting.new(id, value)
      end
      SettingsFrame.new(list_of_settings)
    end

    private def check_setting(id : SettingId, value : UInt32) : Nil
      case id
      when .enable_push?, .enable_connect_protocol?, .no_rfc7540_priorities?
        connection_error(ErrorCode::ProtocolError, "SETTINGS #{id} of #{value}, not 0 or 1") if value > 1
      when .initial_window_size?
        if value > MAX_WINDOW_SIZE
          connection_error(ErrorCode::FlowControlError, "SETTINGS_INITIAL_WINDOW_SIZE of #{value} is over 2^31-1")
        end
      when .max_frame_size?
        unless DEFAULT_MAX_FRAME_SIZE <= value <= LARGEST_MAX_FRAME_SIZE
          connection_error(ErrorCode::ProtocolError, "SETTINGS_MAX_FRAME_SIZE of #{value} is outside " \
                                                     "#{DEFAULT_MAX_FRAME_SIZE} to #{LARGEST_MAX_FRAME_SIZE}")
        end
      else
        # HEADER_TABLE_SIZE, MAX_CONCURRENT_STREAMS and MAX_HEADER_LIST_SIZE
        # take any 32-bit value.
      end
    end

    private def parse_push_promise(flags : UInt8, stream_id : UInt32, payload : Bytes) : Frame
      require_stream(FrameType::PushPromise, stream_id)
      content, padding = unpad(FrameType::PushPromise, flags, payload, 4)
      promised = IO::ByteFormat::BigEndian.decode(UInt32, content[0, 4]) & MAX_STREAM_ID
      block = content[4, content.size - 4]
      end_headers = flags & Flags::END_HEADERS != 0
      open_block(stream_id, block.size, end_headers)
      PushPromiseFrame.new(stream_id, promised, block.dup, end_headers: end_headers, padding: padding)
    end

    private def parse_ping(flags : UInt8, stream_id : UInt32, payload : Bytes) : Frame
      require_connection(FrameType::Ping, stream_id)
      connection_error(ErrorCode::FrameSizeError, "PING frame of #{payload.size} bytes, not 8") if payload.size != 8
      PingFrame.new(IO::ByteFormat::BigEndian.decode(UInt64, payload), ack: flags & Flags::ACK != 0)
    end

    private def parse_goaway(stream_id : UInt32, payload : Bytes) : Frame
      require_connection(FrameType::Goaway, stream_id)
      connection_error(ErrorCode::FrameSizeError, "GOAWAY frame of #{payload.size} bytes, under 8") if payload.size < 8
      last_stream_id = IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4]) & MAX_STREAM_ID
      code = IO::ByteFormat::BigEndian.decode(UInt32, payload[4, 4])
      GoawayFrame.new(last_stream_id, code, payload[8, payload.size - 8].dup)
    end

    private def parse_window_update(stream_id : UInt32, payload : Bytes) : Frame
      if payload.size != 4
        connection_error(ErrorCode::FrameSizeError, "WINDOW_UPDATE frame of #{payload.size} bytes, not 4")
      end
      increment = IO::ByteFormat::BigEndian.decode(UInt32, payload) & MAX_STREAM_ID
      frame = WindowUpdateFrame.new(stream_id, increment)
      if increment == 0
        connection_error(ErrorCode::ProtocolError, "WINDOW_UPDATE with a zero increment on stream 0") if stream_id == 0
        raise FrameError.new("WINDOW_UPDATE with a zero increment on stream #{stream_id}", position,
          ErrorCode::ProtocolError, false, stream_id, frame)
      end
      frame
    end

    private def parse_continuation(flags : UInt8, stream_id : UInt32, payload : Bytes) : Frame
      @continuation_frames += 1
      if @continuation_frames > @limits.max_continuation_frames
        error = FrameLimitError.new("Header block has more than #{@limits.max_continuation_frames} CONTINUATION frames",
          position, "max_continuation_frames")
        @failure = error
        raise error
      end
      add_block_bytes(payload.size)
      end_headers = flags & Flags::END_HEADERS != 0
      @open_block_stream = nil if end_headers
      ContinuationFrame.new(stream_id, payload.dup, end_headers: end_headers)
    end
  end
end
