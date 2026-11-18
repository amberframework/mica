require "../spec_helper"

# Compile-family complexity specs from the regex roadmap (followup-17 6.8).
#
# 1. The four hostile compile families are refused under
#    UNTRUSTED_PATTERN by a named limit, and the process allocates less
#    than max_compile_bytes while refusing them (measured with GC.stats,
#    not with the ledger the code under test keeps).
# 2. Upper envelopes: for each family, the compile work Mica charges at
#    sizes x1, x2, x4 and x8 stays below C x the pattern size, with C
#    committed per family, and grows no faster than linearly
#    (Mica::Testing::Complexity).

private UNTRUSTED = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN

# Limits opened wide, so only the algorithm decides the work.
private OPEN = Mica::Regex::CompileLimits.custom(
  max_pattern_bytes: Int32::MAX,
  max_nest_depth: 1_000_000,
  max_captures: Mica::Regex::CompileLimits::MAX_GROUP_NUMBER,
  max_class_ranges: Int32::MAX,
  max_program_states: Int64::MAX,
  max_pike_bytes: Int64::MAX,
  max_compile_bytes: Int64::MAX,
)

# Bytes the process allocates while checking *pattern*, and the error.
private def allocation_of(pattern : String, limits : Mica::Regex::CompileLimits) : {Int64, Mica::Error?}
  GC.collect
  before = GC.stats.total_bytes
  error = Mica::Regex::Syntax.error?(pattern, dialect: :crystal, compile_limits: limits)
  {(GC.stats.total_bytes - before).to_i64, error}
end

# Compile operations for *pattern*; an error ends the count where it was
# raised.
private def compile_operations(pattern : String) : Int64
  meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
  begin
    Mica::Regex::Syntax.check(pattern, dialect: :crystal, compile_limits: OPEN, meter: meter)
  rescue Mica::Error
  end
  meter.operations
end

# name => {pattern builder for size k, base k, committed envelope C (ops per pattern byte)}
private ENVELOPES = {
  "literal run a*k"                 => {->(k : Int32) { "a" * k }, 512, 8.0},
  "alternation of 8-byte literals"  => {->(k : Int32) { (0...k).map { |i| "lit%05d" % i }.join('|') }, 64, 8.0},
  "nested groups (*k a )*k"         => {->(k : Int32) { "(" * k + "a" + ")" * k }, 256, 8.0},
  "a{k}"                            => {->(k : Int32) { "a{#{k}}" }, 1_000, 30.0},
  "[\\p{L}\\p{N}]{1,k}"             => {->(k : Int32) { "[\\p{L}\\p{N}]{1,#{k}}" + "x" * k }, 256, 600.0},
  "class escapes \\p{L}*k"          => {->(k : Int32) { "\\p{L}" * k }, 64, 600.0},
  "case-folded classes (?i)[a-z]*k" => {->(k : Int32) { "(?i)" + "[a-z]" * k }, 128, 200.0},
  "counted nesting (a{2})*k"        => {->(k : Int32) { "(?:a{2})" * k }, 128, 30.0},
}

describe "Mica::Regex compile complexity" do
  {
    "((a{100}){100}){100}"        => {"((a{100}){100}){100}", "max_program_states"},
    "(a{1000}){1000}"             => {"(a{1000}){1000}", "max_program_states"},
    "a 4 KiB alternation"         => {(0...456).map { |i| "lit%05d" % i }.join('|'), "max_pattern_bytes"},
    "nesting at max_nest_depth+1" => {"(?:" * 65 + "a" + ")" * 65, "max_nest_depth"},
  }.each do |label, (pattern, limit_name)|
    it_satisfies "REGEX-R1-compile-complexity", "refuses #{label} by #{limit_name} with allocation below max_compile_bytes" do
      allocated, error = allocation_of(pattern, UNTRUSTED)
      error.should be_a(Mica::Regex::CompileLimitError)
      error.as(Mica::Regex::CompileLimitError).limit_name.should eq(limit_name)
      allocated.should be < UNTRUSTED.max_compile_bytes
    end
  end

  it_satisfies "REGEX-R1-ledger", "accepts a 4 KiB alternation under TRUSTED_PATTERN with allocation below max_compile_bytes" do
    pattern = (0...455).map { |i| "lit%05d" % i }.join('|')
    pattern.bytesize.should be <= 4096
    allocated, error = allocation_of(pattern, UNTRUSTED)
    error.should be_nil
    allocated.should be < UNTRUSTED.max_compile_bytes
  end

  ENVELOPES.each do |name, (builder, base, envelope)|
    it_satisfies "REGEX-R1-compile-complexity", "keeps compile work for #{name} under #{envelope} ops per byte at x1..x8 and linear" do
      [1, 2, 4, 8].each do |factor|
        pattern = builder.call(base * factor)
        operations = compile_operations(pattern)
        per_byte = operations / pattern.bytesize
        fail "#{name} at x#{factor}: #{per_byte.round(1)} ops per byte exceeds #{envelope}" if per_byte > envelope
      end
      result = Mica::Testing::Complexity.measure(name, base) { |size| compile_operations(builder.call(size)) }
      COMPLEXITY_RESULTS << result
      result.linear?.should be_true
    end
  end
end
