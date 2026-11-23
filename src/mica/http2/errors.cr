module Mica::HTTP2
  # Raised when a frame, or the run of frames carrying one header block,
  # breaks RFC 9113. `error_code` is the code RFC 9113 assigns, and
  # `connection_error?` says whether the whole connection must close
  # (GOAWAY) or only the stream `stream_id` must reset (RST_STREAM).
  # `byte_offset` is the 0-based offset, in everything the parser was fed
  # (the preface included), of the frame header where the problem was
  # found.
  #
  # After a connection error the parser raises it again on every call. After
  # a stream error the parser has consumed the frame and goes on with the
  # next one; `frame` is the parsed frame when the connection still needs
  # it (a HEADERS frame whose field block must reach the HPACK decoder to
  # keep its table in step).
  class FrameError < Mica::ParseError
    getter error_code : ErrorCode
    getter stream_id : UInt32
    getter frame : Frame?

    def initialize(detail : String, position : Core::Position, @error_code : ErrorCode, @connection_error : Bool,
                   @stream_id : UInt32 = 0_u32, @frame : Frame? = nil)
      super(detail, position)
    end

    # Returns true for a connection error, false for a stream error.
    def connection_error? : Bool
      @connection_error
    end
  end

  # Raised when the frames that carry one header block pass one of the
  # parser's `FrameLimits`. `limit` names it: "max_header_block_bytes" or
  # "max_continuation_frames". Always a connection error, with
  # `error_code` ENHANCE_YOUR_CALM.
  class FrameLimitError < Mica::LimitExceededError
    getter limit : String
    getter error_code : ErrorCode = ErrorCode::EnhanceYourCalm

    def initialize(detail : String, position : Core::Position, @limit : String)
      super(detail, position)
    end

    # Returns true: the connection must close.
    def connection_error? : Bool
      true
    end
  end
end
