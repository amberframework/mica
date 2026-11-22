# Compression: Inflate and Deflate (milestones Z1 and Z2)

`Mica::Deflate`, `Mica::Zlib` and `Mica::Gzip` decode and encode raw
DEFLATE (RFC 1951), zlib (RFC 1950) and gzip (RFC 1952) in pure Crystal. A
program that uses them links no libz (`scripts/check_linkage.sh`).

## Decoding

Every decode takes two required arguments: `limits:` (a `DecodeLimits`
preset or `DecodeLimits.custom`) and `timeout:` (a `Time::Span`, or `nil`
to state that the call has no deadline).

```crystal
limits = Mica::Deflate::DecodeLimits::REQUEST_BODY

# One-shot: the whole input in memory, the whole output returned.
body = Mica::Gzip.decode(bytes, limits: limits, timeout: 2.seconds)
data = Mica::Zlib.decode(bytes, limits: limits, timeout: nil)
raw = Mica::Deflate.decode(bytes, limits: limits, timeout: nil)

# A zlib stream compressed with a preset dictionary (FDICT).
Mica::Zlib.decode(bytes, limits: limits, timeout: nil, dictionary: dictionary)

# Streaming: an IO that decodes as it is read.
reader = Mica::Gzip::Reader.new(request.body, limits: limits, timeout: 2.seconds)
IO.copy(reader, destination)
reader.list_of_headers.first.file_name # => the FNAME bytes, or nil
```

A stream must be complete: raw DEFLATE ends with its final block, zlib with
its Adler-32, gzip with a member's CRC-32 and ISIZE, and no byte may follow
(gzip allows further members). The streaming readers read ahead from their
source, so give each one an IO that holds only the compressed stream (an
HTTP body, a file).

## Encoding

Every encoder takes a `level:` from 0 to 9 (default 6): 0 stores the input
without compressing it, 1 is the fastest, 9 the smallest. Any other level
raises `ArgumentError`. The same input, level and options always give the
same bytes.

```crystal
# One-shot: the whole input in memory, the whole stream returned.
body = Mica::Gzip.encode(bytes, level: 6)
data = Mica::Zlib.encode(bytes, level: 9)
raw = Mica::Deflate.encode(bytes, level: 1)

# A zlib stream that starts from a preset dictionary (FDICT). The decoder
# needs the same dictionary.
Mica::Zlib.encode(bytes, level: 6, dictionary: dictionary)

# A gzip member with header fields.
header = Mica::Gzip::Header.new(modification_time: 1_795_000_000_u32, extra_flags: 0_u8, operating_system: 3_u8,
  is_text: true, extra_field: nil, file_name: "notes.txt".to_slice, comment: nil)
Mica::Gzip.encode(bytes, header: header)

# Streaming: an IO that encodes what is written to it.
writer = Mica::Gzip::Writer.new(response.output, level: 6)
writer << "event: ready\n\n"
writer.flush      # everything written so far can be decoded by the peer
IO.copy(source, writer)
writer.close      # finishes the stream; closes the destination with sync_close: true
```

| Call | What it does |
|---|---|
| `write` | Encodes the bytes. The destination receives output as blocks fill. |
| `flush` | A sync flush: ends the current block and appends an empty stored block, so the output ends on a byte boundary and a decoder can decode everything written before the call. Flushes the destination. A second `flush` with nothing written in between adds no bytes. |
| `full_flush` | A `flush` that also drops the history: the bytes written after it refer to nothing before it, so a decoder can start there. |
| `close` | Writes the final block and the trailer, flushes the destination and, with `sync_close: true`, closes it. Calling it again does nothing. |

Writing to a closed writer raises `IO::Error`, and so does reading from a
writer. If libc cannot supply an encoder's memory,
`Mica::Deflate::OutOfMemoryError` is raised.

**zlib** streams start with the header zlib writes: compression method 8, a
32 KiB window (CINFO 7), the level hint zlib gives the level (FLEVEL 0 for
levels 0 and 1, 1 for 2 to 5, 2 for 6, 3 for 7 to 9) and the check bits.
With `dictionary:` the header sets FDICT and carries the Adler-32 of the
whole dictionary, and the dictionary's last 32 KiB are the history the
first bytes can refer to. The stream ends with the Adler-32 of the input.

**gzip** output is one member. Without `header:` it has no optional
fields, modification time 0 and operating system 255 (unknown), so the
output does not depend on when or where it is made; XFL is 2 at level 9 and
4 at levels 0 and 1, as zlib writes it. With a `Mica::Gzip::Header`, its
modification time, XFL, operating system and FTEXT are written as given,
and FEXTRA, FNAME and FCOMMENT when the header has them. A file name or
comment that contains a zero byte, or an extra field longer than 65,535
bytes, raises `ArgumentError`. The member ends with the CRC-32 of the input
and its size modulo 2^32.

### Sizes and levels

The encoder follows zlib's algorithm, so its output is about the size of
zlib's at the same level (see [benchmarks.md](benchmarks.md), "Deflate
encoders", for the measured sizes and speeds): a 32 KiB history, hash chains
over 3-byte sequences, and zlib's parameters per level.

| Level | Matching | Good length | Lazy limit | Nice length | Chain limit |
|---|---|---|---|---|---|
| 0 | none: stored blocks of up to 65,535 bytes | | | | |
| 1 | greedy | 4 | 4 | 8 | 4 |
| 2 | greedy | 4 | 5 | 16 | 8 |
| 3 | greedy | 4 | 6 | 32 | 32 |
| 4 | lazy | 4 | 4 | 16 | 16 |
| 5 | lazy | 8 | 16 | 32 | 32 |
| 6 | lazy | 8 | 16 | 128 | 128 |
| 7 | lazy | 8 | 32 | 128 | 256 |
| 8 | lazy | 32 | 128 | 258 | 1,024 |
| 9 | lazy | 32 | 258 | 258 | 4,096 |

Greedy matching takes the longest match at each position; lazy matching
first checks whether the next position has a longer one. The chain limit is
the number of earlier positions examined, quartered once a match of the
good length is in hand; a search stops at a match of the nice length.

Symbols collect in a buffer of 16,383, and each full buffer becomes one
block: stored, fixed Huffman or dynamic Huffman, whichever is smallest. Data
that does not compress is therefore stored, and a one-shot stream is never
more than 5 bytes per block larger than its input plus the container.

Where Mica differs from zlib: a match may reach the full 32,768 bytes back
(zlib stops at 32,506), so on inputs with repeats at that distance Mica's
output is a little smaller.

### Memory

A streaming encoder at any level from 1 to 9 holds 294,992 bytes (288 KiB),
however long the stream is:

| Part | Bytes | From |
|---|---|---|
| Window (the last 32 KiB of input and the bytes being encoded) | 65,536 | libc |
| Hash table | 65,536 | libc |
| Chain table | 65,536 | libc |
| Symbol buffer | 65,536 | libc |
| Output buffer | 16,400 | libc |
| Huffman code builders' arrays | 13,472 | libc |
| The encoder's objects | 2,976 | the collector |

The libc blocks are freed by `close`, and with the writer if it is dropped
unclosed. Each block is under 128 KiB, a size libc's allocator hands back
from the blocks just freed, so a server that opens a writer per response
reuses the same memory. A one-shot encode searches the caller's bytes in
place, so it needs no window, and sizes its chain table and symbol buffer
to a short input. Level 0 holds the window, the output buffer and the code
builders' arrays.

## Limits

| Limit | Meaning | `REQUEST_BODY` | `HTTP_CLIENT_RESPONSE` | `WEBSOCKET_MESSAGE` | `TRUSTED_ASSET` |
|---|---|---|---|---|---|
| `max_output_bytes` | Decoded bytes across every member. Raises the moment the next byte would pass it | 8 MiB | 64 MiB | 1 MiB | 1 GiB |
| `max_ratio` | Output bytes per input byte consumed, checked once the output passes 1 MiB | 1,100 | 1,100 | 1,100 | 1,100 |
| `max_window_bytes` | History a zlib header may declare or a back reference may reach | 32 KiB | 32 KiB | 32 KiB | 32 KiB |
| `max_members` | gzip members | 64 | 64 | 1 | 4,096 |
| `max_metadata_bytes` | gzip FEXTRA + FNAME + FCOMMENT per member | 64 KiB | 64 KiB | 0 | 1 MiB |
| `work_per_unit`, `base_work`, `work_ceiling` | The work budget (`Core::WorkBudget`): one unit per input byte read and per output byte produced | 64, 10^6, none | same | same | same |

Exceeding a limit raises `Mica::Deflate::DecodeLimitError`, whose `limit`
names it. The work budget raises `Mica::WorkBudgetExceededError` and the
timeout `Mica::DeadlineExceededError`. Every limit is checked before the
bytes it guards are written, so a decompression bomb costs at most
`max_output_bytes` of output plus fixed buffers. The one-shot decoder
decodes the first 160 KiB in the decoder's own buffer; an output that
fits is returned as an exact-size copy, and a larger one moves to a
result buffer sized from the compression ratio it has shown so far, never
past `max_output_bytes`. When that buffer fills, the decoder moves to a
larger one (by at least a quarter, at most eightfold) and frees the one it
leaves, so at most two result buffers exist at a time. A result buffer
that ends more than half larger than the output is copied out at the exact
size and freed, so the `Bytes` a decode returns holds at most one and a
half times its size. The streaming decoder
holds 160 KiB of output and 64 KiB of input. A declared size (gzip ISIZE)
is checked, never used to size a buffer.

A decoder keeps its Huffman tables and buffers when a decode ends, and the
next decode (one-shot or a new reader) takes it over, so a small body
allocates only its result. One spare decoder is kept: at most 160 KiB of
output buffer, 64 KiB of input buffer and 13 KiB of tables. A reader gives
its decoder back when the stream ends or at `close`.

A read into a slice of at least 32 KiB is decoded straight into the slice
(the decoder copies only the last 32 KiB aside as history); smaller reads
are served from the decoder's own buffer.

Decoding charges one work operation per unit plus the Huffman table
entries each block header builds, so only a stream that spends its input
rebuilding tables (thousands of tiny dynamic blocks) approaches the budget.
The meter, the ratio check and the deadline are settled every 64 KiB of
output (a run of the decoding loop may pass 64 KiB by one symbol, at most
261 bytes) and at every block header.

## Errors

| Error | When |
|---|---|
| `Mica::Deflate::MalformedStreamError` | The stream breaks its RFC: block type 3, a stored block whose LEN and NLEN disagree, an invalid or incomplete Huffman code, a back reference before the start of the output, a bad header, trailing data |
| `Mica::Deflate::TruncatedStreamError` | The input ends inside a block, a header or a trailer |
| `Mica::Deflate::ChecksumError` | Adler-32, CRC-32, ISIZE, the gzip header CRC (FHCRC), or a preset dictionary's id does not match |
| `Mica::Deflate::DecodeLimitError` | A `DecodeLimits` limit (`limit` names it) |

All four are `Mica::ParseError`s with the byte offset in the compressed
input where the problem was found.

## Where Mica follows zlib

zlib 1.2.12 is the differential reference, so where RFC 1951's text leaves
room Mica decides as zlib does:

- Length code 284 with extra bits 31 decodes as length 258.
- An incomplete Huffman code is accepted only when it is a single code of
  length 1 (literal/length and distance codes); a code with no distance
  symbols is accepted until a distance is used; oversubscribed codes are
  always rejected.
- HLIT above 286 and HDIST above 30 are rejected.
- A zlib header's CINFO is checked (at most 7, and its window within
  `max_window_bytes`), and back references may reach the full 32 KiB
  window, as zlib does without `INFLATE_STRICT`.

## How the decoder is built

The decoder keeps a 64-bit bit buffer refilled eight bytes at a time and
decodes through two-level Huffman tables (a 10-bit root for literals and
lengths, 8-bit for distances), the layout zlib and libdeflate use. A fast
loop runs while at least 8 input bytes and 258 bytes of output room remain,
decoding up to two literals per refill and copying back references 8 or 16
bytes at a time; a careful loop handles the edges of the input and the
output. Input is pulled from the source when the decoder needs bits, so
the only place a stream pauses is a full output buffer.

CRC-32 uses the ARMv8 CRC32 instructions on Apple silicon (through LLVM
intrinsics, so nothing is linked) and slicing-by-8 tables elsewhere.
Adler-32 is written as two block reductions that LLVM vectorizes.

## How the encoder is built

One engine, `Mica::Deflate::Deflater`, serves the three containers and both
APIs. One-shot, it reads the caller's bytes where they lie; streaming, it
copies them into the window and moves the last 32 KiB to the front when the
window fills.

The hash table and the chain table hold positions modulo 65,536 in 16 bits,
so following a chain is one masked load per candidate, as in zlib. Every
32,000 positions the hash table's entries that are out of reach are
overwritten (the work zlib's `slide_hash` does), and a chain ends where the
next position is not farther back than the last. The hash table starts
zeroed: entry 0 names stream position 0, which nothing matches. A candidate is compared in
full only when its two bytes at the current best length match, and the
comparison runs eight bytes at a time (XOR of two 64-bit loads, then a count
of trailing zero bits).

`HuffmanCodeBuilder` builds each block's codes the way zlib's `build_tree`
does (a heap ordered by frequency and then by depth, held as one 64-bit
key per node so that a comparison is one load, and the same
redistribution when a code would pass 15 bits, or 7 for the code-length
code), which is why block sizes match zlib's. `BlockWriter` knows a block's
exact size before it writes it, reserves that much once, and writes each
symbol through a 64-bit bit buffer with one 8-byte store. With a
destination IO the output buffer stays at 16 KiB: compressed blocks pass
through it 2,048 symbols at a time and stored blocks go to the destination
directly.

## Testing and measurement

- Specs: `crystal-alpha spec spec/deflate` (conformance vectors, a port of
  zlib's `test/infcover.c`, limits and bombs, streaming over 1-byte reads,
  and a small differential against system zlib). Requirement catalog:
  `spec/requirements/deflate.tsv`.
- Encoder specs: `spec/deflate/encoder_spec.cr`, `writer_spec.cr` and
  `encode_fuzz_spec.cr` (every level and container round-trips through
  Mica's decoder and system zlib; the streams are read block by block to
  check what was written). Requirement catalog:
  `spec/requirements/deflate_encoder.tsv`.
- Differential fuzzing of the decoder against system zlib:
  `fuzz/deflate_campaign.cr`.
- Round-trip fuzzing of the encoder (system zlib and Mica must both decode
  every stream to the input): `fuzz/deflate_encode_campaign.cr`.
- Benchmarks against zlib: `bench/deflate/run.sh` for the decoder and
  `bench/deflate_encode/run.sh` for the encoder (see
  [benchmarks.md](benchmarks.md)).
- Linkage: `scripts/check_linkage.sh`.
