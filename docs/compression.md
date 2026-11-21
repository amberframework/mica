# Compression: Inflate (milestone Z1)

`Mica::Deflate`, `Mica::Zlib` and `Mica::Gzip` decode raw DEFLATE
(RFC 1951), zlib (RFC 1950) and gzip (RFC 1952) in pure Crystal. A program
that uses them links no libz (`scripts/check_linkage.sh`). Encoders follow
in milestone Z2.

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
`max_output_bytes` of output plus fixed buffers (the one-shot decoder's
output buffer doubles as it fills and never grows past `max_output_bytes`,
so it allocates at most about twice that in all;
the streaming decoder holds 160 KiB of output and 64 KiB of input). A
declared size (gzip ISIZE) is checked, never used to size a buffer.

Decoding charges one work operation per unit plus the Huffman table
entries each block header builds, so only a stream that spends its input
rebuilding tables (thousands of tiny dynamic blocks) approaches the budget.
The meter, the ratio check and the deadline are settled at least every
64 KiB of output and at every block header.

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

## How it is built

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

## Testing and measurement

- Specs: `crystal-alpha spec spec/deflate` (conformance vectors, a port of
  zlib's `test/infcover.c`, limits and bombs, streaming over 1-byte reads,
  and a small differential against system zlib). Requirement catalog:
  `spec/requirements/deflate.tsv`.
- Differential fuzzing against system zlib: `fuzz/deflate_campaign.cr`.
- Benchmarks against zlib: `bench/deflate/run.sh` (see
  [benchmarks.md](benchmarks.md)).
- Linkage: `scripts/check_linkage.sh`.
