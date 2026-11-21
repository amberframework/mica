# Negative control for scripts/check_linkage.sh: a program that decodes
# gzip with the standard library's Compress::Gzip. The check must find
# libz in it, proving the probes would catch libz in minimal_inflate if it
# were there.
require "compress/gzip"

io = IO::Memory.new
Compress::Gzip::Writer.open(io) { |gzip| gzip << (ARGV[0]? || "hello") }
io.rewind
STDOUT << Compress::Gzip::Reader.new(io).gets_to_end << '\n'
