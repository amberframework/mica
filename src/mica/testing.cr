require "./core"

# Test machinery shared by every Mica format. It is not loaded by
# `require "mica"`; specs and fuzz drivers require it explicitly:
#
# ```
# require "mica/testing"
# ```
#
# - `Complexity` measures a workload's operation count at two input sizes
#   to prove it linear.
# - `ByteMutator` and `FuzzCampaign` drive seeded, replayable hostile-byte
#   fuzzing through any format.
# - `Traceability` maps specification requirement ids to the specs that
#   cover them.
module Mica::Testing
end

require "./testing/complexity"
require "./testing/byte_mutator"
require "./testing/fuzz_campaign"
require "./testing/traceability"
