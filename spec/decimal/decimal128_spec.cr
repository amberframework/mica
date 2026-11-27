require "./support"

describe Mica::Decimal128 do
  describe ".new" do
    it_satisfies "DECIMAL-NEW", "builds a value from a coefficient and a scale" do
      value = Mica::Decimal128.new(1230, 2)
      value.coefficient.should eq 1230
      value.scale.should eq 2
      value.to_s.should eq "12.30"
      Mica::Decimal128.new(-5).to_s.should eq "-5"
      Mica::Decimal128.new(7_u8, 1).to_s.should eq "0.7"
      Mica::Decimal128.new(Int128.new(-1), 38).to_s.should eq "-0.#{"0" * 37}1"
      Mica::Decimal128.zero(3).to_s.should eq "0.000"
    end

    it_satisfies "DECIMAL-NEW", "refuses more than 38 digits and a scale outside 0..38" do
      expect_raises(Mica::Decimal128::OverflowError) { Mica::Decimal128.new(10_i128 ** 38) }
      expect_raises(Mica::Decimal128::OverflowError) { Mica::Decimal128.new(-(10_i128 ** 38)) }
      expect_raises(Mica::Decimal128::OverflowError) { Mica::Decimal128.new(UInt128::MAX) }
      expect_raises(ArgumentError) { Mica::Decimal128.new(1, 39) }
      expect_raises(ArgumentError) { Mica::Decimal128.new(1, -1) }
    end
  end

  describe ".parse" do
    it_satisfies "DECIMAL-PARSE", "keeps the written scale, trailing zeros included" do
      {
        "12.30" => {1230, 2}, "-0.50" => {-50, 2}, "0" => {0, 0}, "0.000" => {0, 3},
        "+7" => {7, 0}, "007.10" => {710, 2}, "-0" => {0, 0}, "100" => {100, 0},
      }.each do |text, (coefficient, scale)|
        value = dec(text)
        value.coefficient.should eq coefficient
        value.scale.should eq scale
      end
    end

    it_satisfies "DECIMAL-PARSE", "reads PostgreSQL numeric and MySQL DECIMAL text" do
      # PostgreSQL NUMERIC(18,4) and MySQL DECIMAL(18,4) both pad to the scale.
      dec("1234.5600").to_s.should eq "1234.5600"
      dec("-0.0001").to_s.should eq "-0.0001"
      dec("0.0000").to_s.should eq "0.0000"
      dec("#{NINES_38}").to_s.should eq NINES_38
    end

    it_satisfies "DECIMAL-PARSE-EXPONENT", "moves the point by the exponent" do
      dec("1.0e-6").to_s.should eq "0.0000010"
      dec("1.2345e+19").to_s.should eq "12345000000000000000"
      dec("1.5E3").to_s.should eq "1500"
      dec("15e-1").to_s.should eq "1.5"
      dec("0e10").to_s.should eq "0"
      dec("0.0e-2").to_s.should eq "0.000"
      dec("1e-38").to_s.should eq "0.#{"0" * 37}1"
      dec("1e37").to_s.should eq "1#{"0" * 37}"
    end

    it_satisfies "DECIMAL-PARSE-EXPONENT", "drops trailing zeros only when the written scale cannot be kept" do
      dec("1.000e-38").coefficient.should eq 1
      dec("1.000e-38").scale.should eq 38
      dec("1.#{"0" * 40}").should eq Mica::Decimal128.new(1)
      dec("1.#{"0" * 40}").scale.should eq 37
      dec("0.#{"0" * 45}").scale.should eq 38
    end

    it_satisfies "DECIMAL-PARSE-ERRORS", "raises ParseError for text that is not a decimal" do
      ["", "-", "+", ".5", "5.", "1.2.3", "1e", "1e+", " 1", "1 ", "NaN", "Infinity", "-Infinity", "1,000", "0x10", "1_000", "--1", "e5"].each do |text|
        expect_raises(Mica::Decimal128::ParseError) { dec(text) }
        Mica::Decimal128.parse?(text).should be_nil
      end
    end

    it_satisfies "DECIMAL-PARSE-ERRORS", "raises OverflowError for an exact value past 38 digits or scale 38" do
      ["1#{NINES_38}", "1e38", "1e-39", "0.#{"0" * 38}1", "1.#{"0" * 37}1", "1e999999999999"].each do |text|
        expect_raises(Mica::Decimal128::OverflowError) { dec(text) }
        Mica::Decimal128.parse?(text).should be_nil
      end
    end
  end

  describe "#to_s" do
    it_satisfies "DECIMAL-TO-S", "writes plain digits with the scale kept" do
      ["12.30", "-0.05", "0", "0.0000", "1234.56", "-1", "0.1", "-12345678901234567890.123456789012345678"].each do |text|
        dec(text).to_s.should eq text
        String.build { |io| io << dec(text) }.should eq text
        dec(text).inspect.should eq text
      end
      dec("1e30").to_s.should_not contain "e"
    end
  end

  describe "#+ and #-" do
    it_satisfies "DECIMAL-ADD-SUB", "adds and subtracts exactly at the larger scale" do
      (dec("0.1") + dec("0.2")).should eq dec("0.3")
      (dec("0.1") + dec("0.20")).to_s.should eq "0.30"
      (dec("12") - dec("0.005")).to_s.should eq "11.995"
      (dec("-1.5") + dec("1.5")).to_s.should eq "0.0"
      (dec("1e37") + dec("-9999999999999999999999999999999999999.9")).to_s.should eq "0.1"
    end

    it_satisfies "DECIMAL-ADD-SUB", "raises OverflowError past 38 digits" do
      expect_raises(Mica::Decimal128::OverflowError) { dec(NINES_38) + dec("1") }
      expect_raises(Mica::Decimal128::OverflowError) { dec("-#{NINES_38}") - dec("1") }
      expect_raises(Mica::Decimal128::OverflowError) { dec(NINES_38) + dec("0.1") }
      expect_raises(Mica::Decimal128::OverflowError) { dec("1e37") + dec("1e37") * dec("9") }
    end
  end

  describe "#*" do
    it_satisfies "DECIMAL-MUL", "multiplies exactly at the sum of the scales" do
      (dec("19.99") * dec("0.07")).to_s.should eq "1.3993"
      (dec("-1.5") * dec("2.00")).to_s.should eq "-3.000"
      (dec("1#{"0" * 18}") * dec("1#{"0" * 19}")).to_s.should eq "1#{"0" * 37}"
      (dec("0.5") * dec("0")).to_s.should eq "0.0"
    end

    it_satisfies "DECIMAL-MUL", "raises OverflowError past 38 digits or scale 38" do
      expect_raises(Mica::Decimal128::OverflowError) { dec("1#{"0" * 19}") * dec("1#{"0" * 19}") }
      expect_raises(Mica::Decimal128::OverflowError) { dec(NINES_38) * dec(NINES_38) }
      expect_raises(Mica::Decimal128::OverflowError) { dec("0.#{"0" * 19}1") * dec("0.#{"0" * 18}1") }
    end
  end

  describe "#divide" do
    it_satisfies "DECIMAL-DIVIDE", "rounds the quotient to the scale asked for" do
      one = Mica::Decimal128.new(1)
      one.divide(Mica::Decimal128.new(3), 4, :ties_even).to_s.should eq "0.3333"
      Mica::Decimal128.new(2).divide(Mica::Decimal128.new(3), 2, :ties_away).to_s.should eq "0.67"
      Mica::Decimal128.new(-2).divide(Mica::Decimal128.new(3), 2, :truncate).to_s.should eq "-0.66"
      one.divide(Mica::Decimal128.new(8), 3, :unnecessary).to_s.should eq "0.125"
      dec("100.00").divide(dec("3"), 2, :floor).to_s.should eq "33.33"
      dec("0").divide(dec("7"), 5, :unnecessary).to_s.should eq "0.00000"
      dec("1").divide(dec("0.#{"0" * 36}1"), 0, :unnecessary).to_s.should eq "1#{"0" * 37}"
    end

    it_satisfies "DECIMAL-DIVIDE", "raises for a zero divisor, an oversized quotient and an inexact Unnecessary" do
      expect_raises(Mica::Decimal128::DivisionByZeroError) { dec("1").divide(dec("0.00"), 2, :ties_even) }
      expect_raises(Mica::Decimal128::DivisionByZeroError) { dec("0").divide(dec("0"), 2, :ties_even) }
      expect_raises(Mica::Decimal128::OverflowError) { dec("1").divide(dec("0.#{"0" * 37}1"), 1, :truncate) }
      expect_raises(Mica::Decimal128::OverflowError) { dec(NINES_38).divide(dec("0.5"), 0, :truncate) }
      expect_raises(Mica::Decimal128::OverflowError) { dec(NINES_38).divide(dec("1"), 0, :ties_away).divide(dec("0.9999"), 0, :ceiling) }
      expect_raises(Mica::Decimal128::InexactError) { dec("1").divide(dec("3"), 10, :unnecessary) }
      expect_raises(ArgumentError) { dec("1").divide(dec("3"), 39, :truncate) }
    end
  end

  describe "#round" do
    it_satisfies "DECIMAL-ROUND", "lowers the scale with the mode" do
      dec("2.345").round(2, :ties_even).to_s.should eq "2.34"
      dec("-2.345").round(2, :ties_away).to_s.should eq "-2.35"
      dec("1234.5678").round(0, :truncate).to_s.should eq "1234"
      dec("0.004").round(2, :ties_away).to_s.should eq "0.00"
      dec("-0.004").round(2, :ties_away).to_s.should eq "0.00"
      dec("9.995").round(2, :ties_away).to_s.should eq "10.00"
    end

    it_satisfies "DECIMAL-ROUND", "leaves a value already at or below the scale unchanged" do
      dec("2.3").round(2, :floor).to_s.should eq "2.3"
      dec("2.30").round(2, :unnecessary).to_s.should eq "2.30"
    end
  end

  describe "#rescale" do
    it_satisfies "DECIMAL-RESCALE", "raises the scale exactly and lowers it with a mode" do
      dec("12.3").rescale(2).to_s.should eq "12.30"
      dec("12.30").rescale(1).to_s.should eq "12.3"
      dec("12.35").rescale(1, :ties_even).to_s.should eq "12.4"
      dec("12.25").rescale(1, :ties_even).to_s.should eq "12.2"
      dec("5").rescale(38 - 1).to_s.should eq "5.#{"0" * 37}"
    end

    it_satisfies "DECIMAL-RESCALE", "raises InexactError by default and OverflowError past 38 digits" do
      expect_raises(Mica::Decimal128::InexactError) { dec("12.35").rescale(1) }
      expect_raises(Mica::Decimal128::OverflowError) { dec("10").rescale(37) }
      expect_raises(ArgumentError) { dec("1").rescale(39) }
    end
  end

  describe "#<=>, #== and #hash" do
    it_satisfies "DECIMAL-COMPARE", "compares by value across scales" do
      (dec("12.30") == dec("12.3")).should be_true
      dec("12.30").hash.should eq dec("12.3").hash
      dec("0").hash.should eq dec("0.000").hash
      dec("-5.000").hash.should eq dec("-5").hash
      dec("1200").hash.should eq dec("1200.00").hash
      dec("1200").hash.should_not eq dec("12").hash
      dec("#{NINES_38}").hash.should eq dec("#{NINES_38}").hash
      dec("1.#{"0" * 37}").hash.should eq dec("1").hash
      (dec("0.1") <=> dec("0.10")).should eq 0
      (dec("0.1") < dec("0.11")).should be_true
      (dec("-0.1") < dec("-0.09")).should be_true
      (dec("-1") < dec("0.00")).should be_true
      (dec(NINES_38) > dec("9.#{"9" * 37}")).should be_true
      (dec("-#{NINES_38}") < dec("-9.#{"9" * 37}")).should be_true
      (dec("0.#{"0" * 37}1") > dec("0")).should be_true
      [dec("2"), dec("-1.5"), dec("0.25"), dec("2.000")].sort.map(&.to_s).should eq ["-1.5", "0.25", "2", "2.000"]
      {dec("1.0") => :a}[dec("1")]?.should eq :a
    end
  end

  describe "conversions" do
    it_satisfies "DECIMAL-CONVERSIONS", "converts to integers and floats and reports its sign and digits" do
      dec("1234.56").to_i64.should eq 1234
      dec("-1234.56").to_i64.should eq -1234
      expect_raises(Mica::Decimal128::OverflowError) { dec("1e19").to_i64 }
      dec("9223372036854775807").to_i64.should eq Int64::MAX
      dec("1234.56").to_f64.should eq 1234.56
      dec("-0.07").to_f64.should eq -0.07
      dec("0.1").to_f64.should eq 0.1
      dec(NINES_38).to_f64.should eq 1e38
      dec("1.2345678901234567890123").to_f64.should eq 1.2345678901234567890123
      dec("0.000").zero?.should be_true
      dec("-0.01").negative?.should be_true
      dec("0").negative?.should be_false
      dec("-0.50").abs.to_s.should eq "0.50"
      (-dec("0.50")).to_s.should eq "-0.50"
      dec("-12.30").precision.should eq 4
      dec("0").precision.should eq 1
      dec(NINES_38).precision.should eq 38
      dec("1e37").precision.should eq 38
    end
  end

  describe "bounds" do
    it_satisfies "DECIMAL-38-DIGITS", "works at 38 digits and scale 38 and fails one past" do
      max = dec(NINES_38)
      (max - dec("1") + dec("1")).should eq max
      (-max).to_s.should eq "-#{NINES_38}"
      small = dec("0.#{"9" * 38}")
      small.scale.should eq 38
      expect_raises(Mica::Decimal128::OverflowError) { small + dec("0.#{"0" * 37}1") }
      (small - small).to_s.should eq "0.#{"0" * 38}"
      expect_raises(Mica::Decimal128::OverflowError) { max * dec("1.0") }
      (max * dec("1")).should eq max
      max.round(0, :ties_even).should eq max
    end
  end

  describe "errors" do
    it_satisfies "DECIMAL-ERRORS", "descend from one base class" do
      Mica::Decimal128::Error.new.is_a?(Exception).should be_true
      [Mica::Decimal128::ParseError.new, Mica::Decimal128::OverflowError.new,
       Mica::Decimal128::DivisionByZeroError.new, Mica::Decimal128::InexactError.new].each do |error|
        error.is_a?(Mica::Decimal128::Error).should be_true
      end
    end
  end

  describe "allocation" do
    it_satisfies "DECIMAL-NO-ALLOCATION", "allocates nothing in arithmetic, comparison, hashing, rounding and rescaling" do
      a = dec("1234.56")
      b = dec("0.07")
      big = dec("1234567890123456789012345.6789")
      wide = dec("12345678901234567890.123456")
      sink = Mica::Decimal128.zero
      flags = 0
      run = ->(count : Int32) do
        count.times do
          sink = a + b
          sink = a - big
          sink = a * b
          sink = wide * dec_constant
          sink = big.divide(b, 6, :ties_even)
          sink = wide.divide(big, 30, :ties_away)
          sink = big.round(2, :ties_even)
          sink = a.rescale(6)
          sink = (a * b).round(2, :floor)
          flags &+= (a <=> big) &+ (wide <=> big) &+ (a == dec_constant ? 1 : 0)
          flags &+= big.hash.to_i32! &+ a.hash.to_i32!
        end
      end
      run.call(10)
      before = GC.stats.total_bytes
      run.call(10_000)
      # The runtime itself allocates a few KiB a second in the background;
      # one allocation per operation would be over 1.7 MB here.
      (GC.stats.total_bytes - before).should be < 4096
      sink.zero?.should be_false
    end
  end
end

# A constant operand, so the allocation spec does not count parsing.
private DEC_CONSTANT = Mica::Decimal128.new(3, 1)

private def dec_constant : Mica::Decimal128
  DEC_CONSTANT
end
