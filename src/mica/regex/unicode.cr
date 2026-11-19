module Mica::Regex
  # Unicode data for classes and case folding: the property sets and the
  # simple case folding orbits of one pinned Unicode Character Database
  # version (`Tables::VERSION`), generated into `unicode/tables.cr` by
  # scripts/unicode/generate_tables.rb. The tables are static table_bytes in the
  # binary; a set's ranges are decoded into integers once per process, the
  # first time a class uses the set.
  module Unicode
    # What a property name refers to, following PCRE2's property types.
    enum PropertyKind
      # A two-letter general category such as `Lu`.
      GeneralCategory
      # A one-letter general category group such as `L`.
      GeneralCategoryGroup
      # `L&` or `LC`: `Lu`, `Ll` and `Lt` together.
      LetterAmpersand
      # A script that appears in no Script_Extensions list (script only).
      Script
      # A script that appears in Script_Extensions lists; a bare name means
      # Script_Extensions, `sc:` asks for the Script property alone.
      ScriptExtensions
      # A Bidi_Class value, named `bidi<value>` or `bc:<value>`.
      BidiClass
      # A Boolean property such as `Alphabetic`.
      Boolean
      # `Any`.
      Any
      # `Xan`: letters and numbers.
      Alnum
      # `Xps` and `Xsp`: separators plus horizontal and vertical space.
      Space
      # `Xuc`: characters a universal character name can spell.
      UniversalName
      # `Xwd`: letters, numbers, `Mn` and `Pc`.
      Word
    end

    # The result of `lookup`: which set a property name selects.
    record Property, kind : PropertyKind, set_id : Int32

    # Looks up a property name from `\p{...}`. *loose* is the name as PCRE2
    # normalizes it: negation removed, ASCII letters lower-cased, and
    # spaces, hyphens, underscores and other ASCII white space dropped. It
    # may carry a `sc:`, `scx:`, `script:`, `scriptextensions:`, `bc:` or
    # `bidiclass:` prefix (the first `:` or `=` separates it). Returns nil
    # for an unknown name.
    #
    # ```
    # Mica::Regex::Unicode.lookup("greek").try(&.kind)    # => PropertyKind::ScriptExtensions
    # Mica::Regex::Unicode.lookup("sc:greek").try(&.kind) # => PropertyKind::Script
    # ```
    def self.lookup(loose : String) : Property?
      separator = loose.each_char_with_index { |char, index| break index if char == ':' || char == '=' }
      return lookup_loose(loose) unless separator
      prefix = loose[0, separator]
      value = loose[(separator + 1)..]
      case prefix
      when "bidiclass", "bc"
        entry = lookup_loose("bidi" + value)
        return entry if entry && entry.kind.bidi_class?
        nil
      when "script", "sc"
        script_property(value, script_only: true)
      when "scriptextensions", "scx"
        script_property(value, script_only: false)
      end
    end

    private def self.script_property(value : String, script_only : Bool) : Property?
      entry = Tables::PROPERTY_NAMES[value]?
      return nil unless entry
      kind, set_id, script_set_id = entry
      return Property.new(PropertyKind::Script, set_id) if kind.script?
      return nil unless kind.script_extensions?
      script_only ? Property.new(PropertyKind::Script, script_set_id) : Property.new(kind, set_id)
    end

    private def self.lookup_loose(loose : String) : Property?
      entry = Tables::PROPERTY_NAMES[loose]?
      return nil unless entry
      kind, set_id, _script_set_id = entry
      Property.new(kind, set_id)
    end

    # Returns the number of ranges in static set *set_id*.
    def self.range_count(set_id : Int32) : Int32
      Tables::SETS[set_id][1]
    end

    # Yields each range of static set *set_id* as `{first, last}`, in
    # order.
    def self.each_range(set_id : Int32, & : Int32, Int32 ->) : Nil
      first_index, count = Tables::SETS[set_id]
      table_bytes = Tables::RANGES.to_slice
      count.times do |index|
        offset = (first_index + index) * 12
        yield hex6(table_bytes, offset), hex6(table_bytes, offset + 6)
      end
    end

    # Returns the ranges of static set *set_id* as `first, last` pairs,
    # decoded from the hex table once per process on first use (a set is
    # lowered from them every time a pattern uses it). Callers read the
    # slice and never write it.
    def self.decoded_ranges(set_id : Int32) : Slice(Int32)
      # Every read and write of the memo is under the mutex: a
      # `Slice(Int32)?` is wider than a machine word, so an unsynchronized
      # read could see a torn value. Callers take the slice once per class.
      @@decoded_mutex.synchronize do
        @@decoded_bounds[set_id] ||= begin
          bounds = Slice(Int32).new(range_count(set_id) * 2)
          index = 0
          each_range(set_id) do |first, last|
            bounds[index] = first
            bounds[index + 1] = last
            index += 2
          end
          bounds
        end
      end
    end

    @@decoded_bounds = Array(Slice(Int32)?).new(Tables::SETS.size, nil)
    @@decoded_mutex = Mutex.new

    # Returns true when *code_point* is in static set *set_id* (a binary
    # search).
    def self.includes?(set_id : Int32, code_point : Int32) : Bool
      first_index, count = Tables::SETS[set_id]
      table_bytes = Tables::RANGES.to_slice
      low = 0
      high = count
      while low < high
        middle = (low + high) // 2
        offset = (first_index + middle) * 12
        if hex6(table_bytes, offset + 6) < code_point
          low = middle + 1
        elsif hex6(table_bytes, offset) > code_point
          high = middle
        else
          return true
        end
      end
      false
    end

    # Calls the block with every other member of *code_point*'s simple case
    # folding orbit (at most `Tables::LARGEST_ORBIT - 1` of them).
    def self.each_fold_partner(code_point : Int32, & : Int32 ->) : Nil
      index = fold_index_at_or_after(code_point)
      return if index >= fold_entry_count
      table_bytes = Tables::FOLD_CYCLE.to_slice
      return unless hex6(table_bytes, index * 12) == code_point
      partner = hex6(table_bytes, index * 12 + 6)
      steps = 0
      while partner != code_point && steps < Tables::LARGEST_ORBIT
        yield partner
        partner = hex6(table_bytes, fold_index_at_or_after(partner) * 12 + 6)
        steps += 1
      end
    end

    # Calls the block with each code point in *first*..*last* that has fold
    # partners, in order, and returns the number of such code points
    # visited (the work done).
    def self.each_folding_code_point(first : Int32, last : Int32, & : Int32 ->) : Int32
      index = fold_index_at_or_after(first)
      table_bytes = Tables::FOLD_CYCLE.to_slice
      visited = 0
      while index < fold_entry_count
        code_point = hex6(table_bytes, index * 12)
        break if code_point > last
        yield code_point
        visited += 1
        index += 1
      end
      visited
    end

    # Returns the number of code points in *first*..*last* that have fold
    # partners, without visiting them (two binary searches).
    def self.folding_code_point_count(first : Int32, last : Int32) : Int32
      fold_index_at_or_after(last + 1) - fold_index_at_or_after(first)
    end

    private def self.fold_entry_count : Int32
      Tables::FOLD_CYCLE.bytesize // 12
    end

    private def self.fold_index_at_or_after(code_point : Int32) : Int32
      table_bytes = Tables::FOLD_CYCLE.to_slice
      low = 0
      high = fold_entry_count
      while low < high
        middle = (low + high) // 2
        if hex6(table_bytes, middle * 12) < code_point
          low = middle + 1
        else
          high = middle
        end
      end
      low
    end

    # Reads six upper-case hex digits at *offset*. Callers index entries
    # of the generated tables, so the bounds are checked once here and the
    # digits are read without per-byte checks.
    @[AlwaysInline]
    private def self.hex6(table_bytes : Bytes, offset : Int32) : Int32
      raise IndexError.new unless 0 <= offset && offset + 6 <= table_bytes.size
      digits = table_bytes.to_unsafe + offset
      value = 0
      6.times do |index|
        byte = digits[index].to_i32
        digit = byte <= 0x39 ? byte &- 0x30 : byte &- 0x37
        value = (value << 4) | digit
      end
      value
    end
  end
end

require "./unicode/tables"
