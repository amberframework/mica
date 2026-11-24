# One engine of the Brotli encode benchmark: Mica::Brotli.encode.
#
#   mica_encode_runner FILE QUALITY REPS
#
# Encodes FILE once to warm up, then REPS times (window 22), and prints
# one line: the encoded size and each encode's time in nanoseconds.
require "../../src/mica/brotli"

path, quality, reps = ARGV[0], ARGV[1].to_i, ARGV[2].to_i
input = File.read(path).to_slice
size = Mica::Brotli.encode(input, quality: quality, window_bits: 22).size
times = Array(Int64).new(reps) do
  started = Time.instant
  Mica::Brotli.encode(input, quality: quality, window_bits: 22)
  (Time.instant - started).total_nanoseconds.to_i64
end
puts "#{size} #{times.join(" ")}"
