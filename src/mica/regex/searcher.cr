module Mica::Regex
  # :nodoc:
  # Which engines a `Searcher` may run. `Auto` is what the public API uses;
  # the others let specs, the fuzzers and the benchmarks force one path.
  enum Engine
    # Every engine (see `SearchPlan`): literal search and the prefilter,
    # the lazy DFAs, the one-pass DFA, with the R2 engines as fallbacks.
    Auto
    # As `Auto` with the literal accelerators off: the lazy DFAs and the
    # one-pass DFA, with the R2 engines as fallbacks.
    NoAccelerators
    # Milestone R2's two phases: a capture-free Pike VM pass finds the
    # span; when captures are wanted, the bounded backtracker (when the
    # span fits its bitset) or a Pike VM with every slot runs again over
    # the span alone.
    TwoPhase
    # One Pike VM pass with every capture slot.
    PikeVM
    # One bounded backtracker pass over the whole haystack (it must fit).
    Backtracker
    # As `NoAccelerators`, with every unanchored search of a program whose
    # matches are short (`SearchPlan#short_match`) made from each start
    # (`LazyDFA#find_from_each_start`), as `Auto` does once its forward
    # cache thrashes. For the differential fuzzers.
    EachStart
    # As `NoAccelerators`, with every match start found by the reverse DFA
    # reading each class backward through its `ReversedClass`, the reverse
    # DFA `Auto` widens to when its states grow wide. For the differential
    # fuzzers and the conformance replay.
    ReversedClasses

    # True when the engine may use the lazy DFAs and the one-pass DFA.
    def automata? : Bool
      auto? || no_accelerators? || each_start? || reversed_classes?
    end
  end

  # :nodoc:
  # Runs the searches of one call over one haystack: it validates the
  # haystack once, holds the call's `SearchMeter`, leases the program's
  # lazy-DFA caches for the call, and keeps its engine workspaces for the
  # searches that follow (as `scan` and `gsub` make).
  #
  # **Phase 1** finds the leftmost-first span `[s, e)` on the fastest path
  # `SearchPlan` allows: a literal search, or the forward lazy DFA (with
  # the prefilter skipping ahead in its start state) for `e` and the
  # reverse lazy DFA for `s` (widened to read classes backward once its
  # states grow wide, see `ReversedClass`; for a program whose matches are
  # short, the forward DFA run anchored from each start, see `ShortMatch`,
  # takes over while either cache thrashes); or, when the DFAs do not apply
  # or give up, a
  # Pike VM tracking only group 0, in O(m·(n + 1)). Once a DFA gives up in
  # a call, the call's later searches go straight to the Pike VM, so a
  # thrashing cache costs its bounded work once. Once the prefilter has
  # proved ineffective (`PrefilterScan#ineffective?`), the call stops
  # using it.
  #
  # **Phase 2** runs only when captures are asked for, anchored at s and
  # reading no byte at or after e: the highest-priority match that starts
  # at s still ends at e when bytes past e are cut off, because cutting
  # bytes only removes matches. The one-pass DFA reads it in O(L + c) when
  # the pattern is one-pass; otherwise the backtracker costs
  # O(m·(L + 1) + c) and the Pike VM O(m·c·(L + 1)), for L = e − s.
  #
  # **First line.** Under `CompileOptions::FirstLine` an unanchored search
  # starts no match after the first line feed at or after its offset. The
  # searcher scans for that line feed once and reuses it while the offsets
  # of later searches stay at or before it, so an iteration call scans each
  # byte at most once; every byte scanned is charged one operation.
  #
  # **One workspace.** The searcher holds at most one `PikeVM` workspace:
  # the span layout while only spans are asked for, the capture layout
  # (which also runs span searches) once captures are, releasing the span
  # workspace first. Beside it lives at most one `BoundedBacktracker`, sized
  # within `Program#backtracker_allowance`, so everything a search holds
  # stays within `CompileLimits#max_pike_bytes`. The lazy-DFA caches are
  # bounded by their `CachePool`.
  #
  # Call `finish` when the call is done, so the next call reuses the warm
  # caches and workspaces; a searcher that is never finished only loses
  # that reuse.
  #
  # WARNING: A searcher belongs to one call and one fiber.
  class Searcher
    # The call's meter.
    getter meter : SearchMeter
    # True once a lazy DFA gave up in this call (for specs).
    getter? dfa_gave_up = false
    # Which path found the last span (for specs and the benchmarks).
    getter last_path : Path = Path::None

    # The phase-1 paths.
    enum Path
      None
      Literal
      LazyDFA
      PikeVM
      Backtracker
    end

    @pike : PikeVM? = nil
    @backtracker : BoundedBacktracker? = nil
    @span_slots = Slice(Int64).new(2, PikeVM::UNSET)
    @capture_slots : Slice(Int64)
    # The last first-line scan: it started at @line_scan_start and found
    # the line feed (or the haystack end) at @line_feed_at.
    @line_scan_start = -1
    @line_feed_at = -1
    @plan : SearchPlan?
    @lease : SearchLease?
    @scan : PrefilterScan?
    @prefilter_off = false
    # Searches started in this call (see `check_resumed_deadline`).
    @searches_started = 0
    # The forward cache's counters when this search retried the unanchored
    # DFA (see `from_each_start?`).
    @retry_from : {Int64, Int64}? = nil
    # The same for the reverse cache (see `reverse_thrashing?`).
    @reverse_retry_from : {Int64, Int64}? = nil

    def initialize(@program : Program, @haystack : String, limits : SearchLimits, timeout : Time::Span?,
                   @engine : Engine = Engine::Auto, @cache_pool : CachePool = CachePool.default,
                   lease : SearchLease? = nil)
      @meter = SearchMeter.new(limits, @program.state_count, @haystack.bytesize, timeout)
      @capture_slots = Slice(Int64).new(@program.slot_count, PikeVM::UNSET)
      if @engine.automata?
        plan = @plan = @program.plan
        attach(lease || plan.lease(@cache_pool))
      end
      begin_call_or_finish
    end

    # Returns a searcher for one call of the default path over *haystack*:
    # the one the program's lease kept from an earlier call, started over,
    # or a new one. Pair it with `finish`.
    def self.open(program : Program, haystack : String, limits : SearchLimits, timeout : Time::Span?,
                  cache_pool : CachePool) : Searcher
      lease = program.plan.lease(cache_pool)
      if searcher = lease.take_searcher
        searcher.resume(lease, haystack, limits, timeout)
        searcher
      else
        new(program, haystack, limits, timeout, Engine::Auto, cache_pool, lease)
      end
    end

    # Starts this (finished) searcher over for a new call on *lease*.
    protected def resume(lease : SearchLease, @haystack : String, limits : SearchLimits, timeout : Time::Span?) : Nil
      @meter.restart(limits, @program.state_count, @haystack.bytesize, timeout)
      @line_scan_start = -1
      @line_feed_at = -1
      @scan.try(&.reset(@haystack.to_slice))
      @prefilter_off = false
      @searches_started = 0
      @dfa_gave_up = false
      @last_path = Path::None
      @cache_pool = lease.pool
      attach(lease)
      begin_call_or_finish
    end

    private def attach(lease : SearchLease) : Nil
      @lease = lease
      @pike = lease.take_pike
      @backtracker = lease.take_backtracker
    end

    # Starts the call; when that raises (an invalid haystack, a deadline
    # already passed, a validation charge over the budget), gives the lease
    # back first, so its caches return to the pool idle and evictable.
    private def begin_call_or_finish : Nil
      begin_call
    rescue error
      finish
      raise error
    end

    # Validates the haystack (unless the lease validated this very string)
    # and reads the deadline.
    private def begin_call : Nil
      lease = @lease
      unless lease && lease.validated?(@haystack)
        # Validation reads every byte once: one operation per byte. A lease
        # remembers the last `String` it validated, so an iteration of
        # separate calls over one haystack validates it once.
        bytes = @haystack.to_slice
        @meter.charge(bytes.size, 0)
        if offset = Core::UTF8.first_invalid_offset(bytes)
          raise Mica::EncodingError.new("The haystack is not valid UTF-8", Core::Position.new(offset.to_i64))
        end
        lease.try(&.remember_validated(@haystack))
      end
      # The deadline is read at the start of every call, so a timeout that
      # has already passed fails even a search too short to reach a clock
      # checkpoint.
      @meter.enforce_deadline(0)
    end

    # True once the prefilter proved ineffective in this call (for specs).
    def prefilter_off? : Bool
      @prefilter_off || !!@scan.try(&.ineffective?)
    end

    # Hands the leased caches back to the program for later calls. Without
    # a lease (an engine other than `Auto` or `NoAccelerators`), releases
    # the Pike VM workspace, so its charge goes back to the pool now.
    def finish : Nil
      if (lease = @lease) && (plan = @plan)
        @lease = nil
        lease.keep(@pike, @backtracker, @engine.auto? ? self : nil)
        @pike = nil
        @backtracker = nil
        plan.give_back(lease)
      elsif pike = @pike
        @pike = nil
        pike.release
      end
    end

    # Returns the slots of the leftmost-first match at or after
    # *byte_index* (group 0 only unless *captures*), or nil. Raises
    # `ArgumentError` when *byte_index* is negative or inside a character.
    def find(byte_index : Int32, options : MatchOptions, captures : Bool) : Slice(Int64)?
      check_resumed_deadline(byte_index)
      bytes = @haystack.to_slice
      return nil if byte_index > bytes.size
      check_start(bytes, byte_index)
      anchored = @program.options.anchored? || options.anchored? || anchored_start?
      end_anchored = @program.options.end_anchored? || options.end_anchored?
      case @engine
      in .pike_vm?
        slots = @capture_slots
        want_captures = @program.slot_count > 2
        @last_path = Path::PikeVM
        found = pike(want_captures).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, false,
          @meter, slots, first_line_end(bytes, byte_index, anchored), want_captures)
        found ? slots : nil
      in .backtracker?
        slots = @capture_slots
        @last_path = Path::Backtracker
        found = backtracker.search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, @meter, slots,
          first_line_end(bytes, byte_index, anchored))
        found ? slots : nil
      in .auto?, .no_accelerators?, .two_phase?, .each_start?, .reversed_classes?
        find_in_two_phases(bytes, byte_index, anchored, end_anchored, captures)
      end
    end

    # Returns true when anything matches at or after *byte_index*; stops at
    # the first match it reaches.
    def matches?(byte_index : Int32, options : MatchOptions) : Bool
      check_resumed_deadline(byte_index)
      bytes = @haystack.to_slice
      return false if byte_index > bytes.size
      check_start(bytes, byte_index)
      anchored = @program.options.anchored? || options.anchored? || anchored_start?
      end_anchored = @program.options.end_anchored? || options.end_anchored?
      if dfa = automaton(end_anchored)
        if literal_search?(anchored)
          return literal_span(bytes, byte_index)
        end
        lease = @lease || raise Mica::Error.new("internal error: no lease")
        if cache = lease.forward_cache(dfa)
          unless from_each_start?(cache, anchored)
            found = dfa.find_end(cache, bytes, byte_index, anchored, true, prefilter_scan(bytes, anchored), @meter)
            judge_retry(cache)
            return found >= 0 unless found == LazyDFA::GAVE_UP
          end
          if !anchored && (short_match = @plan.try(&.short_match))
            start, _ = dfa.find_from_each_start(cache, bytes, byte_index, true, short_match, @meter)
            return start >= 0 unless start == LazyDFA::GAVE_UP
          end
        end
        @dfa_gave_up = true
      end
      pike(false).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, true, @meter, @span_slots,
        first_line_end(bytes, byte_index, anchored), false)
    end

    private def find_in_two_phases(bytes : Bytes, byte_index : Int32, anchored : Bool, end_anchored : Bool,
                                   captures : Bool) : Slice(Int64)?
      span = @span_slots
      want_captures = captures && @program.slot_count > 2
      return nil unless find_span(bytes, byte_index, anchored, end_anchored, span, want_captures)
      return span unless want_captures
      start = span[0].to_i32
      finish = span[1].to_i32
      slots = @capture_slots
      found = false
      if @engine.automata? && (one_pass = @program.plan.one_pass)
        found = one_pass.captures(bytes, start, finish, byte_index, slots, @meter)
      end
      unless found
        found = if BoundedBacktracker.fits?(@program, finish - start)
                  backtracker.search(bytes, start, finish, byte_index, true, end_anchored, @meter, slots, Int32::MAX)
                else
                  pike(true).search(bytes, start, finish, byte_index, true, end_anchored, false, @meter, slots,
                    Int32::MAX, true)
                end
      end
      unless found && slots[0] == span[0] && slots[1] == span[1]
        raise Mica::Error.new("internal error: the capture pass did not find the span #{start}...#{finish}")
      end
      slots
    end

    # Finds the span of the leftmost-first match into *span*; returns
    # false when there is none.
    # A Pike VM span pass runs in the capture layout when *capture_layout*
    # (the capture pass will need it), so only one workspace is ever made.
    private def find_span(bytes : Bytes, byte_index : Int32, anchored : Bool, end_anchored : Bool,
                          span : Slice(Int64), capture_layout : Bool) : Bool
      if dfa = automaton(end_anchored)
        if literal_search?(anchored)
          @last_path = Path::Literal
          return literal_span(bytes, byte_index)
        end
        lease = @lease || raise Mica::Error.new("internal error: no lease")
        cache = lease.forward_cache(dfa)
        finish = if cache.nil? || from_each_start?(cache, anchored)
                   LazyDFA::GAVE_UP
                 else
                   dfa.find_end(cache, bytes, byte_index, anchored, false, prefilter_scan(bytes, anchored), @meter)
                 end
        judge_retry(cache) if cache
        return false if finish == LazyDFA::NO_MATCH
        if finish >= 0
          start = anchored ? byte_index : match_start(lease, dfa, cache, bytes, finish, byte_index)
          if start >= 0
            @last_path = Path::LazyDFA
            span[0] = start.to_i64
            span[1] = finish.to_i64
            return true
          end
        elsif cache && !anchored && (short_match = @plan.try(&.short_match))
          start, finish = dfa.find_from_each_start(cache, bytes, byte_index, false, short_match, @meter)
          return false if start == LazyDFA::NO_MATCH
          if start >= 0
            @last_path = Path::LazyDFA
            span[0] = start.to_i64
            span[1] = finish.to_i64
            return true
          end
        end
        @dfa_gave_up = true
      end
      @last_path = Path::PikeVM
      pike(capture_layout).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, false, @meter, span,
        first_line_end(bytes, byte_index, anchored), false)
    end

    # The start of the leftmost-first match that ends at *finish*, no lower
    # than *lower_bound*. When every match is short (`SearchPlan#short_match`)
    # it is the first start, from `ShortMatch#longest` bytes before
    # *finish*, where the forward DFA run anchored finds any match: no
    # earlier start has one, as the match is leftmost. Otherwise the
    # reverse DFA finds it.
    private def match_start(lease : SearchLease, dfa : LazyDFA, cache : DFACache?, bytes : Bytes, finish : Int32,
                            lower_bound : Int32) : Int32
      short_match = cache && !@engine.reversed_classes? ? @program.plan.short_match : nil
      if cache && short_match && (@engine.each_start? || reverse_thrashing?(lease))
        return start_from_each_start(dfa, cache, short_match, bytes, finish, lower_bound)
      end
      start = reverse_start(lease, bytes, finish, lower_bound)
      if start == LazyDFA::GAVE_UP && cache && short_match
        return start_from_each_start(dfa, cache, short_match, bytes, finish, lower_bound)
      end
      start
    end

    # The start of the match ending at *finish*: the first position, from
    # `ShortMatch#longest` bytes before it, where the forward DFA run
    # anchored reaches a match.
    private def start_from_each_start(dfa : LazyDFA, cache : DFACache, short_match : ShortMatch, bytes : Bytes,
                                      finish : Int32, lower_bound : Int32) : Int32
      from = Math.max(lower_bound, finish - short_match.longest)
      start, _ = dfa.find_from_each_start(cache, bytes, from, true, short_match, @meter)
      return start unless start == LazyDFA::NO_MATCH
      raise Mica::Error.new("internal error: no start found for the match ending at #{finish}")
    end

    # True when the reverse cache thrashes (`DFACache#thrashing?`) and this
    # is not one of its periodic retries, whose outcome `reverse_start`
    # reports.
    private def reverse_thrashing?(lease : SearchLease) : Bool
      reverse = @program.plan.reverse || return false
      cache = lease.reverse_cache(reverse) || return false
      return false unless cache.thrashing?
      return true unless cache.retry?
      @reverse_retry_from = {cache.states_built, cache.bytes_read}
      false
    end

    private def reverse_start(lease : SearchLease, bytes : Bytes, finish : Int32, lower_bound : Int32) : Int32
      plan = @program.plan
      reverse = (@engine.reversed_classes? ? plan.reverse_with_reversed_classes : plan.reverse) || return LazyDFA::GAVE_UP
      cache = lease.reverse_cache(reverse) || return LazyDFA::GAVE_UP
      start = reverse.find_start(cache, bytes, finish, lower_bound, @meter)
      if retry_from = @reverse_retry_from
        @reverse_retry_from = nil
        cache.judge_retry(*retry_from)
      end
      if cache.widest_key > SearchPlan::WIDE_REVERSE_KEY && !reverse.with_reversed_classes?
        plan.widen_reverse(@cache_pool.max_cache_bytes)
      end
      if start == LazyDFA::NO_MATCH
        raise Mica::Error.new("internal error: the reverse DFA found no start for the match ending at #{finish}")
      end
      start
    end

    # True when an unanchored search should skip the unanchored forward DFA
    # and run `LazyDFA#find_from_each_start`: its cache thrashes on this
    # program (`DFACache#thrashing?`), every match is short enough
    # (`SearchPlan#short_match`), and this is not a periodic retry.
    private def from_each_start?(cache : DFACache, anchored : Bool) : Bool
      return false if anchored
      plan = @plan
      return false unless plan && plan.short_match
      return true if @engine.each_start?
      return false unless cache.thrashing?
      return true unless cache.retry?
      @retry_from = {cache.states_built, cache.bytes_read}
      false
    end

    # Reports a retry of the unanchored DFA (see `from_each_start?`) to
    # *cache*.
    private def judge_retry(cache : DFACache) : Nil
      if retry_from = @retry_from
        @retry_from = nil
        cache.judge_retry(*retry_from)
      end
    end

    # True when the plan proved every match starts at the start of the text,
    # so an unanchored search finds only what an anchored one at its offset
    # finds (nothing past offset 0).
    private def anchored_start? : Bool
      return false unless @engine.automata?
      plan = @plan
      !!plan && plan.anchored_start?
    end

    # The forward lazy DFA when this search may use it, or nil.
    private def automaton(end_anchored : Bool) : LazyDFA?
      return nil unless @engine.automata?
      return nil if @dfa_gave_up || end_anchored || @program.options.first_line?
      @plan.try(&.forward)
    end

    private def literal_search?(anchored : Bool) : Bool
      return false unless @engine.auto? && !anchored
      plan = @plan
      !!plan && plan.literal_search?
    end

    # The literal search: the prefilter's next candidate is the match, and
    # the first literal (in priority order) found there is its text.
    private def literal_span(bytes : Bytes, byte_index : Int32) : Bool
      prefilter = @plan.try(&.prefilter) || raise Mica::Error.new("internal error: no prefilter")
      scan = @scan ||= PrefilterScan.new(prefilter, bytes, verified_only: true)
      start = scan.find(byte_index, @meter)
      return false if start < 0
      literal = prefilter.literal_at(bytes, start, @meter)
      @span_slots[0] = start.to_i64
      @span_slots[1] = (start + prefilter.literal_size(literal)).to_i64
      true
    end

    # The prefilter scan for this call, or nil when the engine, the search
    # or the call's experience so far rules it out.
    private def prefilter_scan(bytes : Bytes, anchored : Bool) : PrefilterScan?
      return nil if anchored || @prefilter_off || !@engine.auto?
      prefilter = @plan.try(&.prefilter)
      return nil unless prefilter
      scan = @scan ||= PrefilterScan.new(prefilter, bytes)
      if scan.ineffective?
        @prefilter_off = true
        return nil
      end
      scan
    end

    # Returns the last position where an unanchored search from *start*
    # may begin a match: the first line feed at or after *start* under
    # `CompileOptions::FirstLine`, or `Int32::MAX`. A scan already made
    # from at or before *start* answers when its line feed is at or after
    # *start* (no line feed lies between); otherwise the bytes from
    # *start* are scanned, each charged one operation.
    private def first_line_end(bytes : Bytes, start : Int32, anchored : Bool) : Int32
      return Int32::MAX if anchored || !@program.options.first_line?
      return @line_feed_at if @line_scan_start >= 0 && @line_scan_start <= start <= @line_feed_at
      line_feed_at = bytes.index(Look::LINE_FEED, start) || bytes.size
      @meter.charge(line_feed_at - start + 1, start)
      @line_scan_start = start
      @line_feed_at = line_feed_at
    end

    # Reads the deadline again when a later search of the call starts: the
    # caller's block (an `each_match` or `gsub` block) runs between searches,
    # and its time counts against the call's timeout. The first search was
    # checked when the call started.
    private def check_resumed_deadline(byte_index : Int32) : Nil
      @meter.enforce_deadline(byte_index) if @searches_started > 0
      @searches_started += 1
    end

    private def check_start(bytes : Bytes, byte_index : Int32) : Nil
      raise ArgumentError.new("Negative byte index: #{byte_index}") if byte_index < 0
      if byte_index < bytes.size && bytes.unsafe_fetch(byte_index) & 0xC0 == 0x80
        raise ArgumentError.new("Byte index #{byte_index} is inside a UTF-8 character")
      end
    end

    # Returns the workspace, in the capture layout when *captures*, leased
    # from the call's `CachePool` (`SearchLimitError` naming
    # `cache_pool_max_bytes` when the pool cannot supply it). A span
    # workspace is released before a capture one replaces it.
    private def pike(captures : Bool) : PikeVM
      if workspace = @pike
        if workspace.captures? || !captures
          workspace.prepare
          return workspace
        end
        @pike = nil
        workspace.release
      end
      @pike = PikeVM.new(@program, captures, @cache_pool)
    end

    private def backtracker : BoundedBacktracker
      @backtracker ||= BoundedBacktracker.new(@program, @program.slot_count)
    end
  end
end
