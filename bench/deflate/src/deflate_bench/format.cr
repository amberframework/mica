module DeflateBench
  # The three wrappers of one DEFLATE stream.
  enum Format
    Gzip
    Zlib
    Deflate

    def self.named(text : String) : Format
      parse?(text) || raise UsageError.new("unknown format #{text} (gzip, zlib or deflate)")
    end

    # zlib's windowBits for this wrapper with a 32 KiB window.
    def window_bits : Int32
      case self
      in .gzip?    then 31
      in .zlib?    then 15
      in .deflate? then -15
      end
    end

    def file_extension : String
      case self
      in .gzip?    then "gz"
      in .zlib?    then "zz"
      in .deflate? then "deflate"
      end
    end
  end
end
