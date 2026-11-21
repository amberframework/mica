require "../spec_helper"

# What a plan builds only once its searches have paid for it: the one-pass
# DFA of a search at starts whose table is not small, and the analysis
# that tells whether every match has one length.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

private AUTOLINK = "<[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\\x00-\\x20]*>"

private def span_of(pattern : Mica::Regex::Expression, haystack : String) : {Int32, Int32}?
  match = pattern.search(haystack, limits: LIMITS)
  match ? {match.byte_begin(0), match.byte_end(0)} : nil
end

describe Mica::Regex::SearchPlan do
  describe "#start_search_one_pass" do
    it "leaves a large one-pass table unbuilt until the tries have read as much" do
      pattern = Mica::Regex::Expression.new(AUTOLINK, Mica::Regex::CompileOptions::IgnoreCase, compile_limits: TRUSTED)
      padding = "plain words and a < b comparisons, " * 12
      haystack = "#{padding}see <HTTPS://exämple.org/a/long/päth?q=1&r=2> and <not a link> #{padding}"
      expected = {padding.bytesize + 4, padding.bytesize + 4 + "<HTTPS://exämple.org/a/long/päth?q=1&r=2>".bytesize}
      span_of(pattern, haystack).should eq(expected)
      plan = pattern.program.plan
      plan.one_pass_built?.should be_false
      searches = 1
      until plan.one_pass_built? || searches == 10_000
        span_of(pattern, haystack).should eq(expected)
        searches += 1
      end
      plan.one_pass_built?.should be_true
      plan.built_one_pass.should_not be_nil
      searches.should be > 2
      # The same span on the one-pass DFA.
      span_of(pattern, haystack).should eq(expected)
      span_of(pattern, "#{padding}<no link here #{padding}").should be_nil
    end

    it "builds a small one-pass table on the first search at starts" do
      pattern = Mica::Regex::Expression.new(",\\s*", compile_limits: TRUSTED)
      haystack = "#{"word " * 80}alpha,  beta#{" word" * 80}"
      span_of(pattern, haystack).should eq({405, 408})
      pattern.program.plan.one_pass_built?.should be_true
    end
  end

  describe "#fixed_match_bytes" do
    it "waits for a start the backtracker does not find" do
      pattern = Mica::Regex::Expression.new("[$+<=>^`|~\\p{P}]", compile_limits: TRUSTED)
      haystack = "#{"word " * 30}«quoted» #{"word " * 60}"
      span_of(pattern, haystack).should eq({150, 152})
      plan = pattern.program.plan
      plan.fixed_match_bytes_known?.should be_false
      6.times { span_of(pattern, haystack).should eq({150, 152}) }
      plan.fixed_match_bytes_known?.should be_true
      plan.fixed_match_bytes.should eq(-1)
    end

    it "finds the same starts before and after the analysis" do
      pattern = Mica::Regex::Expression.new("[0-9]{4}-[0-9]{2}", compile_limits: TRUSTED)
      near = "#{"word " * 30}on 2026-11 #{"word " * 60}"
      far = "#{"word " * 90}on 2026-11 #{"word " * 10}"
      span_of(pattern, near).should eq({153, 160})
      6.times do
        span_of(pattern, near).should eq({153, 160})
        span_of(pattern, far).should eq({453, 460})
      end
      pattern.program.plan.fixed_match_bytes.should eq(7)
    end
  end
end
