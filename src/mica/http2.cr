require "./core"
require "./hpack"

# The HTTP/2 frame layer (RFC 9113, sections 3.4, 4 and 6) in pure Crystal,
# without I/O: `FrameParser` takes the bytes a peer sends, in chunks of any
# size, and returns `Frame`s; each `Frame` serializes itself. Header blocks
# are compressed with `Mica::HPACK`.
#
# The parser applies every rule that one frame, or the run of frames that
# carries one header block, can break: lengths, flags, padding, stream
# identifiers, SETTINGS values, and the CONTINUATION sequence. Stream
# states, flow-control windows and abuse counters belong to the connection
# core that sits on top of it.
#
# ```
# parser = Mica::HTTP2::FrameParser.new(limits: Mica::HTTP2::FrameLimits::PUBLIC_SERVER, expect_preface: true)
# parser.feed(bytes_from_the_socket) do |frame|
#   # handle the frame
# end
# ```
module Mica::HTTP2
  # The client connection preface (RFC 9113, section 3.4).
  PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_slice

  # The size of a frame header.
  FRAME_HEADER_SIZE = 9

  # The largest stream identifier and window increment (2^31 - 1).
  MAX_STREAM_ID = 0x7fff_ffff_u32

  # The protocol's default and smallest SETTINGS_MAX_FRAME_SIZE, and its
  # largest.
  DEFAULT_MAX_FRAME_SIZE =     16_384
  LARGEST_MAX_FRAME_SIZE = 16_777_215

  # The largest SETTINGS_INITIAL_WINDOW_SIZE (2^31 - 1).
  MAX_WINDOW_SIZE = 0x7fff_ffff_u32
end

require "./http2/error_code"
require "./http2/errors"
require "./http2/frame_limits"
require "./http2/setting"
require "./http2/frame"
require "./http2/frame_parser"
