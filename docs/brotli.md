# Brotli (milestone Z4)

`Mica::Brotli` decodes Brotli streams (RFC 7932) in pure Crystal. A
program that uses it links no libbrotlidec.

## Decoding

Every decode takes `limits:` (a `Mica::Brotli::DecodeLimits` preset or
`DecodeLimits.custom`) and `timeout:` (a `Time::Span`, or `nil` to state
that the call has no deadline). Neither has a default.

```crystal
limits = Mica::Brotli::DecodeLimits::REQUEST_BODY

# One-shot: the whole stream in memory, the whole output returned.
body = Mica::Brotli.decode(bytes, limits: limits, timeout: 2.seconds)

# Streaming: an IO that decodes as it is read.
reader = Mica::Brotli::Reader.new(request.body, limits: limits, timeout: 2.seconds)
IO.copy(reader, destination)
```

A stream must be complete: it ends with its last metablock and zero
padding bits, and no byte may follow it. The Reader reads ahead from its
source, so give it an IO that holds only the compressed stream.

## Limits

| Limit | `REQUEST_BODY` | `HTTP_CLIENT_RESPONSE` | `WEBSOCKET_MESSAGE` | `TRUSTED_ASSET` | What it stops |
|---|---|---|---|---|---|
| `max_output_bytes` | 8 MiB | 64 MiB | 1 MiB | 1 GiB | Raised the moment the next output byte would pass it |
| `max_ratio` | 200:1 | 200:1 | 200:1 | none in practice | Output over input consumed, checked once the output passes 1 MiB |
| `max_window_bytes` | 4 MiB (WBITS 22) | 16 MiB | 1 MiB | 16 MiB | A larger declared window is refused before anything is allocated |
| `max_metadata_bytes` | 64 KiB | 64 KiB | 0 | 16 MiB | Skipped metadata metablocks |
| work budget | 64 per unit + 1,000,000 | same | same | same | One unit per input byte and per output byte; table building and context maps are charged |

A stream of 817 bytes can describe 1 GiB of output (64 metablocks, each one
literal and a 16 MiB copy). Each limit stops it before the bytes it guards
are written, and the Reader's memory is bounded by the window, not by the
output (`spec/brotli/bomb_spec.cr`).

## Errors

| Error | When |
|---|---|
| `Mica::Brotli::MalformedStreamError` | The stream breaks RFC 7932: window bits, metablock header, prefix code, context map, distance, nonzero padding, a command past its metablock, bytes after the end |
| `Mica::Brotli::TruncatedStreamError` | The input ends inside the stream (a subclass of the above) |
| `Mica::Brotli::DecodeLimitError` | A limit; `limit` names it |
| `Mica::WorkBudgetExceededError`, `Mica::DeadlineExceededError` | The work budget or the deadline |

Every error carries the byte offset in the compressed input.

## Where Mica follows libbrotlidec

- A metadata metablock may be the last metablock (RFC 7932 is silent;
  libbrotlidec accepts it, and google/brotli's own test files use it).
- The large-window extension (WBITS above 24) is rejected, as
  libbrotlidec does unless the caller opts in.
- Bytes after the last metablock are rejected, as `BrotliDecoderDecompress`
  does.

## How the decoder is built

- Input is pulled through a 64-bit bit buffer. The static dictionary
  (122,784 bytes) and the 121 transforms are embedded; the dictionary is
  `src/mica/brotli/dictionary.bin` from google/brotli v1.2.1, and
  `scripts/generate_brotli_tables.rb` writes `src/mica/brotli/tables.cr`
  from that release's `transform.c` and `context.c`, each checked by sha256.
- Prefix codes decode through two-level tables (8-bit root).
- A one-shot decode writes into one buffer that grows to the output size
  (the last metablock's length sizes it exactly); the Reader writes into a
  ring of the stream's window, which it drains before wrapping.
- A fast loop runs whole commands with the bit buffer and positions in
  locals while at least 64 input bytes remain; block switches, dictionary
  words and the edges of the buffers go through the careful path.
- Decoders are pooled, so a small body costs no table allocation.

## Testing and measurement

- `conformance/brotli/fetch_testdata.rb` fetches google/brotli's 69 test
  files at v1.2.1, each checked against `conformance/brotli/MANIFEST.tsv`,
  and checks the embedded dictionary's sha256. `spec/brotli/` decodes every
  one of them, one-shot and streaming.
- `fuzz/brotli_differential.cr` compares Mica with libbrotlidec 1.2.1
  (built out of tree by `fuzz/build_brotli_reference.sh`) on generated
  inputs at every quality, window and mode, trickled reads, and mutated
  streams.
- `bench/brotli/` measures one-shot and streaming decode against
  libbrotlidec in separate release-built processes, interleaved.
