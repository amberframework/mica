# Generates src/mica/regex/class_memo_prebuilt.cr, the class blocks of the
# largest classes patterns commonly use, built once here instead of once per
# process (see `Mica::Regex::ClassMemo.block_for`):
#
#   crystal-alpha run scripts/generate_class_blocks.cr > src/mica/regex/class_memo_prebuilt.cr
#   crystal-alpha tool format src/mica/regex/class_memo_prebuilt.cr
#
# Each block is built by `ClassMemo.build_from_trie`, the builder every
# other class uses, so a prebuilt block is the block the process would have
# built; spec/regex/class_memo_prebuilt_spec.cr checks that they are equal.
# Run it again whenever the Unicode tables or the class block builder
# change.
require "../src/mica"

module Mica::Regex
  # The classes whose blocks are prebuilt, as patterns and whether they
  # ignore case: each lowers to one large static set (or its complement),
  # or to a set of at most `MAX_WRITTEN_RANGES` ranges, which is written out
  # beside the blocks (`Prebuilt::WRITTEN_RANGES`). The first three are the
  # sets most classes reach past ASCII with: every code point (`.`, `[^"]`),
  # and the fold partners of the ASCII letters (U+212A for `k`, and U+017F
  # with it for a range of letters); they come first, so a class that is
  # one of them with other ASCII members is found without reading the
  # Unicode tables.
  LIST_OF_PREBUILT_CLASSES = [
    {"\\p{Any}", false}, {"k", true}, {"[a-z]", true},
    {"\\w", false}, {"\\W", false}, {"\\d", false}, {"\\D", false}, {"\\s", false}, {"\\S", false},
    {"\\pL", false}, {"\\PL", false}, {"\\p{Lowercase}", false}, {"\\p{Uppercase}", false}, {"\\pP", false},
  ]

  # The most ranges of a set written out with its block.
  MAX_WRITTEN_RANGES = 8

  # The static set (id and whether it is complemented) whose ranges are
  # *bounds*, if any.
  def self.static_set_of(bounds : Array(Int32)) : {Int32, Bool}?
    Unicode::Tables::SET_COUNT.times do |set_id|
      static = Unicode.decoded_ranges(set_id).to_a
      return {set_id, false} if static == bounds
      return {set_id, true} if complement_of(static) == bounds
    end
    nil
  end

  def self.complement_of(bounds : Array(Int32)) : Array(Int32)
    complement = [] of Int32
    first = 0
    bounds.each_slice(2) do |(low, high)|
      complement << first << low - 1 if low > first
      first = high + 1
    end
    complement << first << CodePointSet::MAX_CODE_POINT if first <= CodePointSet::MAX_CODE_POINT
    complement
  end

  # *value* as a little-endian Int16 (the targets, counts and sentinels of
  # a block all fit one).
  def self.short_bytes(value : Int32) : Bytes
    abort "#{value} does not fit an Int16" unless Int16::MIN <= value <= Int16::MAX
    bytes = Bytes.new(2)
    IO::ByteFormat::LittleEndian.encode(value.to_i16, bytes)
    bytes
  end
end

limits = Mica::Regex::CompileLimits::TRUSTED_PATTERN
entries = [] of String
prebuilt_bytes = IO::Memory.new
seen = Set(Array(Int32)).new
written_ranges = [] of Int32
Mica::Regex::LIST_OF_PREBUILT_CLASSES.each do |pattern, ignore_case|
  options = ignore_case ? Mica::Regex::CompileOptions::IgnoreCase : Mica::Regex::CompileOptions::None
  root = Mica::Regex::Syntax.parse(pattern, dialect: :crystal, compile_limits: limits, options: options).root
  ledger = Mica::Regex::AllocationLedger.new(Int64::MAX)
  meter = Mica::Core::WorkMeter.new
  set = if root.is_a?(Mica::Regex::Ast::CharClass)
          Mica::Regex::ClassLowering.lower(root, :crystal, limits, ledger, meter)
        elsif root.is_a?(Mica::Regex::Ast::Literal)
          Mica::Regex::ClassLowering.fold_literal(root, :crystal, limits, ledger, meter) || abort "#{pattern} has no fold partners"
        else
          abort "#{pattern} is not a single class or literal"
        end
  bounds = set.list_of_bounds
  next unless seen.add?(bounds)
  abort "#{pattern} is not memoized" unless Mica::Regex::ClassMemo.memoized?(set)
  if set.range_count <= Mica::Regex::MAX_WRITTEN_RANGES
    # A negative id: where the set's ranges begin in `WRITTEN_RANGES`.
    set_id = -(written_ranges.size // 2) - 1
    negated = false
    written_ranges.concat(bounds)
  else
    set_id, negated = Mica::Regex.static_set_of(bounds) || abort "#{pattern} is not a static set"
  end
  pattern = "(?i)#{pattern}" if ignore_case
  block = Mica::Regex::ClassMemo.build_from_trie(set)
  offset = prebuilt_bytes.pos
  block.list_of_states.each do |state|
    prebuilt_bytes.write_byte(state.kind.value.to_u8)
    prebuilt_bytes.write_byte(state.low)
    prebuilt_bytes.write_byte(state.high)
    prebuilt_bytes.write(Mica::Regex.short_bytes(state.next_state))
    prebuilt_bytes.write(Mica::Regex.short_bytes(state.alternate))
    prebuilt_bytes.write(Mica::Regex.short_bytes(state.argument))
  end
  block.list_of_transitions.each do |transition|
    prebuilt_bytes.write_byte(transition.low)
    prebuilt_bytes.write_byte(transition.high)
    prebuilt_bytes.write(Mica::Regex.short_bytes(transition.target))
  end
  entries << "      {#{set_id}, #{negated}, #{set.range_count}, #{block.entry}, #{block.list_of_states.size}, " \
             "#{block.list_of_transitions.size}, #{offset}}, # #{pattern}"
end

bytes = prebuilt_bytes.to_slice
puts "# GENERATED by scripts/generate_class_blocks.cr from the class block builder"
puts "# and the Unicode tables (#{Mica::Regex::Unicode::Tables::VERSION}). Do not edit by hand."
puts "module Mica::Regex::ClassMemo"
puts "  # :nodoc:"
puts "  # Class blocks built ahead of time (see `ClassMemo.block_for`)."
puts "  module Prebuilt"
puts "    # Static set id, complemented, range count, entry state, state"
puts "    # count, transition count and byte offset in `DATA` of each block. A"
puts "    # negative id -n - 1 stands for the set whose ranges begin at pair n of"
puts "    # `WRITTEN_RANGES`."
puts "    LIST_OF_ENTRIES = ["
entries.each { |entry| puts entry }
puts "    ] of {Int32, Bool, Int32, Int32, Int32, Int32, Int32}"
puts
puts "    # The ranges, as `first, last` pairs, of the sets that are not static"
puts "    # sets of the Unicode tables."
puts "    WRITTEN_RANGES = Slice(Int32).literal(#{written_ranges.map { |bound| "0x#{bound.to_s(16, upcase: true)}" }.join(", ")})"
puts
puts "    # The blocks' states (`PREBUILT_STATE_BYTES` each) then transitions"
puts "    # (`PREBUILT_TRANSITION_BYTES` each), #{bytes.size} bytes."
print "    DATA = \""
bytes.each_with_index do |byte, index|
  print "\" \\\n           \"" if index > 0 && index % 32 == 0
  print "\\x"
  print byte.to_s(16, upcase: true).rjust(2, '0')
end
puts "\""
puts "  end"
puts "end"
