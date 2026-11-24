# HPACK test vectors

| Source | Pin | sha256 | Used by |
|---|---|---|---|
| [http2jp/hpack-test-case](https://github.com/http2jp/hpack-test-case) (MIT) | commit `8a1406e7d14bfcb6c046021f13cc15cfb162726d`, archive `https://codeload.github.com/http2jp/hpack-test-case/tar.gz/8a1406e7d14bfcb6c046021f13cc15cfb162726d` | `53355bf708fb890a235b3a679061d116a020818e92caaadbc243f9c91c4c48eb` | `spec/hpack/test_case_spec.cr`, `bench/hpack/` |
| [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.txt) Appendix C, extracted into `spec/hpack/fixtures/appendix_c.cr` | May 2015 text | `2239d7f8fb839b69ae2e928e685559b11376888269f131512197a0e3bacf7f7a` | `spec/hpack/appendix_c_spec.cr` |
| [nghttp2](https://github.com/nghttp2/nghttp2) 1.71.0 release tarball `nghttp2-1.71.0.tar.xz` (out of tree, differential and bench only) | tag `v1.71.0` | `c0f55121d88650e4b9227aec28cebaf664d2417ca60fe70be0f8d38829f52116` (the digest GitHub publishes for the asset) | `fuzz/hpack_nghttp2/build.sh` |

The corpus is not vendored: `/usr/bin/ruby conformance/hpack/fetch_test_case.rb`
downloads the archive into `conformance/hpack-test-case/` (git-ignored),
checks its sha256 and extracts it; the spec checks the sha256 again before
reading any story. Without the download the spec runs one case kept inline.
