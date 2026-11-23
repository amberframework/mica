# One engine of the Brotli encode benchmark: google/brotli 1.2.1
# libbrotlienc (BrotliEncoderCompress, generic mode, window 22), built out
# of tree; build with --link-flags naming libbrotli.a.
#
#   ref_encode_runner FILE QUALITY REPS
lib LibRef
  fun BrotliEncoderCompress(quality : Int32, lgwin : Int32, mode : Int32, input_size : LibC::SizeT, input : UInt8*, encoded_size : LibC::SizeT*, encoded : UInt8*) : Int32
  fun BrotliEncoderMaxCompressedSize(input_size : LibC::SizeT) : LibC::SizeT
end

path, quality, reps = ARGV[0], ARGV[1].to_i, ARGV[2].to_i
input = File.read(path).to_slice
output = Bytes.new(LibRef.BrotliEncoderMaxCompressedSize(input.size))
encode = -> do
  size = LibC::SizeT.new(output.size)
  raise "BrotliEncoderCompress failed" unless LibRef.BrotliEncoderCompress(quality, 22, 0, input.size, input.to_unsafe, pointerof(size), output.to_unsafe) == 1
  size.to_i32
end
size = encode.call
times = Array(Int64).new(reps) do
  started = Time.instant
  encode.call
  (Time.instant - started).total_nanoseconds.to_i64
end
puts "#{size} #{times.join(" ")}"
