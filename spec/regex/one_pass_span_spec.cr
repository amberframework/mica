require "../spec_helper"

# `OnePassDFA#search` without a meter, for a program whose only group is
# the match, reads the span alone (`search_span`); with a meter it runs the
# slot-writing loop. Both must find the same match from every start, or a
# candidate or short search would answer differently from the searcher.
private TRUSTED   = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private UNLIMITED = Mica::Regex::SearchLimits.custom(work_ceiling: Int64::MAX // 2, work_per_byte: 1_000_000_i64)

private LIST_OF_PATTERNS = [
  ",\\s*", ",|,\\s", "a+b?", "\\w+", ".*x", "[^\"]*\"", "\\d+$", "\\bfoo\\b", "a\\z", "x*", "(?s:.)*",
  "é+", "\\s+$", "(?:ab)+c?", "[a-z]+\\d*", "\\A\\d+\\z", "(?m)^\\w+$", "\\w+\\b",
]

private LIST_OF_HAYSTACKS = [
  "a, b,c  ,\td", "aaab ab b", "foo bar foo_bar foo", "say \"hi\" \"there\"", "12 34\n56", "xx.x\nyyx",
  "éé é a", "tail  \n  ", "ababc abab", "", "a", "abc123 d4 e", "line\nnext\n", "  x  ",
]

describe Mica::Regex::OnePassDFA do
  describe "#search" do
    it "finds the same span without a meter (span only) as with one, from every start" do
      checked = 0
      LIST_OF_PATTERNS.each do |source|
        program = Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
        next unless program.slot_count == 2
        one_pass = program.plan.one_pass
        next unless one_pass
        LIST_OF_HAYSTACKS.each do |haystack|
          bytes = haystack.to_slice
          (0..bytes.size).each do |start|
            next if start < bytes.size && bytes[start] & 0xC0 == 0x80
            {Int32::MAX, start + 2}.each do |stop|
              span_slots = Slice(Int64).new(2, -1_i64)
              full_slots = Slice(Int64).new(2, -1_i64)
              span_finish, _ = one_pass.search(bytes, start, 0, span_slots, Slice(Int64).new(2, -1_i64), nil, stop)
              meter = Mica::Regex::SearchMeter.new(UNLIMITED, program.state_count, bytes.size, nil)
              full_finish, _ = one_pass.search(bytes, start, 0, full_slots, Slice(Int64).new(2, -1_i64), meter, stop)
              {source, haystack, start, stop, span_finish}.should eq({source, haystack, start, stop, full_finish})
              {source, haystack, start, stop, span_slots}.should eq({source, haystack, start, stop, full_slots}) if full_finish >= 0
              checked += 1
            end
          end
        end
      end
      checked.should be > 1000
    end
  end
end
