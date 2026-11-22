require "./core"

# YAML 1.2 in pure Crystal: a pull parser (`PullParser`) that reads
# events, and a node API on top of it. No libyaml.
#
# Every parse takes required `limits:` (`ParseLimits`: input size, depth,
# nodes, alias expansion and work) and a required `timeout:` (a
# `Time::Span`, or nil for none), and raises a typed error before the
# memory a limit guards is used.
module Mica::YAML
end

require "./yaml/styles"
require "./yaml/dialect"
require "./yaml/errors"
require "./yaml/parse_limits"
require "./yaml/token"
require "./yaml/source"
require "./yaml/scanner"
require "./yaml/pull_parser"
