# One engine of the Brotli decode benchmark: google/brotli 1.2.1
# libbrotlidec, built out of tree; build with --link-flags naming libbrotli.a.
#
#   ref_runner MODE FILE REPS    MODE is oneshot or stream
#
# oneshot: BrotliDecoderDecompress into a new buffer of the decoded size
# (the reference is told the size; Mica is not). stream: one decoder
# state, 64 KiB output chunks.
lib LibRef
  fun BrotliDecoderDecompress(encoded_size : LibC::SizeT, encoded : UInt8*, decoded_size : LibC::SizeT*, decoded : UInt8*) : Int32
  fun BrotliDecoderCreateInstance(alloc : Void*, free : Void*, opaque : Void*) : Void*
  fun BrotliDecoderDestroyInstance(state : Void*)
  fun BrotliDecoderDecompressStream(state : Void*, available_in : LibC::SizeT*, next_in : UInt8**, available_out : LibC::SizeT*, next_out : UInt8**, total_out : LibC::SizeT*) : Int32
end

mode, path, reps = ARGV[0], ARGV[1], ARGV[2].to_i
input = File.read(path).to_slice
expected = ARGV[3].to_i
chunk = Bytes.new(65_536)
decode = ->do
  if mode == "oneshot"
    output = Bytes.new(expected)
    size = LibC::SizeT.new(expected)
    raise "decode failed" unless LibRef.BrotliDecoderDecompress(input.size, input.to_unsafe, pointerof(size), output.to_unsafe) == 1
    size.to_i32
  else
    state = LibRef.BrotliDecoderCreateInstance(nil, nil, nil)
    avail_in = LibC::SizeT.new(input.size)
    next_in = input.to_unsafe
    total = LibC::SizeT.new(0)
    loop do
      avail_out = LibC::SizeT.new(chunk.size)
      next_out = chunk.to_unsafe
      result = LibRef.BrotliDecoderDecompressStream(state, pointerof(avail_in), pointerof(next_in), pointerof(avail_out), pointerof(next_out), pointerof(total))
      break if result == 1
      raise "decode failed" unless result == 3
    end
    LibRef.BrotliDecoderDestroyInstance(state)
    total.to_i32
  end
end
size = decode.call
times = Array(Int64).new(reps) do
  started = Time.instant
  decode.call
  (Time.instant - started).total_nanoseconds.to_i64
end
puts "#{size} #{times.join(" ")}"
