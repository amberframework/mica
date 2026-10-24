require "../spec_helper"

# An IO that sleeps before every read, standing in for a slow peer.
private class SlowIO < IO
  def initialize(@bytes : Bytes, @chunk : Int32, @pause : Time::Span)
    @offset = 0
  end

  def read(slice : Bytes) : Int32
    sleep @pause
    count = Math.min(Math.min(@chunk, slice.size), @bytes.size - @offset)
    return 0 if count <= 0
    slice[0, count].copy_from(@bytes[@offset, count])
    @offset += count
    count
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

private def tight(operations_per_unit : Int, base : Int = 0, timeout : Time::Span? = nil) : Mica::XML::ParserOptions
  budget = Mica::Core::WorkBudget.new(operations_per_unit: operations_per_unit, base_operations: base, timeout: timeout)
  Mica::XML::ParserOptions.new(work_budget: budget)
end

private def large_document(elements : Int32) : String
  String.build do |io|
    io << "<root>\n"
    elements.times { |index| io << %(  <item id=") << index << %(">text &amp; more</item>\n) }
    io << "</root>\n"
  end
end

describe "Mica work budget and deadline" do
  it_satisfies "MICA-BUDGET-DEFAULT", "parses ordinary documents well inside the default budget" do
    meter = Mica::Core::WorkMeter.new
    document = Mica::XML.parse(large_document(20_000), meter: meter)
    document.node_count.should be > 40_000
    (meter.operations / meter.units).should be < 4.0
    Mica::XML::ParserOptions.default.work_budget.operations_per_unit.should eq(64)
    Mica::XML::ParserOptions.default.work_budget.timeout.should eq(60.seconds)
  end

  it_satisfies "MICA-BUDGET-ERROR", "raises WorkBudgetExceededError with the position, operations and allowance" do
    error = expect_raises(Mica::WorkBudgetExceededError, /Work budget exhausted/) do
      Mica::XML.parse(large_document(1_000), tight(1, base: 100))
    end
    error.should be_a(Mica::LimitExceededError)
    error.operations.should be > error.allowance
    error.allowance.should be <= 100 + large_document(1_000).bytesize
    error.line_number.should be >= 1
    error.byte_offset.should be > 0
    error.message.to_s.should contain("line")
  end

  it_satisfies "MICA-BUDGET-ERROR", "stops within one check interval of the allowance, also from a stream" do
    text = large_document(5_000)
    {text.to_slice, TrickleIO.new(text.to_slice, 7)}.each do |source|
      meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 1, base_operations: 0))
      expect_raises(Mica::WorkBudgetExceededError) { Mica::XML.parse(source, meter: meter) }
      (meter.operations - meter.allowance).should be < 200_000
    end
  end

  it_satisfies "MICA-BUDGET-ERROR", "caps total work with max_operations regardless of input size" do
    budget = Mica::Core::WorkBudget.new(max_operations: 50_000)
    expect_raises(Mica::WorkBudgetExceededError) do
      Mica::XML.parse(large_document(10_000), Mica::XML::ParserOptions.new(work_budget: budget))
    end
    budget.allowance(Int64::MAX).should eq(50_000)
  end

  it_satisfies "MICA-BUDGET-DEADLINE", "raises DeadlineExceededError when the timeout passes during a parse" do
    options = tight(64, base: 1_000_000, timeout: 1.nanosecond)
    error = expect_raises(Mica::DeadlineExceededError, /Deadline exceeded/) do
      Mica::XML.parse(large_document(50_000), options)
    end
    error.elapsed.should be > 1.nanosecond
    error.byte_offset.should be >= 0
  end

  it_satisfies "MICA-BUDGET-DEADLINE", "checks the deadline at every refill of a slow stream" do
    bytes = large_document(200).to_slice
    options = tight(64, base: 1_000_000, timeout: 30.milliseconds)
    started = Time.instant
    expect_raises(Mica::DeadlineExceededError) do
      Mica::XML.parse(SlowIO.new(bytes, 16, 2.milliseconds), options)
    end
    (Time.instant - started).should be < 1.second
  end

  it_satisfies "MICA-BUDGET-RENEW", "renews the meter between messages of a long stream" do
    message = "<m>#{"x" * 1_000}</m>"
    stream = "<session>#{message * 200}</session>"
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 4, base_operations: 20_000, max_operations: 20_000)
    reader = Mica::XML::Reader.new(IO::Memory.new(stream), Mica::XML::ParserOptions.new(work_budget: budget))
    messages = 0
    while reader.read
      if reader.node_type.end_element? && reader.name == "m"
        messages += 1
        reader.renew_meter
      end
    end
    messages.should eq(200)
    unrenewed = Mica::XML::Reader.new(IO::Memory.new(stream), Mica::XML::ParserOptions.new(work_budget: budget))
    expect_raises(Mica::WorkBudgetExceededError) do
      while unrenewed.read
      end
    end
  end

  it_satisfies "MICA-BUDGET-XPATH", "bounds XPath evaluation and reports the position in the expression" do
    document = Mica::XML.parse(large_document(2_000))
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 1, base_operations: 1_000)
    error = expect_raises(Mica::WorkBudgetExceededError, /in XPath/) do
      document.xpath("count(//item[@id = //item/@id])", budget: budget)
    end
    error.byte_offset.should be >= 0
    error.byte_offset.should be < "count(//item[@id = //item/@id])".bytesize
    document.xpath("count(//item)").should eq(2_000.0)
  end

  it_satisfies "MICA-BUDGET-XPATH", "applies an XPath deadline" do
    document = Mica::XML.parse(large_document(20_000))
    budget = Mica::Core::WorkBudget.new(timeout: 1.nanosecond)
    expect_raises(Mica::DeadlineExceededError) do
      document.xpath("count(//item[contains(., 'more')])", budget: budget)
    end
  end

  it_satisfies "MICA-BUDGET-XPATH", "shares one meter between a parse and the queries that follow" do
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 8, base_operations: 0))
    document = Mica::XML.parse(large_document(500), meter: meter)
    after_parse = meter.operations
    document.xpath("count(//item)", meter: meter).should eq(500.0)
    meter.operations.should be > after_parse
  end

  it_satisfies "MICA-BUDGET-CORE", "computes allowances with saturation and an unlimited budget" do
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 64, base_operations: 1_000)
    budget.allowance(0).should eq(1_000)
    budget.allowance(10).should eq(1_640)
    budget.allowance(Int64::MAX).should eq(Int64::MAX)
    Mica::Core::WorkBudget.unlimited.allowance(Int64::MAX).should eq(Int64::MAX)
    expect_raises(ArgumentError) { Mica::Core::WorkBudget.new(operations_per_unit: -1) }
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 1, base_operations: 10))
    meter.charge(5).should be_false
    meter.charge(6).should be_true
    meter.verdict.should eq(Mica::Core::WorkMeter::Verdict::BudgetExceeded)
    meter.add_units(100)
    meter.verdict.should eq(Mica::Core::WorkMeter::Verdict::Within)
  end

  it_satisfies "MICA-BUDGET-XPATH", "charges compiling an expression to the meter" do
    document = Mica::XML.parse("<r/>")
    expression = "1" + " + 1" * 20_000
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 1_000)
    error = expect_raises(Mica::WorkBudgetExceededError, /compiling XPath/) { document.xpath(expression, budget: budget) }
    error.byte_offset.should be < expression.bytesize
  end

  it_satisfies "MICA-BUDGET-XPATH", "charges string and number conversions of the result" do
    document = Mica::XML.parse("<r>#{"<i>#{"x" * 1_000}</i>" * 100}</r>")
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 1, base_operations: 0)
    expect_raises(Mica::WorkBudgetExceededError) { document.xpath_string("/", budget: budget) }
    expect_raises(Mica::WorkBudgetExceededError) { document.xpath_float("/", budget: budget) }
    document.xpath_string("string(/r/i[1])").size.should eq(1_000)
  end

  it_satisfies "MICA-BUDGET-DEADLINE", "checks the deadline when reading starts and before the document completes" do
    reader = Mica::XML::Reader.new("<a/>", Mica::XML::ParserOptions.new(work_budget: Mica::Core::WorkBudget.new(timeout: 1.millisecond)))
    sleep 5.milliseconds
    expect_raises(Mica::DeadlineExceededError) { reader.read }
  end

  it_satisfies "MICA-BUDGET-ERROR", "stops a long name within one check interval when max_name_bytes is raised" do
    name = "n" * 1_000_000
    options = Mica::XML::ParserOptions.new(max_name_bytes: Int32::MAX, work_budget: Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 1_000))
    meter = Mica::Core::WorkMeter.new(options.work_budget)
    expect_raises(Mica::WorkBudgetExceededError) { Mica::XML.parse("<#{name}/>", options, meter) }
    (meter.operations - meter.allowance).should be <= 70_000
  end

  it_satisfies "MICA-BUDGET-RENEW", "gives a renewed meter the units of bytes already buffered" do
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 8, base_operations: 0)
    reader = Mica::XML::Reader.new("<r><m>#{"x" * 1_000}</m><m>#{"y" * 1_000}</m></r>", Mica::XML::ParserOptions.new(work_budget: budget))
    reader.read
    meter = reader.renew_meter
    meter.units.should be > 2_000
    while reader.read
    end
  end

  it_satisfies "MICA-BUDGET-CORE", "rejects negative charges and saturates at Int64::MAX" do
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    expect_raises(ArgumentError) { meter.charge(-1) }
    expect_raises(ArgumentError) { meter.add_units(-1) }
    meter.charge(Int64::MAX)
    meter.charge(Int64::MAX)
    meter.operations.should eq(Int64::MAX)
  end

  it_satisfies "MICA-BUDGET-CORE", "counts name-table probes reproducibly with a fixed seed" do
    xml = "<r>#{(1..2_000).join { |index| "<e#{index}/>" }}</r>"
    counts = Array.new(2) do
      reader = Mica::XML::Reader.new(xml, name_seed: 42_u32)
      while reader.read
      end
      reader.operations
    end
    counts.uniq.size.should eq(1)
    table = Mica::XML::NameTable.new(7_u32)
    2_000.times { |index| table.intern("name#{index}") }
    table.operations.should be >= table.probes
  end
end
