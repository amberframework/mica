module Mica::Regex
  # :nodoc:
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

  # :nodoc:
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
  # **First line.** Under `CompileOptions::FirstLine` an unanchored search
  # starts no match after the first line feed at or after its offset. The
  # searcher scans for that line feed once and reuses it while the offsets
  # of later searches stay at or before it, so an iteration call scans each
  # byte at most once; every byte scanned is charged one operation.
  #
  # **One workspace.** The searcher holds at most one `PikeVM` workspace:
  # the span layout while only spans are asked for, the capture layout
  # (which also runs span searches) once captures are, releasing the span
  # workspace first. Beside it lives at most one `BoundedBacktracker`, sized
  # within `Program#backtracker_allowance`, so everything a search holds
  # stays within `CompileLimits#max_pike_bytes`.
  #
  # WARNING: A searcher belongs to one call and one fiber.
  class Searcher
    # The call's meter.
    getter meter : SearchMeter

    @pike : PikeVM? = nil
    @backtracker : BoundedBacktracker? = nil
    @span_slots = Slice(Int64).new(2, PikeVM::UNSET)
    @capture_slots : Slice(Int64)
    # The last first-line scan: it started at @line_scan_start and found
    # the line feed (or the haystack end) at @line_feed_at.
    @line_scan_start = -1
    @line_feed_at = -1

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
      # The deadline is read at the start of every call, so a timeout that
      # has already passed fails even a search too short to reach a clock
      # checkpoint.
      @meter.enforce_deadline(0)
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
        want_captures = @program.slot_count > 2
        found = pike(want_captures).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, false,
          @meter, slots, first_line_end(bytes, byte_index, anchored), want_captures)
        found ? slots : nil
      in .backtracker?
        slots = @capture_slots
        found = backtracker.search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, @meter, slots,
          first_line_end(bytes, byte_index, anchored))
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
      pike(false).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, true, @meter, @span_slots,
        first_line_end(bytes, byte_index, anchored), false)
    end

    private def find_in_two_phases(bytes : Bytes, byte_index : Int32, anchored : Bool, end_anchored : Bool,
                                   captures : Bool) : Slice(Int64)?
      span = @span_slots
      want_captures = captures && @program.slot_count > 2
      return nil unless pike(want_captures).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored,
                          false, @meter, span, first_line_end(bytes, byte_index, anchored), false)
      return span unless want_captures
      start = span[0].to_i32
      finish = span[1].to_i32
      slots = @capture_slots
      found = if BoundedBacktracker.fits?(@program, finish - start)
                backtracker.search(bytes, start, finish, byte_index, true, end_anchored, @meter, slots, Int32::MAX)
              else
                pike(true).search(bytes, start, finish, byte_index, true, end_anchored, false, @meter, slots, Int32::MAX,
                  true)
              end
      unless found && slots[0] == span[0] && slots[1] == span[1]
        raise Mica::Error.new("internal error: the capture pass did not find the span #{start}...#{finish}")
      end
      slots
    end

    # Returns the last position where an unanchored search from *start*
    # may begin a match: the first line feed at or after *start* under
    # `CompileOptions::FirstLine`, or `Int32::MAX`. A scan already made
    # from at or before *start* answers when its line feed is at or after
    # *start* (no line feed lies between); otherwise the bytes from
    # *start* are scanned, each charged one operation.
    private def first_line_end(bytes : Bytes, start : Int32, anchored : Bool) : Int32
      return Int32::MAX if anchored || !@program.options.first_line?
      return @line_feed_at if @line_scan_start >= 0 && @line_scan_start <= start <= @line_feed_at
      line_feed_at = bytes.index(Look::LINE_FEED, start) || bytes.size
      @meter.charge(line_feed_at - start + 1, start)
      @line_scan_start = start
      @line_feed_at = line_feed_at
    end

    private def check_start(bytes : Bytes, byte_index : Int32) : Nil
      raise ArgumentError.new("Negative byte index: #{byte_index}") if byte_index < 0
      if byte_index < bytes.size && bytes.unsafe_fetch(byte_index) & 0xC0 == 0x80
        raise ArgumentError.new("Byte index #{byte_index} is inside a UTF-8 character")
      end
    end

    # Returns the workspace, in the capture layout when *captures*. A span
    # workspace is released before a capture one replaces it.
    private def pike(captures : Bool) : PikeVM
      if workspace = @pike
        return workspace if workspace.captures? || !captures
        workspace.release
        @pike = nil
      end
      @pike = PikeVM.new(@program, captures)
    end

    private def backtracker : BoundedBacktracker
      @backtracker ||= BoundedBacktracker.new(@program, @program.slot_count)
    end
  end
end
