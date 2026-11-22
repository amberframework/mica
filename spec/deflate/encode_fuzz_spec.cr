require "../spec_helper"
require "../../fuzz/deflate_encode_fuzz"

# A fast slice of the encoder round-trip campaign
# (fuzz/deflate_encode_fuzz.cr): seeded generated inputs encoded by Mica in
# one call and through the Writer; the system zlib and Mica's decoder must
# return the input from both streams. Replay one case with
# DeflateEncodeFuzz.case_for(seed, iteration, DeflateEncodeFuzz::Profile::QUICK).
# Override the run with MICA_DEFLATE_ENCODE_FUZZ_SEED /
# MICA_DEFLATE_ENCODE_FUZZ_ITERATIONS; release campaigns of a million cases
# use fuzz/deflate_encode_campaign.cr.
private ENCODE_FUZZ_SEED       = (ENV["MICA_DEFLATE_ENCODE_FUZZ_SEED"]? || "20261122").to_i64
private ENCODE_FUZZ_ITERATIONS = (ENV["MICA_DEFLATE_ENCODE_FUZZ_ITERATIONS"]? || "1500").to_i

describe "Mica::Deflate encoder round trips against the system zlib" do
  it_satisfies({"DEFLATE-ENC-FUZZ-roundtrip", "DEFLATE-ENC-ROUNDTRIP-mica", "DEFLATE-ENC-ROUNDTRIP-zlib"},
    "round-trips #{ENCODE_FUZZ_ITERATIONS} generated cases (seed #{ENCODE_FUZZ_SEED}) through zlib #{DeflateOracle.version} and Mica, one-shot and streaming") do
    report = DeflateEncodeFuzz.run(ENCODE_FUZZ_SEED, ENCODE_FUZZ_ITERATIONS, profile: DeflateEncodeFuzz::Profile::QUICK)
    report.list_of_failures.first(5).should eq([] of String)
    report.cases.should eq(ENCODE_FUZZ_ITERATIONS)
    report.streams.should eq(2 * ENCODE_FUZZ_ITERATIONS)
    # Every family, container, level and way of writing took part.
    DeflateEncodeFuzz::Family.each { |family| report.by_family[family].should be > 0 }
    DeflateOracle::Format.each { |format| report.by_format[format].should be > 0 }
    0.upto(9) { |level| report.by_level[level].should be > 0 }
    DeflateEncodeFuzz::Chunking.each { |chunking| report.by_chunking[chunking].should be > 0 }
    report.with_dictionary.should be > 0
    report.with_header.should be > 0
    report.with_flushes.should be > 0
  end

  it "builds the same case from the same seed and iteration" do
    first = DeflateEncodeFuzz.case_for(7_i64, 1_234, DeflateEncodeFuzz::Profile::QUICK)
    second = DeflateEncodeFuzz.case_for(7_i64, 1_234, DeflateEncodeFuzz::Profile::QUICK)
    second.input.should eq(first.input)
    second.to_s.should eq(first.to_s)
    second.writer_seed.should eq(first.writer_seed)
    DeflateEncodeFuzz.encode_streamed(second).should eq(DeflateEncodeFuzz.encode_streamed(first))
  end

  it "reports a stream that does not decode to the input" do
    kase = DeflateEncodeFuzz.case_for(7_i64, 99, DeflateEncodeFuzz::Profile::QUICK)
    stream = DeflateEncodeFuzz.encode_at_once(kase)
    DeflateEncodeFuzz.failure_of(kase, "one-shot", stream).should be_nil
    DeflateEncodeFuzz.failure_of(kase, "one-shot", stream[0, stream.size - 1]).to_s.should contain("zlib rejects")
    other = DeflateEncodeFuzz.case_for(7_i64, 100, DeflateEncodeFuzz::Profile::QUICK)
    unless other.input == kase.input
      wrong = DeflateEncodeFuzz::Case.new(kase.family, kase.format, kase.level, other.input, kase.dictionary, kase.header,
        kase.chunking, kase.flush_one_in, kase.writer_seed)
      DeflateEncodeFuzz.failure_of(wrong, "one-shot", stream).to_s.should contain("not the input")
    end
  end
end
