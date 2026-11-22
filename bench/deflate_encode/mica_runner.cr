# Engine runner: Mica's Deflate encoders from this checkout, one-shot
# (`mica-oneshot`, `Mica::Gzip.encode`) and streaming (`mica-stream`,
# `Mica::Gzip::Writer`). It references no stdlib `Compress` and binds no
# zlib, so the program links no libz; its streams are checked by Mica's own
# decoder here and by system zlib through `zlib_runner check`.
#   crystal-alpha build --release bench/deflate_encode/mica_runner.cr -o bench/bin/deflate_encode/mica_runner
#
# One more command reports the encoder's memory:
#   mica_runner memory LEVEL INPUT    prints the bytes a streaming encode of INPUT allocates
require "../../src/mica"
require "./src/deflate_encode_bench"
require "./src/deflate_encode_bench/mica_engines"
require "./src/deflate_encode_bench/measure_encoder_memory"

if ARGV[0]? == "memory"
  level = (ARGV[1]? || abort "usage: memory LEVEL INPUT").to_i
  input_path = ARGV[2]? || abort "usage: memory LEVEL INPUT"
  STDOUT.puts DeflateEncodeBench::MeasureEncoderMemory.new(level, input_path).perform.to_json
else
  DeflateEncodeBench::RunTheRunner.perform_or_exit(ARGV, {
    "mica-oneshot" => DeflateEncodeBench::EngineBuilder.new do |level|
      DeflateEncodeBench::MicaOneShotEngine.new(level).as(DeflateEncodeBench::Engine)
    end,
    "mica-stream" => DeflateEncodeBench::EngineBuilder.new do |level|
      DeflateEncodeBench::MicaStreamEngine.new(level).as(DeflateEncodeBench::Engine)
    end,
  })
end
