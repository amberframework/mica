module Mica::Regex
  # The Pike VM: runs a `Program` over a haystack in one forward pass,
  # carrying every live thread in priority order, so it reports the
  # leftmost-first match (Perl and PCRE2 priority) with its captures.
  #
  # **Bounds.** For m states, c capture slots and a scanned span of L bytes:
  #
  # - time O(m·c·(L + 1)): each position visits each state at most once
  #   (the sparse sets), and adding a thread copies its parent's c slots;
  # - memory 16·m·c + 32·m + 8·c bytes, allocated once per workspace as one
  #   pointer-free buffer: two slot tables (current and next step, m·c
  #   slots each), two sparse sets (a dense and a sparse array of m entries
  #   each), the epsilon-closure stack (m frames of 16 bytes: each state
  #   pushes at most one frame per closure) and one scratch slot vector.
  #
  # Every visited state and stepped thread is charged one operation, and
  # every slot vector copy c operations, to the `SearchMeter`.
  #
  # A workspace serves any number of searches in one call, one at a time.
  #
  # WARNING: A workspace belongs to one fiber.
  class PikeVM
    # A slot that holds no position.
    UNSET = -1_i64

    # Returns the bytes a workspace for *program* with *slot_count* slots
    # takes (`Program.pike_workspace_bytes`).
    def self.workspace_bytes(program : Program, slot_count : Int32) : Int64
      Program.pike_workspace_bytes(program.state_count.to_i64, slot_count.to_i64)
    end

    # The slots this workspace tracks: 2 for a span search (group 0), or
    # the program's full `slot_count`.
    getter slot_count : Int32

    @state_count : Int32
    @current_slots : Pointer(Int64)
    @next_slots : Pointer(Int64)
    @current_dense : Pointer(UInt32)
    @current_sparse : Pointer(UInt32)
    @next_dense : Pointer(UInt32)
    @next_sparse : Pointer(UInt32)
    @stack : Pointer(Int64)
    @scratch : Pointer(Int64)
    @current_size = 0
    @next_size = 0

    def initialize(@program : Program, @slot_count : Int32)
      states = @state_count = @program.state_count
      slots_per_thread = @slot_count
      # One buffer, in 8-byte words: 2·m·c slots, 4·m UInt32 set entries
      # (2·m words), m two-word stack frames, and c scratch slots.
      words = 2_i64 * states * slots_per_thread + 2_i64 * states + 2_i64 * states + slots_per_thread
      buffer = Pointer(Int64).malloc(words)
      @current_slots = buffer
      @next_slots = buffer + states.to_i64 * slots_per_thread
      sets = (buffer + 2_i64 * states * slots_per_thread).as(Pointer(UInt32))
      @current_dense = sets
      @current_sparse = sets + states
      @next_dense = sets + 2 * states
      @next_sparse = sets + 3 * states
      @stack = buffer + 2_i64 * states * slots_per_thread + 2_i64 * states
      @scratch = @stack + 2_i64 * states
    end

    # Searches *haystack* for the leftmost-first match that starts at a
    # character boundary in *start*..*end_bound* (only at *start* when
    # *anchored*) and reads no byte at or after *end_bound*; assertions see
    # the whole haystack. *search_start* is where `\G` holds. With
    # *earliest*, stops at the first match state reached (for `matches?`).
    # An unanchored search starts no thread after *first_line_end* (the
    # `CompileOptions::FirstLine` bound, `Int32::MAX` without it).
    # Fills *slots* (at least `slot_count` entries) and returns true on a
    # match.
    def search(haystack : Bytes, start : Int32, end_bound : Int32, search_start : Int32, anchored : Bool,
               end_anchored : Bool, earliest : Bool, meter : SearchMeter, slots : Slice(Int64),
               first_line_end : Int32) : Bool
      slots_per_thread = @slot_count
      @current_size = 0
      @next_size = 0
      matched = false
      at = start
      while true
        if @current_size == 0 && (matched || (anchored && at > start))
          break
        end
        if !matched && (at == start || (!anchored && boundary?(haystack, at) && at <= first_line_end))
          slots_per_thread.times { |index| @scratch[index] = UNSET }
          closure(@program.start_state, at, haystack, search_start, meter, true)
        end
        index = 0
        while index < @current_size
          state_index = @current_dense[index].to_i32
          index += 1
          meter.charge(1, at)
          state = @program.list_of_states.unsafe_fetch(state_index)
          case state.kind
          when .match?
            next if end_anchored && at != haystack.size
            row = @current_slots + state_index.to_i64 * slots_per_thread
            slots_per_thread.times { |slot| slots[slot] = row[slot] }
            matched = true
            return true if earliest
            break
          when .byte_range?
            next if at >= end_bound
            byte = haystack.unsafe_fetch(at)
            next unless state.low <= byte <= state.high
            load_scratch(state_index, meter, at)
            closure(state.next_state, at + 1, haystack, search_start, meter, false)
          when .sparse?
            next if at >= end_bound
            target = @program.sparse_target(state, haystack.unsafe_fetch(at))
            next if target < 0
            load_scratch(state_index, meter, at)
            closure(target, at + 1, haystack, search_start, meter, false)
          end
        end
        break if at >= end_bound
        swap_lists
        at += 1
      end
      matched
    end

    private def boundary?(haystack : Bytes, at : Int32) : Bool
      at >= haystack.size || haystack.unsafe_fetch(at) & 0xC0 != 0x80
    end

    # Copies the slots of the thread at *state_index* into the scratch
    # vector, the parent of the closure that follows.
    private def load_scratch(state_index : Int32, meter : SearchMeter, at : Int32) : Nil
      slots_per_thread = @slot_count
      meter.charge(slots_per_thread, at)
      @scratch.copy_from(@current_slots + state_index.to_i64 * slots_per_thread, slots_per_thread)
    end

    # Adds the epsilon closure of *state_index* at *at*, with the scratch
    # vector as its slots, to the current list (*seed*, a new thread at
    # this position, lowest priority) or to the next list. Depth-first in
    # priority order with an explicit stack: a split pushes its second
    # branch and follows its first, and a slot save pushes a frame that
    # restores the slot when the branch is done.
    private def closure(state_index : Int32, at : Int32, haystack : Bytes, search_start : Int32,
                        meter : SearchMeter, seed : Bool) : Nil
      dense = seed ? @current_dense : @next_dense
      sparse = seed ? @current_sparse : @next_sparse
      table = seed ? @current_slots : @next_slots
      size = seed ? @current_size : @next_size
      slots_per_thread = @slot_count
      depth = 0
      push_explore(depth, state_index)
      depth += 1
      while depth > 0
        depth -= 1
        frame_state = @stack[depth * 2]
        if frame_state < 0
          # A restore frame: slot -(state + 1) gets its saved value back.
          @scratch[-(frame_state + 1)] = @stack[depth * 2 + 1]
          next
        end
        current = frame_state.to_i32
        while true
          member = sparse[current]
          if member < size && dense[member] == current
            state = @program.list_of_states.unsafe_fetch(current)
            break
          end
          sparse[current] = size.to_u32
          dense[size] = current.to_u32
          size += 1
          meter.charge(1, at)
          state = @program.list_of_states.unsafe_fetch(current)
          case state.kind
          when .byte_range?, .sparse?, .match?
            meter.charge(slots_per_thread, at)
            (table + current.to_i64 * slots_per_thread).copy_from(@scratch, slots_per_thread)
            break
          when .split?
            push_explore(depth, state.alternate)
            depth += 1
            current = state.next_state
          when .save?
            slot = state.argument
            if slot < slots_per_thread
              @stack[depth * 2] = -(slot.to_i64 + 1)
              @stack[depth * 2 + 1] = @scratch[slot]
              depth += 1
              @scratch[slot] = at.to_i64
            end
            current = state.next_state
          when .look?
            break unless Look.holds?(Program::LookKind.new(state.argument), haystack, at, search_start)
            current = state.next_state
          else
            break
          end
        end
      end
      if seed
        @current_size = size
      else
        @next_size = size
      end
    end

    private def push_explore(depth : Int32, state_index : Int32) : Nil
      @stack[depth * 2] = state_index.to_i64
    end

    private def swap_lists : Nil
      @current_slots, @next_slots = @next_slots, @current_slots
      @current_dense, @next_dense = @next_dense, @current_dense
      @current_sparse, @next_sparse = @next_sparse, @current_sparse
      @current_size = @next_size
      @next_size = 0
    end
  end
end
