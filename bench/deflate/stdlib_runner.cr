# Engine runner: Crystal's stdlib readers (`Compress::Gzip::Reader`,
# `Compress::Zlib::Reader`, `Compress::Deflate::Reader`) as the context row
# `stdlib-reader`: what a Crystal program uses today, over the same zlib.
#   crystal-alpha build --release bench/deflate/stdlib_runner.cr -o bench/bin/deflate/stdlib_runner
require "./src/deflate_bench"
require "./src/deflate_bench/stdlib_engines"

DeflateBench::RunTheRunner.perform_or_exit(ARGV, {
  "stdlib-reader" => DeflateBench::EngineBuilder.new do |format, expected_bytes|
    DeflateBench::StdlibReaderEngine.new(format, expected_bytes).as(DeflateBench::Engine)
  end,
})
