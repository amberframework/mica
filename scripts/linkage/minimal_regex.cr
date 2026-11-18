# The smallest useful Mica::Regex program: compile a pattern, search a
# haystack with captures, replace and split. Its dynamic libraries and
# symbols are what any Mica::Regex user links (see
# scripts/check_linkage.sh), and they include no PCRE2.
require "../../src/mica"

pattern = ARGV[0]? || "(?<year>\\d{4})-(?<month>\\d{2})"
haystack = ARGV[1]? || "released 2026-11, patched 2026-12"
limits = Mica::Regex::SearchLimits::REQUEST
expression = Mica::Regex::Expression.new(pattern, compile_limits: Mica::Regex::CompileLimits::UNTRUSTED_PATTERN)
match = expression.match(haystack, limits: limits)
STDOUT << "states=" << expression.program.state_count << " captures=" << expression.capture_count << '\n'
STDOUT << "match=" << match.try(&.to_a).inspect << '\n'
STDOUT << "scan=" << expression.scan(haystack, limits: limits).map(&.to_s).inspect << '\n'
STDOUT << "gsub=" << expression.gsub(haystack, "\\2/\\1", limits: limits) << '\n'
STDOUT << "split=" << expression.split(haystack, limits: limits).inspect << '\n'
