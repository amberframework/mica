# The smallest useful Mica Inflate program: decode a gzip file (or a
# built-in gzip member) one-shot and streaming, and a zlib stream. Its
# dynamic libraries and symbols are what any user of Mica::Deflate,
# Mica::Zlib and Mica::Gzip links (see scripts/check_linkage.sh), and
# they include no libz and no PCRE2.
require "../../src/mica/deflate"

# "hello, hello, hello\n" as gzip (FNAME "hello.txt") and as zlib.
GZIP_MEMBER = Bytes[0x1f, 0x8b, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e,
  0x74, 0x78, 0x74, 0x00, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0xc8, 0x40, 0xa2, 0xb8, 0x00, 0xe7, 0x42, 0x6e,
  0x52, 0x14, 0x00, 0x00, 0x00]
ZLIB_STREAM = Bytes[0x78, 0xda, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0xc8, 0x40, 0xa2, 0xb8, 0x00, 0x4b, 0x07,
  0x06, 0xdf]

limits = Mica::Deflate::DecodeLimits::REQUEST_BODY
input = ARGV[0]?.try { |path| File.read(path).to_slice } || GZIP_MEMBER
one_shot = Mica::Gzip.decode(input, limits: limits, timeout: 2.seconds)
reader = Mica::Gzip::Reader.new(IO::Memory.new(input), limits: limits, timeout: 2.seconds)
streamed = reader.gets_to_end
STDOUT << "gzip bytes=" << one_shot.size << " same=" << (streamed.to_slice == one_shot)
STDOUT << " name=" << reader.list_of_headers.first?.try(&.file_name).try { |name| String.new(name) }.inspect << '\n'
STDOUT << "zlib=" << String.new(Mica::Zlib.decode(ZLIB_STREAM, limits: limits, timeout: nil)).inspect << '\n'
