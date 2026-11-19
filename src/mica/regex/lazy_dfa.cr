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
  # `\Z`) so is a line feed that ends the haystack. `\G` is left to the
  # Pike VM.
  #
  # **Unicode word assertions** need a whole character on each side. When a
  # program has one, every byte of a non-ASCII character is read as one of
  # two symbols, its class or its class marked as part of a word character
  # (`word_symbol`), so the transition that reads the next character knows
  # whether it is a word character, and the state after it records whether
  # the previous one was. The search loops decode each non-ASCII character
  # once to choose the symbol (`wide_char`). The DFA never gives up on them.
  # ASCII-mode word assertions (`(?aW)`) in the same pattern read their own
  # look-behind bit, since a non-ASCII letter is a word character for one
  # kind and not for the other.
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
    TEXT_EDGE             =  0x01 # forward: at the start of the text; reverse: at its end
    PREVIOUS_LF           =  0x02 # the byte read last was a line feed
    PREVIOUS_WORD         =  0x04 # the byte read last was an ASCII word character (ASCII assertions)
    PREVIOUS_WIDE         =  0x08 # the byte read last was not ASCII
    PREVIOUS_TAIL         =  0x10 # reverse: the byte read last was a continuation byte
    FINAL_LF_EDGE         =  0x20 # reverse: just before a line feed that ends the text
    UNANCHORED            =  0x40 # forward: start a thread at every character
    START_PENDING         =  0x80 # forward: start a thread here (anchored start)
    PREVIOUS_UNICODE_WORD = 0x100 # the character read last was a Unicode word character (Unicode assertions)
    MATCH_BEHIND          = 0x200 # the closure before the last byte reached a match
    # A start state never carries `MATCH_BEHIND`, so its flags index a
    # table of this many entries (see `DFACache#start_state`).
    START_FLAG_COUNT = MATCH_BEHIND

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
    # True for a reverse DFA that reads classes through `ReversedClass`.
    getter? with_reversed_classes : Bool
    # Entries per state in the transition table: one per class, then the
    # end of input, then (forward) a line feed that ends the haystack.
    getter stride : Int32
    @reverse_nfa : ReverseNFA?
    @relevant_flags : Int32
    @unicode_words : Bool
    @final_lf : Bool
    # The first word symbol (see `word_symbol`); every symbol below it is a
    # plain class or an edge symbol.
    @word_offset : Int32

    # A reverse DFA *with_reversed_classes* reads each class backward
    # through its `ReversedClass` (see `SearchPlan#widen_reverse`).
    def initialize(@program : Program, @byte_classes : ByteClasses, @reverse : Bool,
                   @with_reversed_classes : Bool = false)
      looks = LazyDFA.looks_used(@program)
      @unicode_words = looks.any? { |kind| LazyDFA.unicode_word?(kind) }
      class_count = @byte_classes.class_count
      @word_offset = class_count + 2
      # The classes, the two edge symbols, and (with Unicode word
      # assertions) a word symbol per class, rounded up to a multiple of 4,
      # so a row offset leaves two low bits free for flags (see `find_end`).
      symbols = @unicode_words ? @word_offset + class_count : @word_offset
      @stride = (symbols + 3) & ~3
      @reverse_nfa = @reverse ? ReverseNFA.new(@program, @with_reversed_classes) : nil
      line_start = looks.includes?(Program::LookKind::StartOfLine)
      text_start = looks.includes?(Program::LookKind::StartOfText)
      text_end = looks.includes?(Program::LookKind::EndOfText)
      final_newline = looks.includes?(Program::LookKind::EndOfTextOrFinalNewline)
      line_end = looks.includes?(Program::LookKind::EndOfLine) ||
                 looks.includes?(Program::LookKind::NotBeforeLineFeed)
      ascii_words = looks.any? { |kind| LazyDFA.ascii_word?(kind) }
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
      # ASCII and Unicode word assertions disagree on a non-ASCII word
      # character, so each kind keeps its own look-behind bit.
      relevant |= PREVIOUS_WORD if ascii_words
      relevant |= PREVIOUS_UNICODE_WORD if @unicode_words
      @relevant_flags = relevant
    end

    # The NFA states a DFA state can hold: the program's, or (reverse) the
    # `ReverseNFA`'s nodes.
    def node_count : Int32
      if reverse_nfa = @reverse_nfa
        reverse_nfa.node_count
      else
        @program.state_count
      end
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

    # The symbol for a byte of class *class_index* that is part of a
    # non-ASCII word character (with Unicode word assertions only).
    def word_symbol(class_index : Int32) : Int32
      @word_offset + class_index
    end

    # :nodoc:
    # Returns the start and end of the character holding byte *at* of the
    # (valid UTF-8) haystack, and whether it is a word character (PCRE2's
    # UCP `\w`).
    def self.wide_char(haystack : Bytes, at : Int32) : {Int32, Int32, Bool}
      start = at
      while start > 0 && at - start < 3 && haystack.unsafe_fetch(start) & 0xC0 == 0x80
        start -= 1
      end
      lead = haystack.unsafe_fetch(start)
      length = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4)
      {start, start + length, Look.word_after?(haystack, start, false)}
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
    #
    # With *stop*, a search still undecided when it reaches byte *stop*
    # returns `GAVE_UP` there (see `Searcher#find_at_starts`).
    def find_end(cache : DFACache, haystack : Bytes, start : Int32, anchored : Bool, earliest : Bool,
                 scan : PrefilterScan?, meter : SearchMeter, stop : Int32 = Int32::MAX) : Int32
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
      words = @unicode_words
      # The character the last non-ASCII byte belonged to (see `wide_char`).
      wide_start = wide_end = 0
      wide_word = false
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
        return GAVE_UP if at >= stop
        chunk_end = Math.min(Math.min(limit, stop), at + 4096)
        chunk_start = at
        table = cache.transition_table.to_unsafe
        while at < chunk_end
          byte = bytes[at]
          symbol = class_table[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(haystack, at) unless wide_start <= at < wide_end
            symbol &+= @word_offset if wide_word
          end
          entry = table[(current & ROW_MASK) &+ symbol]
          if entry < 0
            id = cache.transition(self, current // stride, symbol, meter)
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
      words = @unicode_words
      wide_start = wide_end = 0
      wide_word = false
      dead = false
      while at > lower_bound && !dead
        chunk_end = Math.max(lower_bound, at - 4096)
        chunk_start = at
        table = cache.transition_table.to_unsafe
        while at > chunk_end
          byte = bytes[at - 1]
          symbol = class_table[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(haystack, at - 1) unless wide_start <= at - 1 < wide_end
            symbol &+= @word_offset if wide_word
          end
          entry = table[(current & ROW_MASK) &+ symbol]
          if entry < 0
            id = cache.transition(self, current // stride, symbol, meter)
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
      symbol = lower_bound > 0 ? symbol_at(haystack, lower_bound - 1) : edge_symbol
      state = step(cache, current // stride, symbol, meter)
      return GAVE_UP if state < 0
      last_start = lower_bound if cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0
      last_start
    end

    # Finds the leftmost-first match at or after *start* by running the DFA
    # anchored at each character start in turn, for a program whose
    # matches are short (*short_match*). Returns the match's start and end,
    # or `NO_MATCH` (or `GAVE_UP`) as the start.
    #
    # The anchored DFA holds one thread per pattern position at most, so it
    # builds few states where the unanchored one, holding a thread for
    # every start still alive, thrashes (`[a-q][^u-z]{13}x`). Each start
    # reads at most `ShortMatch#longest` + 1 bytes before its DFA dies, and
    # that is below the program's state count, so a search costs
    # O(m·(n + 1)), the Pike VM's bound, and far less when most starts die
    # within a few bytes. When every match ends in one of a few bytes, the
    # starts more than `longest` bytes before the next of them (found with
    # `memchr`, each byte read once) are skipped.
    def find_from_each_start(cache : DFACache, haystack : Bytes, start : Int32, earliest : Bool,
                             short_match : ShortMatch, meter : SearchMeter) : {Int32, Int32}
      size = haystack.size
      limit = @final_lf && size > start && haystack.unsafe_fetch(size - 1) == Look::LINE_FEED ? size - 1 : size
      bytes = haystack.to_unsafe
      class_table = @byte_classes.table
      stride = @stride
      words = @unicode_words
      wide_start = wide_end = 0
      wide_word = false
      unpaid = 0
      origin = start
      list_of_final_bytes = short_match.list_of_final_bytes
      longest = short_match.longest
      # The next position of each final byte at or after `origin`, -1 before
      # it is searched, `Int32::MAX` when there is none.
      final_at = StaticArray(Int32, ShortMatch::MAX_FINAL_BYTES).new(-1)
      next_final = -1
      while origin <= size
        if origin < size && bytes[origin] & 0xC0 == 0x80
          origin += 1
          unpaid += 1
          next
        end
        unless list_of_final_bytes.empty?
          if next_final < origin
            next_final = Int32::MAX
            list_of_final_bytes.each_with_index do |final_byte, slot|
              found = final_at[slot]
              found = final_at[slot] = next_byte(haystack, final_byte, origin, meter) if found < origin
              next_final = found if found < next_final
            end
            break if next_final == Int32::MAX
          end
          first_possible = next_final - longest + 1
          if origin < first_possible
            origin = first_possible
            next
          end
        end
        state = cache.start_state(self, start_flags(haystack, origin, true), meter)
        return {GAVE_UP, 0} if state < 0
        current = cache.entry_of(state)
        last_end = NO_MATCH
        at = origin
        table = cache.transition_table.to_unsafe
        dead = false
        while at < limit
          byte = bytes[at]
          symbol = class_table[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(haystack, at) unless wide_start <= at < wide_end
            symbol &+= @word_offset if wide_word
          end
          entry = table[(current & ROW_MASK) &+ symbol]
          if entry < 0
            id = cache.transition(self, current // stride, symbol, meter)
            return {GAVE_UP, 0} if id < 0
            entry = cache.entry_of(id)
            table = cache.transition_table.to_unsafe
          end
          at &+= 1
          current = entry
          if entry & SPECIAL != 0
            marks = cache.list_of_marks.unsafe_fetch(entry // stride)
            if marks & MARK_MATCH != 0
              last_end = at - 1
              break if earliest
            end
            if marks & MARK_DEAD != 0
              dead = true
              break
            end
          end
        end
        unpaid += at - origin + 1
        if unpaid >= 4096
          meter.charge(unpaid, at)
          cache.note_bytes(unpaid)
          unpaid = 0
        end
        unless dead || (earliest && last_end >= 0)
          last_end = finish_at_end(cache, current // stride, at, size, limit, earliest, last_end, meter)
          return {GAVE_UP, 0} if last_end == GAVE_UP
        end
        if last_end >= 0
          meter.charge(unpaid, at)
          cache.note_bytes(unpaid)
          return {origin, last_end}
        end
        origin += 1
      end
      meter.charge(unpaid, size)
      cache.note_bytes(unpaid)
      {NO_MATCH, 0}
    end

    # The first position at or after *from* holding *byte*, or `Int32::MAX`;
    # charges the bytes `memchr` reads, in windows of 4096 bytes.
    private def next_byte(haystack : Bytes, byte : UInt8, from : Int32, meter : SearchMeter) : Int32
      at = from
      size = haystack.size
      while at < size
        stop = Math.min(size, at + 4096)
        if found = haystack[at, stop - at].index(byte)
          meter.charge(found + 1, at)
          return at + found
        end
        meter.charge(stop - at, at)
        at = stop
      end
      Int32::MAX
    end

    # Reads the end of the haystack (the line feed that ends it, then the
    # end of input) from *state* at *at*, after the scan stopped at
    # *limit*, and returns the match end found so far or `GAVE_UP`.
    private def finish_at_end(cache : DFACache, state : Int32, at : Int32, size : Int32, limit : Int32,
                              earliest : Bool, last_end : Int32, meter : SearchMeter) : Int32
      if at == size - 1 && limit == size - 1
        state = step(cache, state, final_lf_symbol, meter)
        return GAVE_UP if state < 0
        at += 1
        marks = cache.list_of_marks.unsafe_fetch(state)
        if marks & MARK_MATCH != 0
          last_end = at - 1
          return last_end if earliest
        end
        return last_end if marks & MARK_DEAD != 0
      end
      return last_end unless at >= size
      state = step(cache, state, edge_symbol, meter)
      return GAVE_UP if state < 0
      cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0 ? size : last_end
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
        flags |= symbol_flags(haystack.unsafe_fetch(at - 1).to_i32, symbol_at(haystack, at - 1))
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
        flags |= symbol_flags(byte.to_i32, symbol_at(haystack, at))
        flags |= PREVIOUS_TAIL if byte & 0xC0 == 0x80
        flags |= FINAL_LF_EDGE if at == size - 1 && byte == Look::LINE_FEED
      end
      flags & @relevant_flags
    end

    # The flags reading *byte* (read as *symbol*) leaves for the next
    # position. An ASCII word byte sets both word bits; a non-ASCII byte
    # sets only `PREVIOUS_UNICODE_WORD`, when its symbol is a word symbol
    # (with Unicode word assertions).
    private def symbol_flags(byte : Int32, symbol : Int32) : Int32
      flags = 0
      flags |= PREVIOUS_LF if byte == Look::LINE_FEED
      if byte < 0x80
        flags |= PREVIOUS_WORD | PREVIOUS_UNICODE_WORD if Look.word_code_point?(byte, true)
      else
        flags |= PREVIOUS_WIDE
        flags |= PREVIOUS_UNICODE_WORD if symbol >= @word_offset
      end
      flags
    end

    # The symbol the search loops read for byte *at* of *haystack*.
    private def symbol_at(haystack : Bytes, at : Int32) : Int32
      byte = haystack.unsafe_fetch(at)
      symbol = @byte_classes.class_of(byte)
      symbol += @word_offset if @unicode_words && byte >= 0x80 && LazyDFA.wide_char(haystack, at)[2]
      symbol
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
      symbol -= @word_offset if symbol >= @word_offset
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
      next_flags |= symbol_flags(byte, symbol)
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
        word_look(kind, flags & PREVIOUS_UNICODE_WORD != 0, symbol_word?(byte, symbol))
      in .word_boundary_ascii?, .not_word_boundary_ascii?, .word_start_ascii?, .word_end_ascii?
        word_look(kind, flags & PREVIOUS_WORD != 0, word_byte?(byte))
      end
    end

    private def word_byte?(byte : Int32) : Bool
      byte >= 0 && byte < 0x80 && Look.word_code_point?(byte, true)
    end

    # True when the character *byte* (read as *symbol*) belongs to is a
    # Unicode word character; false at an edge.
    private def symbol_word?(byte : Int32, symbol : Int32) : Bool
      return word_byte?(byte) if byte < 0x80
      symbol >= @word_offset && symbol != edge_symbol && symbol != final_lf_symbol
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
            verdict = reverse_look(Program::LookKind.new(look), flags, byte, symbol)
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
      next_flags |= symbol_flags(byte, symbol)
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
    private def reverse_look(kind : Program::LookKind, flags : Int32, byte : Int32, symbol : Int32) : Bool?
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
        word_look(kind, symbol_word?(byte, symbol), flags & PREVIOUS_UNICODE_WORD != 0)
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
