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
      # ranges; `argument` is the first index in `list_of_transitions`,
      # `alternate` the count) and goes to that transition's target.
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

    def initialize(@list_of_states : Array(State), @list_of_transitions : Array(Transition), @start_state : Int32,
                   @capture_count : Int32, @list_of_group_names : Array(Ast::GroupName), @options : CompileOptions,
                   @backtracker_allowance : Int64, @source_end : Ast::SourceEnd = Ast::SourceEnd::Closed,
                   @literal_set : LiteralSet? = nil,
                   @list_of_class_blocks : Array(ClassBlock) = [] of ClassBlock)
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
      edges = state_count.to_i64 + @list_of_transitions.size
      return nil if edges > REQUIRED_BYTES_BASE_EDGES + REQUIRED_BYTES_EDGES_PER_BYTE * span_bytes
      list_of_required_bytes
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

    # Returns the target of the transition of Sparse state *state* that
    # holds *byte*, or -1. The ranges are sorted and disjoint, so this is a
    # binary search.
    def sparse_target(state : State, byte : UInt8) : Int32
      low = state.argument
      high = state.argument + state.alternate
      while low < high
        middle = (low + high) >> 1
        transition = @list_of_transitions.unsafe_fetch(middle)
        if transition.high < byte
          low = middle + 1
        elsif transition.low > byte
          high = middle
        else
          return transition.target
        end
      end
      -1
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
            transition = @list_of_transitions[state.argument + offset]
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
