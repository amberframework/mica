require "./support/bit_writer"

# A port of the inflate cases of zlib 1.2.12's test/infcover.c (the
# coverage test of inflate.c, inftrees.c and inffast.c). Source:
# zlib-1.2.12.tar.gz, sha256
# 91844808532e5ce316b3c010929493c0244f3d37593afd6de04f71821d5136d9 (the
# value zlib.net published for the release). Each example cites the line
# of test/infcover.c its hex vector comes from, and keeps zlib's name for
# the case.
#
# infcover.c asserts what one inflate() call returns: Z_STREAM_END,
# Z_DATA_ERROR, or Z_OK for a stream that has not ended yet. Here each
# vector is decoded whole under Mica's acceptance rules, so:
#
# - Z_STREAM_END and nothing left: the vector must decode to the output
#   zlib 1.2.12 produces.
# - Z_DATA_ERROR: the vector must be rejected (as a checksum error for
#   zlib's "incorrect data check", "incorrect length check" and "header
#   crc mismatch").
# - Z_OK with the input used up before the final block ends: the vector
#   must be reported as truncated.
# - Vectors that carry bytes after the final block (infcover pads them so
#   that inflate_fast() has its 6 bytes of input): rejected as they stand,
#   and decoded without the padding.
#
# infcover.c runs its vectors with 256-byte and 32 KiB windows to steer
# zlib's window code; the output is the same, so they decode here under
# the full window.
#
# Cases not ported, because they exercise zlib's C API and not the format:
#
# - cover_support (lines 350-385): inflatePrime, inflateSetDictionary with
#   a null dictionary, inflateInit_ with a wrong version, the memory hooks
#   (mem_setup, mem_used, mem_done), and line 371 "bad window size"
#   (inflateInit2 refusing windowBits 1 before any input).
# - cover_wrap (lines 394-397 and 413-443): inflate, inflateEnd and
#   inflateCopy with null streams; forced allocation failures (mem_limit);
#   inflateSync, inflateSyncPoint, inflateCopy, inflateUndermine and
#   inflateMark.
# - cover_back (lines 470-505) and the inflateBack half of try() (lines
#   552-568): the inflateBack callback interface.
# - cover_trees (lines 617-638): inflate_table called directly with a code
#   that needs more table space than ENOUGH_DISTS, which no stream can
#   produce.
# - Inside inf() (lines 286-346): inflateGetHeader buffers, inflateCopy of
#   the stream at each step, inflateReset2, and feeding the input in steps
#   (streaming_spec.cr replays every vector here at chunk sizes 1, 2, 3, 7
#   and 4096).

private def vector(text : String) : Bytes
  DeflateConformance.hex(text)
end

private def zeros(count : Int32) : Bytes
  Bytes.new(count)
end

describe "zlib 1.2.12 test/infcover.c" do
  describe "cover_support" do
    # test/infcover.c:367, "force window allocation": a literal in a
    # non-final fixed block, then the input ends.
    it_rejects_vector "DEFLATE-1951-3.2.3-final-block", "force window allocation: a non-final block alone is truncated", :raw, vector("63 0"), :truncated

    # test/infcover.c:368, "force window replacement".
    it_rejects_vector "DEFLATE-1951-3.2.3-final-block", "force window replacement: a literal and a 258-byte match in a non-final block are truncated", :raw, vector("63 18 5"), :truncated

    # test/infcover.c:369, "force split window update".
    it_decodes_vector "DEFLATE-1951-3.2.5-overlap", "force split window update: decodes to 257 zero bytes", :raw, vector("63 18 68 30 d0 0 0"), zeros(257)

    # test/infcover.c:370, "use fixed blocks".
    it_decodes_vector "DEFLATE-1951-3.2.6-fixed-codes", "use fixed blocks: decodes an empty fixed block", :raw, vector("3 0"), Bytes.empty
  end

  describe "cover_wrap" do
    # test/infcover.c:399, "bad gzip method".
    it_rejects_vector "DEFLATE-1952-2.3-cm", "bad gzip method: rejects CM 0", :gzip, vector("1f 8b 0 0"), :malformed

    # test/infcover.c:400, "bad gzip flags".
    it_rejects_vector "DEFLATE-1952-2.3-reserved-flags", "bad gzip flags: rejects FLG 0x80", :gzip, vector("1f 8b 8 80"), :malformed

    # test/infcover.c:401, "bad zlib method".
    it_rejects_vector "DEFLATE-1950-2.2-cm", "bad zlib method: rejects CM 7", :zlib, vector("77 85"), :malformed

    # test/infcover.c:402, "set window size from header": CINFO 0, then
    # the input ends.
    it_rejects_vector "DEFLATE-1950-2.2-cinfo", "set window size from header: a CINFO 0 header alone is truncated", :zlib, vector("8 99"), :truncated

    # test/infcover.c:403, "bad zlib window size": zlib, told to use a
    # 256-byte window, refuses a header that declares 32 KiB. Mica's
    # counterpart is max_window_bytes.
    it_satisfies "DEFLATE-LIMIT-max-window-bytes", "bad zlib window size: a header declaring 32 KiB passes a 256-byte max_window_bytes" do
      limits = Mica::Deflate::DecodeLimits.custom(max_window_bytes: 256)
      error = expect_raises(Mica::Deflate::DecodeLimitError) do
        Mica::Zlib.decode(vector("78 9c"), limits: limits, timeout: nil)
      end
      error.limit.should eq("max_window_bytes")
    end

    # test/infcover.c:403 again, under the full window.
    it_rejects_vector "DEFLATE-API-truncation", "bad zlib window size: the same header alone is truncated under a 32 KiB window", :zlib, vector("78 9c"), :truncated

    # test/infcover.c:404, "check adler32".
    it_decodes_vector "DEFLATE-1950-2.2-adler32", "check adler32: decodes one zero byte and accepts its Adler-32", :zlib, vector("78 9c 63 0 0 0 1 0 1"), zeros(1)

    # test/infcover.c:405, "bad header crc": FHCRC, FEXTRA, FNAME and
    # FCOMMENT set, an extra field of one byte, empty name and comment.
    it_rejects_vector "DEFLATE-1952-2.3-fhcrc", "bad header crc: reports a wrong CRC16 as a checksum error", :gzip, vector("1f 8b 8 1e 0 0 0 0 0 0 1 0 0 0 0 0 0"), :checksum

    # test/infcover.c:407, "check gzip length".
    it_decodes_vector({"DEFLATE-1952-2.3-fhcrc", "DEFLATE-1952-2.3-isize"}, "check gzip length: decodes an empty member with a header CRC", :gzip,
      vector("1f 8b 8 2 0 0 0 0 0 0 1d 26 3 0 0 0 0 0 0 0 0 0"), Bytes.empty)

    # test/infcover.c:409, "bad zlib header check".
    it_rejects_vector "DEFLATE-1950-2.2-fcheck", "bad zlib header check: rejects 78 90", :zlib, vector("78 90"), :malformed

    # test/infcover.c:410, "need dictionary": FDICT with DICTID 1, which
    # is the Adler-32 of the empty dictionary infcover then supplies.
    it_rejects_vector "DEFLATE-1950-2.2-fdict", "need dictionary: rejects the stream when no dictionary is given", :zlib, vector("8 b8 0 0 0 1"), :malformed
    it_rejects_vector "DEFLATE-1950-2.2-fdict", "need dictionary: accepts the empty dictionary, and the header alone is truncated", :zlib, vector("8 b8 0 0 0 1"), :truncated, Bytes.empty

    # test/infcover.c:411, "compute adler32": the data without its trailer.
    it_rejects_vector "DEFLATE-1950-2.2-adler32", "compute adler32: a stream without its Adler-32 is truncated", :zlib, vector("78 9c 63 0"), :truncated
  end

  describe "cover_inflate" do
    # test/infcover.c:583.
    it_rejects_vector "DEFLATE-1951-3.2.4-stored-length", "invalid stored block lengths", :raw, vector("0 0 0 0 0"), :malformed

    # test/infcover.c:584.
    it_decodes_vector "DEFLATE-1951-3.2.6-fixed-codes", "fixed", :raw, vector("3 0"), Bytes.empty

    # test/infcover.c:585.
    it_rejects_vector "DEFLATE-1951-3.2.3-reserved-block-type", "invalid block type", :raw, vector("6"), :malformed

    # test/infcover.c:586.
    it_decodes_vector "DEFLATE-1951-3.2.4-stored-data", "stored", :raw, vector("1 1 0 fe ff 0"), zeros(1)

    # test/infcover.c:587: HLIT 31 and HDIST 31.
    it_rejects_vector({"DEFLATE-1951-3.2.7-hlit", "DEFLATE-1951-3.2.7-hdist"}, "too many length or distance symbols", :raw, vector("fc 0 0"), :malformed)

    # test/infcover.c:588: an oversubscribed code length code.
    it_rejects_vector "DEFLATE-1951-3.2.7-code-length-code", "invalid code lengths set", :raw, vector("4 0 fe ff"), :malformed

    # test/infcover.c:589: symbol 16 with no previous length.
    it_rejects_vector "DEFLATE-1951-3.2.7-repeat-16", "invalid bit length repeat (no previous length)", :raw, vector("4 0 24 49 0"), :malformed

    # test/infcover.c:590: a repeat past the last code length.
    it_rejects_vector "DEFLATE-1951-3.2.7-repeat-overrun", "invalid bit length repeat (more lengths than declared)", :raw, vector("4 0 24 e9 ff ff"), :malformed

    # test/infcover.c:591.
    it_rejects_vector "DEFLATE-1951-3.2.7-end-of-block-code", "invalid code -- missing end-of-block", :raw, vector("4 0 24 e9 ff 6d"), :malformed

    # test/infcover.c:592.
    it_rejects_vector "DEFLATE-1951-3.2.2-oversubscribed", "invalid literal/lengths set", :raw, vector("4 80 49 92 24 49 92 24 71 ff ff 93 11 0"), :malformed

    # test/infcover.c:594.
    it_rejects_vector "DEFLATE-1951-3.2.2-incomplete", "invalid distances set", :raw, vector("4 80 49 92 24 49 92 24 f b4 ff ff c3 84"), :malformed

    # test/infcover.c:595: the unassigned code of an incomplete code.
    it_rejects_vector "DEFLATE-1951-3.2.2-unused-code", "invalid literal/length code", :raw, vector("4 c0 81 8 0 0 0 0 20 7f eb b 0 0"), :malformed

    # test/infcover.c:596: distance symbol 30 of the fixed code.
    it_rejects_vector "DEFLATE-1951-3.2.5-reserved-symbols", "invalid distance code", :raw, vector("2 7e ff ff"), :malformed

    # test/infcover.c:597.
    it_rejects_vector "DEFLATE-1951-3.2.5-distance-too-far", "invalid distance too far back", :raw, vector("c c0 81 0 0 0 0 0 90 ff 6b 4 0"), :malformed

    # test/infcover.c:600.
    it_rejects_vector "DEFLATE-1952-2.3-crc32", "incorrect data check", :gzip, vector("1f 8b 8 0 0 0 0 0 0 0 3 0 0 0 0 1"), :checksum

    # test/infcover.c:601.
    it_rejects_vector "DEFLATE-1952-2.3-isize", "incorrect length check", :gzip, vector("1f 8b 8 0 0 0 0 0 0 0 3 0 0 0 0 0 0 0 0 1"), :checksum

    # test/infcover.c:603: a header whose code lengths use symbol 17.
    it_decodes_vector "DEFLATE-1951-3.2.7-repeat-17", "pull 17", :raw, vector("5 c0 21 d 0 0 0 80 b0 fe 6d 2f 91 6c"), Bytes.empty

    # test/infcover.c:604: codes longer than zlib's 9-bit root table.
    it_decodes_vector "DEFLATE-1951-3.2.2-code-length-limits", "long code", :raw,
      vector("5 e0 81 91 24 cb b2 2c 49 e2 f 2e 8b 9a 47 56 9f fb fe ec d2 ff 1f"), Bytes.empty

    # test/infcover.c:606.
    it_decodes_vector "DEFLATE-1951-3.2.5-length-codes", "length extra", :raw, vector("ed c0 1 1 0 0 0 40 20 ff 57 1b 42 2c 4f"), zeros(516)

    # test/infcover.c:607.
    it_decodes_vector "DEFLATE-1951-3.2.5-distance-codes", "long distance and extra", :raw,
      vector("ed cf c1 b1 2c 47 10 c4 30 fa 6f 35 1d 1 82 59 3d fb be 2e 2a fc f c"), zeros(518)

    # test/infcover.c:609: output that runs to the end of a 32 KiB window.
    it_decodes_vector "DEFLATE-1951-3.2.5-window", "window end", :raw,
      vector("ed c0 81 0 0 0 0 80 a0 fd a9 17 a9 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 6"), zeros(33_025)

    # test/infcover.c:611: four empty non-final fixed blocks and an empty
    # final one.
    it_decodes_vector "DEFLATE-1951-3.2.3-block-sequence", "inflate_fast TYPE return", :raw, vector("2 8 20 80 0 3 0"), Bytes.empty

    # test/infcover.c:613.
    it_decodes_vector "DEFLATE-1951-3.2.5-overlap", "window wrap", :raw, vector("63 18 5 40 c 0"), zeros(262)
  end

  describe "cover_fast" do
    # test/infcover.c:643. zlib reports "invalid distance too far back".
    it_rejects_vector "DEFLATE-1951-3.2.5-distance-too-far", "fast length extra bits", :raw,
      vector("e5 e0 81 ad 6d cb b2 2c c9 01 1e 59 63 ae 7d ee fb 4d fd b5 35 41 68 ff 7f 0f 0 0 0"), :malformed

    # test/infcover.c:645. zlib reports "invalid distance too far back".
    it_rejects_vector "DEFLATE-1951-3.2.5-distance-too-far", "fast distance extra bits", :raw,
      vector("25 fd 81 b5 6d 59 b6 6a 49 ea af 35 6 34 eb 8c b9 f6 b9 1e ef 67 49 50 fe ff ff 3f 0 0"), :malformed

    # test/infcover.c:648.
    it_rejects_vector "DEFLATE-1951-3.2.5-reserved-symbols", "fast invalid distance code", :raw, vector("3 7e 0 0 0 0 0"), :malformed

    # test/infcover.c:650.
    it_rejects_vector "DEFLATE-1951-3.2.5-reserved-symbols", "fast invalid literal/length code", :raw, vector("1b 7 0 0 0 0 0"), :malformed

    # test/infcover.c:652.
    it_rejects_vector "DEFLATE-1951-3.2.5-distance-too-far", "fast 2nd level codes and too far back", :raw,
      vector("d c7 1 ae eb 38 c 4 41 a0 87 72 de df fb 1f b8 36 b1 38 5d ff ff 0"), :malformed

    # test/infcover.c:654: the stream ends after 7 bytes; 3 bytes of
    # padding follow.
    it_decodes_vector "DEFLATE-1951-3.2.5-overlap", "very common case, without its padding", :raw, vector("63 18 5 8c 10 8 0"),
      DeflateConformance.join(zeros(259), Bytes[1, 0, 1, 0, 1, 0, 1])
    it_rejects_vector "DEFLATE-API-trailing-data", "very common case, with its 3 bytes of padding", :raw, vector("63 18 5 8c 10 8 0 0 0 0"), :malformed

    # test/infcover.c:655: the stream ends after 14 bytes; 4 bytes follow.
    it_decodes_vector "DEFLATE-1951-3.2.5-overlap", "contiguous and wrap around window, without its padding", :raw,
      vector("63 60 60 18 c9 0 8 18 18 18 26 c0 28 0"),
      DeflateConformance.join(zeros(261), Bytes[144], zeros(6), Bytes[144, 0])
    it_rejects_vector "DEFLATE-API-trailing-data", "contiguous and wrap around window, with its 4 bytes of padding", :raw,
      vector("63 60 60 18 c9 0 8 18 18 18 26 c0 28 0 29 0 0 0"), :malformed

    # test/infcover.c:657: the stream ends after 4 bytes; 4 bytes follow.
    it_decodes_vector "DEFLATE-1951-3.2.5-overlap", "copy direct from output, without its padding", :raw, vector("63 0 3 0"), zeros(6)
    it_rejects_vector "DEFLATE-API-trailing-data", "copy direct from output, with its 4 bytes of padding", :raw, vector("63 0 3 0 0 0 0 0"), :malformed
  end
end
