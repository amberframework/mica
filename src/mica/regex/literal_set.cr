module Mica::Regex
  # The literals every match of a pattern starts with, extracted from its
  # `Hir` when the pattern is compiled (roadmap 6.2, pipeline step 4). The
  # accelerators in `Prefilter` use them to skip ahead to the next position
  # where a match could start.
  #
  # Each literal is a byte string. Every match of the pattern starts with
  # one of them. When `exact?`, the set is more than that: the pattern
  # matches exactly these strings, in this priority order (leftmost-first,
  # earlier entries first), and contains no assertion, so a literal search
  # alone finds the match.
  #
  # A pattern that can match the empty string, or whose start is too varied
  # (a large class, more than `MAX_LITERALS` alternatives), has no set.
  class LiteralSet
    # The most literals a set holds.
    MAX_LITERALS = 64
    # The longest literal kept; longer ones are cut to a prefix.
    MAX_LITERAL_BYTES = 32
    # A class with more code points than this ends the literal.
    MAX_CLASS_CODE_POINTS = 8
    # How deep extraction descends into the tree before it stops.
    MAX_DEPTH = 512

    # The literals in priority order.
    getter list_of_literals : Array(Bytes)
    # True when the pattern matches exactly these literals (see the class
    # description).
    getter? exact : Bool

    def initialize(@list_of_literals : Array(Bytes), @exact : Bool)
    end

    # Returns the set for *pattern*, or nil when it has none. Charges one
    # operation per node visited to *meter*.
    def self.extract(pattern : Hir::Pattern, meter : Core::WorkMeter) : LiteralSet?
      extractor = LiteralExtractor.new(meter)
      sequence = extractor.sequence(pattern.root, 0)
      return nil unless sequence
      return nil if sequence.empty? || sequence.any?(&.bytes.empty?)
      exact = sequence.all?(&.exact?) && !extractor.saw_look? && unrestricted?(pattern.options)
      list_of_literals = [] of Bytes
      sequence.each do |entry|
        list_of_literals << entry.bytes unless list_of_literals.includes?(entry.bytes)
      end
      new(list_of_literals, exact)
    end

    # True when no option changes where a literal match may start or end.
    private def self.unrestricted?(options : CompileOptions) : Bool
      !options.anchored? && !options.end_anchored? && !options.first_line?
    end

    # The shortest literal's length.
    def minimum_length : Int32
      @list_of_literals.min_of(&.size)
    end
  end

  # :nodoc:
  # One literal of a sequence: its bytes, and whether it is the whole match
  # of its branch (exact) or only a prefix of it.
  record LiteralEntry, bytes : Bytes, exact : Bool do
    def exact? : Bool
      exact
    end
  end

  # :nodoc:
  # Computes the prefix literal sequence of a `Hir` node, following the
  # rules of Rust regex's literal extractor in a simpler form. A sequence of
  # nil means "anything can follow" (no finite set of prefixes).
  class LiteralExtractor
    getter? saw_look : Bool = false

    def initialize(@meter : Core::WorkMeter)
    end

    def sequence(node : Hir::Node, depth : Int32) : Array(LiteralEntry)?
      @meter.charge(1)
      return nil if depth > LiteralSet::MAX_DEPTH
      if node.is_a?(Hir::Empty)
        [LiteralEntry.new(Bytes.empty, true)]
      elsif node.is_a?(Hir::Look)
        @saw_look = true
        [LiteralEntry.new(Bytes.empty, true)]
      elsif node.is_a?(Hir::Literal)
        [LiteralEntry.new(node.code_point.chr.to_s.to_slice, true)]
      elsif node.is_a?(Hir::Class)
        class_sequence(node.code_point_set)
      elsif node.is_a?(Hir::Capture)
        sequence(node.child, depth + 1)
      elsif node.is_a?(Hir::Repetition)
        repetition_sequence(node, depth)
      elsif node.is_a?(Hir::Concatenation)
        concatenation_sequence(node.list_of_children, depth)
      elsif node.is_a?(Hir::Alternation)
        alternation_sequence(node.list_of_branches, depth)
      else
        nil
      end
    end

    private def class_sequence(set : CodePointSet) : Array(LiteralEntry)?
      return nil if set.empty? || set.size > LiteralSet::MAX_CLASS_CODE_POINTS
      list_of_entries = [] of LiteralEntry
      set.each_range do |low, high|
        (low..high).each { |code_point| list_of_entries << LiteralEntry.new(code_point.chr.to_s.to_slice, true) }
      end
      list_of_entries
    end

    private def repetition_sequence(node : Hir::Repetition, depth : Int32) : Array(LiteralEntry)?
      return [LiteralEntry.new(Bytes.empty, false)] if node.minimum == 0
      child = sequence(node.child, depth + 1)
      return nil unless child
      if node.maximum == node.minimum
        result = [LiteralEntry.new(Bytes.empty, true)]
        node.minimum.times do
          break unless result.any?(&.exact?)
          crossed = cross(result, child)
          return inexact(result) unless crossed
          result = crossed
        end
        result
      else
        inexact(child)
      end
    end

    private def concatenation_sequence(list_of_children : Array(Hir::Node), depth : Int32) : Array(LiteralEntry)?
      result = [LiteralEntry.new(Bytes.empty, true)]
      list_of_children.each do |child|
        break unless result.any?(&.exact?)
        child_sequence = sequence(child, depth + 1)
        return inexact(result) unless child_sequence
        crossed = cross(result, child_sequence)
        return inexact(result) unless crossed
        result = crossed
      end
      result
    end

    private def alternation_sequence(list_of_branches : Array(Hir::Node), depth : Int32) : Array(LiteralEntry)?
      result = [] of LiteralEntry
      list_of_branches.each do |branch|
        branch_sequence = sequence(branch, depth + 1)
        return nil unless branch_sequence
        result.concat(branch_sequence)
        return nil if result.size > LiteralSet::MAX_LITERALS
      end
      result
    end

    # Appends each entry of *right* to each exact entry of *left*, in
    # priority order; inexact entries of *left* stay as they are. Returns nil
    # when the product would hold more than `MAX_LITERALS` entries.
    private def cross(left : Array(LiteralEntry), right : Array(LiteralEntry)) : Array(LiteralEntry)?
      size = left.sum { |entry| entry.exact? ? right.size : 1 }
      return nil if size > LiteralSet::MAX_LITERALS
      result = Array(LiteralEntry).new(size)
      left.each do |entry|
        unless entry.exact?
          result << entry
          next
        end
        right.each do |suffix|
          bytes = Bytes.new(entry.bytes.size + suffix.bytes.size)
          entry.bytes.copy_to(bytes)
          suffix.bytes.copy_to(bytes + entry.bytes.size)
          if bytes.size > LiteralSet::MAX_LITERAL_BYTES
            result << LiteralEntry.new(bytes[0, LiteralSet::MAX_LITERAL_BYTES], false)
          else
            result << LiteralEntry.new(bytes, suffix.exact?)
          end
        end
      end
      result
    end

    private def inexact(list_of_entries : Array(LiteralEntry)) : Array(LiteralEntry)
      list_of_entries.map { |entry| LiteralEntry.new(entry.bytes, false) }
    end
  end
end
