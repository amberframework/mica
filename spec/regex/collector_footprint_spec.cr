require "../spec_helper"

# What Mica asks of the garbage collector's heap: nothing when a program
# starts (its shared tables, sets and locks are static objects), and as
# little as it can for a compile and a first search (scratch sits outside
# the collector's heap or in the stack frame of the call that uses it). A
# program that is about to collect then does not start its collection
# inside a regex call.
private LIMITS = Mica::Regex::CompileLimits::TRUSTED_PATTERN

private def hir_root(source : String) : Mica::Regex::Hir::Node
  Mica::Regex::Syntax.translate(source, dialect: :crystal, compile_limits: LIMITS).root
end

private def class_set(source : String) : Mica::Regex::CodePointSet
  hir_root(source).as(Mica::Regex::Hir::Class).code_point_set
end

private def in_collector_heap?(object : Reference) : Bool
  GC.is_heap_ptr(object.as(Void*))
end

# The fold set the Unicode table gives ASCII *code_point*, or nil when the
# code point matches only itself.
private def fold_bounds_from_the_table(code_point : Int32, restricted : Bool) : Array(Int32)?
  members = [code_point]
  Mica::Regex::Unicode.each_fold_partner(code_point) do |partner|
    members << partner unless restricted && partner >= 0x80
  end
  return nil if members.size == 1
  bounds = [] of Int32
  members.sort.each do |member|
    if !bounds.empty? && member == bounds[-1] + 1
      bounds[-1] = member
    else
      bounds << member << member
    end
  end
  bounds
end

describe "Mica::Regex and the collector's heap" do
  describe "the tables every program shares" do
    it "keeps the node of an ASCII literal outside the collector's heap" do
      literal = hir_root("a")
      literal.should be_a(Mica::Regex::Hir::Literal)
      in_collector_heap?(literal).should be_false
      literal.as(Mica::Regex::Hir::Literal).code_point.should eq('a'.ord)
      hir_root("a").should be(literal)
    end

    it "makes the node of a literal past ASCII in the collector's heap" do
      literal = hir_root("é")
      in_collector_heap?(literal).should be_true
      literal.as(Mica::Regex::Hir::Literal).code_point.should eq('é'.ord)
    end

    it "keeps the sets of `.` outside the collector's heap" do
      but_newline = Mica::Regex::ClassLowering.any_character(false)
      everything = Mica::Regex::ClassLowering.any_character(true)
      in_collector_heap?(but_newline).should be_false
      in_collector_heap?(everything).should be_false
      but_newline.list_of_bounds.to_a.should eq([0, 0x09, 0x0B, 0x10FFFF])
      everything.full?.should be_true
    end

    it "keeps the fold set of an ASCII letter outside the collector's heap" do
      set = class_set("(?i)k")
      in_collector_heap?(set).should be_false
      set.list_of_bounds.to_a.should eq([0x4B, 0x4B, 0x6B, 0x6B, 0x212A, 0x212A])
      class_set("(?i)K").should be(set)
    end

    it "gives every ASCII code point the fold set the Unicode table gives it" do
      0x80.times do |code_point|
        source = "\\x{#{code_point.to_s(16)}}"
        {false, true}.each do |restricted|
          expected = fold_bounds_from_the_table(code_point, restricted)
          root = hir_root("(?i#{restricted ? "r" : ""})#{source}")
          if expected
            root.as(Mica::Regex::Hir::Class).code_point_set.list_of_bounds.to_a.should eq(expected)
          else
            root.as(Mica::Regex::Hir::Literal).code_point.should eq(code_point)
          end
        end
      end
    end

    it "gives the first letter and the last their own fold sets" do
      class_set("(?i)a").list_of_bounds.to_a.should eq([0x41, 0x41, 0x61, 0x61])
      class_set("(?i)z").list_of_bounds.to_a.should eq([0x5A, 0x5A, 0x7A, 0x7A])
      hir_root("(?i)@").should be_a(Mica::Regex::Hir::Literal)
      hir_root("(?i)\\[").should be_a(Mica::Regex::Hir::Literal)
      hir_root("(?i)`").should be_a(Mica::Regex::Hir::Literal)
      hir_root("(?i)\\{").should be_a(Mica::Regex::Hir::Literal)
    end
  end

  describe "a class of one static set" do
    it "reads the Unicode table in place" do
      digits = class_set("\\d")
      table = Mica::Regex::Unicode.decoded_ranges(Mica::Regex::Unicode::Tables::SET_GC_ND)
      digits.list_of_bounds.to_unsafe.should eq(table.to_unsafe)
      digits.list_of_bounds.size.should eq(table.size)
    end

    it "copies the bounds of a class that merges members" do
      merged = class_set("[\\d_]")
      table = Mica::Regex::Unicode.decoded_ranges(Mica::Regex::Unicode::Tables::SET_GC_ND)
      merged.list_of_bounds.to_unsafe.should_not eq(table.to_unsafe)
      merged.includes?('_'.ord).should be_true
      merged.includes?('7'.ord).should be_true
    end

    it "lowers a member written twice or more as it lowers it once" do
      class_set("[\\d\\d]").should eq(class_set("\\d"))
      class_set("[\\d\\w\\d\\w]").should eq(class_set("[\\d\\w]"))
      class_set("[\\w\\d]").should eq(class_set("\\w"))
    end
  end

  describe Mica::Regex::ScratchStack do
    it "pushes and pops in the caller's stack frame" do
      stack = Mica::Regex.scratch_stack(Int32, 3)
      stack.empty?.should be_true
      stack << 1
      stack << 2
      stack << 3
      stack.size.should eq(3)
      stack[0].should eq(1)
      stack[2].should eq(3)
      stack.pop.should eq(3)
      stack.pop?.should eq(2)
      stack.pop.should eq(1)
      stack.pop?.should be_nil
    end

    it "refuses a push past its capacity and a pop when empty" do
      stack = Mica::Regex.scratch_stack(Int32, 1)
      stack << 1
      expect_raises(IndexError) { stack << 2 }
      stack.pop
      expect_raises(IndexError) { stack.pop }
      expect_raises(IndexError) { stack[0] }
    end

    it "holds exactly the inline capacity in the frame and one more in the heap" do
      inline = Mica::Regex::ScratchStack::INLINE_CAPACITY
      {inline - 1, inline, inline + 1}.each do |capacity|
        stack = Mica::Regex.scratch_stack(Int32, capacity)
        capacity.times { |value| stack << value }
        expect_raises(IndexError) { stack << 0 }
        (capacity - 1).downto(0) { |value| stack.pop.should eq(value) }
      end
    end
  end

  describe "a pattern of more nodes than a scratch stack keeps in the frame" do
    it "translates and matches as a small one does" do
      count = Mica::Regex::ScratchStack::INLINE_CAPACITY * 3
      source = "a" * count
      regex = Mica::Regex.compile(source, dialect: :crystal, compile_limits: LIMITS)
      found = regex.search("b" + source, limits: Mica::Regex::SearchLimits::TRUSTED_INPUT)
      found.should_not be_nil
      found.try(&.byte_begin(0)).should eq(1)
      found.try(&.byte_end(0)).should eq(count + 1)
    end
  end

  describe "the one-pass DFA" do
    it "keeps its tables outside the collector's heap" do
      before = Mica::Regex::OffHeap.allocated_bytes
      program = Mica::Regex::Syntax.compile("\\$\\d+", dialect: :crystal, compile_limits: LIMITS)
      plan = program.plan
      heap_before = GC.stats.total_bytes
      one_pass = plan.one_pass
      heap_after = GC.stats.total_bytes
      one_pass.should_not be_nil
      # The DFA object alone: its cells are tens of kilobytes outside.
      (heap_after - heap_before).should be < 1024
      (Mica::Regex::OffHeap.allocated_bytes - before).should be > 8 * 1024
    end

    it "answers nil for a program that is not one-pass and keeps nothing" do
      program = Mica::Regex::Syntax.compile("(a*)(a*)", dialect: :crystal, compile_limits: LIMITS)
      program.plan.one_pass.should be_nil
    end
  end
end
