module RegexBench
  # When a batch of timed searches is about to run, then every search in it
  # gets its own String, equal to the haystack but a separate object, as a
  # web app gets a new String with every request. An engine that remembers
  # the last String it validated (Mica does, by identity) therefore pays
  # UTF-8 validation on every timed search, as PCRE2-JIT does.
  #
  # The copies are made by `#prepare`, before the batch's clock starts, so
  # the copy itself is never timed. A batch whose copies would pass
  # *byte_ceiling* rotates through as many copies as fit, and never fewer
  # than two, so consecutive searches still see different objects. Each
  # engine runs this same code, in its own process.
  class HaystackCopies
    # 256 MiB of copies at most per batch.
    DEFAULT_BYTE_CEILING = 256_i64 * 1024 * 1024

    getter original : String
    getter copy_count : Int32 = 0

    def initialize(@original : String, @byte_ceiling : Int64 = DEFAULT_BYTE_CEILING)
      @list_of_copies = [] of String
    end

    # Makes the copies for a batch of *iterations* runs.
    def prepare(iterations : Int32) : Nil
      fitting = @original.bytesize > 0 ? @byte_ceiling // @original.bytesize : iterations.to_i64
      @copy_count = {iterations.to_i64, {fitting, 2_i64}.max}.min.to_i32
      # Built into a new array while the last batch's copies are still held,
      # so no copy reuses the address of the String searched just before it.
      @list_of_copies = Array(String).new(@copy_count) { String.new(@original.to_slice) }
    end

    # The copy for run *index* of the batch.
    def [](index : Int32) : String
      @list_of_copies[index % @copy_count]
    end
  end
end
