require "../spec_helper"
require "../../fuzz/regex_engine_differential"

# The engine-internal differential (fuzz/regex_engine_differential.cr) on a
# seeded share of its patterns; the release campaign
# (fuzz/regex_engine_campaign.cr) runs two million cases. Override with
# MICA_FUZZ_SEED and MICA_REGEX_DIFFERENTIAL_PATTERNS.
private DIFFERENTIAL_SEED     = (ENV["MICA_FUZZ_SEED"]? || "20261118").to_i64
private DIFFERENTIAL_PATTERNS = (ENV["MICA_REGEX_DIFFERENTIAL_PATTERNS"]? || "12").to_i

describe "Mica::Regex engine differential" do
  it_satisfies "REGEX-R2-differential", "every engine path agrees on #{DIFFERENTIAL_PATTERNS} generated patterns over every short string" do
    report = EngineDifferential.run(DIFFERENTIAL_SEED, DIFFERENTIAL_PATTERNS)
    report.list_of_disagreements.first(5).should eq([] of String)
    report.cases.should be > 0
  end

  it "covers every string up to length 6 over the 4-letter alphabet" do
    EngineDifferential.haystacks.size.should eq(1 + 4 + 16 + 64 + 256 + 1024 + 4096)
  end
end
