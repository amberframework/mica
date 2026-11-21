# Soak test for the engine's buffers outside the collector's heap
# (`Mica::Regex::OffHeapList`, `Mica::Regex::OffHeap`): compiles, searches
# and drops expressions in a long loop and prints, every *report_every*
# rounds, after a full collection, the bytes libc's allocator holds in use,
# the collector's heap and the off-heap bytes counted so far. A leak shows
# as malloc bytes in use that keep climbing; freed memory read again shows
# as a crash or a wrong match (every search is checked against the first
# answer for its pattern). The resident set size and the default
# `CachePool`'s member count show the collector-side bookkeeping: both level
# off once the pool prunes the references of collected leases.
#
#   crystal-alpha build --release bench/regex/off_heap/soak.cr -o soak
#   ./soak [rounds] [report_every] [threads]
#
# Each line: round, malloc bytes in use, malloc blocks in use, GC heap
# bytes, GC free bytes, off-heap bytes allocated so far, resident set
# size in KiB, default CachePool member count.
require "../../../src/mica"

{% if flag?(:darwin) %}
  lib LibMallocZone
    struct MallocStatistics
      blocks_in_use : UInt32
      size_in_use : LibC::SizeT
      max_size_in_use : LibC::SizeT
      size_allocated : LibC::SizeT
    end

    fun malloc_zone_statistics(zone : Void*, stats : MallocStatistics*) : Void
  end
{% else %}
  lib LibMallocInfo
    struct MallocInfo2
      arena : LibC::SizeT
      ordblks : LibC::SizeT
      smblks : LibC::SizeT
      hblks : LibC::SizeT
      hblkhd : LibC::SizeT
      usmblks : LibC::SizeT
      fsmblks : LibC::SizeT
      uordblks : LibC::SizeT
      fordblks : LibC::SizeT
      keepcost : LibC::SizeT
    end

    fun mallinfo2 : MallocInfo2
  end
{% end %}

module OffHeapSoak
  # Patterns that reach every off-heap owner: the 26 Amber patterns of the
  # official benchmark, class runs and optional runs (`x{n}`, `x{n,m}`),
  # large memoized classes, captures (one-pass DFA, Pike VM), and the
  # backtracker on first searches.
  LIST_OF_PATTERNS = [
    "\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z",
    "\\A[a-z0-9]+(?:-[a-z0-9]+)*\\z",
    "\\A\\d+\\z",
    ".*:(\\d+)",
    "\\A[\\w+\\-.]+@[a-z\\d\\-]+(\\.[a-z\\d\\-]+)*\\.[a-z]+\\z",
    "\\Ahttps?:\\/\\/(www\\.)?[-a-zA-Z0-9@:%._\\+~#=]{1,256}\\.[a-zA-Z0-9()]{1,6}\\b([-a-zA-Z0-9()@:%_\\+.~#?&\\/\\/=]*)\\z",
    "&(?:([a-zA-Z0-9]{2,32};)|(#[xX][\\da-fA-F]+;?|#\\d+;?))",
    "[$+<=>^`|~\\p{P}]",
    "[ \\t\\n\\x0b\\x0c\\x0d]+",
    "<([a-zA-Z0-9.!#$%&'*+\\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>",
    "<[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\\x00-\\x20]*>",
    "^(?:(?:\\*[ \\t]*){3,}|(?:_[ \\t]*){3,}|(?:-[ \\t]*){3,})[ \\t]*$",
    "^\\\#{1,6}(?:[ \\t]+|$)",
    "^\\[\\^([^\\s\\]]+)\\]:\\s+(.*)",
    "^(?<file>[^:]+)(?:\\:(?<line>\\d+)(?:\\:(?<col>\\d+))?)? in '\\*?(?<method>.*?)'(?: at (?i-msx:(?<addr>0x[a-f0-9]+)))?$",
    "^src\\/",
    "\\b\\d+\\b",
    "'[^']*'",
    "\\$\\d+",
    "\\s+",
    "([a-zA-Z0-9_$']+)",
    ",\\s*",
    ",|,\\s",
    "[^a-z0-9]+",
    "([a-z\\d])([A-Z])",
    "\\{\\{([^}]+)\\}\\}",
    "\\w{40}",
    "\\p{L}{3,40}x",
    "[a-c]{2,300}?d",
    "(?i)\\p{Lu}+\\d{2,9}",
    "(\\w+)@(\\w+)\\.com",
    "(a|b|c)*abc(d+)",
  ]

  HAYSTACK = String.build do |io|
    200.times do |index|
      io << "user" << index << "@example.com 'quoted " << index << "' $" << index << " {{ name }} "
      io << "src/app.cr:" << index << ":7 in 'run' at 0x1f2e3d\n"
      io << "https://www.example.com/path?" << index << "=1 <mailto:a" << index << "@b.org> &amp; #" << index << ";\n"
      io << "CamelCaseWord" << index << " aaaaabbbbbcccccd été 中文 ***\n"
    end
  end

  # Large classes, distinct per round once the memo is full, so blocks the
  # memo does not keep (owned by their program) are made and freed too.
  def self.memo_overflow_pattern(round : Int32) : String
    low = 0x4E00 + (round % 4096) * 3
    "[\\x{#{low.to_s(16)}}-\\x{#{(low + 2000).to_s(16)}}a-z]{2}"
  end

  def self.malloc_in_use : {UInt64, UInt64}
    {% if flag?(:darwin) %}
      stats = LibMallocZone::MallocStatistics.new
      LibMallocZone.malloc_zone_statistics(nil, pointerof(stats))
      {stats.size_in_use.to_u64, stats.blocks_in_use.to_u64}
    {% else %}
      info = LibMallocInfo.mallinfo2
      {info.uordblks.to_u64, (info.ordblks + info.hblks).to_u64}
    {% end %}
  end

  def self.resident_kib : Int64
    output = IO::Memory.new
    Process.run("ps", ["-o", "rss=", "-p", Process.pid.to_s], output: output)
    output.to_s.strip.to_i64
  end

  def self.report(round : Int32) : Nil
    3.times { GC.collect }
    bytes, blocks = malloc_in_use
    stats = GC.stats
    STDOUT.puts "#{round} #{bytes} #{blocks} #{stats.heap_size} #{stats.free_bytes} #{Mica::Regex::OffHeap.allocated_bytes} #{resident_kib} #{Mica::Regex::CachePool.default.member_count}"
    STDOUT.flush
  end

  def self.run(rounds : Int32, report_every : Int32, threads : Int32) : Nil
    limits = Mica::Regex::SearchLimits::TRUSTED_INPUT
    compile_limits = Mica::Regex::CompileLimits::TRUSTED_PATTERN
    tight = Mica::Regex::CompileLimits.custom(max_program_states: 64_i64)
    expected = LIST_OF_PATTERNS.map do |pattern|
      expression = Mica::Regex::Expression.new(pattern, compile_limits: compile_limits)
      expression.scan(HAYSTACK, limits: limits).map(&.byte_begin(0))
    end
    report(0)
    done = Channel(Nil).new
    threads.times do |thread|
      spawn do
        (1..rounds).each do |round|
          index = (round + thread) % LIST_OF_PATTERNS.size
          pattern = LIST_OF_PATTERNS[index]
          expression = Mica::Regex::Expression.new(pattern, compile_limits: compile_limits)
          # A first search, then whole scans (the plan, its caches and leases).
          expression.match(HAYSTACK, limits: limits)
          found = expression.scan(HAYSTACK, limits: limits).map(&.byte_begin(0))
          raise "round #{round}: #{pattern} found #{found.size} matches, expected #{expected[index].size}" unless found == expected[index]
          # A compile a limit stops: its lists are freed on the way out.
          begin
            Mica::Regex::Expression.new(pattern, compile_limits: tight)
          rescue Mica::Regex::CompileLimitError
          end
          overflow = Mica::Regex::Expression.new(memo_overflow_pattern(round), compile_limits: compile_limits)
          overflow.match(HAYSTACK, limits: limits)
          report(round) if thread == 0 && round % report_every == 0
          Fiber.yield if round % 64 == 0
        end
        done.send(nil)
      end
    end
    threads.times { done.receive }
  end
end

rounds = (ARGV[0]? || "20000").to_i
report_every = (ARGV[1]? || "2000").to_i
threads = (ARGV[2]? || "1").to_i
OffHeapSoak.run(rounds, report_every, threads)
