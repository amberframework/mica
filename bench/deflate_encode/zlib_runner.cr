# Engine runner: system zlib's deflate through the harness's own binding
# (bench/deflate/src/deflate_bench/lib_system_z.cr), one-shot
# (`zlib-oneshot`: `deflateInit2`, `deflate(Z_FINISH)` into a
# `deflateBound`-sized buffer allocated per encode, `deflateEnd`) and
# streaming (`zlib-stream`: 64 KiB pieces). It requires no Mica and no
# stdlib `Compress`.
#   crystal-alpha build --release bench/deflate_encode/zlib_runner.cr -o bench/bin/deflate_encode/zlib_runner
#
# One more command prepares a run:
#   zlib_runner zlib-version    prints zlibVersion()
require "./src/deflate_encode_bench"
require "./src/deflate_encode_bench/zlib_engines"

if ARGV[0]? == "zlib-version"
  STDOUT.puts DeflateEncodeBench::SystemZ.version
else
  DeflateEncodeBench::RunTheRunner.perform_or_exit(ARGV, {
    "zlib-oneshot" => DeflateEncodeBench::EngineBuilder.new do |level|
      DeflateEncodeBench::ZlibOneShotEngine.new(level).as(DeflateEncodeBench::Engine)
    end,
    "zlib-stream" => DeflateEncodeBench::EngineBuilder.new do |level|
      DeflateEncodeBench::ZlibStreamEngine.new(level).as(DeflateEncodeBench::Engine)
    end,
  })
end
