require "../spec_helper"

# Linear-time proofs for Mica::Form by operation count (report 17,
# section 0): each family runs at n and 8n and must grow by at most
# 8 x 1.1, and must stay under a declared number of operations per input
# byte. Limits are off, so the counts show the algorithm's own cost.
private UNBOUNDED = Mica::Form::Limits.unbounded(reason: "complexity measurement")

# Most operations per input byte any family may use.
private OPERATIONS_PER_BYTE = 12

private def form_operations(input : String, limits : Mica::Form::Limits = UNBOUNDED,
                            invalid_utf8 : Mica::Form::InvalidUTF8Handling = :reject) : Int64
  meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
  begin
    Mica::Form.parse(input, limits: limits, meter: meter, invalid_utf8: invalid_utf8)
  rescue Mica::ParseError
    # Error paths are measured too; the operations so far count.
  end
  meter.operations
end

private def check_linear(name : String, size : Int32,
                         invalid_utf8 : Mica::Form::InvalidUTF8Handling = :reject, & : Int32 -> String) : Nil
  bytes_at = {} of Int32 => Int32
  result = Mica::Testing::Complexity.measure(name, size, factor: 8, slack: 1.1) do |count|
    input = yield count
    bytes_at[count] = input.bytesize
    form_operations(input, invalid_utf8: invalid_utf8)
  end
  COMPLEXITY_RESULTS << result
  result.linear?.should be_true
  (result.large / bytes_at[size * 8]).should be <= OPERATIONS_PER_BYTE
end

describe "Mica::Form complexity" do
  it_satisfies "MICA-LINEAR-FORM-PAIRS", "parses pair-heavy shapes in linear operations" do
    check_linear("form: many separators", 20_000) { |count| "&" * count }
    check_linear("form: many short pairs", 5_000) { |count| "a=b&" * count }
    check_linear("form: long percent run", 10_000) { |count| "a=" + "%41" * count }
    check_linear("form: many plus signs", 20_000) { |count| "a=" + "+" * count }
    check_linear("form: many bare percent signs", 20_000) { |count| "%=" + "%" * count }
    check_linear("form: many names before one '='", 10_000) { |count| "a&" * count + "b=c" }
    check_linear("form: invalid UTF-8 after a long escape run", 10_000) { |count| "a=" + "%C3%A9" * count + "%FF" }
    check_linear("form: replaced escaped invalid bytes", 10_000, :replace_like_browsers) { |count| "a=" + "%FF" * count }
    check_linear("form: replaced raw invalid bytes", 20_000, :replace_like_browsers) { |count| "a=" + "\xFF" * count }
    check_linear("form: replaced truncated sequences in keys", 5_000, :replace_like_browsers) { |count| "k\xE2\x82[]=\xF0\x9F\x98&" * count }
  end

  it_satisfies "MICA-LINEAR-FORM-KEYS", "maps key-heavy shapes in linear operations, with huge indices O(1)" do
    check_linear("form: many distinct keys", 2_000) { |count| (1..count).join('&') { |index| "k#{index.to_s.rjust(6, '0')}=v" } }
    check_linear("form: deep bracket key", 5_000) { |count| "a" + "[b]" * count + "=v" }
    check_linear("form: deep dot key", 5_000) { |count| "a" + ".b" * count + "=v" }
    check_linear("form: many appends", 5_000) { |count| "t[]=v&" * count }
    check_linear("form: dense indices", 2_000) { |count| (0...count).join('&') { |index| "a[#{index}]=#{"v" * (6 - index.to_s.size)}" } }
    check_linear("form: Rack append chain", 2_000) { |count| "a[][x]=1&a[][y]=2&" * count }
    check_linear("form: appends inside one deep key", 2_000) { |count| "a" + "[][x]" * count + "=v" }
    check_linear("form: long digit index", 20_000) { |count| "a[" + "9" * count + "]=v" }
    huge = form_operations("a[999999999]=x", Mica::Form::Limits::REQUEST_BODY)
    small = form_operations("a[9]=x", Mica::Form::Limits::REQUEST_BODY)
    huge.should be <= small + 64
  end

  it "parses a 2 MiB body of the worst shapes in under one second" do
    body = "a[]=" + "%41" * 100_000 + "&" + "k=v&" * 200_000
    started = Time.instant
    Mica::Form.parse(body, limits: Mica::Form::Limits.new(max_pairs: 300_000, max_array_slots: 10, max_input_bytes: 4_i64 * 1024 * 1024))
    (Time.instant - started).should be < 1.second
  end
end
