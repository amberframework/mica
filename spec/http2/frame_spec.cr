require "./support"

private alias H2 = Mica::HTTP2
private alias S = HTTP2Spec

private def expect_frame_error(bytes : Bytes, code : H2::ErrorCode, connection : Bool) : H2::FrameError
  error = S.error(bytes)
  error.error_code.should eq code
  error.connection_error?.should eq connection
  error
end

describe Mica::HTTP2::FrameParser do
  it_satisfies "H2-9113-3.4-preface", "accepts the client preface in any chunking and fails at the first differing byte" do
    bytes = S.serialize([H2::SettingsFrame.new] of H2::Frame)
    whole = IO::Memory.new
    whole.write(H2::PREFACE)
    whole.write(bytes)
    [1, 3, 7, 24, 100].each do |chunk|
      S.outcome(whole.to_slice, [chunk], expect_preface: true).should eq [H2::SettingsFrame.new.inspect]
    end
    parser = S.parser(expect_preface: true)
    parser.feed("PRI * HTTP/2.0\r\n".to_slice)
    parser.next_frame.should be_nil
    parser.preface_received?.should be_false
    bad = "PRI * HTTP/1.1\r\n\r\nSM\r\n\r\n".to_slice
    S.outcome(bad, [1], expect_preface: true).should eq ["connection ProtocolError at 11"]
    expect_raises(H2::FrameError, /preface/) { S.parser(expect_preface: true).feed("GET / HTTP/1.1\r\n".to_slice) { } }
  end

  it_satisfies "H2-9113-4.1-frame-header", "reads 24-bit lengths and 31-bit stream identifiers, ignoring the reserved bit" do
    frame = S.frames(S.raw(0, 0, 0x8000_0003_u32, "abc".to_slice)).first.as(H2::DataFrame)
    frame.stream_id.should eq 3
    frame.data.should eq "abc".to_slice
    # Serializing clears the reserved bit.
    bytes = H2::WindowUpdateFrame.new(H2::MAX_STREAM_ID, H2::MAX_STREAM_ID).to_slice(max_frame_size: 16_384)
    bytes.should eq Bytes[0, 0, 4, 8, 0, 0x7f, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff]
    limits = H2::FrameLimits.custom(max_frame_size: H2::LARGEST_MAX_FRAME_SIZE)
    big = S.frames(S.raw(0, 0, 1_u32, Bytes.new(70_000)), limits).first.as(H2::DataFrame)
    big.data.size.should eq 70_000
    expect_raises(ArgumentError) { H2::DataFrame.new(0x8000_0000_u32, Bytes.empty) }
  end

  it_satisfies "H2-9113-4.1-unknown-type", "skips frames of unknown types" do
    bytes = IO::Memory.new
    bytes.write(S.raw(0x0a, 0xff, 1_u32, Bytes.new(30)))
    bytes.write(S.raw(0xff, 0, 0_u32))
    bytes.write(H2::PingFrame.new(7_u64).to_slice(max_frame_size: 16_384))
    S.frames(bytes.to_slice).should eq [H2::PingFrame.new(7_u64)] of H2::Frame
  end

  it_satisfies "H2-9113-4.1-unknown-flags", "ignores flags a frame type does not define" do
    S.frames(S.raw(6, 0xfe, 0_u32, Bytes.new(8))).should eq [H2::PingFrame.new(0_u64)] of H2::Frame
    S.frames(S.raw(0, 0xf6, 1_u32)).should eq [H2::DataFrame.new(1_u32, Bytes.empty)] of H2::Frame
    S.frames(S.raw(3, 0xff, 1_u32, S.u32(8))).should eq [H2::RstStreamFrame.new(1_u32, H2::ErrorCode::Cancel)] of H2::Frame
  end

  it_satisfies "H2-9113-4.2-frame-size", "rejects a frame over SETTINGS_MAX_FRAME_SIZE when its header arrives" do
    parser = S.parser
    parser.feed(S.raw(0, 0, 1_u32, Bytes.empty, length: 16_385)[0, 9])
    error = expect_raises(H2::FrameError) { parser.next_frame }
    error.error_code.should eq H2::ErrorCode::FrameSizeError
    error.connection_error?.should be_true
    S.frames(S.raw(0, 0, 1_u32, Bytes.new(16_384))).size.should eq 1
    expect_raises(ArgumentError) { H2::DataFrame.new(1_u32, Bytes.new(16_385)).to_slice(max_frame_size: 16_384) }
    expect_raises(ArgumentError) { H2::FrameLimits.custom(max_frame_size: 16_383) }
  end

  it_satisfies "H2-9113-6.1-data", "parses DATA with END_STREAM and rejects it on stream 0" do
    S.frames(S.raw(0, 1, 5_u32, "hi".to_slice)).should eq [H2::DataFrame.new(5_u32, "hi".to_slice, end_stream: true)] of H2::Frame
    expect_frame_error(S.raw(0, 0, 0_u32, "hi".to_slice), H2::ErrorCode::ProtocolError, true)
  end

  it_satisfies "H2-9113-6.1-padding", "validates padding on DATA, HEADERS and PUSH_PROMISE" do
    S.frames(S.raw(0, 8, 1_u32, Bytes[2, 'a'.ord, 0, 0])).should eq [H2::DataFrame.new(1_u32, "a".to_slice, padding: 2_u8)] of H2::Frame
    S.frames(S.raw(0, 8, 1_u32, Bytes[3, 0, 0, 0])).should eq [H2::DataFrame.new(1_u32, Bytes.empty, padding: 3_u8)] of H2::Frame
    expect_frame_error(S.raw(0, 8, 1_u32, Bytes[4, 0, 0, 0]), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(S.raw(0, 8, 1_u32, Bytes.empty), H2::ErrorCode::FrameSizeError, true)
    expect_frame_error(S.raw(1, 0x0c, 1_u32, Bytes[2, 0x82]), H2::ErrorCode::ProtocolError, true)
    # HEADERS with PRIORITY: padding may not reach into the 5 priority bytes.
    expect_frame_error(S.raw(1, 0x2c, 1_u32, Bytes[2, 0, 0, 0, 0, 16, 0x82]), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(S.raw(5, 0x0c, 1_u32, Bytes[1, 0, 0, 0, 2]), H2::ErrorCode::ProtocolError, true)
  end

  it_satisfies "H2-9113-6.2-headers", "parses HEADERS fields, priority and padding" do
    frame = S.frames(S.raw(1, 0x2d, 3_u32, Bytes[1, 0x80, 0, 0, 1, 15, 0x82, 0])).first.as(H2::HeadersFrame)
    frame.should eq H2::HeadersFrame.new(3_u32, Bytes[0x82], end_stream: true, end_headers: true,
      priority: H2::Priority.new(1_u32, 15_u8, true), padding: 1_u8)
    expect_frame_error(S.raw(1, 4, 0_u32, Bytes[0x82]), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(S.raw(1, 0x24, 1_u32, Bytes[0, 0, 0]), H2::ErrorCode::FrameSizeError, true)
    error = expect_frame_error(S.raw(1, 0x24, 3_u32, Bytes[0, 0, 0, 3, 15, 0x82]), H2::ErrorCode::ProtocolError, false)
    error.stream_id.should eq 3
    error.frame.as(H2::HeadersFrame).field_block.should eq Bytes[0x82]
  end

  it_satisfies "H2-9113-6.3-priority", "checks PRIORITY's length, stream and dependency" do
    S.frames(S.raw(2, 0, 3_u32, Bytes[0, 0, 0, 1, 255])).should eq [H2::PriorityFrame.new(3_u32, H2::Priority.new(1_u32, 255_u8))] of H2::Frame
    expect_frame_error(S.raw(2, 0, 3_u32, Bytes[0, 0, 0, 1]), H2::ErrorCode::FrameSizeError, false)
    expect_frame_error(S.raw(2, 0, 0_u32, Bytes[0, 0, 0, 1, 1]), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(S.raw(2, 0, 3_u32, Bytes[0, 0, 0, 3, 1]), H2::ErrorCode::ProtocolError, false)
  end

  it_satisfies "H2-9113-6.4-rst-stream", "checks RST_STREAM's length and stream, and keeps unknown codes" do
    frame = S.frames(S.raw(3, 0, 1_u32, S.u32(0x99))).first.as(H2::RstStreamFrame)
    frame.error_code.should be_nil
    frame.error_code_value.should eq 0x99
    expect_frame_error(S.raw(3, 0, 1_u32, Bytes[0, 0, 0]), H2::ErrorCode::FrameSizeError, true)
    expect_frame_error(S.raw(3, 0, 0_u32, S.u32(0)), H2::ErrorCode::ProtocolError, true)
  end

  it_satisfies "H2-9113-6.5-settings", "checks SETTINGS framing, acknowledgments and unknown parameters" do
    payload = Bytes[0, 1, 0, 0, 0x10, 0, 0, 0x77, 0, 0, 0, 1, 0, 3, 0, 0, 0, 100]
    S.frames(S.raw(4, 0, 0_u32, payload)).should eq [H2::SettingsFrame.new([
      H2::Setting.new(H2::SettingId::HeaderTableSize, 4_096_u32), H2::Setting.new(H2::SettingId::MaxConcurrentStreams, 100_u32),
    ])] of H2::Frame
    S.frames(S.raw(4, 1, 0_u32)).should eq [H2::SettingsFrame.new(ack: true)] of H2::Frame
    expect_frame_error(S.raw(4, 1, 0_u32, Bytes[0, 1, 0, 0, 0, 0]), H2::ErrorCode::FrameSizeError, true)
    expect_frame_error(S.raw(4, 0, 0_u32, Bytes[0, 1, 0, 0, 0]), H2::ErrorCode::FrameSizeError, true)
    expect_frame_error(S.raw(4, 0, 1_u32), H2::ErrorCode::ProtocolError, true)
    expect_raises(ArgumentError) { H2::SettingsFrame.new([H2::Setting.new(H2::SettingId::EnablePush, 0_u32)], ack: true) }
  end

  it_satisfies "H2-9113-6.5.2-settings-values", "checks the ranges of SETTINGS values" do
    setting = ->(id : Int32, value : UInt32) { S.raw(4, 0, 0_u32, Bytes[0, id.to_u8] + S.u32(value)) }
    {2, 8, 9}.each do |id|
      S.frames(setting.call(id, 1_u32)).size.should eq 1
      expect_frame_error(setting.call(id, 2_u32), H2::ErrorCode::ProtocolError, true)
    end
    S.frames(setting.call(4, H2::MAX_WINDOW_SIZE)).size.should eq 1
    expect_frame_error(setting.call(4, H2::MAX_WINDOW_SIZE + 1), H2::ErrorCode::FlowControlError, true)
    S.frames(setting.call(5, 16_384_u32)).size.should eq 1
    S.frames(setting.call(5, 16_777_215_u32)).size.should eq 1
    expect_frame_error(setting.call(5, 16_383_u32), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(setting.call(5, 16_777_216_u32), H2::ErrorCode::ProtocolError, true)
  end

  it_satisfies "H2-9113-6.6-push-promise", "parses PUSH_PROMISE and rejects it on stream 0" do
    S.frames(S.raw(5, 4, 1_u32, S.u32(0x8000_0002) + Bytes[0x82])).should eq [H2::PushPromiseFrame.new(1_u32, 2_u32, Bytes[0x82])] of H2::Frame
    expect_frame_error(S.raw(5, 4, 0_u32, S.u32(2)), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(S.raw(5, 4, 1_u32, Bytes[0, 0]), H2::ErrorCode::FrameSizeError, true)
  end

  it_satisfies "H2-9113-6.7-ping", "checks PING's length and stream" do
    S.frames(S.raw(6, 1, 0_u32, Bytes[0, 0, 0, 0, 0, 0, 1, 2])).should eq [H2::PingFrame.new(258_u64, ack: true)] of H2::Frame
    expect_frame_error(S.raw(6, 0, 0_u32, Bytes.new(7)), H2::ErrorCode::FrameSizeError, true)
    expect_frame_error(S.raw(6, 0, 1_u32, Bytes.new(8)), H2::ErrorCode::ProtocolError, true)
  end

  it_satisfies "H2-9113-6.8-goaway", "checks GOAWAY's length and stream, and keeps its debug data" do
    S.frames(S.raw(7, 0, 0_u32, S.u32(0x8000_0007) + S.u32(0xb) + "calm".to_slice)).should eq [
      H2::GoawayFrame.new(7_u32, H2::ErrorCode::EnhanceYourCalm, "calm".to_slice),
    ] of H2::Frame
    expect_frame_error(S.raw(7, 0, 0_u32, Bytes.new(7)), H2::ErrorCode::FrameSizeError, true)
    expect_frame_error(S.raw(7, 0, 1_u32, Bytes.new(8)), H2::ErrorCode::ProtocolError, true)
  end

  it_satisfies "H2-9113-6.9-window-update", "checks WINDOW_UPDATE's length and zero increments" do
    S.frames(S.raw(8, 0, 0_u32, S.u32(0x8000_0001))).should eq [H2::WindowUpdateFrame.new(0_u32, 1_u32)] of H2::Frame
    expect_frame_error(S.raw(8, 0, 1_u32, Bytes.new(3)), H2::ErrorCode::FrameSizeError, true)
    expect_frame_error(S.raw(8, 0, 0_u32, S.u32(0)), H2::ErrorCode::ProtocolError, true)
    error = expect_frame_error(S.raw(8, 0, 9_u32, S.u32(0x8000_0000)), H2::ErrorCode::ProtocolError, false)
    error.stream_id.should eq 9
  end

  it_satisfies "H2-9113-6.10-continuation", "keeps a header block's frames together" do
    headers = S.raw(1, 0, 1_u32, Bytes[0x82])
    continuation = S.raw(9, 4, 1_u32, Bytes[0x84])
    S.frames(headers + continuation).should eq [
      H2::HeadersFrame.new(1_u32, Bytes[0x82], end_headers: false), H2::ContinuationFrame.new(1_u32, Bytes[0x84]),
    ] of H2::Frame
    expect_frame_error(headers + S.raw(9, 4, 3_u32, Bytes[0x84]), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(headers + S.raw(6, 0, 0_u32, Bytes.new(8)), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(headers + S.raw(0x0a, 0, 1_u32), H2::ErrorCode::ProtocolError, true)
    expect_frame_error(continuation, H2::ErrorCode::ProtocolError, true)
    expect_frame_error(S.raw(9, 4, 0_u32, Bytes[0x84]), H2::ErrorCode::ProtocolError, true)
    promise = S.raw(5, 0, 1_u32, S.u32(2) + Bytes[0x82])
    S.frames(promise + continuation).size.should eq 2
  end

  it_satisfies "H2-9113-7-error-codes", "defines the 14 error codes" do
    H2::ErrorCode.values.size.should eq 14
    H2::ErrorCode::Http11Required.value.should eq 0xd
    H2::ErrorCode::EnhanceYourCalm.value.should eq 0xb
  end

  it_satisfies "H2-LIMIT-header-block", "stops a CONTINUATION flood at max_continuation_frames and max_header_block_bytes" do
    limits = H2::FrameLimits.custom(max_continuation_frames: 3, max_header_block_bytes: 100)
    flood = IO::Memory.new
    flood.write(S.raw(1, 0, 1_u32, Bytes[0x82]))
    10.times { flood.write(S.raw(9, 0, 1_u32, Bytes[0x82])) }
    S.outcome(flood.to_slice, limits: limits).last.should eq "limit max_continuation_frames at 40"
    big = S.raw(1, 0, 1_u32, Bytes.new(60)) + S.raw(9, 0, 1_u32, Bytes.new(41))
    S.outcome(big, limits: limits).last.should eq "limit max_header_block_bytes at 69"
    S.outcome(S.raw(1, 4, 1_u32, Bytes.new(101)), limits: limits).last.should eq "limit max_header_block_bytes at 0"
  end

  it_satisfies "H2-API-errors", "repeats a connection error and continues after a stream error" do
    parser = S.parser
    parser.feed(S.raw(2, 0, 3_u32, Bytes[0, 0, 0, 1]) + H2::PingFrame.new(1_u64).to_slice(max_frame_size: 16_384))
    expect_raises(H2::FrameError) { parser.next_frame }
    parser.next_frame.should eq H2::PingFrame.new(1_u64)
    parser.feed(S.raw(6, 0, 1_u32, Bytes.new(8)) + H2::PingFrame.new(2_u64).to_slice(max_frame_size: 16_384))
    expect_raises(H2::FrameError) { parser.next_frame }
    expect_raises(H2::FrameError) { parser.next_frame }
  end
end
