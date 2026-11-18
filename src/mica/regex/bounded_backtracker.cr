module Mica::Regex
  # The bounded backtracker (RE2's BitState): a depth-first search in
  # leftmost-first priority order that marks every (state, position) pair
  # it visits in a bitset and never visits one twice. A pair that was
  # visited and did not lead to a match cannot lead to one later, because
  # whether a state matches from a position does not depend on the
  # captures recorded on the way there.
  #
  # It runs only when the bitset is small and its memory fits: `fits?`
  # requires m × (L + 1) ≤ `MAX_VISITED_BITS` for m states over a span of
  # L bytes, and `allocation_charge` within the program's
  # `Program#backtracker_allowance` (what the Pike VM workspace leaves of
  # `CompileLimits#max_pike_bytes`).
  #
  # **Bounds.** Time O(m·(L + 1) + c): each pair is visited once and each
  # visit pushes at most one job (a second branch or a slot restore).
  # Memory: m·(L + 1)/8 bytes of bitset, a job stack of m·(L + 1) + 1
  # entries of 16 bytes (allocated at that size, so it never grows during
  # a search), and c slots; `allocation_charge` counts them as the
  # collector hands them out.
  #
  # Each visit and each slot undo entry is charged one operation to the
  # `SearchMeter`.
  #
  # WARNING: A backtracker belongs to one fiber.
  class BoundedBacktracker
    # The largest visited bitset, in bits (256 Ki bits, 32 KiB).
    MAX_VISITED_BITS = 256_i64 * 1024

    # Returns true when a search of *program* over a span of *span_bytes*
    # bytes fits the bitset gate.
    def self.fits?(program : Program, span_bytes : Int32) : Bool
      return false unless visited_bits(program, span_bytes) <= MAX_VISITED_BITS
      allocation_charge(program, span_bytes) <= program.backtracker_allowance
    end

    # Returns the bytes the collector hands out for a backtracker of
    # *program* searching a span of *span_bytes* bytes: the bitset, the job
    # stack, the slots and this object, each rounded up to the collector's
    # granule (`AllocationLedger.granules`).
    def self.allocation_charge(program : Program, span_bytes : Int32) : Int64
      bits = visited_bits(program, span_bytes)
      bitset = AllocationLedger.granules((bits + 63) // 64 * 8)
      jobs = AllocationLedger.granules((bits + 1) * sizeof(Job))
      slots = AllocationLedger.granules(program.slot_count.to_i64 * sizeof(Int64))
      bitset + jobs + slots + AllocationLedger.granules(instance_sizeof(BoundedBacktracker))
    end

    private def self.visited_bits(program : Program, span_bytes : Int32) : Int64
      program.state_count.to_i64 * (span_bytes.to_i64 + 1)
    end

    # A job: explore *state* at *at*, or (when *state* is negative) restore
    # slot -(state + 1) to the value *at*.
    private record Job, state : Int32, at : Int64

    @slots : Slice(Int64)
    @visited : Slice(UInt64)
    # The job stack: @job_capacity entries, the first @job_count in use.
    @jobs : Pointer(Job) = Pointer(Job).null
    @job_capacity = 0_i64
    @job_count = 0_i64

    def initialize(@program : Program, @slot_count : Int32)
      @slots = Slice(Int64).new(@slot_count, PikeVM::UNSET)
      @visited = Slice(UInt64).new(0)
    end

    # Searches like `PikeVM#search`, over *start*..*end_bound*, which must
    # satisfy `fits?`, with the same *first_line_end* bound. Fills *slots*
    # and returns true on a match.
    def search(haystack : Bytes, start : Int32, end_bound : Int32, search_start : Int32, anchored : Bool,
               end_anchored : Bool, meter : SearchMeter, slots : Slice(Int64),
               first_line_end : Int32) : Bool
      span = end_bound - start
      unless BoundedBacktracker.fits?(@program, span)
        raise ArgumentError.new("A span of #{span} bytes does not fit the backtracker's bitset")
      end
      columns = span + 1
      bits = @program.state_count.to_i64 * columns
      words = ((bits + 63) // 64).to_i32
      if @visited.size < words
        GC.free(@visited.to_unsafe.as(Void*)) unless @visited.empty?
        @visited = Slice(UInt64).new(words, 0_u64)
      else
        @visited.fill(0_u64, 0, words)
      end
      # Each visit pushes at most one job, after the one each start pushes.
      if @job_capacity < bits + 1
        GC.free(@jobs.as(Void*)) unless @jobs.null?
        @jobs = Pointer(Job).malloc(bits + 1)
        @job_capacity = bits + 1
      end
      at = start
      while at <= end_bound
        if at == start || (!anchored && boundary?(haystack, at) && at <= first_line_end)
          @slots.fill(PikeVM::UNSET)
          if explore_from(haystack, start, columns, at, end_bound, search_start, end_anchored, meter)
            @slot_count.times { |slot| slots[slot] = @slots[slot] }
            return true
          end
        end
        break if anchored
        at += 1
      end
      false
    end

    private def explore_from(haystack : Bytes, start : Int32, columns : Int32, from : Int32, end_bound : Int32,
                             search_start : Int32, end_anchored : Bool, meter : SearchMeter) : Bool
      @job_count = 0_i64
      push_job(@program.start_state, from.to_i64)
      while @job_count > 0
        @job_count -= 1
        job = @jobs[@job_count]
        if job.state < 0
          @slots[-(job.state + 1)] = job.at
          next
        end
        current = job.state
        at = job.at.to_i32
        while true
          bit = current.to_i64 * columns + (at - start)
          word = bit >> 6
          mask = 1_u64 << (bit & 63)
          if @visited[word] & mask != 0
            state = @program.list_of_states.unsafe_fetch(current)
            break
          end
          @visited[word] |= mask
          meter.charge(1, at)
          state = @program.list_of_states.unsafe_fetch(current)
          case state.kind
          when .byte_range?
            break unless at < end_bound
            byte = haystack.unsafe_fetch(at)
            break unless state.low <= byte <= state.high
            current = state.next_state
            at += 1
          when .sparse?
            break unless at < end_bound
            target = @program.sparse_target(state, haystack.unsafe_fetch(at))
            break if target < 0
            current = target
            at += 1
          when .split?
            push_job(state.alternate, at.to_i64)
            current = state.next_state
          when .save?
            slot = state.argument
            if slot < @slot_count
              meter.charge(1, at)
              push_job(-(slot + 1), @slots[slot])
              @slots[slot] = at.to_i64
            end
            current = state.next_state
          when .look?
            break unless Look.holds?(Program::LookKind.new(state.argument), haystack, at, search_start)
            current = state.next_state
          when .match?
            break if end_anchored && at != haystack.size
            return true
          else
            break
          end
        end
      end
      false
    end

    # Pushes a job. The stack was allocated for one job per possible visit
    # plus one, so running past it would be a defect, reported as one.
    private def push_job(state : Int32, at : Int64) : Nil
      if @job_count >= @job_capacity
        raise Mica::Error.new("internal error: the backtracker pushed more jobs than its #{@job_capacity} entries")
      end
      @jobs[@job_count] = Job.new(state, at)
      @job_count += 1
    end

    private def boundary?(haystack : Bytes, at : Int32) : Bool
      at >= haystack.size || haystack.unsafe_fetch(at) & 0xC0 != 0x80
    end
  end
end
