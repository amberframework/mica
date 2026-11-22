# The smallest useful Mica Deflate encoder program: gzip a file (or a
# built-in text) one-shot and through the Writer, compress it as zlib and
# raw DEFLATE, and decode everything again. Its dynamic libraries and
# symbols are what any user of the Mica::Deflate, Mica::Zlib and Mica::Gzip
# encoders links (see scripts/check_linkage.sh), and they include no libz
# and no PCRE2.
require "../../src/mica/deflate"

limits = Mica::Deflate::DecodeLimits::REQUEST_BODY
input = ARGV[0]?.try { |path| File.read(path).to_slice } || ("hello, hello, hello\n" * 40).to_slice

one_shot = Mica::Gzip.encode(input, level: 6)
io = IO::Memory.new
writer = Mica::Gzip::Writer.new(io, level: 6)
writer.write(input)
writer.close
STDOUT << "gzip bytes=" << one_shot.size << " writer_same=" << (io.to_slice == one_shot)
STDOUT << " round_trip=" << (Mica::Gzip.decode(one_shot, limits: limits, timeout: 2.seconds) == input) << '\n'
zlib_stream = Mica::Zlib.encode(input, level: 9)
raw_stream = Mica::Deflate.encode(input, level: 1)
STDOUT << "zlib bytes=" << zlib_stream.size << " round_trip="
STDOUT << (Mica::Zlib.decode(zlib_stream, limits: limits, timeout: nil) == input)
STDOUT << " deflate bytes=" << raw_stream.size << " round_trip="
STDOUT << (Mica::Deflate.decode(raw_stream, limits: limits, timeout: nil) == input) << '\n'
