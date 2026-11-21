module Mica::Regex::Static
  # One direction's DFA read over UTF-8 decoder states (see
  # `BuildTheDecoderProduct`): `list_of_transitions` holds `symbols`
  # columns per state, `list_of_columns` each byte's column, and the
  # states are (DFA state, decoder state) pairs numbered from 2 (0 and 1
  # are the dead states, as in the DFA). `list_of_start_ids` follows the
  # DFA's start list, and `list_of_dfa_ids` and `list_of_decoder_states`
  # tell each state's pair.
  record DecoderProduct,
    list_of_transitions : Array(Int32),
    state_count : Int32,
    symbols : Int32,
    list_of_columns : Array(Int32),
    edge_symbol : Int32,
    word_offset : Int32,
    list_of_start_ids : Array(Int32),
    list_of_dfa_ids : Array(Int32),
    list_of_decoder_states : Array(Int32)

  # When a direction's DFA has been explored and its table is too wide for
  # the static limits, then it is rebuilt over UTF-8 decoder states, so its
  # rows narrow.
  #
  # A search reads valid UTF-8 from a character boundary, so each byte it
  # reads comes at a known decoder state: going forward, between
  # characters (an ASCII byte or a lead byte) or inside one with one, two
  # or three continuation bytes left; going backward, between characters
  # (an ASCII byte or the last byte of a character) or inside one (a
  # continuation byte or the lead byte). A DFA state reached at two
  # decoder states becomes two states, one per decoder state, and each
  # reads only the bytes valid UTF-8 has there. Byte classes that no state
  # reads at the same decoder state then share a column: the byte classes
  # (split where the byte's UTF-8 role changes) are colored so the classes
  # one decoder state reads are told apart, non-ASCII classes first, so
  # their Unicode-word columns (`word_offset` past them) stay few.
  #
  # The search loop is unchanged: one class map, one shift. A haystack
  # that is not valid UTF-8 is rejected before a search reads it.
  class BuildTheDecoderProduct
    # The decoder state between characters (both directions).
    BETWEEN = 0
    # Going backward, inside a character.
    INSIDE_BACKWARD = 9

    # The product state of each (DFA state, decoder state) pair met so far.
    @ids = {} of {Int32, Int32} => Int32
    @list_of_dfa_ids = [LazyDFA::DEAD, LazyDFA::DEAD_MATCH]
    @list_of_decoder_states = [BETWEEN, BETWEEN]
    # The product states whose rows are still to be written, in order.
    @list_of_pending = [] of Int32

    def initialize(@list_of_transitions : Array(Int32), @symbols : Int32, @list_of_start_ids : Array(Int32),
                   @byte_classes : ByteClasses, @dfa : LazyDFA)
    end

    def perform : DecoderProduct
      list_of_kinds = Array(Int32).new(256) { |byte| BuildTheDecoderProduct.utf8_role(byte) }
      # The byte classes split by UTF-8 role: (class, role) => index.
      split_index = {} of {Int32, Int32} => Int32
      list_of_split_by_byte = Array(Int32).new(256) do |byte|
        key = {@byte_classes.class_of(byte.to_u8), list_of_kinds[byte]}
        split_index[key] ||= split_index.size
      end
      list_of_splits = split_index.keys
      list_of_columns_by_split = color(list_of_splits)
      column_count = (list_of_columns_by_split.max? || 0) + 1
      non_ascii_columns = list_of_splits.each_index.select { |index| list_of_splits[index][1] > 0 }
        .max_of? { |index| list_of_columns_by_split[index] + 1 } || 0
      unicode_words = @dfa.unicode_words?
      edge_symbol = column_count
      word_offset = column_count + 2
      symbols = unicode_words ? word_offset + non_ascii_columns : word_offset
      list_of_start_ids = @list_of_start_ids.map { |dfa_id| id_of(dfa_id, BETWEEN) }
      list_of_transitions = [] of Int32
      cursor = 0
      while cursor < @list_of_pending.size
        id = @list_of_pending[cursor]
        cursor += 1
        required = (id + 1) * symbols
        list_of_transitions.concat(Array(Int32).new(required - list_of_transitions.size, 0)) if list_of_transitions.size < required
        dfa_id = @list_of_dfa_ids[id]
        decoder_state = @list_of_decoder_states[id]
        row = dfa_id * @symbols
        list_of_splits.each_with_index do |(class_index, kind), split|
          following = next_decoder_state(decoder_state, kind)
          next if following < 0
          column = list_of_columns_by_split[split]
          list_of_transitions[id * symbols + column] = id_of(@list_of_transitions[row + class_index], following)
          if unicode_words && kind > 0
            list_of_transitions[id * symbols + word_offset + column] =
              id_of(@list_of_transitions[row + @dfa.word_symbol(class_index)], following)
          end
        end
        if decoder_state == BETWEEN
          edge = @byte_classes.class_count
          list_of_transitions[id * symbols + edge_symbol] = id_of(@list_of_transitions[row + edge], BETWEEN)
          list_of_transitions[id * symbols + edge_symbol + 1] = id_of(@list_of_transitions[row + edge + 1], BETWEEN)
        end
      end
      state_count = @list_of_dfa_ids.size
      list_of_transitions.concat(Array(Int32).new(state_count * symbols - list_of_transitions.size, 0)) if list_of_transitions.size < state_count * symbols
      list_of_columns = list_of_split_by_byte.map { |split| list_of_columns_by_split[split] }
      DecoderProduct.new(list_of_transitions: list_of_transitions, state_count: state_count, symbols: symbols,
        list_of_columns: list_of_columns, edge_symbol: edge_symbol, word_offset: word_offset,
        list_of_start_ids: list_of_start_ids, list_of_dfa_ids: @list_of_dfa_ids,
        list_of_decoder_states: @list_of_decoder_states)
    end

    # A byte's UTF-8 role: 0 ASCII, 1 a continuation byte, 2 to 4 the lead
    # byte of a character of that many bytes, 5 a byte valid UTF-8 never
    # has.
    def self.utf8_role(byte : Int32) : Int32
      return 0 if byte < 0x80
      return 1 if byte < 0xC0
      return 2 if byte < 0xE0
      return 3 if byte < 0xF0
      return 4 if byte < 0xF8
      5
    end

    # True when a search may read a byte of UTF-8 role *kind* at
    # *decoder_state*.
    def self.readable?(reverse : Bool, decoder_state : Int32, kind : Int32) : Bool
      following_state(reverse, decoder_state, kind) >= 0
    end

    # The decoder state after a byte of UTF-8 role *kind* is read at
    # *decoder_state*, or -1 when valid UTF-8 has no such byte there.
    def self.following_state(reverse : Bool, decoder_state : Int32, kind : Int32) : Int32
      if reverse
        if decoder_state == BETWEEN
          return BETWEEN if kind == 0
          return kind == 1 ? INSIDE_BACKWARD : -1
        end
        return INSIDE_BACKWARD if kind == 1
        2 <= kind <= 4 ? BETWEEN : -1
      else
        if decoder_state == BETWEEN
          return BETWEEN if kind == 0
          return 2 <= kind <= 4 ? kind - 1 : -1
        end
        kind == 1 ? decoder_state - 1 : -1
      end
    end

    # The product state of DFA state *dfa_id* read at *decoder_state*,
    # numbered (and its row queued) when first met; the dead states keep
    # their ids.
    private def id_of(dfa_id : Int32, decoder_state : Int32) : Int32
      return dfa_id if dfa_id <= LazyDFA::DEAD_MATCH
      @ids[{dfa_id, decoder_state}] ||= begin
        @list_of_dfa_ids << dfa_id
        @list_of_decoder_states << decoder_state
        @list_of_pending << @list_of_dfa_ids.size - 1
        @list_of_dfa_ids.size - 1
      end
    end

    private def next_decoder_state(decoder_state : Int32, kind : Int32) : Int32
      BuildTheDecoderProduct.following_state(@dfa.reverse?, decoder_state, kind)
    end

    # A column for each split class, so the classes any one decoder state
    # reads have distinct columns: greedy, non-ASCII classes first.
    private def color(list_of_splits : Array({Int32, Int32})) : Array(Int32)
      list_of_decoder_states = @dfa.reverse? ? [BETWEEN, INSIDE_BACKWARD] : [BETWEEN, 1, 2, 3]
      list_of_readers = list_of_splits.map do |(_, kind)|
        list_of_decoder_states.select { |decoder_state| next_decoder_state(decoder_state, kind) >= 0 }
      end
      list_of_columns = Array(Int32).new(list_of_splits.size, -1)
      order = list_of_splits.each_index.to_a.sort_by { |index| {list_of_splits[index][1] > 0 ? 0 : 1, index} }
      order.each do |index|
        taken = Set(Int32).new
        list_of_splits.each_index do |other|
          next if list_of_columns[other] < 0
          next if (list_of_readers[index] & list_of_readers[other]).empty?
          taken << list_of_columns[other]
        end
        column = 0
        while taken.includes?(column)
          column += 1
        end
        list_of_columns[index] = column
      end
      list_of_columns
    end
  end
end
