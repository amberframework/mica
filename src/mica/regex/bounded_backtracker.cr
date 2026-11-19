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
  # Memory: m·(L + 1)/8 bytes of bitset, a job stack of at most
  # m·(L + 1) + 1 entries of 16 bytes, and c slots; `allocation_charge`
  # counts them as the collector hands them out. The job stack grows as a
  # search needs it, in chunks that double in size (`FIRST_JOB_CHUNK`
  # entries, then twice as many, and so on), the last one cut so the stack
  # never holds more than m·(L + 1) + 1 entries for the longest span it has
  # searched. A chunk is never copied or moved, so the stack never holds
  # more than that bound plus one granule per chunk, and a search that
  # needs few jobs allocates few.
  #
  # Each visit and each slot undo entry is charged one operation to the
  # `SearchMeter`.
  #
  # WARNING: A backtracker belongs to one fiber.
  class BoundedBacktracker
    # The largest visited bitset, in bits (256 Ki bits, 32 KiB).
    MAX_VISITED_BITS = 256_i64 * 1024
    # Entries in the first chunk of the job stack (4 KiB).
    FIRST_JOB_CHUNK = 256_i64
    # The most chunks the job stack has: the doubling chunks reach
    # `MAX_VISITED_BITS` + 1 entries within 11, whatever was cut before.
    MAX_JOB_CHUNKS = 16

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
      # Every chunk adds at most one granule to the entries it holds.
      jobs = AllocationLedger.granules((bits + 1) * sizeof(Job)) + (MAX_JOB_CHUNKS - 1) * AllocationLedger::GRANULE
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
    # The job stack: @chunk_count chunks allocated, holding @job_capacity
    # entries in all; the jobs in use fill the chunks before @chunk_index
    # and the first @in_chunk entries of @chunk (chunk @chunk_index, of
    # @chunk_size entries).
    @list_of_chunks = StaticArray(Pointer(Job), MAX_JOB_CHUNKS).new(Pointer(Job).null)
    @list_of_chunk_sizes = StaticArray(Int64, MAX_JOB_CHUNKS).new(0_i64)
    @chunk_count = 0
    @job_capacity = 0_i64
    # The most jobs the current search may hold (m·(L + 1) + 1).
    @job_limit = 0_i64
    @job_count = 0_i64
    @chunk = Pointer(Job).null
    @chunk_index = -1
    @chunk_size = 0_i64
    @in_chunk = 0_i64
    # The most visits one search may make before it gives up (see
    # `gave_up?`); unlimited unless set.
    setter visit_limit : Int64 = Int64::MAX
    @visits_left = Int64::MAX
    # True when the last search reached `visit_limit` before it decided.
    getter? gave_up = false

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
      limit_jobs(bits + 1)
      @visits_left = @visit_limit
      @gave_up = false
      at = start
      while at <= end_bound
        if at == start || (!anchored && boundary?(haystack, at) && at <= first_line_end)
          @slots.fill(PikeVM::UNSET)
          if explore_from(haystack, start, columns, at, end_bound, search_start, end_anchored, meter)
            @slot_count.times { |slot| slots[slot] = @slots[slot] }
            return true
          end
          return false if @gave_up
        end
        break if anchored
        at += 1
      end
      false
    end

    private def explore_from(haystack : Bytes, start : Int32, columns : Int32, from : Int32, end_bound : Int32,
                             search_start : Int32, end_anchored : Bool, meter : SearchMeter) : Bool
      clear_jobs
      push_job(@program.start_state, from.to_i64)
      while @job_count > 0
        job = pop_job
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
          visited = @visited.to_unsafe + word
          break if visited.value & mask != 0
          visited.value |= mask
          if (@visits_left -= 1) < 0
            @gave_up = true
            return false
          end
          meter.charge(1, at)
          state = @program.state_at(current)
          case state.kind
          when .byte_range?
            break unless at < end_bound
            byte = haystack.unsafe_fetch(at)
            break unless state.low <= byte <= state.high
            current = state.next_state
            at += 1
          when .sparse?
            break unless at < end_bound
            target = @program.sparse_target(current, state, haystack.unsafe_fetch(at))
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

    # Sets the most jobs a search may hold to *limit*. The stack is empty
    # between searches, so a last chunk cut short for a smaller limit is
    # freed, to be allocated again at the size this limit allows.
    private def limit_jobs(limit : Int64) : Nil
      @job_limit = limit
      last = @chunk_count - 1
      return unless last >= 0 && @job_capacity < limit && @list_of_chunk_sizes[last] < FIRST_JOB_CHUNK << last
      GC.free(@list_of_chunks[last].as(Void*))
      @job_capacity -= @list_of_chunk_sizes[last]
      @list_of_chunks[last] = Pointer(Job).null
      @list_of_chunk_sizes[last] = 0_i64
      @chunk_count = last
    end

    private def clear_jobs : Nil
      @job_count = 0_i64
      @chunk = Pointer(Job).null
      @chunk_index = -1
      @chunk_size = 0_i64
      @in_chunk = 0_i64
    end

    # Pushes a job, moving to the next chunk (allocating it the first time)
    # when the current one is full.
    @[AlwaysInline]
    private def push_job(state : Int32, at : Int64) : Nil
      next_chunk if @in_chunk == @chunk_size
      @chunk[@in_chunk] = Job.new(state, at)
      @in_chunk += 1
      @job_count += 1
    end

    # Pops the last job; the stack must not be empty.
    @[AlwaysInline]
    private def pop_job : Job
      if @in_chunk == 0
        @chunk_index -= 1
        @chunk = @list_of_chunks[@chunk_index]
        @chunk_size = @list_of_chunk_sizes[@chunk_index]
        @in_chunk = @chunk_size
      end
      @in_chunk -= 1
      @job_count -= 1
      @chunk[@in_chunk]
    end

    # Moves to the next chunk, allocating it when needed. Each visit pushes
    # at most one job, after the one each start pushes, so a stack that
    # would pass the search's limit is a defect, reported as one.
    private def next_chunk : Nil
      index = @chunk_index + 1
      if index == @chunk_count
        room = @job_limit - @job_capacity
        if room <= 0 || index >= MAX_JOB_CHUNKS
          raise Mica::Error.new("internal error: the backtracker pushed more than its #{@job_limit} jobs")
        end
        size = Math.min(FIRST_JOB_CHUNK << index, room)
        @list_of_chunks[index] = Pointer(Job).malloc(size)
        @list_of_chunk_sizes[index] = size
        @job_capacity += size
        @chunk_count += 1
      end
      @chunk_index = index
      @chunk = @list_of_chunks[index]
      @chunk_size = @list_of_chunk_sizes[index]
      @in_chunk = 0_i64
    end

    private def boundary?(haystack : Bytes, at : Int32) : Bool
      at >= haystack.size || haystack.unsafe_fetch(at) & 0xC0 != 0x80
    end
  end
end
