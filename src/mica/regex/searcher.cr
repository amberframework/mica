module Mica::Regex
  # Which engine a `Searcher` runs. `Auto` is what the public API uses;
  # the others let specs and the engine differential force one path.
  enum Engine
    # A capture-free Pike VM pass finds the match span; when captures are
    # wanted, the bounded backtracker (when the span fits its bitset) or a
    # Pike VM with every slot runs again over the span alone.
    Auto
    # One Pike VM pass with every capture slot.
    PikeVM
    # One bounded backtracker pass over the whole haystack (it must fit).
    Backtracker
  end

  # Runs the searches of one call over one haystack: it validates the
  # haystack once, holds the call's `SearchMeter`, and keeps its engine
  # workspaces for the searches that follow (as `scan` and `gsub` make).
  #
  # **Two phases**, as roadmap 6.2.1 lays out. Phase 1 finds the
  # leftmost-first span `[s, e)` with a Pike VM tracking only group 0, in
  # O(m·(n + 1)). Phase 2 runs only when captures are asked for, anchored
  # at s and reading no byte at or after e: the highest-priority match that
  # starts at s still ends at e when bytes past e are cut off, because
  # cutting bytes only removes matches. It costs O(m·(L + 1) + c) in the
  # backtracker or O(m·c·(L + 1)) in the Pike VM, for L = e − s.
  #
  # WARNING: A searcher belongs to one call and one fiber.
  class Searcher
    # The call's meter.
    getter meter : SearchMeter

    @span_vm : PikeVM? = nil
    @capture_vm : PikeVM? = nil
    @backtracker : BoundedBacktracker? = nil
    @span_slots = Slice(Int64).new(2, PikeVM::UNSET)
    @capture_slots : Slice(Int64)

    def initialize(@program : Program, @haystack : String, limits : SearchLimits, timeout : Time::Span?,
                   @engine : Engine = Engine::Auto)
      bytes = @haystack.to_slice
      @meter = SearchMeter.new(limits, @program.state_count, bytes.size, timeout)
      @capture_slots = Slice(Int64).new(@program.slot_count, PikeVM::UNSET)
      # Validation reads every byte once: one operation per byte.
      @meter.charge(bytes.size, 0)
      if offset = Core::UTF8.first_invalid_offset(bytes)
        raise Mica::EncodingError.new("The haystack is not valid UTF-8", Core::Position.new(offset.to_i64))
      end
    end

    # Returns the slots of the leftmost-first match at or after
    # *byte_index* (group 0 only unless *captures*), or nil. Raises
    # `ArgumentError` when *byte_index* is negative or inside a character.
    def find(byte_index : Int32, options : MatchOptions, captures : Bool) : Slice(Int64)?
      bytes = @haystack.to_slice
      return nil if byte_index > bytes.size
      check_start(bytes, byte_index)
      anchored = @program.options.anchored? || options.anchored?
      end_anchored = @program.options.end_anchored? || options.end_anchored?
      case @engine
      in .pike_vm?
        slots = @capture_slots
        found = capture_vm.search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, false, @meter, slots)
        found ? slots : nil
      in .backtracker?
        slots = @capture_slots
        found = backtracker.search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, @meter, slots)
        found ? slots : nil
      in .auto?
        find_in_two_phases(bytes, byte_index, anchored, end_anchored, captures)
      end
    end

    # Returns true when anything matches at or after *byte_index*; stops at
    # the first match state reached.
    def matches?(byte_index : Int32, options : MatchOptions) : Bool
      bytes = @haystack.to_slice
      return false if byte_index > bytes.size
      check_start(bytes, byte_index)
      anchored = @program.options.anchored? || options.anchored?
      end_anchored = @program.options.end_anchored? || options.end_anchored?
      span_vm.search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, true, @meter, @span_slots)
    end

    private def find_in_two_phases(bytes : Bytes, byte_index : Int32, anchored : Bool, end_anchored : Bool,
                                   captures : Bool) : Slice(Int64)?
      span = @span_slots
      return nil unless span_vm.search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, false,
                          @meter, span)
      return span if !captures || @program.slot_count == 2
      start = span[0].to_i32
      finish = span[1].to_i32
      slots = @capture_slots
      found = if BoundedBacktracker.fits?(@program, finish - start)
                backtracker.search(bytes, start, finish, byte_index, true, end_anchored, @meter, slots)
              else
                capture_vm.search(bytes, start, finish, byte_index, true, end_anchored, false, @meter, slots)
              end
      unless found && slots[0] == span[0] && slots[1] == span[1]
        raise Mica::Error.new("internal error: the capture pass did not find the span #{start}...#{finish}")
      end
      slots
    end

    private def check_start(bytes : Bytes, byte_index : Int32) : Nil
      raise ArgumentError.new("Negative byte index: #{byte_index}") if byte_index < 0
      if byte_index < bytes.size && bytes.unsafe_fetch(byte_index) & 0xC0 == 0x80
        raise ArgumentError.new("Byte index #{byte_index} is inside a UTF-8 character")
      end
    end

    private def span_vm : PikeVM
      @span_vm ||= PikeVM.new(@program, 2)
    end

    private def capture_vm : PikeVM
      @capture_vm ||= PikeVM.new(@program, @program.slot_count)
    end

    private def backtracker : BoundedBacktracker
      @backtracker ||= BoundedBacktracker.new(@program, @program.slot_count)
    end
  end
end
