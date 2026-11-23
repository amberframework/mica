module Mica::HTTP2
  # Upper bounds on the frames one `FrameParser` accepts. A parser takes
  # them as a required `limits:` argument (there is no default): use a
  # preset (`PUBLIC_SERVER`, `INTERNAL_SERVER`, `CLIENT`) or
  # `FrameLimits.custom`.
  #
  # ```
  # limits = Mica::HTTP2::FrameLimits.custom(max_continuation_frames: 4)
  # limits.max_frame_size # => 16_384 (from PUBLIC_SERVER)
  # ```
  struct FrameLimits
    # The SETTINGS_MAX_FRAME_SIZE this side advertises: the largest frame
    # payload it accepts (16,384 to 16,777,215).
    getter max_frame_size : Int32
    # Field block bytes across one HEADERS or PUSH_PROMISE frame and its
    # CONTINUATION frames, counted as each frame arrives (CONTINUATION
    # flood, VU#421644).
    getter max_header_block_bytes : Int32
    # CONTINUATION frames per header block.
    getter max_continuation_frames : Int32

    def initialize(@max_frame_size : Int32, @max_header_block_bytes : Int32, @max_continuation_frames : Int32)
      unless DEFAULT_MAX_FRAME_SIZE <= @max_frame_size <= LARGEST_MAX_FRAME_SIZE
        raise ArgumentError.new("max_frame_size must be between #{DEFAULT_MAX_FRAME_SIZE} and #{LARGEST_MAX_FRAME_SIZE}")
      end
      raise ArgumentError.new("max_header_block_bytes must not be negative") if @max_header_block_bytes < 0
      raise ArgumentError.new("max_continuation_frames must not be negative") if @max_continuation_frames < 0
    end

    # Returns limits that start from `PUBLIC_SERVER` and change only the
    # values given.
    def self.custom(*, max_frame_size : Int32 = PUBLIC_SERVER.max_frame_size,
                    max_header_block_bytes : Int32 = PUBLIC_SERVER.max_header_block_bytes,
                    max_continuation_frames : Int32 = PUBLIC_SERVER.max_continuation_frames) : self
      new(max_frame_size, max_header_block_bytes, max_continuation_frames)
    end

    # For a server that faces the internet: the protocol's 16 KiB frames,
    # 32 KiB header blocks in at most 16 CONTINUATION frames.
    PUBLIC_SERVER = new(max_frame_size: DEFAULT_MAX_FRAME_SIZE, max_header_block_bytes: 32_768,
      max_continuation_frames: 16)

    # For a server behind a proxy the operator runs: 128 KiB header blocks
    # in at most 64 CONTINUATION frames.
    INTERNAL_SERVER = new(max_frame_size: DEFAULT_MAX_FRAME_SIZE, max_header_block_bytes: 131_072,
      max_continuation_frames: 64)

    # For a client reading from servers it does not control: 128 KiB header
    # blocks in at most 64 CONTINUATION frames.
    CLIENT = new(max_frame_size: DEFAULT_MAX_FRAME_SIZE, max_header_block_bytes: 131_072,
      max_continuation_frames: 64)
  end
end
