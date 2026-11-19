module Mica::Regex
  # Compiles `Hir` into a `Program`, the byte-level Thompson NFA the
  # engines run.
  #
  # The construction runs backward: each node is compiled knowing the state
  # that follows it, so no edge is ever patched except the one back edge of
  # an unbounded loop. Repetitions are expanded here (`{n,m}` as n copies
  # and m − n nested optional copies, `{n,}` as n copies whose last one
  # loops). Classes become UTF-8 automata through `Utf8Sequences`, with
  # shared leading byte ranges, so a class emits at most the byte ranges the
  # size preflight counted for it.
  #
  # Like the front half, the compiler never recurses on the pattern's
  # structure (it keeps an explicit task stack), charges every allocation
  # to the `AllocationLedger` before making it, charges one operation per
  # task and per emitted state to the `Core::WorkMeter`, and checks
  # `CompileLimits#max_program_states` as it emits, and
  # `CompileLimits#max_pike_bytes` when it finishes.
  class Compiler
    # What a task on the work stack does.
    private enum TaskKind
      # Compile `node` so that it continues at `next_state`; push its start.
      Compile
      # A child of a concatenation is compiled; compile the one before it.
      ConcatenationStep
      # Every branch of an alternation is compiled; join them with splits.
      AlternationFinish
      # A capture's child is compiled; add the opening slot save.
      CaptureFinish
      # An unbounded loop's body is compiled; close the loop split.
      LoopFinish
      # Compile the next optional copy of a bounded repetition.
      OptionalStep
      # An optional copy is compiled; put a split in front of it.
      OptionalFinish
      # Compile the next mandatory copy of a repetition.
      MandatoryStep
    end

    # The lists the compiler reuses, whose growth `grow` charges.
    private enum GrowingList
      Tasks
      Values
      TrieStates
      Visited
    end

    private record Task, task_kind : TaskKind, node : Hir::Node, next_state : Int32, count : Int32

    private NONE = -1

    # Compiles *pattern*, whose size preflight bounded its states by
    # *estimate*, under *limits*.
    def self.compile(pattern : Hir::Pattern, estimate : Int64, limits : CompileLimits, ledger : AllocationLedger,
                     meter : Core::WorkMeter) : Program
      new(pattern, estimate, limits, ledger, meter).compile
    end

    @list_of_states : Array(Program::State)
    @list_of_transitions : Array(Program::Transition)
    @list_of_tasks : Array(Task)
    @list_of_values : Array(Int32)
    # The byte trie of the small class being compiled, reused for every
    # class, and the state of each of its nodes.
    @class_trie : ClassTrie
    @list_of_trie_states : Array(Int32)
    # The memoized class block instantiated last, and its set: the copies
    # of a repeated class share one set object, so the memo is asked once
    # per set rather than once per copy.
    @last_memo_set : CodePointSet? = nil
    @last_memo_block : ClassMemo::Block? = nil
    # The alternation merged into one class last, and its union.
    @last_merged_node : Hir::Alternation? = nil
    @last_merged_set : CodePointSet? = nil
    # The small class of the repetition being compiled, and its emitted
    # block once the first copy is built.
    @repeated_small_set : CodePointSet? = nil
    @repeated_small_block : ClassMemo::Block? = nil
    @high_water = StaticArray(Int32, 4).new(0)
    @list_of_visited = [] of Bool
    @list_of_class_blocks = [] of Program::ClassBlock
    # The shared tables the program's large classes use (see
    # `Program#list_of_shared_tables`); a `Sparse` state names one by its
    # position plus one, in a byte, so at most `MAX_SHARED_TABLES`.
    @list_of_shared_tables = [] of Array(Program::Transition)
    # The copies of large classes the program reads in place
    # (`Program::ClassCopy`), numbered from `COPY_BASE` while compiling.
    # (Made on the first copy, so a program without any allocates none.)
    @list_of_class_copies : Array(Program::ClassCopy)? = nil
    @copied_state_count = 0
    # The memoized classes a counted repetition repeats (see `in_place?`).
    @list_of_in_place_sets : Array(CodePointSet)? = nil
    # The states the held list may take before it grows to the bound.
    @held_capacity : Int32
    # The preflight's bound on states, where the held list grows to.
    @state_bound : Int32

    # While compiling, the state numbers of class copies start here, past
    # any held state; `relocate_copies` moves them to follow the held
    # states once their number is known.
    private COPY_BASE = 1 << 30
    # The held states allocated up front: a program bound to more starts
    # with this many and grows to its bound only when it holds more, so
    # one whose states are mostly class copies allocates no more.
    private FIRST_HELD_STATES = 512

    private def initialize(@pattern : Hir::Pattern, @estimate : Int64, @limits : CompileLimits,
                           @ledger : AllocationLedger, @meter : Core::WorkMeter)
      @state_bound = @estimate.clamp(1_i64, @limits.max_program_states).to_i32
      @held_capacity = @state_bound > FIRST_HELD_STATES && repeats_a_large_class? ? FIRST_HELD_STATES : @state_bound
      @ledger.charge_object(instance_sizeof(Compiler), "the compiler", 0)
      @ledger.charge_array(@held_capacity, sizeof(Program::State), "the program states", 0)
      # The states at the preflight's bound: the held list grown to it, or
      # the class copies written out on the first search that reads one
      # (`Program#state_at`).
      if @held_capacity < @state_bound
        @ledger.charge_array(@state_bound, sizeof(Program::State), "the program states written out", 0)
      end
      @list_of_states = Array(Program::State).new(@held_capacity)
      # A program of few states has few transitions; it skips the bound
      # and grows its list as it emits.
      transition_bound = @estimate >= PRESIZE_MIN_STATES ? transitions_bound : 0_i64
      if PRESIZED_TRANSITIONS <= transition_bound <= @limits.max_program_states
        @ledger.charge_array(transition_bound, sizeof(Program::Transition), "the program transitions", 0)
        @list_of_transitions = Array(Program::Transition).new(transition_bound.to_i32)
      else
        @ledger.charge_array(0, sizeof(Program::Transition), "the program transitions", 0)
        @list_of_transitions = [] of Program::Transition
      end
      @ledger.charge_array(0, sizeof(Task), "the compiler task stack", 0)
      @list_of_tasks = [] of Task
      @ledger.charge_array(0, sizeof(Int32), "the compiler value stack", 0)
      @list_of_values = [] of Int32
      ClassTrie.charge_new(@ledger)
      @class_trie = ClassTrie.new
      @ledger.charge_array(0, sizeof(Int32), "the class trie", 0)
      @list_of_trie_states = [] of Int32
    end

    # A program bound to have at least this many transitions gets its
    # transition list allocated once, at the bound, rather than grown.
    private PRESIZED_TRANSITIONS = 512_i64
    # Programs bound to fewer states than this never need the transition bound.
    private PRESIZE_MIN_STATES = 128_i64

    # An upper bound on the transitions the program's classes emit: each
    # class's transitions (a large class's memoized block exactly, a small
    # class's UTF-8 byte ranges, which its trie never exceeds) times the
    # copies its enclosing repetitions make (one more for an unbounded
    # repetition's fresh copy). Saturates rather than overflows.
    private def transitions_bound : Int64
      total = 0_i64
      @ledger.charge_array(0, sizeof({Hir::Node, Int64}), "the transition bound stack", 0)
      stack = [] of {Hir::Node, Int64}
      push_bound_entry(stack, @pattern.root, 1_i64)
      while entry = stack.pop?
        node, copies = entry
        charge_work
        case node
        when Hir::Class
          total = Preflight.add(total, Preflight.multiply(class_transitions(node.code_point_set), copies))
        when Hir::LineBreak
          total = Preflight.add(total, Preflight.multiply(OTHER_LINE_BREAKS.range_count.to_i64 * 4, copies))
        when Hir::Repetition
          maximum = node.maximum
          repeated = if maximum
                       maximum.to_i64
                     else
                       # The fresh copy exists only for a body that can match
                       # the empty string (see `finish_loop`).
                       Math.max(node.minimum, 1).to_i64 + (consumes?(node.child, BOUND_DEPTH) ? 0 : 1)
                     end
          push_bound_entry(stack, node.child, Preflight.multiply(copies, repeated))
        when Hir::Capture
          push_bound_entry(stack, node.child, copies)
        when Hir::Concatenation
          node.list_of_children.each { |child| push_bound_entry(stack, child, copies) }
        when Hir::Alternation
          node.list_of_branches.each { |branch| push_bound_entry(stack, branch, copies) }
        end
      end
      total
    end

    # How deep `consumes?` looks before it answers false.
    private BOUND_DEPTH = 4

    # True when every match of *node* consumes a byte, looking at most
    # *depth* levels down (deeper, it answers false, which only widens the
    # bound). Over-allocating the transitions of `\w+` by a second copy of
    # `\w` doubled the bytes a small pattern allocated.
    private def consumes?(node : Hir::Node, depth : Int32) : Bool
      return false if depth == 0
      case node
      when Hir::Class, Hir::Literal, Hir::LineBreak
        true
      when Hir::Capture
        consumes?(node.child, depth - 1)
      when Hir::Concatenation
        node.list_of_children.any? { |child| consumes?(child, depth - 1) }
      when Hir::Alternation
        node.list_of_branches.all? { |branch| consumes?(branch, depth - 1) }
      when Hir::Repetition
        node.minimum > 0 && consumes?(node.child, depth - 1)
      else
        false
      end
    end

    private def push_bound_entry(stack : Array({Hir::Node, Int64}), node : Hir::Node, copies : Int64) : Nil
      @ledger.charge_append(sizeof({Hir::Node, Int64}), "the transition bound stack", 0)
      stack << {node, copies}
    end

    private def class_transitions(set : CodePointSet) : Int64
      # A memoized class's transitions stay in its shared table.
      return 0_i64 if ClassMemo.memoized?(set)
      return set.range_count.to_i64 if set.empty? || set.list_of_bounds[-1] < 0x80
      byte_ranges = 0_i64
      set.each_range { |first, last| byte_ranges += Utf8Sequences.count(first, last)[1] }
      byte_ranges
    end

    protected def compile : Program
      match_state = emit(Program::StateKind::Match)
      close_whole = emit_save(1, match_state)
      push_task(TaskKind::Compile, @pattern.root, close_whole)
      run_tasks
      body = @list_of_values.pop
      start = emit_save(0, body)
      start = relocate_copies(start)
      workspace_charge = check_pike_bytes
      group_names = @pattern.list_of_group_names
      literal_set = LiteralSet.extract(@pattern, @meter)
      charge_literal_set(literal_set) if literal_set
      @ledger.charge_object(instance_sizeof(Program), "the program", 0)
      Program.new(@list_of_states, @list_of_transitions, start, @pattern.capture_count, group_names,
        @pattern.options, @limits.max_pike_bytes - workspace_charge, @pattern.source_end, literal_set,
        @list_of_class_blocks, @list_of_shared_tables, @list_of_class_copies || Program::NO_CLASS_COPIES)
    end

    # Numbers the class copies after the held states: every reference to a
    # copy's state (from held states, own transitions, class blocks and
    # other copies' exits) moves from `COPY_BASE` to the held count.
    # Returns *start*, moved the same way.
    private def relocate_copies(start : Int32) : Int32
      copies = @list_of_class_copies || return start
      shift = @list_of_states.size - COPY_BASE
      states = @list_of_states.to_unsafe
      @list_of_states.size.times do |index|
        charge_work
        state = states[index]
        if state.next_state >= COPY_BASE || state.alternate >= COPY_BASE
          states[index] = state.copy_with(next_state: copied(state.next_state, shift), alternate: copied(state.alternate, shift))
        end
      end
      transitions = @list_of_transitions.to_unsafe
      @list_of_transitions.size.times do |index|
        transition = transitions[index]
        transitions[index] = transition.copy_with(target: transition.target + shift) if transition.target >= COPY_BASE
      end
      copies.map! do |copy|
        copy.copy_with(first_state: copy.first_state + shift, exit: copied(copy.exit, shift))
      end
      @list_of_class_blocks.map! do |block|
        block.copy_with(first_state: copied(block.first_state, shift), end_state: copied(block.end_state, shift),
          entry: copied(block.entry, shift), exit: copied(block.exit, shift))
      end
      copied(start, shift)
    end

    private def copied(target : Int32, shift : Int32) : Int32
      target >= COPY_BASE ? target + shift : target
    end

    # Grows the held states to the preflight's bound when *added* more do
    # not fit (see `FIRST_HELD_STATES`), charging the new list first: a
    # program that also has class copies may then hold both it and the
    # written-out states (`Program#state_at`), charged when compiling
    # began.
    private def reserve_held_states(added : Int32) : Nil
      return if @list_of_states.size + added <= @held_capacity
      @ledger.charge_array(@state_bound, sizeof(Program::State), "the program states", 0)
      grown = Array(Program::State).new(@state_bound)
      grown.concat(@list_of_states)
      @list_of_states = grown
      @held_capacity = @state_bound
    end

    private def charge_literal_set(literal_set : LiteralSet) : Nil
      @ledger.charge_object(instance_sizeof(LiteralSet), "the literal set", 0)
      @ledger.charge_array(literal_set.list_of_literals.size, sizeof(Bytes), "the literal set", 0)
      literal_set.list_of_literals.each { |literal| @ledger.charge_string(literal.size, "a literal", 0) }
    end

    private def run_tasks : Nil
      while task = @list_of_tasks.pop?
        charge_work
        node = task.node
        case task.task_kind
        in .compile?
          compile_node(node, task.next_state)
        in .concatenation_step?
          start = @list_of_values.pop
          if task.count == 0
            push_value(start)
          else
            push_task(TaskKind::ConcatenationStep, node, NONE, task.count - 1)
            push_task(TaskKind::Compile, children_of(node)[task.count - 1], start)
          end
        in .alternation_finish?
          finish_alternation(task.count)
        in .capture_finish?
          capture = expect_node(node, Hir::Capture)
          push_value(emit_save(capture.capture_index * 2, @list_of_values.pop))
        in .loop_finish?
          finish_loop(expect_node(node, Hir::Repetition), task.count, task.next_state)
        in .optional_step?
          repetition = expect_node(node, Hir::Repetition)
          if task.count == 0
            push_task(TaskKind::MandatoryStep, node, NONE, repetition.minimum)
          else
            continuation = @list_of_values.pop
            push_task(TaskKind::OptionalFinish, node, task.next_state, task.count)
            push_task(TaskKind::Compile, repetition.child, continuation)
          end
        in .optional_finish?
          repetition = expect_node(node, Hir::Repetition)
          copy = @list_of_values.pop
          exit = task.next_state
          split = repetition.greedy? ? emit_split(copy, exit) : emit_split(exit, copy)
          push_value(split)
          push_task(TaskKind::OptionalStep, node, exit, task.count - 1)
        in .mandatory_step?
          if task.count > 0
            continuation = @list_of_values.pop
            push_task(TaskKind::MandatoryStep, node, NONE, task.count - 1)
            push_task(TaskKind::Compile, expect_node(node, Hir::Repetition).child, continuation)
          end
        end
      end
    end

    private def compile_node(node : Hir::Node, next_state : Int32) : Nil
      case node
      when Hir::Empty
        push_value(next_state)
      when Hir::Literal
        push_value(compile_literal(node.code_point, next_state))
      when Hir::Class
        push_value(compile_recorded_class(node.code_point_set, next_state))
      when Hir::Look
        push_value(emit_look(look_kind(node), next_state))
      when Hir::LineBreak
        push_value(compile_line_break(node.any_crlf?, next_state))
      when Hir::Concatenation
        count = node.list_of_children.size
        if count == 0
          push_value(next_state)
        else
          push_task(TaskKind::ConcatenationStep, node, NONE, count - 1)
          push_task(TaskKind::Compile, node.list_of_children[count - 1], next_state)
        end
      when Hir::Alternation
        if set = merged_class(node)
          push_value(compile_recorded_class(set, next_state))
          return
        end
        branches = node.list_of_branches
        push_task(TaskKind::AlternationFinish, node, NONE, branches.size)
        (branches.size - 1).downto(0) { |index| push_task(TaskKind::Compile, branches[index], next_state) }
      when Hir::Capture
        close = emit_save(node.capture_index * 2 + 1, next_state)
        push_task(TaskKind::CaptureFinish, node, NONE, 0)
        push_task(TaskKind::Compile, node.child, close)
      when Hir::Repetition
        compile_repetition(node, next_state)
      else
        raise SyntaxError.new("internal error: unknown Hir node #{node.class}", Core::Position.new(0_i64))
      end
    end

    private def children_of(node : Hir::Node) : Array(Hir::Node)
      expect_node(node, Hir::Concatenation).list_of_children
    end

    # Returns *node* as the *type* its task was pushed for; anything else is
    # a compiler defect, reported as one.
    private def expect_node(node : Hir::Node, type : T.class) : T forall T
      node.as?(T) || raise SyntaxError.new("internal error: expected a #{T}, got #{node.class}", Core::Position.new(0_i64))
    end

    # Joins the branches on the value stack (first branch deepest) with
    # splits that try them in order.
    private def finish_alternation(count : Int32) : Nil
      first = @list_of_values.size - count
      current = @list_of_values[-1]
      (count - 2).downto(0) do |index|
        current = emit_split(@list_of_values[first + index], current)
      end
      count.times { @list_of_values.pop }
      push_value(current)
    end

    private def compile_repetition(node : Hir::Repetition, next_state : Int32) : Nil
      maximum = node.maximum
      reserve_class_copies(node, maximum)
      mark_in_place(node, maximum)
      if maximum.nil?
        loop_split = emit(Program::StateKind::Split)
        push_task(TaskKind::LoopFinish, node, next_state, loop_split)
        push_task(TaskKind::Compile, node.child, loop_split)
      elsif maximum == 0
        push_value(next_state)
      elsif single_item?(node.child)
        push_value(compile_counted_item(node, maximum, next_state))
      else
        push_value(next_state)
        push_task(TaskKind::OptionalStep, node, next_state, maximum - node.minimum)
      end
    end

    # True when *node* compiles in one step, without tasks of its own.
    private def single_item?(node : Hir::Node) : Bool
      node.is_a?(Hir::Literal) || node.is_a?(Hir::Class)
    end

    # Compiles `x{n,m}` for a literal or class *x* in a loop, emitting what
    # the `OptionalStep`, `OptionalFinish` and `MandatoryStep` tasks emit
    # for it, in the same order: the optional copies from the last back,
    # each behind a split to *next_state*, then the mandatory copies.
    # `[\w.%+-]{1,256}` is hundreds of copies, and a task round per copy
    # cost more than the copy.
    private def compile_counted_item(node : Hir::Repetition, maximum : Int32, next_state : Int32) : Int32
      child = node.child
      current = next_state
      (maximum - node.minimum).times do
        charge_work
        copy = compile_item(child, current)
        current = node.greedy? ? emit_split(copy, next_state) : emit_split(next_state, copy)
      end
      node.minimum.times do
        charge_work
        current = compile_item(child, current)
      end
      current
    end

    private def compile_item(node : Hir::Node, next_state : Int32) : Int32
      if node.is_a?(Hir::Literal)
        compile_literal(node.code_point, next_state)
      elsif node.is_a?(Hir::Class)
        compile_recorded_class(node.code_point_set, next_state)
      else
        raise SyntaxError.new("internal error: #{node.class} is not a single item", Core::Position.new(0_i64))
      end
    end

    # Closes the loop of `{n,}`. The body on the value stack (the *consumed*
    # copy) returns to *loop_split*, which starts another iteration or exits
    # to *exit*.
    #
    # When the body can match the empty string, each iteration starts in a
    # second, *fresh* copy of the body: the same states, except that its
    # epsilon edges stay inside the fresh copy and its byte edges lead into
    # the consumed copy, and reaching its end goes to *exit* instead of back
    # to the loop. An iteration therefore loops again only after it consumed
    # a byte, and one that matched the empty string ends the repetition, which
    # is how PCRE2 ends a group repetition after an empty iteration. Whether
    # the iteration consumed anything is part of the state number, so the
    # engines' one-visit-per-state rule stays exact.
    private def finish_loop(node : Hir::Repetition, loop_split : Int32, exit : Int32) : Nil
      consumed_start = @list_of_values.pop
      first = loop_split + 1
      last = @list_of_states.size
      fresh_start = consumed_start
      if nullable_body?(consumed_start, first, last, loop_split)
        fresh_start = copy_fresh_body(consumed_start, first, last, loop_split, exit)
      end
      preferred, other = node.greedy? ? {fresh_start, exit} : {exit, fresh_start}
      @list_of_states[loop_split] = Program::State.new(Program::StateKind::Split, 0_u8, 0_u8, preferred, other, 0)
      if node.minimum == 0
        push_value(loop_split)
      else
        push_value(fresh_start)
        push_task(TaskKind::MandatoryStep, node, NONE, node.minimum - 1)
      end
    end

    # Returns true when an epsilon path (splits, slot saves, assertions) leads
    # from *start* to *loop_split* through the body states *first*...*last*.
    private def nullable_body?(start : Int32, first : Int32, last : Int32, loop_split : Int32) : Bool
      return true if start == loop_split
      # A body that starts by reading a byte (a class, a literal) has no
      # epsilon path at all, so its states need no walk.
      return false if first <= start < last && @list_of_states[start].kind.in?(Program::StateKind::ByteRange, Program::StateKind::Sparse)
      size = last - first
      grow(GrowingList::Visited, size, sizeof(Bool))
      visited = @list_of_visited
      visited.clear
      size.times { visited << false }
      stack = @list_of_values
      base = stack.size
      push_value(start)
      found = false
      while stack.size > base
        current = stack.pop
        if current == loop_split
          found = true
          break
        end
        next unless first <= current < last
        next if visited[current - first]
        visited[current - first] = true
        charge_work
        state = @list_of_states[current]
        case state.kind
        when .split?
          push_value(state.alternate)
          push_value(state.next_state)
        when .save?, .look?
          push_value(state.next_state)
        end
      end
      (stack.size - base).times { stack.pop }
      found
    end

    # Emits the fresh copy of the body *first*...*last* and returns the copy
    # of *start*.
    private def copy_fresh_body(start : Int32, first : Int32, last : Int32, loop_split : Int32, exit : Int32) : Int32
      offset = @list_of_states.size - first
      (first...last).each do |index|
        state = @list_of_states[index]
        case state.kind
        when .split?
          add_state(state.copy_with(next_state: fresh_target(state.next_state, first, last, offset, loop_split, exit),
            alternate: fresh_target(state.alternate, first, last, offset, loop_split, exit)))
        when .save?, .look?
          add_state(state.copy_with(next_state: fresh_target(state.next_state, first, last, offset, loop_split, exit)))
        else
          # Byte states keep their targets in the consumed copy; match and
          # fail states have none.
          add_state(state)
        end
      end
      fresh_target(start, first, last, offset, loop_split, exit)
    end

    private def fresh_target(target : Int32, first : Int32, last : Int32, offset : Int32, loop_split : Int32,
                             exit : Int32) : Int32
      return target + offset if first <= target < last
      return exit if target == loop_split
      target
    end

    private def compile_literal(code_point : Int32, next_state : Int32) : Int32
      bytes = StaticArray(UInt8, 4).new(0_u8)
      length = Core::UTF8.encode(code_point, bytes.to_slice)
      current = next_state
      (length - 1).downto(0) do |index|
        current = emit_byte_range(bytes[index], bytes[index], current)
      end
      current
    end

    # `\R`: `\r\n`, a lone `\r` not followed by `\n` (so a later failure
    # never splits `\r\n`, as in PCRE2's atomic `\R`), or one of the other
    # line breaks.
    private def compile_line_break(any_crlf : Bool, next_state : Int32) : Int32
      line_feed = emit_byte_range(0x0A_u8, 0x0A_u8, next_state)
      lone = emit_look(Program::LookKind::NotBeforeLineFeed, next_state)
      after_return = emit_split(line_feed, lone)
      carriage_return = emit_byte_range(0x0D_u8, 0x0D_u8, after_return)
      others = any_crlf ? LINE_FEED_ONLY : OTHER_LINE_BREAKS
      emit_split(carriage_return, compile_class(others, next_state))
    end

    # The line breaks of `\R` other than `\r`.
    private OTHER_LINE_BREAKS = CodePointSet.from_bounds([0x0A, 0x0C, 0x85, 0x85, 0x2028, 0x2029])
    # The line breaks of `\R` under `(*BSR_ANYCRLF)` other than `\r`.
    private LINE_FEED_ONLY = CodePointSet.from_bounds([0x0A, 0x0A])

    # Compiles *set* (see `compile_class`) and records its states as a
    # `Program::ClassBlock` when they are more than one.
    private def compile_recorded_class(set : CodePointSet, next_state : Int32) : Int32
      first_state = @list_of_states.size
      copies = @copied_state_count
      entry = compile_class(set, next_state)
      end_state = @list_of_states.size
      if @copied_state_count > copies
        # The class was copied in place: its states are the last copy's.
        first_state = COPY_BASE + copies
        end_state = COPY_BASE + @copied_state_count
      end
      if end_state - first_state > 1
        @ledger.charge_append(sizeof(Program::ClassBlock), "a class block", 0)
        @list_of_class_blocks << Program::ClassBlock.new(first_state, end_state, entry, next_state)
      end
      entry
    end

    # Compiles *set* into a byte automaton. A small set becomes its byte
    # trie, its UTF-8 sequences sharing their leading byte ranges, one state
    # per trie node (a `ByteRange` for one edge, a `Sparse` for several),
    # every last byte going to *next_state*. A large set becomes a copy of
    # its memoized minimal automaton (`ClassMemo`).
    private def compile_class(set : CodePointSet, next_state : Int32) : Int32
      return emit(Program::StateKind::Fail) if set.empty?
      return instantiate(memo_block(set), next_state, in_place?(set)) if ClassMemo.memoized?(set)
      return compile_class_from_trie(set, next_state) unless set.same?(@repeated_small_set)
      if block = @repeated_small_block
        return instantiate(block, next_state)
      end
      first_state = @list_of_states.size
      first_transition = @list_of_transitions.size
      entry = compile_class_from_trie(set, next_state)
      @repeated_small_block = capture_block(first_state, first_transition, entry, next_state)
      entry
    end

    # The states and transitions emitted from *first_state* and
    # *first_transition* on, as a block relative to them whose exit is
    # *next_state*, charged before it is copied.
    private def capture_block(first_state : Int32, first_transition : Int32, entry : Int32,
                              next_state : Int32) : ClassMemo::Block
      state_count = @list_of_states.size - first_state
      transition_count = @list_of_transitions.size - first_transition
      @ledger.charge_array(state_count, sizeof(Program::State), "a repeated class", 0)
      @ledger.charge_array(transition_count, sizeof(Program::Transition), "a repeated class", 0)
      list_of_states = Array(Program::State).new(state_count) do |offset|
        state = @list_of_states[first_state + offset]
        state.copy_with(next_state: relative_target(state.next_state, first_state, next_state),
          argument: state.kind.sparse? ? state.argument - first_transition : state.argument)
      end
      list_of_transitions = Array(Program::Transition).new(transition_count) do |offset|
        transition = @list_of_transitions[first_transition + offset]
        transition.copy_with(target: relative_target(transition.target, first_state, next_state))
      end
      ClassMemo::Block.new(list_of_states, list_of_transitions, entry - first_state)
    end

    private def relative_target(target : Int32, first_state : Int32, next_state : Int32) : Int32
      return target if target == NONE
      target == next_state ? ClassMemo::EXIT : target - first_state
    end

    # Emits a memoized class block after the current states, its exit
    # leading to *next_state*, and returns its entry state. The block is
    # checked against the limits and charged as a whole, as emitting its
    # states one by one would check and charge them.
    private def instantiate(block : ClassMemo::Block, next_state : Int32, in_place : Bool = false) : Int32
      if table = block.shared_table
        if table_id = shared_table_id(table)
          return in_place ? copy_in_place(block, table_id, next_state) : hold_shared(block, table_id, next_state)
        end
      end
      first_state = @list_of_states.size
      first_transition = @list_of_transitions.size
      block_states = block.list_of_states
      block_transitions = block.list_of_transitions
      check_state_room(block_states.size)
      reserve_held_states(block_states.size)
      @ledger.charge(sizeof(Program::Transition).to_i64 * AllocationLedger::GROWTH_FACTOR * block_transitions.size,
        "a class transition", 0)
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(block_states.size)
      reserve_transitions(block_transitions.size)
      # Copied whole (a memory copy), then relocated in place: a large
      # class is hundreds of states and over a thousand transitions, so
      # appending them one by one dominated compiling a pattern like `\w+`.
      @list_of_transitions.concat(block_transitions)
      transitions = @list_of_transitions.to_unsafe + first_transition
      block_transitions.size.times do |index|
        transition = transitions[index]
        transitions[index] = transition.copy_with(target: absolute_target(transition.target, first_state, next_state))
      end
      @list_of_states.concat(block_states)
      states = @list_of_states.to_unsafe + first_state
      block_states.size.times do |index|
        state = states[index]
        states[index] = state.copy_with(next_state: absolute_target(state.next_state, first_state, next_state),
          argument: state.kind.sparse? ? state.argument + first_transition : state.argument)
      end
      block.entry + first_state
    end

    private MAX_SHARED_TABLES = 255

    # The number a `Sparse` state uses for *table* (its position in the
    # program's shared tables, plus one), adding it the first time; nil
    # once `MAX_SHARED_TABLES` are in use, when the block is copied whole.
    private def shared_table_id(table : Array(Program::Transition)) : UInt8?
      if index = @list_of_shared_tables.index(&.same?(table))
        return (index + 1).to_u8
      end
      return nil if @list_of_shared_tables.size >= MAX_SHARED_TABLES
      @ledger.charge_append(sizeof(Array(Program::Transition)), "a shared class table", 0)
      @list_of_shared_tables << table
      @list_of_shared_tables.size.to_u8
    end

    # Adds a copy of a memoized class block that a counted repetition
    # repeats (see `in_place?`), its exit leading to *next_state* and its
    # `Sparse` states reading their transitions from shared table
    # *table_id*, and returns its entry state. The program reads the copy's
    # states from the block in place (`Program::ClassCopy`), so a copy
    # costs one record however many states the class has: `\w{25}` holds
    # 25 records, not 25 copies of `\w`'s 354 states.
    private def copy_in_place(block : ClassMemo::Block, table_id : UInt8, next_state : Int32) : Int32
      block_states = block.list_of_states
      check_state_room(block_states.size)
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(block_states.size)
      first_state = COPY_BASE + @copied_state_count
      @ledger.charge_append(sizeof(Program::ClassCopy), "a class copy", 0)
      list_of_copies = @list_of_class_copies ||= [] of Program::ClassCopy
      list_of_copies << Program::ClassCopy.new(first_state, block_states, table_id, next_state)
      @copied_state_count += block_states.size
      block.entry + first_state
    end

    # Emits a memoized class block's states after the current ones, its
    # exit leading to *next_state*, with its `Sparse` states reading their
    # transitions from shared table *table_id* (one memory copy of the
    # states, relocated in place; no transitions are copied), and returns
    # its entry state. The engines read held states fastest, so every copy
    # a counted repetition does not repeat is held.
    private def hold_shared(block : ClassMemo::Block, table_id : UInt8, next_state : Int32) : Int32
      first_state = @list_of_states.size
      block_states = block.list_of_states
      check_state_room(block_states.size)
      reserve_held_states(block_states.size)
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(block_states.size)
      @list_of_states.concat(block_states)
      states = @list_of_states.to_unsafe + first_state
      block_states.size.times do |index|
        state = states[index]
        states[index] = if state.kind.sparse?
                          state.copy_with(low: table_id, next_state: next_state)
                        else
                          state.copy_with(next_state: absolute_target(state.next_state, first_state, next_state))
                        end
      end
      block.entry + first_state
    end

    # True when a counted repetition may repeat a large class (see
    # `mark_in_place`), so the program may hold far fewer states than the
    # preflight's bound. One walk of the `Hir`, an operation per node.
    private def repeats_a_large_class? : Bool
      @ledger.charge_array(0, sizeof(Hir::Node), "the repetition walk stack", 0)
      stack = [@pattern.root] of Hir::Node
      while node = stack.pop?
        charge_work
        case node
        when Hir::Repetition
          child = node.child
          if (node.maximum || node.minimum) >= 2
            return true if child.is_a?(Hir::Class) && ClassMemo.memoized?(child.code_point_set)
            return true if child.is_a?(Hir::Alternation)
          end
          push_walk(stack, child)
        when Hir::Capture
          push_walk(stack, node.child)
        when Hir::Concatenation
          node.list_of_children.each { |child| push_walk(stack, child) }
        when Hir::Alternation
          node.list_of_branches.each { |branch| push_walk(stack, branch) }
        end
      end
      false
    end

    private def push_walk(stack : Array(Hir::Node), node : Hir::Node) : Nil
      @ledger.charge_append(sizeof(Hir::Node), "the repetition walk stack", 0)
      stack << node
    end

    # Marks a large class that *node* repeats in two or more copies
    # (`\w{25,}`, `\p{L}{2,8}`) to be read in place (`copy_in_place`).
    private def mark_in_place(node : Hir::Repetition, maximum : Int32?) : Nil
      return if (maximum || node.minimum) < 2
      child = node.child
      set = if child.is_a?(Hir::Class)
              child.code_point_set
            elsif child.is_a?(Hir::Alternation)
              merged_class(child)
            end
      return unless set && ClassMemo.memoized?(set) && !in_place?(set)
      @ledger.charge_append(sizeof(CodePointSet), "a repeated class", 0)
      list_of_sets = @list_of_in_place_sets ||= [] of CodePointSet
      list_of_sets << set
    end

    # True when *set*'s copies are read in place (see `mark_in_place`).
    private def in_place?(set : CodePointSet) : Bool
      list_of_sets = @list_of_in_place_sets
      !list_of_sets.nil? && list_of_sets.any?(&.same?(set))
    end

    # Marks a repeated small class to be copied rather than rebuilt. A
    # large (memoized) class needs nothing: its copies read its shared
    # table and add no transitions.
    private def reserve_class_copies(node : Hir::Repetition, maximum : Int32?) : Nil
      child = node.child
      set = if child.is_a?(Hir::Class)
              child.code_point_set
            elsif child.is_a?(Hir::Alternation)
              merged_class(child)
            end
      return unless set
      return if ClassMemo.memoized?(set)
      copies = maximum || Math.max(node.minimum, 1)
      if copies > 1 && !set.same?(@repeated_small_set)
        @repeated_small_set = set
        @repeated_small_block = nil
      end
    end

    # The one class an alternation of classes and single characters stands
    # for, when a branch is a large class: `(?:\p{Lu}|\p{Ll})` matches
    # exactly one code point of either set whichever branch is taken, so it
    # compiles as their union,
    # one automaton instead of two joined by a split. Nil for any other
    # alternation, or when the union could pass `max_class_ranges`. The
    # union is computed once per alternation node, so the copies of a
    # repetition share it.
    private def merged_class(node : Hir::Alternation) : CodePointSet?
      return @last_merged_set if node.same?(@last_merged_node)
      branches = node.list_of_branches
      return nil if branches.size < 2
      return nil unless branches.all? { |branch| branch.is_a?(Hir::Class) || branch.is_a?(Hir::Literal) }
      return nil unless branches.any? { |branch| branch.is_a?(Hir::Class) && ClassMemo.memoized?(branch.code_point_set) }
      @ledger.charge_array(branches.size, sizeof(CodePointSet), "a class union", 0)
      list_of_sets = Array(CodePointSet).new(branches.size)
      branches.each do |branch|
        if branch.is_a?(Hir::Class)
          list_of_sets << branch.code_point_set
        elsif branch.is_a?(Hir::Literal)
          @ledger.charge_object(instance_sizeof(CodePointSet), "a class union", 0)
          @ledger.charge_array(2, sizeof(Int32), "a class union", 0)
          list_of_sets << CodePointSet.from_bounds([branch.code_point, branch.code_point])
        end
      end
      return nil unless list_of_sets.sum(0_i64, &.range_count) <= @limits.max_class_ranges
      merged = ClassLowering.union_of(list_of_sets, @limits, @ledger, @meter, 0)
      @last_merged_node = node
      @last_merged_set = merged
      merged
    end

    # The memoized block of *set*, asking the memo once per set object.
    private def memo_block(set : CodePointSet) : ClassMemo::Block
      block = @last_memo_block
      return block if block && set.same?(@last_memo_set)
      block = ClassMemo.block_for(set, @ledger, @meter)
      @last_memo_set = set
      @last_memo_block = block
      block
    end

    # Makes room for *added* more transitions in one step (at least
    # doubling), rather than through the many smaller steps appending
    # them one by one would take. The growth stays within what
    # `AllocationLedger#charge_append` charged for them.
    private def reserve_transitions(added : Int32) : Nil
      size = @list_of_transitions.size
      # `remaining_capacity` counts from the start of the buffer, so it
      # includes the elements already held.
      return if @list_of_transitions.remaining_capacity - size >= added
      grown = Array(Program::Transition).new(Math.max(size + added, size * 2))
      grown.concat(@list_of_transitions)
      @list_of_transitions = grown
    end

    private def absolute_target(target : Int32, first_state : Int32, next_state : Int32) : Int32
      return target if target == NONE
      target == ClassMemo::EXIT ? next_state : target + first_state
    end

    private def compile_class_from_trie(set : CodePointSet, next_state : Int32) : Int32
      return compile_ascii_class(set, next_state) if set.list_of_bounds[-1] < 0x80
      trie = @class_trie
      trie.build(set, @ledger, @meter)
      # A set of surrogates only (`\p{Cs}`) has no UTF-8 sequences: like an
      # empty class, it never matches.
      return emit(Program::StateKind::Fail) if trie.empty?
      states = @list_of_trie_states
      states.clear
      grow(GrowingList::TrieStates, trie.node_count, sizeof(Int32))
      trie.node_count.times { states << NONE }
      # Children are created after their parents, so emitting from the
      # last node back reaches every child before its parent.
      (trie.node_count - 1).downto(0) do |node_index|
        states[node_index] = emit_trie_node(node_index, next_state)
      end
      states[0]
    end

    # Compiles a non-empty set of ASCII code points straight to the state
    # its trie would give: every range is a one-byte sequence, so the trie
    # is a root whose edges all end the class. One range is a `ByteRange`,
    # several a `Sparse` state, in range order. Case-insensitive literals
    # (`S` is `[Ss]`) take this path once per character.
    private def compile_ascii_class(set : CodePointSet, next_state : Int32) : Int32
      bounds = set.list_of_bounds
      range_count = bounds.size // 2
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(range_count)
      return emit_byte_range(bounds[0].to_u8, bounds[1].to_u8, next_state) if range_count == 1
      first_transition = @list_of_transitions.size
      range_count.times do |index|
        @ledger.charge_append(sizeof(Program::Transition), "a class transition", 0)
        @list_of_transitions << Program::Transition.new(bounds[index * 2].to_u8, bounds[index * 2 + 1].to_u8, next_state)
      end
      add_state(Program::State.new(Program::StateKind::Sparse, 0_u8, 0_u8, NONE, range_count, first_transition))
    end

    private def emit_trie_node(node_index : Int32, next_state : Int32) : Int32
      list_of_edges = @class_trie.list_of_edges
      first_edge, last_edge = @class_trie.list_of_nodes[node_index]
      if first_edge == last_edge
        edge = list_of_edges[first_edge]
        return emit_byte_range(edge.low, edge.high, trie_target(edge, next_state))
      end
      first_transition = @list_of_transitions.size
      count = 0
      edge_index = first_edge
      while edge_index != NONE
        edge = list_of_edges[edge_index]
        @ledger.charge_append(sizeof(Program::Transition), "a class transition", 0)
        @list_of_transitions << Program::Transition.new(edge.low, edge.high, trie_target(edge, next_state))
        count += 1
        edge_index = edge.next_sibling
      end
      add_state(Program::State.new(Program::StateKind::Sparse, 0_u8, 0_u8, NONE, count, first_transition))
    end

    private def trie_target(edge : ClassTrie::Edge, next_state : Int32) : Int32
      edge.child == ClassTrie::LEAF ? next_state : @list_of_trie_states[edge.child]
    end

    private def look_kind(node : Hir::Look) : Program::LookKind
      ascii = node.ascii_word?
      case node.assertion_kind
      in .start_of_text?                then Program::LookKind::StartOfText
      in .start_of_line?                then Program::LookKind::StartOfLine
      in .end_of_text?                  then Program::LookKind::EndOfText
      in .end_of_text_or_final_newline? then Program::LookKind::EndOfTextOrFinalNewline
      in .end_of_line?                  then Program::LookKind::EndOfLine
      in .search_start?                 then Program::LookKind::SearchStart
      in .word_boundary?
        ascii ? Program::LookKind::WordBoundaryAscii : Program::LookKind::WordBoundary
      in .not_word_boundary?
        ascii ? Program::LookKind::NotWordBoundaryAscii : Program::LookKind::NotWordBoundary
      in .word_start?
        ascii ? Program::LookKind::WordStartAscii : Program::LookKind::WordStart
      in .word_end?
        ascii ? Program::LookKind::WordEndAscii : Program::LookKind::WordEnd
      end
    end

    private def emit(kind : Program::StateKind) : Int32
      add_state(Program::State.new(kind, 0_u8, 0_u8, NONE, NONE, 0))
    end

    private def emit_byte_range(low : UInt8, high : UInt8, next_state : Int32) : Int32
      add_state(Program::State.new(Program::StateKind::ByteRange, low, high, next_state, NONE, 0))
    end

    private def emit_split(preferred : Int32, other : Int32) : Int32
      add_state(Program::State.new(Program::StateKind::Split, 0_u8, 0_u8, preferred, other, 0))
    end

    private def emit_save(slot : Int32, next_state : Int32) : Int32
      add_state(Program::State.new(Program::StateKind::Save, 0_u8, 0_u8, next_state, NONE, slot))
    end

    private def emit_look(kind : Program::LookKind, next_state : Int32) : Int32
      add_state(Program::State.new(Program::StateKind::Look, 0_u8, 0_u8, next_state, NONE, kind.value))
    end

    # Appends *state*, checking `max_program_states` first. The states
    # array was allocated with the preflight's bound, so passing that bound
    # would be a compiler defect, and it is reported as one.
    private def add_state(state : Program::State) : Int32
      check_state_room(1)
      reserve_held_states(1)
      charge_work
      @list_of_states << state
      @list_of_states.size - 1
    end

    # Raises unless *added* more states fit under `max_program_states` and
    # within the preflight bound.
    private def check_state_room(added : Int32) : Nil
      count = @list_of_states.size.to_i64 + @copied_state_count + added
      limit = @limits.max_program_states
      if count > limit
        raise CompileLimitError.new("max_program_states", limit, "A program of #{count} states", Core::Position.new(0_i64))
      end
      if count > @estimate
        raise SyntaxError.new("internal error: the compiler emitted more states than the preflight bound #{@estimate}",
          Core::Position.new(0_i64))
      end
    end

    private def push_task(kind : TaskKind, node : Hir::Node, next_state : Int32, count : Int32 = 0) : Nil
      grow(GrowingList::Tasks, @list_of_tasks.size + 1, sizeof(Task))
      @list_of_tasks << Task.new(kind, node, next_state, count)
    end

    private def push_value(value : Int32) : Nil
      grow(GrowingList::Values, @list_of_values.size + 1, sizeof(Int32))
      @list_of_values << value
    end

    # Charges a reused list's growth only when it passes its largest size
    # so far, so pushing and popping costs the ledger nothing.
    private def grow(list : GrowingList, size : Int32, element_bytes : Int32) : Nil
      high_water = @high_water[list.value]
      return if size <= high_water
      @ledger.charge(element_bytes.to_i64 * AllocationLedger::GROWTH_FACTOR * (size - high_water), "a compiler list", 0)
      @high_water[list.value] = size
    end

    private def charge_work : Nil
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(1)
    end

    # Refuses a program whose Pike VM workspace passes `max_pike_bytes`,
    # and returns its charge (`PikeVM.workspace_charge`). The workspace is
    # the one a search holds: the capture layout (16·m·c + 32·m + 8·c
    # bytes) when the pattern has groups, the span layout (32·m) when it
    # has none. A search on a program with groups runs both phases in its
    # capture workspace, so no second workspace is ever alive beside it.
    private def check_pike_bytes : Int64
      states = @list_of_states.size.to_i64 + @copied_state_count
      slots = (@pattern.capture_count.to_i64 + 1) * 2
      captures = @pattern.capture_count > 0
      bytes = PikeVM.workspace_charge(states, slots, captures)
      limit = @limits.max_pike_bytes
      return bytes if bytes <= limit
      layout = captures ? "#{slots} slots" : "no captures"
      raise CompileLimitError.new("max_pike_bytes", limit,
        "A Pike VM workspace of #{bytes} bytes (#{states} states, #{layout})", Core::Position.new(0_i64))
    end
  end
end
