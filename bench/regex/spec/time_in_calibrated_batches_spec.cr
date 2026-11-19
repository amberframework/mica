require "./spec_helper"

# The Apple Silicon monotonic clock's tick.
private TICK = 1.0 / 24_000_000

# A simulated clock: operations advance it by a fixed number of seconds,
# and a read rounds down to whole ticks of *tick* (0 reads it exactly).
private class SimulatedClock
  getter operations = 0

  def initialize(@tick : Float64 = 0.0)
    @now = 0.0
  end

  def read : Float64
    @tick > 0 ? (@now / @tick).floor * @tick : @now
  end

  def run(seconds : Float64) : Nil
    @operations += 1
    @now += seconds
  end
end

private def settings : RegexBench::MeasurementSettings
  RegexBench::MeasurementSettings.new
end

# Times an operation of *seconds* on *clock* in calibrated batches.
private def measure(seconds : Float64, clock : SimulatedClock,
                    measurement_settings : RegexBench::MeasurementSettings = settings) : RegexBench::Statistics
  RegexBench::TimeInCalibratedBatches.new(measurement_settings, ->clock.read).measure { clock.run(seconds) }
end

describe RegexBench::TimeInCalibratedBatches do
  describe "#measure" do
    it "doubles the batch until one timed loop takes at least 10 us, then divides each sample by it" do
      clock = SimulatedClock.new
      statistics = measure(100e-9, clock)
      # 64 operations take 6.4 us, 128 take 12.8 us.
      statistics.iterations_per_sample.should eq(128)
      statistics.median.should be_close(100e-9, 1e-15)
      statistics.sample_count.should eq(settings.max_samples)
      (statistics.min * statistics.iterations_per_sample).should be >= settings.min_batch_seconds
      # Calibration (1 + 2 + ... + 128 operations, and 128 again to confirm),
      # then every sample's batch.
      clock.operations.should eq(255 + 128 + 128 * settings.max_samples)
    end

    it "resolves an operation of a few clock ticks to well under one tick" do
      {85e-9, 125e-9, 300e-9, 1.7e-6}.each do |seconds|
        statistics = measure(seconds, SimulatedClock.new(TICK))
        statistics.iterations_per_sample.should be > 1
        statistics.median.should be_close(seconds, seconds / 100)
      end
    end

    it "keeps an operation of 10 us or more to a batch of one, its calibration timings its first samples" do
      {12e-6, 50e-6, 0.3}.each do |seconds|
        clock = SimulatedClock.new
        statistics = measure(seconds, clock)
        statistics.iterations_per_sample.should eq(1)
        statistics.median.should be_close(seconds, 1e-12)
        clock.operations.should eq(statistics.sample_count)
      end
    end

    it "doubles past a batch one slow timing made look long enough" do
      # A 40 ns operation whose 5th call stalls for 20 us (a collection),
      # inside the calibration timing of a batch of 4.
      clock = SimulatedClock.new(TICK)
      calls = 0
      statistics = RegexBench::TimeInCalibratedBatches.new(settings, ->clock.read).measure do
        calls += 1
        clock.run(calls == 5 ? 20e-6 : 40e-9)
      end
      (statistics.median * statistics.iterations_per_sample).should be >= settings.min_batch_seconds
      statistics.median.should be_close(40e-9, 40e-9 / 100)
    end

    it "samples again with a larger batch when the median batch fell short of 10 us" do
      # Calibration sees 1 us operations; every later call takes 100 ns.
      clock = SimulatedClock.new
      calls = 0
      statistics = RegexBench::TimeInCalibratedBatches.new(settings, ->clock.read).measure do
        calls += 1
        clock.run(calls <= 47 ? 1e-6 : 100e-9)
      end
      statistics.iterations_per_sample.should eq(128)
      statistics.median.should be_close(100e-9, 1e-15)
    end

    it "batches a short operation whose first call alone took 10 us or more" do
      # A first call that builds something lazily, then 167 ns calls: as a
      # Mica search's first calls build its plan.
      clock = SimulatedClock.new(TICK)
      first = true
      statistics = RegexBench::TimeInCalibratedBatches.new(settings, ->clock.read).measure do
        clock.run(first ? 50e-6 : 167e-9)
        first = false
      end
      statistics.iterations_per_sample.should eq(64)
      statistics.median.should be_close(167e-9, 167e-9 / 100)
    end

    it "samples an operation slower than slow_iteration_seconds once, as before batching" do
      clock = SimulatedClock.new
      statistics = measure(3.0, clock)
      statistics.sample_count.should eq(1)
      statistics.iterations_per_sample.should eq(1)
      clock.operations.should eq(1)
    end

    it "counts batches against min_samples and phase_seconds" do
      short_phase = RegexBench::MeasurementSettings.new(max_samples: 1_000, min_samples: 3, phase_seconds: 50e-6)
      statistics = measure(1e-6, SimulatedClock.new, short_phase)
      statistics.iterations_per_sample.should eq(16)
      # Each batch takes 16 us, so the 50 us phase ends after 4 samples.
      statistics.sample_count.should eq(4)
    end

    it "settles on the same batch for two operations of the same length, whatever the engine" do
      first = measure(240e-9, SimulatedClock.new(TICK))
      second = measure(240e-9, SimulatedClock.new(TICK))
      first.iterations_per_sample.should eq(second.iterations_per_sample)
      first.median.should eq(second.median)
    end

    it "stops doubling at MAX_ITERATIONS_PER_SAMPLE for an operation the clock reads as zero" do
      statistics = measure(0.0, SimulatedClock.new)
      statistics.iterations_per_sample.should eq(RegexBench::TimeInCalibratedBatches::MAX_ITERATIONS_PER_SAMPLE)
      statistics.median.should eq(0.0)
    end
  end
end

describe RegexBench::Statistics do
  it "reads a result written before batching as a batch of one" do
    statistics = RegexBench::Statistics.from_json(%({"sample_count": 3, "median": 1.0, "p25": 1.0, "p75": 1.0,
      "min": 1.0, "max": 1.0}))
    statistics.iterations_per_sample.should eq(1)
  end

  it "keeps the batch size through JSON" do
    statistics = RegexBench::Statistics.of([1e-7, 2e-7], 64)
    RegexBench::Statistics.from_json(statistics.to_json).iterations_per_sample.should eq(64)
  end
end
