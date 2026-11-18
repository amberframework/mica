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
      TrieNodes
      TrieEdges
      TrieStates
      Visited
    end

    private record Task, task_kind : TaskKind, node : Hir::Node, next_state : Int32, count : Int32

    # One edge of the byte trie a class is built from: a byte range and the
    # trie node it leads to (`LEAF` for the end of a sequence).
    private record TrieEdge, low : UInt8, high : UInt8, child : Int32, next_sibling : Int32

    private LEAF = -1
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
    # The byte trie of the class being compiled, reused for every class:
    # each node's first and last edge, and the edges themselves.
    @list_of_trie_nodes : Array({Int32, Int32})
    @list_of_trie_edges : Array(TrieEdge)
    @list_of_trie_states : Array(Int32)
    @high_water = StaticArray(Int32, 6).new(0)
    @list_of_visited = [] of Bool

    private def initialize(@pattern : Hir::Pattern, @estimate : Int64, @limits : CompileLimits,
                           @ledger : AllocationLedger, @meter : Core::WorkMeter)
      capacity = @estimate.clamp(1_i64, @limits.max_program_states).to_i32
      @ledger.charge_object(instance_sizeof(Compiler), "the compiler", 0)
      @ledger.charge_array(capacity, sizeof(Program::State), "the program states", 0)
      @list_of_states = Array(Program::State).new(capacity)
      @ledger.charge_array(0, sizeof(Program::Transition), "the program transitions", 0)
      @list_of_transitions = [] of Program::Transition
      @ledger.charge_array(0, sizeof(Task), "the compiler task stack", 0)
      @list_of_tasks = [] of Task
      @ledger.charge_array(0, sizeof(Int32), "the compiler value stack", 0)
      @list_of_values = [] of Int32
      @ledger.charge_array(0, sizeof({Int32, Int32}), "the class trie", 0)
      @list_of_trie_nodes = [] of {Int32, Int32}
      @ledger.charge_array(0, sizeof(TrieEdge), "the class trie", 0)
      @list_of_trie_edges = [] of TrieEdge
      @ledger.charge_array(0, sizeof(Int32), "the class trie", 0)
      @list_of_trie_states = [] of Int32
    end

    protected def compile : Program
      match_state = emit(Program::StateKind::Match)
      close_whole = emit_save(1, match_state)
      push_task(TaskKind::Compile, @pattern.root, close_whole)
      run_tasks
      body = @list_of_values.pop
      start = emit_save(0, body)
      workspace_charge = check_pike_bytes
      group_names = @pattern.list_of_group_names
      literal_set = LiteralSet.extract(@pattern, @meter)
      charge_literal_set(literal_set) if literal_set
      @ledger.charge_object(instance_sizeof(Program), "the program", 0)
      Program.new(@list_of_states, @list_of_transitions, start, @pattern.capture_count, group_names,
        @pattern.options, @limits.max_pike_bytes - workspace_charge, @pattern.source_end, literal_set)
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
        push_value(compile_class(node.code_point_set, next_state))
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
      if maximum.nil?
        loop_split = emit(Program::StateKind::Split)
        push_task(TaskKind::LoopFinish, node, next_state, loop_split)
        push_task(TaskKind::Compile, node.child, loop_split)
      elsif maximum == 0
        push_value(next_state)
      else
        push_value(next_state)
        push_task(TaskKind::OptionalStep, node, next_state, maximum - node.minimum)
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

    # Compiles *set* into a byte trie: its UTF-8 sequences share their
    # leading byte ranges, one state per trie node (a `ByteRange` for one
    # edge, a `Sparse` for several), and every last byte goes to
    # *next_state*.
    private def compile_class(set : CodePointSet, next_state : Int32) : Int32
      return emit(Program::StateKind::Fail) if set.empty?
      return compile_class_from_trie(set, next_state) unless ClassMemo.memoized?(set)
      if block = ClassMemo.block(set)
        return instantiate(block, next_state)
      end
      first_state = @list_of_states.size
      first_transition = @list_of_transitions.size
      entry = compile_class_from_trie(set, next_state)
      ClassMemo.store(set, ClassMemo::Block.new(
        @list_of_states[first_state..].map { |state| relative_state(state, first_state, first_transition, next_state) },
        @list_of_transitions[first_transition..].map do |transition|
          transition.copy_with(target: relative_target(transition.target, first_state, next_state))
        end,
        entry - first_state))
      entry
    end

    # Emits a memoized class block after the current states, its exit
    # leading to *next_state*, and returns its entry state.
    private def instantiate(block : ClassMemo::Block, next_state : Int32) : Int32
      first_state = @list_of_states.size
      first_transition = @list_of_transitions.size
      block.list_of_transitions.each do |transition|
        @ledger.charge_append(sizeof(Program::Transition), "a class transition", 0)
        @list_of_transitions << transition.copy_with(target: absolute_target(transition.target, first_state, next_state))
      end
      block.list_of_states.each do |state|
        add_state(state.copy_with(next_state: absolute_target(state.next_state, first_state, next_state),
          argument: state.kind.sparse? ? state.argument + first_transition : state.argument))
      end
      block.entry + first_state
    end

    private def relative_state(state : Program::State, first_state : Int32, first_transition : Int32,
                               next_state : Int32) : Program::State
      state.copy_with(next_state: relative_target(state.next_state, first_state, next_state),
        argument: state.kind.sparse? ? state.argument - first_transition : state.argument)
    end

    private def relative_target(target : Int32, first_state : Int32, next_state : Int32) : Int32
      return target if target == NONE
      target == next_state ? ClassMemo::EXIT : target - first_state
    end

    private def absolute_target(target : Int32, first_state : Int32, next_state : Int32) : Int32
      return target if target == NONE
      target == ClassMemo::EXIT ? next_state : target + first_state
    end

    private def compile_class_from_trie(set : CodePointSet, next_state : Int32) : Int32
      build_trie(set)
      # A set of surrogates only (`\p{Cs}`) has no UTF-8 sequences: like an
      # empty class, it never matches.
      return emit(Program::StateKind::Fail) if @list_of_trie_nodes[0][0] == NONE
      states = @list_of_trie_states
      states.clear
      grow(GrowingList::TrieStates, @list_of_trie_nodes.size, sizeof(Int32))
      @list_of_trie_nodes.size.times { states << NONE }
      # Children are created after their parents, so emitting from the
      # last node back reaches every child before its parent.
      (@list_of_trie_nodes.size - 1).downto(0) do |node_index|
        states[node_index] = emit_trie_node(node_index, next_state)
      end
      states[0]
    end

    private def build_trie(set : CodePointSet) : Nil
      @list_of_trie_nodes.clear
      @list_of_trie_edges.clear
      add_trie_node
      lows = StaticArray(UInt8, 4).new(0_u8)
      highs = StaticArray(UInt8, 4).new(0_u8)
      set.each_range do |first, last|
        Utf8Sequences.each(first, last) do |length, low, high|
          charge_work
          Core::UTF8.encode(low, lows.to_slice)
          Core::UTF8.encode(high, highs.to_slice)
          node = 0
          length.times do |depth|
            final = depth == length - 1
            node = add_trie_edge(node, lows[depth], highs[depth], final)
          end
        end
      end
    end

    # Adds a node with no edges and returns its index.
    private def add_trie_node : Int32
      grow(GrowingList::TrieNodes, @list_of_trie_nodes.size + 1, sizeof({Int32, Int32}))
      @list_of_trie_nodes << {NONE, NONE}
      @list_of_trie_nodes.size - 1
    end

    # Follows (or adds) the edge *low*..*high* from *node* and returns the
    # node it leads to (`LEAF` for a sequence's last byte). Sequences
    # arrive in code point order, so an equal edge can only be the last one
    # added to *node*.
    private def add_trie_edge(node : Int32, low : UInt8, high : UInt8, final : Bool) : Int32
      first_edge, last_edge = @list_of_trie_nodes[node]
      if last_edge != NONE
        edge = @list_of_trie_edges[last_edge]
        return edge.child if edge.low == low && edge.high == high && !final && edge.child != LEAF
      end
      child = final ? LEAF : add_trie_node
      grow(GrowingList::TrieEdges, @list_of_trie_edges.size + 1, sizeof(TrieEdge))
      @list_of_trie_edges << TrieEdge.new(low, high, child, NONE)
      edge_index = @list_of_trie_edges.size - 1
      if last_edge == NONE
        @list_of_trie_nodes[node] = {edge_index, edge_index}
      else
        previous = @list_of_trie_edges[last_edge]
        @list_of_trie_edges[last_edge] = previous.copy_with(next_sibling: edge_index)
        @list_of_trie_nodes[node] = {first_edge, edge_index}
      end
      child
    end

    private def emit_trie_node(node_index : Int32, next_state : Int32) : Int32
      first_edge, last_edge = @list_of_trie_nodes[node_index]
      if first_edge == last_edge
        edge = @list_of_trie_edges[first_edge]
        return emit_byte_range(edge.low, edge.high, trie_target(edge, next_state))
      end
      first_transition = @list_of_transitions.size
      count = 0
      edge_index = first_edge
      while edge_index != NONE
        edge = @list_of_trie_edges[edge_index]
        @ledger.charge_append(sizeof(Program::Transition), "a class transition", 0)
        @list_of_transitions << Program::Transition.new(edge.low, edge.high, trie_target(edge, next_state))
        count += 1
        edge_index = edge.next_sibling
      end
      add_state(Program::State.new(Program::StateKind::Sparse, 0_u8, 0_u8, NONE, count, first_transition))
    end

    private def trie_target(edge : TrieEdge, next_state : Int32) : Int32
      edge.child == LEAF ? next_state : @list_of_trie_states[edge.child]
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
      count = @list_of_states.size.to_i64 + 1
      limit = @limits.max_program_states
      if count > limit
        raise CompileLimitError.new("max_program_states", limit, "A program of #{count} states", Core::Position.new(0_i64))
      end
      if count > @estimate
        raise SyntaxError.new("internal error: the compiler emitted more states than the preflight bound #{@estimate}",
          Core::Position.new(0_i64))
      end
      charge_work
      @list_of_states << state
      @list_of_states.size - 1
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
      states = @list_of_states.size.to_i64
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
