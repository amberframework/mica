require "../spec_helper"
require "../../fuzz/mutator"

# Seeded mutation fuzzing of the reader and DOM. Replay one case with
# Fuzz.case_bytes(seed, iteration). Override the run with
# MICA_FUZZ_SEED / MICA_FUZZ_ITERATIONS.
private FUZZ_SEED       = (ENV["MICA_FUZZ_SEED"]? || "20261024").to_i64
private FUZZ_ITERATIONS = (ENV["MICA_FUZZ_ITERATIONS"]? || "20000").to_i

# Returns the event stream, or the error class and message.
private def fuzz_outcome(reader : Mica::XML::Reader) : String
  reader_events(reader).join('\n')
rescue error : Mica::Error
  "#{error.class}: #{error.message}"
end

describe "Mica fuzzing" do
  it "survives #{FUZZ_ITERATIONS} seeded mutations (seed #{FUZZ_SEED}) with matching String/IO results and stable round trips" do
    failures = [] of String
    slowest = Time::Span.zero
    accepted = 0
    FUZZ_ITERATIONS.times do |iteration|
      bytes = Fuzz.case_bytes(FUZZ_SEED, iteration)
      started = Time.instant
      begin
        from_string = fuzz_outcome(Mica::XML::Reader.new(bytes))
        chunk = 1 + iteration % 7
        from_io = fuzz_outcome(Mica::XML::Reader.new(TrickleIO.new(bytes, chunk)))
        if from_string != from_io
          failures << "iteration #{iteration}: String and #{chunk}-byte IO disagree:\n#{from_string[0, 300]}\n---\n#{from_io[0, 300]}"
          next
        end
        next if from_string.starts_with?("Mica::")
        accepted += 1
        first = Mica::XML.parse(bytes).to_xml(indent: 0)
        second = Mica::XML.parse(first).to_xml(indent: 0)
        failures << "iteration #{iteration}: round trip not stable" unless first == second
      rescue error
        failures << "iteration #{iteration}: crash #{error.class}: #{error.message}"
      ensure
        took = Time.instant - started
        slowest = took if took > slowest
      end
    end
    failures.first(10).should eq([] of String)
    slowest.should be < 1.second
    accepted.should be > 0
  end
end
