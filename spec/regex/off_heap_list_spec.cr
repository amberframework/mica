require "../spec_helper"

# The engine's buffers outside the collector's heap (`OffHeapList`,
# `OffHeap`). The soak run in bench/regex/off_heap/soak.cr checks that a
# long loop of compiles, searches and drops keeps malloc's bytes in use flat.
describe Mica::Regex::OffHeapList do
  describe "#<<" do
    it "grows as elements are appended and reads them back" do
      list = Mica::Regex::OffHeapList(Int32).new
      100.times { |value| list << value * 3 }
      list.size.should eq(100)
      list.capacity.should be >= 100
      list[0].should eq(0)
      list[99].should eq(297)
      list.sum.should eq(14_850)
      list.free
      list.size.should eq(0)
      list.capacity.should eq(0)
    end
  end

  describe "#pop?" do
    it "removes from the end and answers nil when empty" do
      list = Mica::Regex::OffHeapList(UInt8).new(2)
      list << 1_u8
      list << 2_u8
      list.pop?.should eq(2_u8)
      list.pop?.should eq(1_u8)
      list.pop?.should be_nil
      list.free
    end
  end

  describe "#fill_to" do
    it "appends copies of a value up to a size" do
      list = Mica::Regex::OffHeapList(Bool).new
      list << true
      list.fill_to(4, false)
      list.to_a.should eq([true, false, false, false])
      list.free
    end
  end

  describe "#concat" do
    it "appends a slice and keeps records whole" do
      list = Mica::Regex::OffHeapList(Mica::Regex::Program::Transition).new
      transitions = [Mica::Regex::Program::Transition.new(1_u8, 2_u8, 3), Mica::Regex::Program::Transition.new(4_u8, 5_u8, -6)]
      list.concat(transitions)
      list.concat(transitions)
      list.to_a.should eq(transitions + transitions)
      list.should eq(transitions + transitions)
      list.free
    end
  end

  describe "#trim" do
    it "shrinks the buffer to the elements held" do
      list = Mica::Regex::OffHeapList(Int64).new(64)
      list << 7_i64
      list.trim
      list.capacity.should eq(1)
      list[0].should eq(7_i64)
      list.free
    end
  end

  describe "#free" do
    it "is safe on an empty or already freed list" do
      list = Mica::Regex::OffHeapList(Int32).new
      list.free
      list << 1
      list.free
      list.free
      list.empty?.should be_true
    end
  end

  it "counts the bytes it asks of libc" do
    before = Mica::Regex::OffHeap.allocated_bytes
    list = Mica::Regex::OffHeapList(Int64).new(1000)
    (Mica::Regex::OffHeap.allocated_bytes - before).should eq(8000)
    list.free
    buffer = Mica::Regex::OffHeap.slice(Int32, 10, -1)
    buffer.sum.should eq(-10)
    (Mica::Regex::OffHeap.allocated_bytes - before).should eq(8040)
    Mica::Regex::OffHeap.free(buffer)
  end
end

describe "Mica::Regex off-heap tables" do
  it "compiles and searches with the collector allocating few objects" do
    limits = Mica::Regex::SearchLimits::TRUSTED_INPUT
    compile_limits = Mica::Regex::CompileLimits::TRUSTED_PATTERN
    # Warm the process-wide memo (`\s`), as an earlier pattern would have.
    Mica::Regex::Expression.new("\\s+", compile_limits: compile_limits).match(" ", limits: limits)
    GC.collect
    before = GC.stats.total_bytes
    off_before = Mica::Regex::OffHeap.allocated_bytes
    expression = Mica::Regex::Expression.new("\\s+", compile_limits: compile_limits)
    expression.match("SELECT  *\n FROM t", limits: limits).try(&.byte_begin(0)).should eq(6)
    collector = (GC.stats.total_bytes - before).to_i64
    off_heap = Mica::Regex::OffHeap.allocated_bytes - off_before
    # The program's states, its plan's tables and the search's workspace
    # come from libc; the collector holds only the objects that refer to
    # them.
    off_heap.should be > 0
    collector.should be < 8_192
  end
end
