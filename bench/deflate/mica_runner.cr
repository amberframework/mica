# Engine runner: Mica's Inflate decoders from this checkout, one-shot
# (`mica-oneshot`) and streaming (`mica-stream`). It references no stdlib
# `Compress` and binds no zlib, so the program links no libz.
#   crystal-alpha build --release bench/deflate/mica_runner.cr -o bench/bin/deflate/mica_runner
require "../../src/mica"
require "./src/deflate_bench"
require "./src/deflate_bench/mica_engines"

DeflateBench::RunTheRunner.perform_or_exit(ARGV, {
  "mica-oneshot" => DeflateBench::EngineBuilder.new do |format, expected_bytes|
    DeflateBench::MicaOneShotEngine.new(format, expected_bytes).as(DeflateBench::Engine)
  end,
  "mica-stream" => DeflateBench::EngineBuilder.new do |format, expected_bytes|
    DeflateBench::MicaStreamEngine.new(format, expected_bytes).as(DeflateBench::Engine)
  end,
})
