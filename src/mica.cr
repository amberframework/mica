# Mica is a family of pure-Crystal parsers. Each format lives in its own
# namespace (`Mica::XML` today) and shares the machinery in `Mica::Core`:
# positioned errors, encodings, buffered input, safety limits, and a work
# budget with an optional deadline that keeps every parse linear in its
# input. No format needs a C library, and none reads the network or file
# system while parsing.
module Mica
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end

require "./mica/core"
require "./mica/xml"
