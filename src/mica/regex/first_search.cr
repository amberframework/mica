module Mica::Regex
  # :nodoc:
  # The engine for a program's first single searches
  # (`Expression#match_at_byte_index` and `#matches_at_byte_index?`): the
  # bounded backtracker over the haystack, with no `SearchPlan`, lease,
  # lazy-DFA cache or reverse NFA built (see "First searches" in
  # docs/regex.md).
  #
  # Building a plan costs more than a search of a small haystack does on
  # the backtracker (the start filter, the byte classes and the reverse
  # NFA of a pattern with `\w` come to tens of microseconds, the search to
  # well under one), so an expression compiled and searched once pays for
  # what that search uses and no more. Once a program has had `SEARCHES`
  # first searches, its later searches take the usual path and build the
  # plan, whose automata pay for themselves over many searches.
  #
  # A first search runs only where the backtracker's whole cost is known
  # to fit before the haystack is read: its bitset gate
  # (`BoundedBacktracker.fits?`) for the span from the offset to the end,
  # and the call's work allowance for validation plus every visit and
  # slot write the backtracker can make, so it never stops on `max_work`
  # where it began. The deadline is read before the haystack, as on every
  # path. The search is O(m·(L + 1) + c) and allocates the backtracker's
  # bitset (at most 32 KiB).
  module FirstSearch
    # How many single searches of a program run here before it builds its
    # plan.
    SEARCHES = 2
    # The longest span from the offset a first search reads: past it the
    # backtracker's visits cost more than the plan would.
    MAX_BYTES = 256
    # The same for a program whose matches start with a literal: its plan
    # is cheap, and its prefilter skips to the literals faster than the
    # backtracker tries each start.
    MAX_LITERAL_BYTES = 64

    # Visits a first search may make, as a fixed part and a part per state:
    # building a plan costs about as much as this many visits, so a
    # backtracker that has not decided by then hands the search to the
    # plan (see `Searcher.first_search`) having spent at most about what
    # the plan costs.
    VISITS_BASE      = 256_i64
    VISITS_PER_STATE =   8_i64

    # The most visits a first search of *program* makes on the
    # backtracker.
    def self.visit_limit(program : Program) : Int64
      VISITS_BASE + VISITS_PER_STATE * program.state_count
    end

    # True when this search of *program* over *haystack* from *byte_index*
    # should run on the backtracker, counting it as one of the program's
    # first searches. Reads nothing of the haystack.
    def self.applies?(program : Program, haystack : String, byte_index : Int32, limits : SearchLimits) : Bool
      return false unless program.first_searches_left?
      return false if byte_index < 0 || byte_index > haystack.bytesize
      span = haystack.bytesize - byte_index
      return false if span > (program.literal_set ? MAX_LITERAL_BYTES : MAX_BYTES)
      return false unless BoundedBacktracker.fits?(program, span)
      return false unless fits_allowance?(program, haystack.bytesize, span, limits)
      program.count_first_search
    end

    # True when validating *haystack_bytes* bytes, the scans for the
    # required bytes (`Searcher#required_byte_missing?`, at most one pass
    # each over *span* bytes) and the most work the backtracker can do
    # over the span (one operation per visit and one per slot write, at
    # most one of each per (state, position) pair) fit the call's
    # allowance.
    private def self.fits_allowance?(program : Program, haystack_bytes : Int32, span : Int32,
                                     limits : SearchLimits) : Bool
      visits = program.state_count.to_i64 * (span.to_i64 + 1)
      scans = StartFilter::MAX_REQUIRED_BYTES.to_i64 * span
      needed = haystack_bytes.to_i64 + scans + 2_i64 * visits
      needed <= limits.max_work(program.state_count, haystack_bytes.to_i64)
    end
  end
end
