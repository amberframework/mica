# Engine runner: system zlib through the harness's own binding, one-shot
# with a new output buffer per decode (`zlib-oneshot-fresh`, the baseline), one-shot
# into one reused buffer (`zlib-oneshot-reused`, zlib's best case) and
# streaming (`zlib-stream`). It requires no Mica and no stdlib `Compress`
# (whose `LibZ` binds the same C functions with other signatures).
#   crystal-alpha build --release bench/deflate/zlib_runner.cr -o bench/bin/deflate/zlib_runner
#
# Two more commands prepare a run:
#   zlib_runner zlib-version                       prints zlibVersion()
#   zlib_runner compress ORIGINAL OUTPUT_PREFIX    writes OUTPUT_PREFIX.gz, .zz and .deflate at level 6
require "./src/deflate_bench"
require "./src/deflate_bench/zlib_engines"
require "./src/deflate_bench/compress_with_system_zlib"

case ARGV[0]?
when "zlib-version"
  STDOUT.puts DeflateBench::SystemZ.version
when "compress"
  original_path = ARGV[1]? || abort "usage: compress ORIGINAL OUTPUT_PREFIX"
  output_prefix = ARGV[2]? || abort "usage: compress ORIGINAL OUTPUT_PREFIX"
  STDOUT.puts DeflateBench::CompressWithSystemZlib.new(original_path, output_prefix).perform.to_json
else
  DeflateBench::RunTheRunner.perform_or_exit(ARGV, {
    "zlib-oneshot-fresh" => DeflateBench::EngineBuilder.new do |format, expected_bytes|
      DeflateBench::ZlibOneShotFreshBufferEngine.new(format, expected_bytes).as(DeflateBench::Engine)
    end,
    "zlib-oneshot-reused" => DeflateBench::EngineBuilder.new do |format, expected_bytes|
      DeflateBench::ZlibOneShotReusedBufferEngine.new(format, expected_bytes).as(DeflateBench::Engine)
    end,
    "zlib-stream" => DeflateBench::EngineBuilder.new do |format, expected_bytes|
      DeflateBench::ZlibStreamEngine.new(format, expected_bytes).as(DeflateBench::Engine)
    end,
  })
end
