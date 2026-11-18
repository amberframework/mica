# The smallest useful Mica::Regex program: check a pattern and print its
# Hir. Its dynamic libraries and symbols are what any Mica::Regex user
# links (see scripts/check_linkage.sh), and they include no PCRE2.
require "../../src/mica"

pattern = ARGV[0]? || "(?<year>\\d{4})-(?i:k)+"
limits = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN
report = Mica::Regex::Syntax.check(pattern, dialect: :crystal, compile_limits: limits)
hir = Mica::Regex::Syntax.translate(pattern, dialect: :crystal, compile_limits: limits)
STDOUT << "captures=" << report.capture_count << " states=" << report.state_estimate << '\n'
STDOUT << hir.root << '\n'
