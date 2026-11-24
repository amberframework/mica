require "../src/mica"

# Frame builders and generators shared by the HTTP/2 frame specs and
# fuzz/http2_campaign.cr.
module HTTP2Fuzz
  alias H2 = Mica::HTTP2

  LIMITS = H2::FrameLimits::PUBLIC_SERVER

  # Returns a frame's bytes built by hand: header fields as given, so specs
  # can write frames the serializer never would.
  def self.raw(type : Int32, flags : Int32, stream_id : UInt32, payload : Bytes = Bytes.empty,
               length : Int32 = payload.size) : Bytes
    io = IO::Memory.new
    io.write_byte((length >> 16).to_u8!)
    io.write_byte((length >> 8).to_u8!)
    io.write_byte(length.to_u8!)
    io.write_byte(type.to_u8)
    io.write_byte(flags.to_u8)
    io.write_bytes(stream_id, IO::ByteFormat::BigEndian)
    io.write(payload)
    io.to_slice
  end

  def self.parser(limits : H2::FrameLimits = LIMITS, expect_preface : Bool = false) : H2::FrameParser
    H2::FrameParser.new(limits: limits, expect_preface: expect_preface)
  end

  # Parses *bytes* fed at once and returns the frames.
  def self.frames(bytes : Bytes, limits : H2::FrameLimits = LIMITS) : Array(H2::Frame)
    list_of_frames = [] of H2::Frame
    parser(limits).feed(bytes) { |frame| list_of_frames << frame }
    list_of_frames
  end

  # Returns the error parsing *bytes* raises.
  def self.error(bytes : Bytes, limits : H2::FrameLimits = LIMITS) : H2::FrameError
    frames(bytes, limits)
    raise "Expected a FrameError"
  rescue error : H2::FrameError
    error
  end

  def self.u32(value : Int) : Bytes
    io = IO::Memory.new
    io.write_bytes(value.to_u32, IO::ByteFormat::BigEndian)
    io.to_slice
  end

  # What parsing *bytes* in chunks gives: frames and stream errors in order,
  # then the connection error that ended it, if any.
  def self.outcome(bytes : Bytes, chunks : Array(Int32)? = nil, limits : H2::FrameLimits = LIMITS,
                   expect_preface : Bool = false) : Array(String)
    events = [] of String
    parser = parser(limits, expect_preface)
    offset = 0
    index = 0
    loop do
      size = chunks ? chunks[index % chunks.size] : bytes.size
      index += 1
      size = Math.min(size, bytes.size - offset)
      parser.feed(bytes[offset, size])
      offset += size
      loop do
        frame = parser.next_frame
        break unless frame
        events << frame.inspect
      rescue error : H2::FrameError
        events << "#{error.connection_error? ? "connection" : "stream"} #{error.error_code} at #{error.byte_offset}"
        return events if error.connection_error?
      rescue error : H2::FrameLimitError
        events << "limit #{error.limit} at #{error.byte_offset}"
        return events
      end
      break if offset >= bytes.size
    end
    events
  end

  # Returns a random frame of a random type.
  def self.random_frame(random : Random) : H2::Frame
    stream = random.rand(1_u32..H2::MAX_STREAM_ID)
    padding = random.rand(3) == 0 ? random.rand(0_u8..255_u8) : nil
    block = Bytes.new(random.rand(0..64)) { random.rand(256).to_u8 }
    priority = H2::Priority.new(random.rand(0_u32..H2::MAX_STREAM_ID), random.rand(256).to_u8, random.rand(2) == 0)
    priority = H2::Priority.new(stream &+ 1 & H2::MAX_STREAM_ID, priority.weight, priority.exclusive?) if priority.stream_dependency == stream
    case random.rand(10)
    when 0 then H2::DataFrame.new(stream, block, end_stream: random.rand(2) == 0, padding: padding)
    when 1
      H2::HeadersFrame.new(stream, block, end_stream: random.rand(2) == 0, end_headers: true,
        priority: random.rand(2) == 0 ? priority : nil, padding: padding)
    when 2 then H2::PriorityFrame.new(stream, priority)
    when 3 then H2::RstStreamFrame.new(stream, random.rand(UInt32::MAX))
    when 4
      ids = H2::SettingId.values
      settings = Array.new(random.rand(0..8)) do
        id = ids[random.rand(ids.size)]
        value = case id
                when .enable_push?, .enable_connect_protocol?, .no_rfc7540_priorities? then random.rand(0_u32..1_u32)
                when .initial_window_size?                                             then random.rand(0_u32..H2::MAX_WINDOW_SIZE)
                when .max_frame_size?                                                  then random.rand(16_384_u32..16_777_215_u32)
                else                                                                        random.rand(UInt32::MAX)
                end
        H2::Setting.new(id, value)
      end
      random.rand(4) == 0 ? H2::SettingsFrame.new(ack: true) : H2::SettingsFrame.new(settings)
    when 5 then H2::PushPromiseFrame.new(stream, random.rand(0_u32..H2::MAX_STREAM_ID), block, padding: padding)
    when 6 then H2::PingFrame.new(random.rand(UInt64::MAX), ack: random.rand(2) == 0)
    when 7 then H2::GoawayFrame.new(random.rand(0_u32..H2::MAX_STREAM_ID), random.rand(UInt32::MAX), block)
    when 8 then H2::WindowUpdateFrame.new(random.rand(0_u32..1_u32) * stream, random.rand(1_u32..H2::MAX_STREAM_ID))
    else
      # A header block split across HEADERS and CONTINUATION is built by
      # random_stream; alone, CONTINUATION would be out of sequence.
      H2::PingFrame.new(random.rand(UInt64::MAX))
    end
  end

  # Returns random frames, with some header blocks split into CONTINUATION
  # frames.
  def self.random_frames(random : Random, count : Int32) : Array(H2::Frame)
    list_of_frames = [] of H2::Frame
    count.times do
      if random.rand(6) == 0
        stream = random.rand(1_u32..1_000_u32)
        list_of_frames << H2::HeadersFrame.new(stream, Bytes.new(random.rand(0..20), 1_u8), end_headers: false)
        random.rand(0..3).times { list_of_frames << H2::ContinuationFrame.new(stream, Bytes.new(random.rand(0..20), 2_u8), end_headers: false) }
        list_of_frames << H2::ContinuationFrame.new(stream, Bytes.new(random.rand(0..20), 3_u8))
      else
        list_of_frames << random_frame(random)
      end
    end
    list_of_frames
  end

  def self.serialize(list_of_frames : Array(H2::Frame)) : Bytes
    io = IO::Memory.new
    list_of_frames.each { |frame| frame.write(io, max_frame_size: H2::DEFAULT_MAX_FRAME_SIZE) }
    io.to_slice
  end
end
