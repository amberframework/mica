module Mica::Regex
  # Counts the bytes one compilation allocates and refuses the allocation
  # that would pass `CompileLimits#max_compile_bytes`.
  #
  # Every structure the compiler builds (syntax nodes, child lists, class
  # range arrays, `Hir` nodes) is charged here *before* it is allocated,
  # with its real size (`instance_sizeof` for objects, element size times
  # capacity for arrays), so a refused pattern has allocated at most one
  # charge past its limit.
  #
  # WARNING: A ledger belongs to one compilation and one fiber.
  class AllocationLedger
    # Bytes charged so far.
    getter bytes : Int64 = 0_i64

    # The limit enforced.
    getter limit : Int64

    def initialize(@limit : Int64)
    end

    # Charges *count* bytes for *what*, an allocation about to happen at
    # *offset* in the pattern. Raises `CompileLimitError` naming
    # `max_compile_bytes` when the total would pass the limit.
    def charge(count : Int, what : String, offset : Int32) : Nil
      raise ArgumentError.new("Negative allocation charge: #{count}") if count < 0
      total = @bytes &+ count
      if total > @limit || total < @bytes
        raise CompileLimitError.new("max_compile_bytes", @limit, "Allocating #{what} (#{count} bytes after #{@bytes})",
          Core::Position.new(offset.to_i64))
      end
      @bytes = total
    end

    # Charges an array of *capacity* elements of *element_bytes* each.
    def charge_array(capacity : Int, element_bytes : Int, what : String, offset : Int32) : Nil
      raise ArgumentError.new("Negative capacity: #{capacity}") if capacity < 0
      count = capacity.to_i64 * element_bytes
      charge(count, what, offset)
    end
  end
end
