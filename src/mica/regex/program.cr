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

    # *copies* copies of one class, one after another from *first_state*,
    # held as the class's block (a large class's `ClassMemo::Block`, shared
    # with every program, or an ASCII class's one byte state) rather than
    # as states: `x{n}` (`\p{L}{256}` is 256 copies of about 300 states).
    # Copy k starts at
    # `first_state + k * block size`; copy 0 leads to *exit*, and each
    # later copy to the entry of the copy before it, as the compiler emits
    # a counted item from the last copy back. Its `Sparse` states read
    # shared table *table_id*. A copy's states are exactly the ones
    # `Compiler#instantiate_shared` would have emitted (see `state_at`).
    record ClassRun, first_state : Int32, copies : Int32, list_of_block_states : Array(State), table_id : UInt8,
      entry : Int32, exit : Int32 do
      # The states the run stands for.
      def size : Int32
        copies * list_of_block_states.size
      end

      # The number after the run's last state.
      def end_state : Int32
        first_state + size
      end

      # The entry of the copy a match reads first (the last emitted).
      def last_entry : Int32
        first_state + (copies - 1) * list_of_block_states.size + entry
      end

      # State *index*, which must lie in the run.
      def state_at(index : Int32) : State
        block_size = list_of_block_states.size
        relative = index - first_state
        copy = relative // block_size
        copy_first = first_state + copy * block_size
        state = list_of_block_states.unsafe_fetch(relative - copy * block_size)
        exit_target = copy == 0 ? exit : copy_first - block_size + entry
        return state.copy_with(low: table_id, next_state: exit_target) if state.kind.sparse?
        target = state.next_state
        target = if target == ClassMemo::EXIT
                   exit_target
                 elsif target != ClassMemo::NONE
                   target + copy_first
                 else
                   target
                 end
        state.copy_with(next_state: target)
      end

      # The class blocks of the run's copies, in emission order.
      def each_class_block(& : ClassBlock ->) : Nil
        block_size = list_of_block_states.size
        # A class of one state is not recorded (see `list_of_class_blocks`).
        return if block_size < 2
        copies.times do |copy|
          copy_first = first_state + copy * block_size
          exit_target = copy == 0 ? exit : copy_first - block_size + entry
          yield ClassBlock.new(copy_first, copy_first + block_size, copy_first + entry, exit_target)
        end
      end
    end

    # The states not in a `ClassRun`, in order.
    @list_of_physical_states : Array(State)
    # Every state, once built (see `list_of_states`).
    @materialized : Array(State)?
    @materialized_blocks : Array(ClassBlock)?
    # The class blocks the compiler recorded outside runs.
    @list_of_recorded_blocks : Array(ClassBlock)
    # The program's runs, in state order.
    getter list_of_runs : Array(ClassRun)
    @state_count : Int32
    # Guards `materialize` (made only for a program with runs).
    @materialize_mutex : Mutex? = nil
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
    # The transition tables of the large classes the program uses, shared
    # with every program that uses them (`ClassMemo::Block`), so a copy
    # of `\w` emits its states but none of its transitions. Never changed.
    getter list_of_shared_tables : Array(Array(Transition))

    # The target in a shared table that stands for the state's
    # `next_state` (the state after the class).
    SHARED_EXIT = Int32::MIN

    # *list_of_states* holds every state outside *list_of_runs*.
    def initialize(list_of_states : Array(State), @list_of_transitions : Array(Transition), @start_state : Int32,
                   @capture_count : Int32, @list_of_group_names : Array(Ast::GroupName), @options : CompileOptions,
                   @backtracker_allowance : Int64, @source_end : Ast::SourceEnd = Ast::SourceEnd::Closed,
                   @literal_set : LiteralSet? = nil,
                   list_of_class_blocks : Array(ClassBlock) = [] of ClassBlock,
                   @list_of_shared_tables : Array(Array(Transition)) = [] of Array(Transition),
                   @list_of_runs : Array(ClassRun) = [] of ClassRun)
      @list_of_physical_states = list_of_states
      @list_of_recorded_blocks = list_of_class_blocks
      @state_count = list_of_states.size + @list_of_runs.sum(&.size)
      if @list_of_runs.empty?
        @materialized = list_of_states
        @materialized_blocks = list_of_class_blocks
      else
        @materialize_mutex = Mutex.new
      end
    end

    # Every state, indexed by number. A program with runs (`ClassRun`)
    # builds this on first use, which the plan makes (its first
    # searches read states through `state_at` and build nothing).
    @[AlwaysInline]
    def list_of_states : Array(State)
      @materialized || materialize
    end

    # The classes of more than one state, in emission order (built with
    # `list_of_states`).
    def list_of_class_blocks : Array(ClassBlock)
      if blocks = @materialized_blocks
        return blocks
      end
      materialize
      @materialized_blocks || raise Mica::Error.new("internal error: the program's class blocks were not built")
    end

    # State *index*, read without building `list_of_states`.
    @[AlwaysInline]
    def state_at(index : Int32) : State
      if states = @materialized
        states.unsafe_fetch(index)
      else
        run_state_at(index)
      end
    end

    # :nodoc:
    # True while the program's runs have not been built into
    # `list_of_states` (for specs).
    def runs_pending? : Bool
      @materialized.nil?
    end

    private def run_state_at(index : Int32) : State
      offset = 0
      @list_of_runs.each do |run|
        break if index < run.first_state
        return run.state_at(index) if index < run.end_state
        offset += run.size
      end
      @list_of_physical_states[index - offset]
    end

    # Builds every state and class block from the physical states and the
    # runs, once; threads racing here wait for the first.
    private def materialize : Array(State)
      mutex = @materialize_mutex || raise Mica::Error.new("internal error: a program without runs has every state")
      mutex.synchronize do
        if built = @materialized
          return built
        end
        states = Array(State).new(@state_count)
        blocks = Array(ClassBlock).new(@list_of_recorded_blocks.size + @list_of_runs.sum(&.copies))
        physical = 0
        recorded = 0
        @list_of_runs.each do |run|
          while states.size < run.first_state
            states << @list_of_physical_states[physical]
            physical += 1
          end
          (run.first_state...run.end_state).each { |index| states << run.state_at(index) }
          while recorded < @list_of_recorded_blocks.size && @list_of_recorded_blocks[recorded].first_state < run.first_state
            blocks << @list_of_recorded_blocks[recorded]
            recorded += 1
          end
          run.each_class_block { |block| blocks << block }
        end
        while physical < @list_of_physical_states.size
          states << @list_of_physical_states[physical]
          physical += 1
        end
        while recorded < @list_of_recorded_blocks.size
          blocks << @list_of_recorded_blocks[recorded]
          recorded += 1
        end
        @materialized_blocks = blocks
        @materialized = states
        states
      end
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
    def plan : SearchPlan
      if built = @plan.get
        return built
      end
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
      # Read through `state_at`, so a program with runs builds its states
      # (as the analysis then does) only when they are within the allowance.
      state_count.times do |index|
        state = state_at(index)
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
      list_of_states.each_with_index do |state, index|
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
