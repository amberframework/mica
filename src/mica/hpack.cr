require "./core"

# HPACK, the header compression of HTTP/2 (RFC 7541), in pure Crystal.
#
# `Decoder` turns header blocks into `Header`s and `Encoder` turns headers
# into blocks. Each side keeps the dynamic table of one direction of one
# connection, so a connection owns one of each, and each is confined to the
# fiber that reads or writes (neither is concurrency-safe).
#
# A decoder takes required `limits:` (`DecodeLimits`): the decoded header
# list it may produce, the encoded block it may read, the table size it
# advertises and the work it may do. The list limit counts decoded bytes as
# they are produced, so a block that expands through table references (an
# HPACK bomb) stops at the limit and costs no more memory than the limit.
#
# ```
# encoder = Mica::HPACK::Encoder.new
# block = encoder.encode([Mica::HPACK::Header.new(":method", "GET")])
# decoder = Mica::HPACK::Decoder.new(limits: Mica::HPACK::DecodeLimits::PUBLIC_SERVER)
# decoder.decode(block) # => [Mica::HPACK::Header(@name=":method", @value="GET", @never_indexed=false)]
# ```
module Mica::HPACK
  # The bytes RFC 7541 section 4.1 adds to every entry when it sizes the
  # dynamic table and a header list.
  ENTRY_OVERHEAD = 32

  # The largest integer a decoder accepts (2^31 - 1), and the most
  # continuation octets one may use.
  MAX_INTEGER             = 2_147_483_647_i64
  MAX_CONTINUATION_OCTETS =                 5
  DEFAULT_TABLE_SIZE      =             4_096
end

require "./hpack/errors"
require "./hpack/decode_limits"
require "./hpack/header"
require "./hpack/prefix_integer"
require "./hpack/static_table"
require "./hpack/huffman"
require "./hpack/dynamic_table"
require "./hpack/decoder"
require "./hpack/encoder"
