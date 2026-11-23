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

## Speed

`bench/brotli/run_ab.rb` and `report.rb` decode Canterbury and the HTTP-shaped
bands at qualities 5 and 11 with Mica and libbrotlidec 1.2.1, each a release
build in its own process, in 10 interleaved rounds alternating order, with
paired bootstrap 95% intervals. One-shot decoding hands libbrotlidec the
decoded size (Mica is not told it); streaming decodes into 64 KiB chunks.
Rounds of the same commit differ by a few percent per case.

#### oneshot decode, m4-mini-01 (Apple M4 Mac mini), 10 rounds

Geometric mean over 36 cases: Mica is **1.06× as fast** as libbrotlidec 1.2.1 (95% interval 1.059 to 1.069× its speed).

| case | bytes | libbrotlidec MB/s | Mica MB/s | Mica vs reference (95% interval) |
|---|---|---|---|---|
| canterbury-lcet10.txt.q11 | 426754 | 617.1 | 568.4 | 1.08× slower (0.907–0.950) |
| canterbury-alice29.txt.q11 | 152089 | 603.6 | 567.1 | 1.06× slower (0.918–0.968) |
| canterbury-cp.html.q11 | 24603 | 650.3 | 623.5 | 1.05× slower (0.940–0.966) |
| http-json_16k.json.q11 | 14995 | 743.6 | 709.8 | 1.05× slower (0.935–0.980) |
| http-json_1k.json.q11 | 1282 | 445.9 | 439.5 | 1.04× slower (0.931–0.986) |
| http-html_1m.html.q5 | 1059557 | 2172.3 | 2081.6 | 1.04× slower (0.940–0.982) |
| http-json_64k.json.q11 | 74750 | 2118.0 | 2043.3 | 1.04× slower (0.958–0.968) |
| http-html_64k.html.q11 | 65085 | 941.6 | 909.7 | 1.03× slower (0.965–0.972) |
| canterbury-asyoulik.txt.q11 | 125179 | 519.3 | 497.7 | 1.03× slower (0.950–0.996) |
| http-html_1m.html.q11 | 1059557 | 2159.2 | 2130.7 | 1.01× slower (0.957–1.020) |
| canterbury-sum.q11 | 38240 | 554.9 | 553.5 | 1.01× slower (0.965–0.997) |
| canterbury-xargs.1.q11 | 4227 | 480.8 | 478.5 | 1.01× slower (0.971–1.003) |
| canterbury-plrabn12.txt.q11 | 481861 | 489.8 | 492.9 | 1.01× slower (0.984–1.003) |
| http-html_1k.html.q11 | 577 | 288.5 | 288.5 | 1.00× as fast (0.996–1.008) |
| http-html_16k.html.q11 | 13142 | 754.6 | 761.9 | 1.00× as fast (0.995–1.009) |
| canterbury-grammar.lsp.q11 | 3721 | 519.2 | 522.2 | 1.01× as fast (0.998–1.011) |
| http-html_1k.html.q5 | 577 | 314.8 | 329.7 | 1.04× as fast (1.028–1.048) |
| canterbury-fields.c.q11 | 11150 | 755.9 | 806.0 | 1.06× as fast (1.061–1.067) |
| canterbury-lcet10.txt.q5 | 426754 | 699.5 | 744.1 | 1.07× as fast (1.056–1.090) |
| http-json_1k.json.q5 | 1282 | 683.7 | 750.6 | 1.10× as fast (1.077–1.128) |
| http-json_16k.json.q5 | 14995 | 893.0 | 1002.5 | 1.11× as fast (1.079–1.125) |
| http-html_16k.html.q5 | 13142 | 806.7 | 893.5 | 1.11× as fast (1.106–1.111) |
| canterbury-xargs.1.q5 | 4227 | 545.4 | 603.9 | 1.11× as fast (1.105–1.126) |
| canterbury-fields.c.q5 | 11150 | 818.3 | 916.4 | 1.12× as fast (1.116–1.120) |
| http-json_64k.json.q5 | 74750 | 3169.7 | 3538.5 | 1.12× as fast (1.110–1.146) |
| canterbury-kennedy.xls.q11 | 1029744 | 929.2 | 1061.6 | 1.13× as fast (1.116–1.157) |
| canterbury-grammar.lsp.q5 | 3721 | 676.5 | 776.5 | 1.14× as fast (1.119–1.148) |
| http-html_64k.html.q5 | 65085 | 1100.8 | 1258.7 | 1.14× as fast (1.126–1.161) |
| canterbury-ptt5.q11 | 513216 | 1099.8 | 1265.0 | 1.15× as fast (1.129–1.183) |
| canterbury-sum.q5 | 38240 | 707.6 | 831.3 | 1.19× as fast (1.165–1.215) |
| canterbury-plrabn12.txt.q5 | 481861 | 535.8 | 641.8 | 1.19× as fast (1.156–1.212) |
| canterbury-alice29.txt.q5 | 152089 | 666.4 | 780.8 | 1.19× as fast (1.165–1.211) |
| canterbury-kennedy.xls.q5 | 1029744 | 1039.4 | 1248.1 | 1.19× as fast (1.171–1.207) |
| canterbury-cp.html.q5 | 24603 | 822.4 | 976.0 | 1.20× as fast (1.181–1.218) |
| canterbury-ptt5.q5 | 513216 | 1184.6 | 1541.0 | 1.25× as fast (1.161–1.363) |
| canterbury-asyoulik.txt.q5 | 125179 | 602.5 | 730.8 | 1.26× as fast (1.233–1.286) |

#### stream decode, m4-mini-01 (Apple M4 Mac mini), 10 rounds

Geometric mean over 36 cases: Mica is **1.04× as fast** as libbrotlidec 1.2.1 (95% interval 1.037 to 1.046× its speed).

| case | bytes | libbrotlidec MB/s | Mica MB/s | Mica vs reference (95% interval) |
|---|---|---|---|---|
| canterbury-alice29.txt.q11 | 152089 | 625.8 | 543.2 | 1.14× slower (0.847–0.915) |
| http-html_64k.html.q11 | 65085 | 889.5 | 819.5 | 1.08× slower (0.903–0.945) |
| http-json_64k.json.q11 | 74750 | 2179.9 | 2024.8 | 1.07× slower (0.927–0.934) |
| canterbury-lcet10.txt.q11 | 426754 | 628.4 | 593.0 | 1.07× slower (0.897–0.965) |
| canterbury-plrabn12.txt.q11 | 481861 | 525.6 | 491.1 | 1.07× slower (0.923–0.954) |
| http-json_16k.json.q11 | 14995 | 759.2 | 712.6 | 1.06× slower (0.935–0.950) |
| http-json_1k.json.q11 | 1282 | 459.2 | 433.4 | 1.05× slower (0.947–0.962) |
| canterbury-cp.html.q11 | 24603 | 639.7 | 618.3 | 1.05× slower (0.941–0.970) |
| canterbury-asyoulik.txt.q11 | 125179 | 513.1 | 508.3 | 1.04× slower (0.921–0.994) |
| http-html_1m.html.q5 | 1059557 | 2687.8 | 2531.5 | 1.03× slower (0.932–1.015) |
| canterbury-xargs.1.q11 | 4227 | 478.5 | 469.7 | 1.03× slower (0.938–1.007) |
| canterbury-sum.q11 | 38240 | 518.2 | 509.6 | 1.02× slower (0.955–1.010) |
| http-html_16k.html.q11 | 13142 | 690.2 | 681.3 | 1.01× slower (0.970–0.999) |
| http-html_1m.html.q11 | 1059557 | 3045.4 | 3001.2 | 1.01× slower (0.964–1.020) |
| canterbury-grammar.lsp.q11 | 3721 | 525.3 | 522.2 | 1.00× slower (0.995–0.998) |
| http-html_1k.html.q5 | 577 | 307.7 | 294.7 | 1.02× as fast (0.991–1.038) |
| http-html_1k.html.q11 | 577 | 261.3 | 276.9 | 1.02× as fast (0.992–1.040) |
| http-json_64k.json.q5 | 74750 | 3291.6 | 3423.7 | 1.02× as fast (0.992–1.040) |
| canterbury-fields.c.q11 | 11150 | 764.6 | 794.0 | 1.04× as fast (1.029–1.045) |
| canterbury-lcet10.txt.q5 | 426754 | 700.6 | 739.8 | 1.07× as fast (1.042–1.088) |
| http-json_16k.json.q5 | 14995 | 906.5 | 937.2 | 1.08× as fast (1.044–1.109) |
| canterbury-cp.html.q5 | 24603 | 839.9 | 886.6 | 1.08× as fast (1.059–1.108) |
| http-json_1k.json.q5 | 1282 | 683.7 | 732.6 | 1.08× as fast (1.060–1.106) |
| http-html_16k.html.q5 | 13142 | 733.5 | 794.5 | 1.08× as fast (1.052–1.110) |
| canterbury-sum.q5 | 38240 | 690.1 | 759.1 | 1.10× as fast (1.082–1.112) |
| http-html_64k.html.q5 | 65085 | 998.7 | 1104.7 | 1.10× as fast (1.085–1.113) |
| canterbury-fields.c.q5 | 11150 | 825.9 | 907.2 | 1.10× as fast (1.076–1.129) |
| canterbury-grammar.lsp.q5 | 3721 | 686.9 | 769.9 | 1.11× as fast (1.078–1.126) |
| canterbury-xargs.1.q5 | 4227 | 502.3 | 557.4 | 1.11× as fast (1.086–1.133) |
| canterbury-kennedy.xls.q11 | 1029744 | 967.5 | 1094.9 | 1.13× as fast (1.116–1.138) |
| canterbury-alice29.txt.q5 | 152089 | 648.5 | 731.6 | 1.14× as fast (1.111–1.164) |
| canterbury-kennedy.xls.q5 | 1029744 | 1103.3 | 1280.3 | 1.16× as fast (1.155–1.165) |
| canterbury-plrabn12.txt.q5 | 481861 | 562.2 | 665.2 | 1.18× as fast (1.173–1.194) |
| canterbury-asyoulik.txt.q5 | 125179 | 575.3 | 691.1 | 1.21× as fast (1.179–1.230) |
| canterbury-ptt5.q11 | 513216 | 1250.6 | 1528.4 | 1.22× as fast (1.191–1.242) |
| canterbury-ptt5.q5 | 513216 | 1486.5 | 1942.8 | 1.33× as fast (1.263–1.416) |


