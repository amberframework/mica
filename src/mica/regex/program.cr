module Mica::Regex
  # A compiled pattern: a byte-level Thompson NFA with UTF-8 automata for
  # its classes, as RE2 and Rust regex build it. `Compiler` emits it from
  # `Hir`; `PikeVM` and `BoundedBacktracker` run it.
  #
  # States are numbered from 0. Every class and literal is a path of byte
  # states that consumes one whole UTF-8 sequence, so a thread only ever
  # rests between characters when it reaches an assertion, a split or the
  # match state.
  #
  # The program has no unanchored `(?s:.)*?` prefix (the size preflight
  # counts one, so the emitted count stays below the estimate): the engines
  # start a new thread at each character boundary instead, which also keeps
  # searches from starting inside a multibyte character.
  class Program
    # What a state does.
    enum StateKind : UInt8
      # Consumes one byte in `low..high`, then goes to `next_state`.
      ByteRange
      # Consumes one byte in one of its transitions (sorted, disjoint
      # ranges; `argument` is the first index in its table, `alternate`
      # the count) and goes to that transition's target. `low` names the
      # table: 0 is `list_of_transitions`, whose targets are state
      # numbers; n is shared table n - 1 (`list_of_shared_tables`), whose
      # targets are relative to the state (`SHARED_EXIT` is `next_state`).
      # Read transitions through `transition_at` and `sparse_target`,
      # which resolve both.
      Sparse
      # Goes to `next_state` first, then to `alternate` (leftmost-first
      # priority).
      Split
      # Records the position in capture slot `argument`, then goes on.
      Save
      # Goes on only when the assertion `argument` (a `LookKind`) holds.
      Look
      # The pattern has matched.
      Match
      # Never matches (an empty class).
      Fail
    end

    # The assertions a `Look` state checks. The word assertions come in a
    # Unicode form (PCRE2's UCP `\w`, letters, numbers, `Mn` and `Pc` plus
    # underscore) and an ASCII form (`(?aW)`).
    enum LookKind
      StartOfText
      StartOfLine
      EndOfText
      EndOfTextOrFinalNewline
      EndOfLine
      WordBoundary
      NotWordBoundary
      WordStart
      WordEnd
      WordBoundaryAscii
      NotWordBoundaryAscii
      WordStartAscii
      WordEndAscii
      SearchStart
      # The next byte is not a line feed: the second half of `\R`'s lone
      # `\r` branch, which makes `\r\n` atomic as PCRE2 matches it.
      NotBeforeLineFeed
    end

    # One state. Field use depends on `kind` (see `StateKind`).
    record State, kind : StateKind, low : UInt8, high : UInt8, next_state : Int32, alternate : Int32,
      argument : Int32

    # One range of a `Sparse` state.
    record Transition, low : UInt8, high : UInt8, target : Int32

    # The states one class compiled to: `first_state` up to (not including)
    # `end_state`, only byte states, entered at `entry` and left to `exit`
    # (see `ReverseNFA`).
    record ClassBlock, first_state : Int32, end_state : Int32, entry : Int32, exit : Int32

    # A copy of a large class's memoized automaton (`ClassMemo::Block`) that
    # the program reads in place rather than holding its states: states
    # `first_state` up to `first_state + list_of_template_states.size` are
    # the template's, its `Sparse` states reading shared table `table_id`
    # and its exit leading to `exit` (see `state_at`).
    record ClassCopy, first_state : Int32, list_of_template_states : Array(State), table_id : UInt8, exit : Int32
    # The ranges of every `Sparse` state.
    getter list_of_transitions : Array(Transition)
    # The state every search starts from.
    getter start_state : Int32
    # Capturing groups (group 0, the whole match, not included).
    getter capture_count : Int32
    # Named groups in pattern order.
    getter list_of_group_names : Array(Ast::GroupName)
    # The options the pattern was compiled with.
    getter options : CompileOptions
    # The bytes a `BoundedBacktracker` may take: `CompileLimits#max_pike_bytes`
    # less the charge of the Pike VM workspace a search holds beside it
    # (`PikeVM.workspace_charge`, capture layout when the program has
    # groups). The two together stay within `max_pike_bytes`.
    getter backtracker_allowance : Int64
    # How the source text ends (see `Ast::SourceEnd`), for `Expression#to_s`.
    getter source_end : Ast::SourceEnd
    # The literals every match starts with (see `LiteralSet`), or nil.
    getter literal_set : LiteralSet?
    # The classes of more than one state, in emission order.
    getter list_of_class_blocks : Array(ClassBlock)
    # The transition tables of the large classes the program uses, shared
    # with every program that uses them (`ClassMemo::Block`), so a copy
    # of `\w` emits its states but none of its transitions. Never changed.
    getter list_of_shared_tables : Array(Array(Transition))

    # The target in a shared table that stands for the state's
    # `next_state` (the state after the class).
    SHARED_EXIT = Int32::MIN

    # The states the program holds: numbers 0 up to `held_state_count`.
    # The class copies (`list_of_class_copies`) number after them.
    @list_of_held_states : Array(State)
    # The copies of large classes the program reads in place, in state
    # order, numbered from `held_state_count` on.
    getter list_of_class_copies : Array(ClassCopy)
    @state_count : Int32

    def initialize(@list_of_held_states : Array(State), @list_of_transitions : Array(Transition), @start_state : Int32,
                   @capture_count : Int32, @list_of_group_names : Array(Ast::GroupName), @options : CompileOptions,
                   @backtracker_allowance : Int64, @source_end : Ast::SourceEnd = Ast::SourceEnd::Closed,
                   @literal_set : LiteralSet? = nil,
                   @list_of_class_blocks : Array(ClassBlock) = [] of ClassBlock,
                   @list_of_shared_tables : Array(Array(Transition)) = [] of Array(Transition),
                   @list_of_class_copies : Array(ClassCopy) = NO_CLASS_COPIES)
      @state_count = @list_of_held_states.size
      if last_copy = @list_of_class_copies.last?
        @state_count = last_copy.first_state + last_copy.list_of_template_states.size
      end
    end

    # Every state, the class copies written out, built on the first read
    # of a copy's state (see `state_at`) and published through the atomic,
    # so a thread that sees it sees it whole.
    @expanded_states = Atomic(Array(State)?).new(nil)
    # One lock for every program's expansion (it runs once per program
    # with copies, so a lock per program would cost each compile an
    # allocation for nothing).
    @@expansion_mutex = Mutex.new

    # The class copies of a program that has none (shared, never changed).
    NO_CLASS_COPIES = [] of ClassCopy

    # The number of states the program holds (`list_of_class_copies` adds
    # the rest).
    def held_state_count : Int32
      @list_of_held_states.size
    end

    # Returns state *index*, which must be below `state_count`. A class
    # copy's state comes from the program's states written out in full
    # (`expanded_states`): compiling a program costs no more than its held
    # states and copy records, and the copies are written out once, by the
    # first search that reads one, which then reads them as fast as held
    # states. The bytes they take were charged to the compilation's ledger
    # as the preflight bound, so this stays within `max_compile_bytes`.
    @[AlwaysInline]
    def state_at(index : Int32) : State
      held = @list_of_held_states
      return held.unsafe_fetch(index) if index < held.size
      (@expanded_states.get(:acquire) || expand_states).unsafe_fetch(index)
    end

    # Writes the class copies out after the held states (see `state_at`).
    private def expand_states : Array(State)
      @@expansion_mutex.synchronize do
        if built = @expanded_states.get(:acquire)
          return built
        end
        # One memory copy per block, relocated in place.
        list = Array(State).new(state_count)
        list.concat(@list_of_held_states)
        @list_of_class_copies.each do |copy|
          list.concat(copy.list_of_template_states)
          states = list.to_unsafe + copy.first_state
          copy.list_of_template_states.size.times do |offset|
            states[offset] = state_of_copy(copy, offset)
          end
        end
        @expanded_states.set(list, :release)
        list
      end
    end

    # Every state with its number, in order.
    def each_state(& : State, Int32 ->) : Nil
      @list_of_held_states.each_with_index { |state, index| yield state, index }
      @list_of_class_copies.each do |copy|
        copy.list_of_template_states.size.times do |offset|
          index = copy.first_state + offset
          yield state_of_copy(copy, offset), index
        end
      end
    end

    # Every state, indexed by number (built on each call: for specs and
    # diagnostics; the engines read `state_at`).
    def list_of_states : Array(State)
      list = Array(State).new(state_count)
      each_state { |state, _| list << state }
      list
    end

    @[AlwaysInline]
    private def state_of_copy(copy : ClassCopy, offset : Int32) : State
      template = copy.list_of_template_states.unsafe_fetch(offset)
      return template.copy_with(low: copy.table_id, next_state: copy.exit) if template.kind.sparse?
      target = template.next_state
      return template if target == ClassMemo::NONE
      template.copy_with(next_state: target == ClassMemo::EXIT ? copy.exit : copy.first_state + target)
    end

    # Published through an atomic, so a thread that sees the plan sees it
    # fully built.
    @plan = Atomic(SearchPlan?).new(nil)
    @plan_mutex = Mutex.new
    # Single searches run on the backtracker so far (see `FirstSearch`),
    # or `FIRST_SEARCHES_ENDED`.
    @first_searches = Atomic(Int32).new(0)

    # Set by `end_first_searches`: past `FirstSearch::SEARCHES`, so one load
    # answers `first_searches_left?`, and apart from any count.
    private FIRST_SEARCHES_ENDED = Int32::MAX // 2

    # :nodoc:
    # True while this program may still run first searches (one relaxed
    # load, so a program past them pays nothing more per search).
    def first_searches_left? : Bool
      @first_searches.get(:relaxed) < FirstSearch::SEARCHES
    end

    # :nodoc:
    # Counts one more first search (see `FirstSearch`) and returns true
    # while the program has had fewer than `FirstSearch::SEARCHES`, so
    # exactly that many return true, however threads race.
    def count_first_search : Bool
      return false if @first_searches.get(:relaxed) >= FirstSearch::SEARCHES
      @first_searches.add(1, :relaxed) < FirstSearch::SEARCHES
    end

    # :nodoc:
    # The first searches this program ran (at most `FirstSearch::SEARCHES`;
    # none after `end_first_searches`).
    def first_search_count : Int32
      count = @first_searches.get(:relaxed)
      count >= FIRST_SEARCHES_ENDED ? 0 : Math.min(count, FirstSearch::SEARCHES)
    end

    # :nodoc:
    # True once `end_first_searches` ran.
    def first_searches_ended? : Bool
      @first_searches.get(:relaxed) >= FIRST_SEARCHES_ENDED
    end

    # :nodoc:
    # Ends this program's first searches without counting any, so its next
    # single searches take the plan's engines and a plan built after this
    # finds every match start with its reverse DFA (for the specs of those
    # engines).
    def end_first_searches : Nil
      @first_searches.set(FIRST_SEARCHES_ENDED, :relaxed)
    end

    # :nodoc:
    # The engines and caches of this program's searches (built on the first
    # search, see `SearchPlan`).
    @[AlwaysInline]
    def plan : SearchPlan
      @plan.get(:acquire) || build_plan
    end

    private def build_plan : SearchPlan
      @plan_mutex.synchronize do
        built = @plan.get
        return built if built
        built = SearchPlan.new(self)
        @plan.set(built)
        built
      end
    end

    # The ASCII bytes every match contains (see
    # `StartFilter.required_bytes`), found on first use.
    @required_bytes = Atomic(Array(UInt8)?).new(nil)

    # :nodoc:
    # The ASCII bytes every match contains, rarest first (see
    # `StartFilter.required_bytes`; found once, on first use).
    def list_of_required_bytes : Array(UInt8)
      if found = @required_bytes.get(:acquire)
        return found
      end
      found = StartFilter.required_bytes(self)
      # Threads racing here find the same bytes; the first to publish wins.
      @required_bytes.compare_and_set(nil, found)
      @required_bytes.get(:acquire) || found
    end

    # :nodoc:
    # The required bytes when a first search (see `FirstSearch`) of
    # *span_bytes* bytes should check them, or nil: once they are found,
    # always; before that, only when finding them (one pass over the
    # states and sparse transitions) costs no more than about a few passes
    # over the span, so a short first search of a large program does not
    # pay for the analysis.
    def required_bytes_for_first_search(span_bytes : Int32) : Array(UInt8)?
      if found = @required_bytes.get(:acquire)
        return found
      end
      allowance = REQUIRED_BYTES_BASE_EDGES + REQUIRED_BYTES_EDGES_PER_BYTE * span_bytes
      return nil unless edges_within?(allowance)
      list_of_required_bytes
    end

    # True when the states plus the sparse transitions they read (in the
    # program's own list and in shared tables) number at most
    # *allowance*. Stops counting once past it.
    private def edges_within?(allowance : Int64) : Bool
      edges = state_count.to_i64 + @list_of_transitions.size
      return false if edges > allowance
      return true if @list_of_shared_tables.empty?
      each_state do |state, _|
        next unless state.kind.sparse? && state.low != 0
        edges += state.alternate
        return false if edges > allowance
      end
      true
    end

    # See `required_bytes_for_first_search`.
    REQUIRED_BYTES_BASE_EDGES     = 256_i64
    REQUIRED_BYTES_EDGES_PER_BYTE =   4_i64

    # :nodoc:
    # True once a search has built the plan (for specs).
    def plan_built? : Bool
      !@plan.get.nil?
    end

    # Returns the number of states (m in the bounds).
    def state_count : Int32
      @state_count
    end

    # Returns the capture slots of a full match (c in the bounds): two per
    # group, group 0 included.
    def slot_count : Int32
      (@capture_count + 1) * 2
    end

    # Returns the bytes of a span-layout Pike VM workspace (no captures):
    # two sparse sets (16·m), the one-word closure stack (8·m) and two
    # `Int32` start tables (8·m), 32·m in all.
    def self.span_workspace_bytes(state_count : Int64) : Int64
      Preflight.multiply(32_i64, state_count)
    end

    # Returns the bytes of a Pike VM workspace for *slot_count* slots: two
    # slot tables (16·m·c), two sparse sets (16·m), the epsilon-closure
    # stack (16·m) and one scratch slot vector (8·c), all in one buffer.
    def self.pike_workspace_bytes(state_count : Int64, slot_count : Int64) : Int64
      Preflight.add(Preflight.add(Preflight.multiply(Preflight.multiply(16_i64, state_count), slot_count),
        Preflight.multiply(32_i64, state_count)), Preflight.multiply(8_i64, slot_count))
    end

    # Returns the target of the transition of Sparse state *state* (number
    # *state_index*) that holds *byte*, or -1. The ranges are sorted and
    # disjoint, so this is a binary search.
    def sparse_target(state_index : Int32, state : State, byte : UInt8) : Int32
      table = table_of(state)
      low = state.argument
      high = state.argument + state.alternate
      while low < high
        middle = (low + high) >> 1
        transition = table.unsafe_fetch(middle)
        if transition.high < byte
          low = middle + 1
        elsif transition.low > byte
          high = middle
        else
          return resolve(state_index, state, transition.target)
        end
      end
      -1
    end

    # Returns transition *offset* of Sparse state *state* (number
    # *state_index*), its target a state number.
    def transition_at(state_index : Int32, state : State, offset : Int32) : Transition
      unless 0 <= offset < state.alternate
        raise IndexError.new("Transition #{offset} of a state of #{state.alternate}")
      end
      transition = table_of(state)[state.argument + offset]
      return transition if state.low == 0
      transition.copy_with(target: resolve(state_index, state, transition.target))
    end

    # Yields the byte range of every transition the program's states can
    # take, in its own list and in each shared table.
    def each_transition_range(& : UInt8, UInt8 ->) : Nil
      @list_of_transitions.each { |transition| yield transition.low, transition.high }
      @list_of_shared_tables.each do |table|
        table.each { |transition| yield transition.low, transition.high }
      end
    end

    @[AlwaysInline]
    private def table_of(state : State) : Array(Transition)
      state.low == 0 ? @list_of_transitions : @list_of_shared_tables[state.low.to_i32 - 1]
    end

    @[AlwaysInline]
    private def resolve(state_index : Int32, state : State, target : Int32) : Int32
      return target if state.low == 0
      target == SHARED_EXIT ? state.next_state : state_index + target
    end

    # Writes the program one state per line, for specs and diagnostics.
    def to_s(io : IO) : Nil
      each_state do |state, index|
        io << index << ": " << state.kind
        case state.kind
        when .byte_range?
          io << " " << state.low.to_s(16) << '-' << state.high.to_s(16) << " -> " << state.next_state
        when .sparse?
          state.alternate.times do |offset|
            transition = transition_at(index, state, offset)
            io << ' ' << transition.low.to_s(16) << '-' << transition.high.to_s(16) << "->" << transition.target
          end
        when .split?
          io << ' ' << state.next_state << ", " << state.alternate
        when .save?
          io << " slot " << state.argument << " -> " << state.next_state
        when .look?
          io << ' ' << LookKind.new(state.argument) << " -> " << state.next_state
        end
        io << '\n'
      end
    end
  end
end
