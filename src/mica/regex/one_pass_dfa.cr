module Mica::Regex
  # A one-pass DFA (roadmap 6.2.1), RE2's OnePass and Rust regex's
  # `onepass::DFA`: for a pattern where, at every point of a match, the next
  # byte alone decides which way the match goes, captures can be read in a
  # single pass with no thread lists and no backtracking.
  #
  # Each DFA state stands for one NFA state that a byte transition leads to
  # (or the start). Building it explores that state's epsilon closure in
  # priority order, collecting on each path the capture slots it saves and
  # the assertions it passes; each byte class may be reached by one path
  # only, and the match state too. Paths after the match state in priority
  # order are left out, as leftmost-first drops them. When two paths meet
  # the same byte class, the same NFA state, or the match state, the
  # pattern is not one-pass and `build` returns nil.
  #
  # It runs only in phase 2, over a span `[s, e)` the span search has
  # already found: from s it follows one transition per byte, checking the
  # path's assertions and writing its slots, and at e it takes the match
  # path. That is O(L + c) for L = e − s, each step charged to the meter.
  # Should a path not exist (it cannot when the span is a real match), it
  # reports failure and the search falls back to the bounded backtracker.
  class OnePassDFA
    # The most NFA states a program may have for a one-pass DFA to be
    # built. Building costs O(m) per DFA state, so this bounds it at
    # MAX_STATES² operations, once per expression.
    MAX_STATES = 1_500
    # The most capture slots (one bit each in a path's slot mask).
    MAX_SLOTS = 64

    # One path: the DFA state it leads to (-1 for the match path), the
    # slots it saves, and the assertions it passes (bit per `LookKind`).
    record Edge, target : Int32, slots : UInt64, looks : UInt32

    @byte_classes : ByteClasses
    @class_count : Int32
    @table : Array(Int32)
    @match_edges : Array(Int32)
    @list_of_edges : Array(Edge)

    # Builds the one-pass DFA of *program*, or returns nil when the program
    # is not one-pass or is too large.
    def self.build(program : Program, byte_classes : ByteClasses) : OnePassDFA?
      return nil if program.state_count > MAX_STATES || program.slot_count > MAX_SLOTS
      OnePassBuilder.new(program, byte_classes).build
    end

    def initialize(@byte_classes : ByteClasses, @table : Array(Int32), @match_edges : Array(Int32),
                   @list_of_edges : Array(Edge))
      @class_count = @byte_classes.class_count
    end

    # Fills *slots* with the captures of the match `[start, finish)` of
    # *haystack*, which the span search found. Returns false when no path
    # reads the span (the caller then uses another engine).
    def captures(haystack : Bytes, start : Int32, finish : Int32, search_start : Int32, slots : Slice(Int64),
                 meter : SearchMeter) : Bool
      slots.fill(PikeVM::UNSET)
      state = 0
      at = start
      charged = start
      while at < finish
        if at - charged >= PrefilterScan::CHARGE_CHUNK
          meter.charge(at - charged, at)
          charged = at
        end
        index = @table.unsafe_fetch(state * @class_count + @byte_classes.class_of(haystack.unsafe_fetch(at)))
        return false if index < 0
        edge = @list_of_edges.unsafe_fetch(index)
        return false unless take(edge, haystack, at, search_start, slots)
        state = edge.target
        at += 1
      end
      meter.charge(finish - charged + 1, charged)
      index = @match_edges.unsafe_fetch(state)
      return false if index < 0
      take(@list_of_edges.unsafe_fetch(index), haystack, finish, search_start, slots)
    end

    # Searches *haystack* anchored at *start* for the leftmost-first match
    # (see `Searcher`'s one-pass search): from *start* it follows one
    # transition per byte, writing the path's slots into *scratch*, and at
    # each position whose state has a match path that holds, copies them
    # with the match path's into *slots*. Every byte edge of a state with a
    # match path ranks above it (the builder leaves out the paths after the
    # match), so the search goes on while a transition exists and the last
    # match recorded is the leftmost-first one.
    #
    # The paths the builder left out rank below a match path that the
    # search may find does not hold here (its assertion fails, as `$` does
    # before the end). Then a left-out path could still match, so when the
    # search ends with no match recorded after such a position it returns
    # `LazyDFA::GAVE_UP`, and the caller searches another way.
    #
    # Returns the match end, `LazyDFA::NO_MATCH` or `LazyDFA::GAVE_UP`, and
    # the bytes read. O(L + c·k) for L bytes read and k positions with a
    # match path.
    def search(haystack : Bytes, start : Int32, search_start : Int32, slots : Slice(Int64), scratch : Slice(Int64),
               meter : SearchMeter) : {Int32, Int32}
      scratch.fill(PikeVM::UNSET)
      state = 0
      at = start
      charged = start
      size = haystack.size
      found = LazyDFA::NO_MATCH
      undecided = false
      while true
        index = @match_edges.unsafe_fetch(state)
        if index >= 0
          edge = @list_of_edges.unsafe_fetch(index)
          if holds?(edge, haystack, at, search_start)
            slots.copy_from(scratch.to_unsafe, slots.size)
            write(edge, at, slots)
            found = at
            undecided = false
          else
            undecided = true
          end
        end
        break if at >= size
        if at - charged >= PrefilterScan::CHARGE_CHUNK
          meter.charge(at - charged, at)
          charged = at
        end
        index = @table.unsafe_fetch(state * @class_count + @byte_classes.class_of(haystack.unsafe_fetch(at)))
        break if index < 0
        edge = @list_of_edges.unsafe_fetch(index)
        break unless take(edge, haystack, at, search_start, scratch)
        state = edge.target
        at += 1
      end
      meter.charge(at - charged + 1, charged)
      {undecided ? LazyDFA::GAVE_UP : found, at - start}
    end

    private def holds?(edge : Edge, haystack : Bytes, at : Int32, search_start : Int32) : Bool
      looks = edge.looks
      while looks != 0
        kind = looks.trailing_zeros_count
        return false unless Look.holds?(Program::LookKind.new(kind.to_i32), haystack, at, search_start)
        looks &= looks - 1
      end
      true
    end

    private def write(edge : Edge, at : Int32, slots : Slice(Int64)) : Nil
      saved = edge.slots
      while saved != 0
        slot = saved.trailing_zeros_count
        slots[slot] = at.to_i64
        saved &= saved - 1
      end
    end

    private def take(edge : Edge, haystack : Bytes, at : Int32, search_start : Int32, slots : Slice(Int64)) : Bool
      looks = edge.looks
      while looks != 0
        kind = looks.trailing_zeros_count
        return false unless Look.holds?(Program::LookKind.new(kind.to_i32), haystack, at, search_start)
        looks &= looks - 1
      end
      saved = edge.slots
      while saved != 0
        slot = saved.trailing_zeros_count
        slots[slot] = at.to_i64
        saved &= saved - 1
      end
      true
    end
  end

  # :nodoc:
  # Builds a `OnePassDFA` (see there for the rules).
  class OnePassBuilder
    record Path, state : Int32, slots : UInt64, looks : UInt32

    @dfa_state_of : Array(Int32)
    @list_of_roots = [] of Int32
    @table = [] of Int32
    @match_edges = [] of Int32
    @list_of_edges = [] of OnePassDFA::Edge
    @seen : Array(Int32)

    def initialize(@program : Program, @byte_classes : ByteClasses)
      @dfa_state_of = Array(Int32).new(@program.state_count, -1)
      @seen = Array(Int32).new(@program.state_count, -1)
    end

    def build : OnePassDFA?
      root_of(@program.start_state)
      index = 0
      while index < @list_of_roots.size
        return nil unless explore(index)
        index += 1
      end
      OnePassDFA.new(@byte_classes, @table, @match_edges, @list_of_edges)
    end

    private def root_of(nfa_state : Int32) : Int32
      existing = @dfa_state_of[nfa_state]
      return existing if existing >= 0
      id = @list_of_roots.size
      @list_of_roots << nfa_state
      @dfa_state_of[nfa_state] = id
      @byte_classes.class_count.times { @table << -1 }
      @match_edges << -1
      id
    end

    private def explore(dfa_state : Int32) : Bool
      class_count = @byte_classes.class_count
      states = @program.list_of_states
      stack = [Path.new(@list_of_roots[dfa_state], 0_u64, 0_u32)]
      matched = false
      while path = stack.pop?
        current = path.state
        slots = path.slots
        looks = path.looks
        while true
          return false if @seen[current] == dfa_state
          @seen[current] = dfa_state
          state = states[current]
          case state.kind
          when .byte_range?
            if !matched && !add_edges(dfa_state, state.low, state.high, state.next_state, slots, looks, class_count)
              return false
            end
            break
          when .sparse?
            unless matched
              state.alternate.times do |offset|
                transition = @program.list_of_transitions[state.argument + offset]
                return false unless add_edges(dfa_state, transition.low, transition.high, transition.target, slots,
                                      looks, class_count)
              end
            end
            break
          when .match?
            return false if matched
            matched = true
            @match_edges[dfa_state] = @list_of_edges.size
            @list_of_edges << OnePassDFA::Edge.new(-1, slots, looks)
            break
          when .split?
            stack << Path.new(state.alternate, slots, looks)
            current = state.next_state
          when .save?
            slots |= 1_u64 << state.argument
            current = state.next_state
          when .look?
            looks |= 1_u32 << state.argument
            current = state.next_state
          else
            break
          end
        end
      end
      true
    end

    private def add_edges(dfa_state : Int32, low : UInt8, high : UInt8, nfa_target : Int32, slots : UInt64,
                          looks : UInt32, class_count : Int32) : Bool
      target = root_of(nfa_target)
      edge_index = @list_of_edges.size
      @list_of_edges << OnePassDFA::Edge.new(target, slots, looks)
      (@byte_classes.class_of(low)..@byte_classes.class_of(high)).each do |class_index|
        cell = dfa_state * class_count + class_index
        return false if @table[cell] >= 0
        @table[cell] = edge_index
      end
      true
    end
  end
end
