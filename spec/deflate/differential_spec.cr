require "../spec_helper"
require "../../fuzz/deflate_fuzz"

# A fast slice of the differential campaign (fuzz/deflate_fuzz.cr): seeded
# generated streams decoded by Mica in one call and through the Reader, and
# by the system zlib; all three must accept with identical bytes or all
# three must reject. Replay one case with
# DeflateFuzz.case_for(seed, iteration, DeflateFuzz::Profile::QUICK).
# Override the run with MICA_DEFLATE_FUZZ_SEED / MICA_DEFLATE_FUZZ_ITERATIONS;
# release campaigns of millions of cases use fuzz/deflate_campaign.cr.
private DEFLATE_FUZZ_SEED       = (ENV["MICA_DEFLATE_FUZZ_SEED"]? || "20261121").to_i64
private DEFLATE_FUZZ_ITERATIONS = (ENV["MICA_DEFLATE_FUZZ_ITERATIONS"]? || "3000").to_i

describe "Mica::Deflate differential against the system zlib" do
  it_satisfies({"DEFLATE-API-one-shot", "DEFLATE-API-streaming-identical", "DEFLATE-LIMIT-differential"},
    "agrees with zlib #{DeflateOracle.version} on #{DEFLATE_FUZZ_ITERATIONS} generated streams (seed #{DEFLATE_FUZZ_SEED}), one-shot and streaming") do
    report = DeflateFuzz.run(DEFLATE_FUZZ_SEED, DEFLATE_FUZZ_ITERATIONS, profile: DeflateFuzz::Profile::QUICK)
    report.list_of_disagreements.first(5).should eq([] of String)
    report.list_of_streaming_differences.first(5).should eq([] of String)
    report.list_of_crashes.first(5).should eq([] of String)
    report.list_of_rejected_valid_cases.first(5).should eq([] of String)
    report.total.cases.should eq(DEFLATE_FUZZ_ITERATIONS)
    # Every family and container took part, and both outcomes occurred.
    DeflateFuzz::Family.each { |family| report.by_family[family].cases.should be > 0 }
    DeflateOracle::Format.each do |format|
      report.by_format[format].agreements.should be > 0
      report.by_format[format].both_reject.should be > 0
    end
  end

  it "builds the same case from the same seed and iteration" do
    first = DeflateFuzz.case_for(7_i64, 1_234, DeflateFuzz::Profile::QUICK)
    second = DeflateFuzz.case_for(7_i64, 1_234, DeflateFuzz::Profile::QUICK)
    second.bytes.should eq(first.bytes)
    second.format.should eq(first.format)
    DeflateFuzz.case_for(7_i64, 1_235, DeflateFuzz::Profile::QUICK).bytes.should_not eq(first.bytes)
  end

  it "has an oracle that implements the acceptance semantics" do
    data = ("oracle check " * 20).to_slice
    raw = DeflateOracle.compress(data)
    DeflateOracle.decode(DeflateOracle::Format::Raw, raw).output.should eq(data)
    DeflateOracle.decode(DeflateOracle::Format::Raw, DeflateFuzz.join(raw, Bytes[0])).rejection.should eq(DeflateOracle::Rejection::Malformed)
    DeflateOracle.decode(DeflateOracle::Format::Raw, raw[0, raw.size - 1]).rejection.should eq(DeflateOracle::Rejection::Truncated)
    member = DeflateOracle.compress(data, DeflateOracle::Format::Gzip)
    two = DeflateOracle.decode(DeflateOracle::Format::Gzip, DeflateFuzz.join(member, member))
    two.members.should eq(2)
    two.output.size.should eq(2 * data.size)
    DeflateOracle.decode(DeflateOracle::Format::Gzip, DeflateFuzz.join(member, Bytes[0, 0])).rejected?.should be_true
    with_dictionary = DeflateOracle.compress(data, DeflateOracle::Format::Zlib, dictionary: "oracle".to_slice)
    DeflateOracle.decode(DeflateOracle::Format::Zlib, with_dictionary).rejection.should eq(DeflateOracle::Rejection::Dictionary)
    DeflateOracle.decode(DeflateOracle::Format::Zlib, with_dictionary, "oracle".to_slice).output.should eq(data)
    DeflateOracle.decode(DeflateOracle::Format::Zlib, with_dictionary, "oracle".to_slice, cap: 10_i64).rejection.should eq(DeflateOracle::Rejection::OverCap)
    DeflateOracle.crc32("123456789".to_slice).should eq(0xCBF43926_u32)
    DeflateOracle.adler32("Wikipedia".to_slice).should eq(0x11E60398_u32)
  end
end
