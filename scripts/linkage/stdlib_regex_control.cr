# Negative control for scripts/check_linkage.sh: a program that uses the
# standard library's Regex. The check must find PCRE2 in it, proving the
# probes would catch PCRE2 in minimal_regex if it were there.
STDOUT << (/a+/.match(ARGV[0]? || "caaat").try(&.[0]) || "") << '\n'
