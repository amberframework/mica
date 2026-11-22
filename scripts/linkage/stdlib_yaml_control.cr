# Negative control for scripts/check_linkage.sh: a program that parses
# YAML with the standard library's YAML (libyaml). The check must find
# libyaml in it, proving the probes would catch libyaml in minimal_yaml if
# it were there.
require "yaml"

STDOUT << YAML.parse(ARGV[0]? || "a: [1, 2]").to_yaml
