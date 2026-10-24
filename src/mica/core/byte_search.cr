module Mica::Core
  # Substring search in linear time, for query engines that run caller- or
  # attacker-supplied patterns (stdlib `String#index(String)` is a
  # Rabin-Karp search with a fixed base, so crafted inputs can make it
  # quadratic).
  #
  # The search is Knuth-Morris-Pratt over bytes: at most
  # `2 * haystack.size + 2 * needle.size` comparisons. UTF-8 is
  # self-synchronizing, so a byte match of a valid UTF-8 needle in valid
  # UTF-8 text always starts on a character boundary.
  module ByteSearch
    # Returns the byte offset of the first occurrence of *needle* in
    # *haystack*, or nil. *on_step* is called with the number of
    # comparisons made, for work accounting.
    #
    # ```
    # Mica::Core::ByteSearch.index("aaab".to_slice, "ab".to_slice) # => 2
    # ```
    def self.index(haystack : Bytes, needle : Bytes, & : Int32 ->) : Int32?
      return 0 if needle.empty?
      return if needle.size > haystack.size
      failure = failure_table(needle)
      yield needle.size
      matched = 0
      steps = 0
      haystack.each_with_index do |byte, offset|
        while matched > 0 && needle[matched] != byte
          matched = failure[matched - 1]
          steps += 1
        end
        steps += 1
        matched += 1 if needle[matched] == byte
        if matched == needle.size
          yield steps
          return offset + 1 - needle.size
        end
      end
      yield steps
      nil
    end

    # :ditto:
    def self.index(haystack : Bytes, needle : Bytes) : Int32?
      index(haystack, needle) { }
    end

    # Returns the KMP failure function: entry *i* is the length of the
    # longest proper prefix of `needle[0..i]` that is also its suffix.
    private def self.failure_table(needle : Bytes) : Array(Int32)
      table = Array(Int32).new(needle.size, 0)
      length = 0
      index = 1
      while index < needle.size
        if needle[index] == needle[length]
          length += 1
          table[index] = length
          index += 1
        elsif length > 0
          length = table[length - 1]
        else
          table[index] = 0
          index += 1
        end
      end
      table
    end
  end
end
