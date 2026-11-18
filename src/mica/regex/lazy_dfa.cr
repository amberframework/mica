module Mica::Regex
  # A lazy DFA over a `Program` (roadmap 6.2.1), built one state at a time
  # as a search needs it, in the RE2 and Rust regex design.
  #
  # **Forward** (`reverse? == false`) it finds the end of the
  # leftmost-first match: a DFA state is the ordered list of NFA states the
  # Pike VM would hold (priority order kept), and reaching the match state
  # drops every lower-priority thread, so the last match the scan records
  # before the DFA dies is the end the Pike VM reports.
  #
  # **Reverse** it finds the start: run backward from the match end `e`
  # over a `ReverseNFA`, it records every position `s` where `[s, e)`
  # matches and keeps the smallest. Because the forward match starts at the
  # leftmost position any match starts at, that is its start.
  #
  # **Assertions.** A state carries what the assertions need to know about
  # the bytes already read (whether the position is the start or end of the
  # text, whether the previous byte was a line feed, a word character, a
  # continuation byte or not ASCII), and the next byte is the transition's
  # input, so every assertion is decided when the transition is built: the
  # closure that leads to a match runs one byte late, as in Rust regex. The
  # end of the haystack is an extra input symbol, and (forward, for `$` and
  # `\Z`) so is a line feed that ends the haystack. Unicode word assertions
  # need a whole character on each side, so a DFA that meets one next to a
  # non-ASCII byte gives up and the search runs on the Pike VM (Rust regex
  # does the same). `\G` is left to the Pike VM.
  #
  # **Cost.** A transition the cache holds costs one table read. Building a
  # state costs one operation per NFA state its closure visits, at most
  # O(m). Every byte read and every state built is charged to the call's
  # `SearchMeter`, and so is every state a cache clear discards. A cache
  # that grows past its ceiling is cleared; when it thrashes (more than
  # `MAX_CLEARS` clears with fewer than `MINIMUM_BYTES_PER_STATE` bytes read
  # per state built since the last one), the DFA gives up and the search
  # runs on the Pike VM. So a search costs O(m·(n + 1)) whatever happens.
  #
  # The definition is immutable and shared; the states live in a
  # `DFACache`, one per search at a time.
  class LazyDFA
    # Search results besides a position.
    NO_MATCH = -1
    GAVE_UP  = -2

    # Cache clears allowed before thrashing can give up.
    MAX_CLEARS = 3
    # The fewest bytes read per state built that does not count as
    # thrashing.
    MINIMUM_BYTES_PER_STATE = 10

    # State flags (the first entry of a state's key).
    TEXT_EDGE       =  0x01 # forward: at the start of the text; reverse: at its end
    PREVIOUS_LF     =  0x02 # the byte read last was a line feed
    PREVIOUS_WORD   =  0x04 # the byte read last was an ASCII word character
    PREVIOUS_WIDE   =  0x08 # the byte read last was not ASCII
    PREVIOUS_TAIL   =  0x10 # reverse: the byte read last was a continuation byte
    FINAL_LF_EDGE   =  0x20 # reverse: just before a line feed that ends the text
    UNANCHORED      =  0x40 # forward: start a thread at every character
    START_PENDING   =  0x80 # forward: start a thread here (anchored start)
    MATCH_BEHIND    = 0x100 # the closure before the last byte reached a match
    LOOKBEHIND_BITS =  0x3F

    # Per-state markers in `DFACache` (one byte per state).
    MARK_MATCH = 0x01_u8
    MARK_DEAD  = 0x02_u8
    MARK_START = 0x04_u8

    # The dead state, and the dead state that reports a match first.
    DEAD       = 0
    DEAD_MATCH = 1

    getter program : Program
    getter byte_classes : ByteClasses
    getter? reverse : Bool
    # Entries per state in the transition table: one per class, then the
    # end of input, then (forward) a line feed that ends the haystack.
    getter stride : Int32
    @reverse_nfa : ReverseNFA?
    @relevant_flags : Int32
    @unicode_words : Bool
    @final_lf : Bool

    def initialize(@program : Program, @byte_classes : ByteClasses, @reverse : Bool)
      # Rounded up to a multiple of 4, so a row offset leaves two low bits
      # free for flags (see `find_end`).
      @stride = (@byte_classes.class_count + 2 + 3) & ~3
      @reverse_nfa = @reverse ? ReverseNFA.new(@program) : nil
      looks = LazyDFA.looks_used(@program)
      line_start = looks.includes?(Program::LookKind::StartOfLine)
      text_start = looks.includes?(Program::LookKind::StartOfText)
      text_end = looks.includes?(Program::LookKind::EndOfText)
      final_newline = looks.includes?(Program::LookKind::EndOfTextOrFinalNewline)
      line_end = looks.includes?(Program::LookKind::EndOfLine) ||
                 looks.includes?(Program::LookKind::NotBeforeLineFeed)
      @unicode_words = looks.any? { |kind| LazyDFA.unicode_word?(kind) }
      words = @unicode_words || looks.any? { |kind| LazyDFA.ascii_word?(kind) }
      @final_lf = !@reverse && final_newline
      relevant = UNANCHORED | START_PENDING | MATCH_BEHIND
      if @reverse
        relevant |= PREVIOUS_TAIL
        relevant |= TEXT_EDGE if line_start || text_end || final_newline || line_end
        relevant |= FINAL_LF_EDGE if final_newline
        relevant |= PREVIOUS_LF if line_end
      else
        relevant |= TEXT_EDGE if text_start || line_start
        relevant |= PREVIOUS_LF if line_start
      end
      relevant |= PREVIOUS_WORD if words
      relevant |= PREVIOUS_WIDE if @unicode_words
      @relevant_flags = relevant
    end

    # True when the lazy DFA can run *program*: everything but `\G`.
    def self.supports?(program : Program) : Bool
      !looks_used(program).includes?(Program::LookKind::SearchStart)
    end

    # The assertion kinds *program* uses.
    def self.looks_used(program : Program) : Array(Program::LookKind)
      program.list_of_states.compact_map do |state|
        Program::LookKind.new(state.argument) if state.kind.look?
      end.uniq!
    end

    protected def self.unicode_word?(kind : Program::LookKind) : Bool
      kind.word_boundary? || kind.not_word_boundary? || kind.word_start? || kind.word_end?
    end

    protected def self.ascii_word?(kind : Program::LookKind) : Bool
      kind.word_boundary_ascii? || kind.not_word_boundary_ascii? || kind.word_start_ascii? || kind.word_end_ascii?
    end

    # The input symbol for the end of input (forward) or the start of the
    # text (reverse).
    def edge_symbol : Int32
      @byte_classes.class_count
    end

    # The input symbol for a line feed that ends the haystack (forward).
    def final_lf_symbol : Int32
      @byte_classes.class_count + 1
    end

    # Searches forward from *start* for the end of the leftmost-first
    # match, reading to the end of *haystack*. Returns the end, `NO_MATCH`,
    # or `GAVE_UP` (the caller then runs the Pike VM). With *earliest*,
    # returns the first match end reached. While the DFA sits in its start
    # state, *scan* (when given) skips to the next position where a literal
    # starts.
    #
    # The loop works on table entries (see `DFACache#entry_of`): a state's
    # row offset with a low bit set for states that need a look (match,
    # dead, start), so the common transition is one load and one test.
    def find_end(cache : DFACache, haystack : Bytes, start : Int32, anchored : Bool, earliest : Bool,
                 scan : PrefilterScan?, meter : SearchMeter) : Int32
      size = haystack.size
      limit = @final_lf && size > start && haystack.unsafe_fetch(size - 1) == Look::LINE_FEED ? size - 1 : size
      state = cache.start_state(self, start_flags(haystack, start, anchored), meter)
      return GAVE_UP if state < 0
      current = cache.entry_of(state)
      last_end = NO_MATCH
      at = start
      bytes = haystack.to_unsafe
      class_table = @byte_classes.table
      stride = @stride
      while true
        if scan && current & START_ENTRY != 0
          candidate = scan.find(at, meter)
          return last_end if candidate < 0
          if candidate > at
            cache.note_bytes(candidate - at)
            at = candidate
            state = cache.start_state(self, start_flags(haystack, at, anchored), meter)
            return GAVE_UP if state < 0
            current = cache.entry_of(state)
          end
          scan = nil if scan.ineffective?
        end
        break if at >= limit
        chunk_end = Math.min(limit, at + 4096)
        chunk_start = at
        table = cache.transition_table.to_unsafe
        while at < chunk_end
          entry = table[(current & ROW_MASK) &+ class_table[bytes[at]]]
          if entry < 0
            id = cache.transition(self, current // stride, @byte_classes.class_of(bytes[at]), meter)
            return GAVE_UP if id < 0
            entry = cache.entry_of(id)
            table = cache.transition_table.to_unsafe
          end
          at &+= 1
          current = entry
          if entry & (SPECIAL | START_ENTRY) != 0
            break if scan && entry & START_ENTRY != 0
            if entry & SPECIAL != 0
              marks = cache.list_of_marks.unsafe_fetch(entry // stride)
              if marks & MARK_MATCH != 0
                last_end = at - 1
                break if earliest
              end
              break if marks & MARK_DEAD != 0
            end
          end
        end
        meter.charge(at - chunk_start, at)
        cache.note_bytes(at - chunk_start)
        return last_end if earliest && last_end >= 0
        return last_end if cache.list_of_marks.unsafe_fetch(current // stride) & MARK_DEAD != 0
      end
      if at == size - 1 && limit == size - 1
        state = step(cache, current // stride, final_lf_symbol, meter)
        return GAVE_UP if state < 0
        at += 1
        meter.charge(1, at)
        if cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0
          last_end = at - 1
          return last_end if earliest
        end
        return last_end if cache.list_of_marks.unsafe_fetch(state) & MARK_DEAD != 0
        current = cache.entry_of(state)
      end
      state = step(cache, current // stride, edge_symbol, meter)
      return GAVE_UP if state < 0
      last_end = size if cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0
      last_end
    end

    # Searches backward from *finish* (a match end) to no lower than
    # *lower_bound* for the leftmost start of a match ending at *finish*.
    # Returns the start, `NO_MATCH`, or `GAVE_UP`.
    def find_start(cache : DFACache, haystack : Bytes, finish : Int32, lower_bound : Int32,
                   meter : SearchMeter) : Int32
      state = cache.start_state(self, reverse_start_flags(haystack, finish), meter)
      return GAVE_UP if state < 0
      current = cache.entry_of(state)
      last_start = NO_MATCH
      at = finish
      bytes = haystack.to_unsafe
      class_table = @byte_classes.table
      stride = @stride
      dead = false
      while at > lower_bound && !dead
        chunk_end = Math.max(lower_bound, at - 4096)
        chunk_start = at
        table = cache.transition_table.to_unsafe
        while at > chunk_end
          entry = table[(current & ROW_MASK) &+ class_table[bytes[at - 1]]]
          if entry < 0
            id = cache.transition(self, current // stride, @byte_classes.class_of(bytes[at - 1]), meter)
            return GAVE_UP if id < 0
            entry = cache.entry_of(id)
            table = cache.transition_table.to_unsafe
          end
          at &-= 1
          current = entry
          if entry & SPECIAL != 0
            marks = cache.list_of_marks.unsafe_fetch(entry // stride)
            last_start = at + 1 if marks & MARK_MATCH != 0
            if marks & MARK_DEAD != 0
              dead = true
              break
            end
          end
        end
        meter.charge(chunk_start - at, at)
        cache.note_bytes(chunk_start - at)
      end
      return last_start if dead
      symbol = lower_bound > 0 ? @byte_classes.class_of(haystack.unsafe_fetch(lower_bound - 1)) : edge_symbol
      state = step(cache, current // stride, symbol, meter)
      return GAVE_UP if state < 0
      last_start = lower_bound if cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0
      last_start
    end

    # The low bits of a table entry (see `find_end`): a match or dead state,
    # and a start state.
    SPECIAL     = 1
    START_ENTRY = 2
    # Clears the flag bits of a table entry, leaving the row offset.
    ROW_MASK = ~3

    private def step(cache : DFACache, state : Int32, symbol : Int32, meter : SearchMeter) : Int32
      entry = cache.transition_table.unsafe_fetch(state * @stride + symbol)
      return entry // @stride if entry >= 0
      cache.transition(self, state, symbol, meter)
    end

    private def start_flags(haystack : Bytes, at : Int32, anchored : Bool) : Int32
      flags = anchored ? START_PENDING : UNANCHORED
      if at == 0
        flags |= TEXT_EDGE
      else
        flags |= byte_flags(haystack.unsafe_fetch(at - 1))
      end
      flags & @relevant_flags
    end

    private def reverse_start_flags(haystack : Bytes, at : Int32) : Int32
      size = haystack.size
      flags = 0
      if at == size
        flags |= TEXT_EDGE
      else
        byte = haystack.unsafe_fetch(at)
        flags |= byte_flags(byte)
        flags |= PREVIOUS_TAIL if byte & 0xC0 == 0x80
        flags |= FINAL_LF_EDGE if at == size - 1 && byte == Look::LINE_FEED
      end
      flags & @relevant_flags
    end

    private def byte_flags(byte : UInt8) : Int32
      flags = 0
      flags |= PREVIOUS_LF if byte == Look::LINE_FEED
      flags |= PREVIOUS_WORD if byte < 0x80 && Look.word_code_point?(byte.to_i32, true)
      flags |= PREVIOUS_WIDE if byte >= 0x80
      flags
    end

    # :nodoc:
    # Builds the state reached from the state with *key* on *symbol* and
    # returns its key, or nil when the DFA must give up (a Unicode word
    # assertion next to a non-ASCII byte). Writes into *builder*, and
    # charges each NFA state the closure visits.
    def next_key(key : Array(Int32), symbol : Int32, builder : DFABuilder, meter : SearchMeter) : Array(Int32)?
      @reverse ? reverse_next_key(key, symbol, builder, meter) : forward_next_key(key, symbol, builder, meter)
    end

    # The byte a symbol stands for (-1 for the edge of the text; the line
    # feed for the final line feed).
    private def symbol_byte(symbol : Int32) : Int32
      return -1 if symbol == edge_symbol
      return Look::LINE_FEED.to_i32 if symbol == final_lf_symbol
      @byte_classes.representative(symbol).to_i32
    end

    private def forward_next_key(key : Array(Int32), symbol : Int32, builder : DFABuilder,
                                 meter : SearchMeter) : Array(Int32)?
      flags = key.unsafe_fetch(0)
      byte = symbol_byte(symbol)
      builder.reset
      matched = false
      quit = false
      states = @program.list_of_states
      explore = ->(seed : Int32) do
        builder.push(seed)
        while current = builder.pop?
          while true
            break unless builder.visit(current)
            meter.charge(1, 0)
            state = states.unsafe_fetch(current)
            case state.kind
            when .byte_range?, .sparse?
              builder.output(current)
              break
            when .match?
              matched = true
              builder.clear_stack
              break
            when .split?
              builder.push(state.alternate)
              current = state.next_state
            when .save?
              current = state.next_state
            when .look?
              verdict = forward_look(Program::LookKind.new(state.argument), flags, byte, symbol)
              if verdict.nil?
                quit = true
                builder.clear_stack
                break
              end
              break unless verdict
              current = state.next_state
            else
              break
            end
          end
        end
        nil
      end
      (1...key.size).each do |index|
        explore.call(key.unsafe_fetch(index))
        break if matched || quit
      end
      boundary = byte < 0x80 || byte >= 0xC0
      if !matched && !quit && (flags & START_PENDING != 0 || (flags & UNANCHORED != 0 && boundary))
        explore.call(@program.start_state)
      end
      return nil if quit
      return matched ? DEAD_MATCH_KEY : DEAD_KEY if byte < 0 && symbol == edge_symbol
      next_flags = matched ? MATCH_BEHIND : 0
      next_flags |= UNANCHORED if flags & UNANCHORED != 0 && !matched
      next_flags |= byte_flags(byte.to_u8)
      builder.begin_targets(next_flags & @relevant_flags)
      builder.each_output do |state_index|
        state = states.unsafe_fetch(state_index)
        target = if state.kind.byte_range?
                   state.low <= byte <= state.high ? state.next_state : -1
                 else
                   @program.sparse_target(state, byte.to_u8)
                 end
        builder.add_target(target) if target >= 0
      end
      targets = builder.targets
      if targets.size == 1 && next_flags & UNANCHORED == 0
        return matched ? DEAD_MATCH_KEY : DEAD_KEY
      end
      targets
    end

    # Returns whether *kind* holds at a position whose earlier bytes are
    # described by *flags* and whose next input is *byte* (-1 at the end),
    # or nil when it cannot be decided without the Pike VM.
    private def forward_look(kind : Program::LookKind, flags : Int32, byte : Int32, symbol : Int32) : Bool?
      at_end = byte < 0
      next_lf = byte == Look::LINE_FEED
      case kind
      in .start_of_text?
        flags & TEXT_EDGE != 0
      in .start_of_line?
        flags & TEXT_EDGE != 0 || (flags & PREVIOUS_LF != 0 && !at_end)
      in .end_of_text?
        at_end
      in .end_of_text_or_final_newline?
        at_end || symbol == final_lf_symbol
      in .end_of_line?
        at_end || next_lf
      in .not_before_line_feed?
        !next_lf
      in .search_start?
        nil
      in .word_boundary?, .not_word_boundary?, .word_start?, .word_end?
        return nil if flags & PREVIOUS_WIDE != 0 || byte >= 0x80
        word_look(kind, flags & PREVIOUS_WORD != 0, word_byte?(byte))
      in .word_boundary_ascii?, .not_word_boundary_ascii?, .word_start_ascii?, .word_end_ascii?
        word_look(kind, flags & PREVIOUS_WORD != 0, word_byte?(byte))
      end
    end

    private def word_byte?(byte : Int32) : Bool
      byte >= 0 && byte < 0x80 && Look.word_code_point?(byte, true)
    end

    private def word_look(kind : Program::LookKind, before : Bool, after : Bool) : Bool
      case kind
      when .word_boundary?, .word_boundary_ascii?         then before != after
      when .not_word_boundary?, .not_word_boundary_ascii? then before == after
      when .word_start?, .word_start_ascii?               then !before && after
      else                                                     before && !after
      end
    end

    private def reverse_next_key(key : Array(Int32), symbol : Int32, builder : DFABuilder,
                                 meter : SearchMeter) : Array(Int32)?
      reverse_nfa = @reverse_nfa || raise Mica::Error.new("internal error: no reverse NFA")
      flags = key.unsafe_fetch(0)
      byte = symbol_byte(symbol)
      builder.reset
      accepted = false
      quit = false
      (1...key.size).each { |index| builder.push(key.unsafe_fetch(index)) }
      while current = builder.pop?
        next unless builder.visit(current)
        meter.charge(1, 0)
        accepted = true if current == reverse_nfa.accept_node
        builder.output(current) if reverse_nfa.consumes?(current)
        reverse_nfa.each_epsilon(current) do |target, look|
          if look >= 0
            verdict = reverse_look(Program::LookKind.new(look), flags, byte)
            if verdict.nil?
              quit = true
              next
            end
            next unless verdict
          end
          builder.push(target)
        end
      end
      return nil if quit
      accepted = false if flags & PREVIOUS_TAIL != 0
      return accepted ? DEAD_MATCH_KEY : DEAD_KEY if byte < 0
      next_flags = accepted ? MATCH_BEHIND : 0
      next_flags |= byte_flags(byte.to_u8)
      next_flags |= PREVIOUS_TAIL if byte & 0xC0 == 0x80
      next_flags |= FINAL_LF_EDGE if flags & TEXT_EDGE != 0 && byte == Look::LINE_FEED
      builder.begin_targets(next_flags & @relevant_flags)
      builder.each_output do |node|
        reverse_nfa.each_byte_target(node, byte.to_u8) { |target| builder.add_target(target) }
      end
      targets = builder.sorted_targets
      return accepted ? DEAD_MATCH_KEY : DEAD_KEY if targets.size == 1
      targets
    end

    # As `forward_look`, read backward: the position's later bytes are in
    # *flags* and its earlier byte is *byte* (-1 at the start of the text).
    private def reverse_look(kind : Program::LookKind, flags : Int32, byte : Int32) : Bool?
      at_start = byte < 0
      at_end = flags & TEXT_EDGE != 0
      later_lf = flags & PREVIOUS_LF != 0
      case kind
      in .start_of_text?
        at_start
      in .start_of_line?
        at_start || (!at_end && byte == Look::LINE_FEED)
      in .end_of_text?
        at_end
      in .end_of_text_or_final_newline?
        at_end || flags & FINAL_LF_EDGE != 0
      in .end_of_line?
        at_end || later_lf
      in .not_before_line_feed?
        at_end || !later_lf
      in .search_start?
        nil
      in .word_boundary?, .not_word_boundary?, .word_start?, .word_end?
        return nil if flags & PREVIOUS_WIDE != 0 || byte >= 0x80
        word_look(kind, word_byte?(byte), flags & PREVIOUS_WORD != 0)
      in .word_boundary_ascii?, .not_word_boundary_ascii?, .word_start_ascii?, .word_end_ascii?
        word_look(kind, word_byte?(byte), flags & PREVIOUS_WORD != 0)
      end
    end

    # The keys of the two dead states.
    DEAD_KEY       = [0]
    DEAD_MATCH_KEY = [MATCH_BEHIND]

    # :nodoc:
    # The key of a start state with *flags*: no NFA states yet (forward), or
    # the match state (reverse).
    def start_key(flags : Int32) : Array(Int32)
      if reverse_nfa = @reverse_nfa
        [flags, reverse_nfa.start_node]
      else
        [flags]
      end
    end

    # :nodoc:
    # True when a state with *key* is a forward start state: no threads,
    # and a new one starts at every character.
    def start_like?(key : Array(Int32)) : Bool
      !@reverse && key.size == 1 && key.unsafe_fetch(0) & UNANCHORED != 0
    end
  end
end
