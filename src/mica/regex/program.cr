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

    # Every state, indexed by number.
    getter list_of_states : Array(State)
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

    def initialize(@list_of_states : Array(State), @list_of_transitions : Array(Transition), @start_state : Int32,
                   @capture_count : Int32, @list_of_group_names : Array(Ast::GroupName), @options : CompileOptions,
                   @backtracker_allowance : Int64, @source_end : Ast::SourceEnd = Ast::SourceEnd::Closed,
                   @literal_set : LiteralSet? = nil,
                   @list_of_class_blocks : Array(ClassBlock) = [] of ClassBlock,
                   @list_of_shared_tables : Array(Array(Transition)) = [] of Array(Transition))
    end

    # Published through an atomic, so a thread that sees the plan sees it
    # fully built.
    @plan = Atomic(SearchPlan?).new(nil)
    @plan_mutex = Mutex.new

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

    # Returns the number of states (m in the bounds).
    def state_count : Int32
      @list_of_states.size
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
      @list_of_states.each_with_index do |state, index|
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
