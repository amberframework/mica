# HTTP/2 frames and HPACK

`Mica::HTTP2` is the frame layer of HTTP/2 (RFC 9113) and `Mica::HPACK` its
header compression (RFC 7541), in pure Crystal with no I/O. They are the
parsing half of HTTP/2: Amber owns sockets, TLS, timers and scheduling, and
the connection core (stream states, flow-control windows, abuse counters)
comes next as milestone H2.3.

## Frames

`FrameParser` takes the bytes a peer sends, in chunks of any size, and
returns frames as they complete. A stream fed one byte at a time gives the
same frames and errors as the same stream fed at once.

```crystal
parser = Mica::HTTP2::FrameParser.new(limits: Mica::HTTP2::FrameLimits::PUBLIC_SERVER, expect_preface: true)
parser.feed(chunk) do |frame|
  if frame.is_a?(Mica::HTTP2::HeadersFrame)
    # frame.field_block goes to the connection's HPACK decoder
  end
end
```

- A server parser (`expect_preface: true`) checks the 24-byte client
  preface first and fails at the first byte that differs.
- The ten frame types are structs: `DataFrame`, `HeadersFrame`,
  `PriorityFrame`, `RstStreamFrame`, `SettingsFrame`, `PushPromiseFrame`,
  `PingFrame`, `GoawayFrame`, `WindowUpdateFrame`, `ContinuationFrame`.
  Each serializes itself with `to_slice(max_frame_size:)` or
  `write(io, max_frame_size:)`, and a parsed frame serializes back to the
  same frame. The reserved bit is ignored on receipt and cleared on send.
- Frames of unknown types, flags a type does not define and SETTINGS
  parameters the codec does not know are ignored, as RFC 9113 requires.
- Every rule one frame can break raises `FrameError` with the RFC 9113
  `ErrorCode` and `connection_error?`. After a connection error the parser
  raises it again on every call; after a stream error it has consumed the
  frame and goes on. A HEADERS frame that makes its stream depend on itself
  is a stream error that still carries the frame (`FrameError#frame`), so
  its field block can reach the HPACK decoder.

### Frame limits

`FrameLimits` is a required argument, with three presets.

| Limit | `PUBLIC_SERVER` | `INTERNAL_SERVER` | `CLIENT` |
|---|---|---|---|
| `max_frame_size` (our SETTINGS_MAX_FRAME_SIZE) | 16,384 | 16,384 | 16,384 |
| `max_header_block_bytes` (HEADERS or PUSH_PROMISE plus CONTINUATION) | 32,768 | 131,072 | 131,072 |
| `max_continuation_frames` per header block | 16 | 64 | 64 |

A frame longer than `max_frame_size` fails with FRAME_SIZE_ERROR as soon
as its 9-byte header arrives, before its payload is buffered (Mica treats
every oversized frame as a connection error). A header block passing
either block limit raises `FrameLimitError` (ENHANCE_YOUR_CALM) when the
frame that passes it arrives: the CONTINUATION flood answer of the plan.

## HPACK

```crystal
decoder = Mica::HPACK::Decoder.new(limits: Mica::HPACK::DecodeLimits::PUBLIC_SERVER)
decoder.decode(field_block) # => Array(Mica::HPACK::Header)

encoder = Mica::HPACK::Encoder.new # peer's table size 4,096, Huffman on
encoder.encode([Mica::HPACK::Header.new(":status", "200")])
```

- One decoder and one encoder per connection, each owned by one fiber (the
  reader and the writer).
- `decoder.max_table_size = n` once the peer acknowledges the SETTINGS
  frame that advertised SETTINGS_HEADER_TABLE_SIZE `n`; when `n` is below
  the table's size, the next block must start with a size update.
- `encoder.max_table_size = n` when the peer's SETTINGS_HEADER_TABLE_SIZE
  changes; the next block starts with the size updates.
- The encoder sends `cookie`, `set-cookie`, `authorization`,
  `proxy-authorization` and any `Header` marked `never_indexed` as
  never-indexed literals, so they never enter a table. It Huffman-codes a
  string when that is no longer than the string, and its output is
  deterministic.
- Decoding errors (`DecodingError` and its subclasses `TruncatedBlockError`,
  `IntegerOverflowError`, `HuffmanError`, `InvalidIndexError`,
  `TableSizeError`) are COMPRESSION_ERROR connection errors; the decoder
  refuses later blocks.

### HPACK limits

| Limit | `PUBLIC_SERVER` | `INTERNAL_SERVER` | `CLIENT` |
|---|---|---|---|
| `max_header_list_bytes` (decoded, name + value + 32 per field) | 16,384 | 65,536 | 65,536 |
| `max_header_block_bytes` (encoded) | 32,768 | 131,072 | 131,072 |
| `max_table_bytes` (largest SETTINGS_HEADER_TABLE_SIZE we advertise) | 4,096 | 4,096 | 4,096 |
| Work | 100,000 + 64 per block byte | same | same |

The list limit counts decoded bytes as they are produced. A block that
expands through table references (an HPACK bomb) yields only the fields
within the limit; the decoder finishes the block so its table stays in step
with the peer's, then raises `DecodeLimitError` with `table_intact?` true,
so the error can be a stream error (HTTP 431). Integers allow at most 5
continuation octets and values up to 2^31-1; Huffman strings that contain
EOS, pad with more than 7 bits or pad with anything but ones are rejected.

## Conformance, differential and fuzzing

- RFC 7541 Appendix C: all 16 examples of C.2 to C.6 decode to their
  headers and table sizes, and the encoder reproduces their bytes
  (`spec/hpack/appendix_c_spec.cr`).
- [http2jp/hpack-test-case](https://github.com/http2jp/hpack-test-case) at
  `8a1406e7d14bfcb6c046021f13cc15cfb162726d`: every story of the 14
  implementation directories (446 stories, 47,142 header blocks) decodes to
  its expected headers, and the encoder's blocks for the 32 raw-data
  stories decode back. `/usr/bin/ruby conformance/hpack/fetch_test_case.rb`
  fetches it (sha256 checked by the script and by the spec; CI fetches it).
  Pin: `spec/vectors/hpack/SOURCES.md`.
- Requirement catalogs: `spec/requirements/http2.tsv` (frame codec) and
  `spec/requirements/hpack.tsv`.
- Differential against nghttp2 1.71.0's HPACK, out of tree
  (`fuzz/hpack_nghttp2/build.sh` builds the library from its release
  tarball, checked by sha256, and `harness.c`; `fuzz/hpack_differential.cr`
  drives it): nghttp2 decodes Mica's blocks (`encode`), Mica decodes
  nghttp2's (`deflate`), and both decode random and mutated blocks
  (`decode`).
- `fuzz/http2_campaign.cr`: random and mutated frame streams parsed at once
  and in random chunks, and random header blocks, with allocation bounds.

```sh
fuzz/hpack_nghttp2/build.sh /tmp/nghttp2
crystal-alpha build --release fuzz/hpack_differential.cr -o bin/hpack_differential
bin/hpack_differential /tmp/nghttp2/bin/hpack_nghttp2 encode 20261122 1000000
crystal-alpha build --release fuzz/http2_campaign.cr -o bin/http2_campaign
bin/http2_campaign 20261122 2000000
```

## Speed

`bench/hpack/` decodes the hpack-test-case corpus with Mica and with
nghttp2 1.71.0, each a release build in its own process, in interleaved
rounds:

```sh
/usr/bin/ruby bench/hpack/make_corpus.rb bench/data/hpack/corpus.bin
crystal-alpha build --release bench/hpack/mica_runner.cr -o bench/bin/hpack/mica_runner
cc -O2 -I/tmp/nghttp2/prefix/include bench/hpack/nghttp2_runner.c /tmp/nghttp2/prefix/lib/libnghttp2.a -o bench/bin/hpack/nghttp2_runner
/usr/bin/ruby bench/hpack/run_ab.rb bench/bin/hpack/mica_runner bench/bin/hpack/nghttp2_runner bench/data/hpack/corpus.bin 10 bench/data/hpack/run
```

On m4-mini-01 (Apple M4 Mac mini, 10 cores), 10 rounds, each keeping each
engine's median of 15 timed passes over every story of the 14
implementation directories (548,382 fields, 8,436,756 block bytes, one
decoder per story):

| Engine | Median pass | Block MB/s |
|---|---|---|
| Mica | 22.90 ms | 368.4 |
| nghttp2 1.71.0 | 31.42 ms | 268.5 |

Mica decodes **1.37× as fast as** nghttp2 (median of the per-round ratios
1.373; bootstrap 95% interval 1.344 to 1.441). Both decoders produce the
same field count and field bytes on every pass.
