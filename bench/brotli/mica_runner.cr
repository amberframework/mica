# One engine of the Brotli decode benchmark: Mica::Brotli.
#
#   mica_runner MODE FILE REPS    MODE is oneshot or stream
#
# Decodes FILE (a .br stream) once to warm up, then REPS times, and prints
# one line: the decoded size and each decode's time in nanoseconds.
require "../../src/mica/brotli"

mode, path, reps = ARGV[0], ARGV[1], ARGV[2].to_i
input = File.read(path).to_slice
limits = Mica::Brotli::DecodeLimits::TRUSTED_ASSET
buffer = Bytes.new(65_536)
decode = ->do
  if mode == "oneshot"
    Mica::Brotli.decode(input, limits: limits, timeout: nil).size
  else
    reader = Mica::Brotli::Reader.new(IO::Memory.new(input, false), limits: limits, timeout: nil)
    total = 0
    while (count = reader.read(buffer)) > 0
      total += count
    end
    total
  end
end
size = decode.call
times = Array(Int64).new(reps) do
  started = Time.instant
  decode.call
  (Time.instant - started).total_nanoseconds.to_i64
end
puts "#{size} #{times.join(" ")}"
