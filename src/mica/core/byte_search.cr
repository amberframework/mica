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
    # Comparisons between two calls of the step block.
    STEP_CHUNK = 4096

    # Returns the byte offset of the first occurrence of *needle* in
    # *haystack*, or nil. The block is called with the number of
    # comparisons made, at least every `STEP_CHUNK` comparisons (while
    # building the failure table and while scanning), so a work meter can
    # stop a long search partway.
    #
    # ```
    # Mica::Core::ByteSearch.index("aaab".to_slice, "ab".to_slice) # => 2
    # ```
    def self.index(haystack : Bytes, needle : Bytes, & : Int32 ->) : Int32?
      return 0 if needle.empty?
      return if needle.size > haystack.size
      failure = failure_table(needle) { |steps| yield steps }
      matched = 0
      steps = 0
      haystack.each_with_index do |byte, offset|
        while matched > 0 && needle[matched] != byte
          matched = failure[matched - 1]
          steps += 1
          if steps >= STEP_CHUNK
            yield steps
            steps = 0
          end
        end
        steps += 1
        if steps >= STEP_CHUNK
          yield steps
          steps = 0
        end
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
    # longest proper prefix of `needle[0..i]` that is also its suffix. Each
    # loop iteration either advances or shrinks `length`, so the loop runs
    # at most `2 * needle.size` times; the block gets the count in chunks.
    private def self.failure_table(needle : Bytes, & : Int32 ->) : Array(Int32)
      table = Array(Int32).new(needle.size, 0)
      length = 0
      index = 1
      steps = 0
      while index < needle.size
        steps += 1
        if steps >= STEP_CHUNK
          yield steps
          steps = 0
        end
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
      yield steps
      table
    end
  end
end
