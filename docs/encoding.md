# Mica::Encoding

`Mica::Encoding` converts between UTF-8 and every encoding of the
[WHATWG Encoding Standard](https://encoding.spec.whatwg.org/), in Crystal,
with no iconv. It is the engine behind `String#encode`,
`String.new(bytes, encoding)` and `IO#set_encoding` in crystal-alpha
(vendored as `IO::Mica`), and it works the same from the `mica` shard on
stock Crystal.

```crystal
require "mica/encoding"

codec = Mica::Encoding.lookup!("shift_jis")
Mica::Encoding.decode(Bytes[0x82, 0xA0], codec) # => "あ"
Mica::Encoding.encode("あ", codec)               # => Bytes[0x82, 0xA0]

decoder = codec.decoder(Mica::Encoding::ErrorMode::Fatal)
output = Bytes.new(4096)
result = decoder.convert(chunk, output, last: false) # streaming: any chunk sizes
```

## Encodings

| Family | Encodings | Decoder | Encoder |
|---|---|---|---|
| Unicode | UTF-8, UTF-16BE, UTF-16LE | yes | yes (UTF-16 has none in the standard; Mica has one for iconv names) |
| Single-byte | IBM866, ISO-8859-2 to -8, -8-I, -10, -13 to -16, KOI8-R, KOI8-U, macintosh, windows-874, windows-1250 to -1258, x-mac-cyrillic, x-user-defined | yes | yes |
| Chinese | gb18030, GBK, Big5 | yes | yes |
| Japanese | EUC-JP, ISO-2022-JP, Shift_JIS | yes | yes (EUC-JP writes no JIS X 0212, as the standard says) |
| Korean | EUC-KR | yes | yes |
| Other | replacement | yes (one U+FFFD for any input) | none |
| iconv names only | exact ISO-8859-1, US-ASCII, UTF-16 and UTF-32 with byte order marks, UTF-32BE/LE, UCS-2, UCS-2BE/LE, BIG5-HKSCS | yes | yes |

Tables are generated from the standard's index files by
`scripts/generate_encoding_tables.rb` and compile to read-only data
(`Slice.literal`); a reverse page table per index makes encoding a lookup.

## Two label rules

`Mica::Encoding.lookup(label, rule)` trims ASCII whitespace, folds ASCII
case and refuses labels over 64 bytes before looking anything up.

| Label | `LabelRule::Web` (HTTP, HTML forms) | `LabelRule::IconvCompatible` (`String#encode`, `IO#set_encoding`) |
|---|---|---|
| `iso-8859-1`, `latin1`, `l1`, `cp819` | windows-1252 (what browsers send) | exact ISO-8859-1 (byte n is U+00nn) |
| `ascii`, `us-ascii` | windows-1252 | US-ASCII (bytes over 0x7F are errors) |
| `utf-16` | UTF-16LE | UTF-16 with a byte order mark (big-endian without one) |
| `unicode`, `ucs-2`, `csunicode`, `iso-10646-ucs-2` | UTF-16LE | UTF-16 (`unicode`) or UCS-2 (big-endian, no surrogates) |
| `utf-32`, `ucs-4`, `utf-32le`, `utf-32be` | unknown | UTF-32 forms |
| `big5-hkscs` | Big5 | BIG5-HKSCS: Big5's decoder, plus an encoder that writes HKSCS and the composed pairs |
| `iso-2022-cn`, `iso-2022-cn-ext`, `iso-2022-kr`, `hz-gb-2312`, `csiso2022kr`, `replacement` | replacement (decodes to one U+FFFD) | unknown |
| `cp936`, `euc-cn`, `cp949`, `uhc`, `cp950`, `eucjp`, `euckr`, `macroman` | unknown | GBK, GBK, EUC-KR, EUC-KR, Big5, EUC-JP, EUC-KR, macintosh |
| every other label of the standard | its encoding | the same encoding |

Names iconv knows outside this set (UTF-7, the EBCDIC code pages, ISO-2022-CN,
TSCII, ...) are unknown under both rules. That is deliberate: the
converters a client could name through an HTTP `charset` are exactly the
ones above, all in Crystal (the gconv converter family behind
CVE-2024-2961 is out of reach).

## Error modes

| Mode | Decoder | Encoder |
|---|---|---|
| `Fatal` | `convert` stops with `Status::Error`, the problem (`InvalidSequence` or `IncompleteSequence`) and the offset of the failing sequence's first byte, counted over the whole stream; `decode` raises `ConversionError` | the same, plus `Unmappable` with the code point; invalid UTF-8 input is `InvalidSequence` |
| `Replacement` | U+FFFD for each maximal subpart (Unicode chapter 3, Table 3-8) | the standard's "html" mode: `&#NNNN;` for a code point the encoding lacks; ill-formed UTF-8 input becomes U+FFFD first |
| `Skip` | drops what fails (the standard library's `invalid: :skip`) | drops what fails |

After a fatal error the converter returns to its initial state (whatwg/encoding
commit 7d2e3e08e1, 2026-11-20). A byte that ends an ill-formed sequence and
may begin the next one is not consumed (`Result#read` excludes it), exactly as
the standard's decoders restore it to the queue.

`Decoder#decode` and `Encoder#encode` strip nothing by default;
`codec.decoder(strip_bom: true)` drops a leading U+FEFF from UTF-8 and
UTF-16BE/LE output as `TextDecoder` does. `Mica::Encoding.sniff_byte_order_mark`
is the standard's "BOM sniff".

## Limits

| Limit | Value |
|---|---|
| Label length | 64 bytes, checked before lookup |
| Decoder output | `Codec#max_decoded_size(n)`: `3n + 3` bytes (every byte a U+FFFD at worst); `1.5n + 3` for UTF-16 and UCS-2; `n + 3` for UTF-32 |
| Encoder output | `Codec#max_encoded_size(n, mode)`: `3n` for UTF-8, `2n + 2` for UTF-16, `4n + 4` for UTF-32, `3n + 3` for the legacy encodings, `8n + 3` with `Replacement` (an `&#65533;` per ill-formed byte) |
| State | at most four restored bytes and one shift state per converter; nothing grows with the input |
| Output buffer | `MIN_OUTPUT_BYTES` (16): one step never writes more |
| Allocation | `convert` into the caller's buffers allocates nothing (spec `ENC-NO-ALLOCATION`) |

## Conformance

The vectors are pinned by commit and sha256 in `conformance/encoding/MANIFEST`
and fetched by `/usr/bin/ruby conformance/encoding/fetch_vectors.rb`:

- WHATWG Encoding Standard at [7d2e3e08e1](https://github.com/whatwg/encoding/commit/7d2e3e08e11f57ba1b080390b490d53648c6f69c): `encodings.json` and all 36 index files.
- web-platform-tests `encoding/` at [f0045110fe](https://github.com/web-platform-tests/wpt/commit/f0045110fe5cd9736dbd4dee58ede80b0a753ef3): 25 test files, the label list, the single-byte indexes and the reference codecs.

Every reader (specs, generator, harnesses) checks a file's sha256 before
using it and names the file on a mismatch.

| Check | How | Result |
|---|---|---|
| WPT `encoding/` tests | `node conformance/encoding/wpt_runner.js bin/encoding_oracle`: the WPT `.any.js` files run unmodified under Node, with `TextDecoder`, `TextEncoder` and a data-URL `XMLHttpRequest` backed by Mica (Node's own decoders are never called) | 11,881 of 11,881 subtests pass |
| Index round trips | `spec/encoding/conformance_spec.cr` | 3,434 single-byte entries, 7,724 jis0208, 6,067 jis0212, 17,048 EUC-KR, 23,940 gb18030, 207 gb18030 ranges, 18,590 Big5 |
| Labels | the same spec, from `encodings.json` | 228 labels, each plain, uppercased and whitespace-padded |
| WPT reference codecs | `conformance/encoding/differential.js`: random inputs through the WPT reference decoders and encoders (Shift_JIS, EUC-JP, ISO-2022-JP, EUC-KR, Big5) and the single-byte indexes | 0 disagreements |
| ICU | the same script, Node's ICU `TextDecoder` | 0 disagreements where ICU agrees with the WPT reference; ICU's own departures from the standard are counted separately |
| Chunking | `spec/encoding/streaming_spec.cr` and `fuzz/encoding_campaign.cr`: every encoding and error mode, random splits and output sizes | identical output and error offsets |

## Differences from iconv

`conformance/encoding/iconv_differential.cr` compares the
iconv-compatible names with the platform's iconv through the standard
library and groups each divergent input by its shortest divergent window.
The groups and their reasons:

DIFFERENCES_TABLE

## Speed

BENCHMARK_TABLE
