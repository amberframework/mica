module Mica::HPACK
  # The 61 entries of RFC 7541 Appendix A, indexed from 1.
  module StaticTable
    ENTRIES = {
      Header.new(":authority", ""),
      Header.new(":method", "GET"),
      Header.new(":method", "POST"),
      Header.new(":path", "/"),
      Header.new(":path", "/index.html"),
      Header.new(":scheme", "http"),
      Header.new(":scheme", "https"),
      Header.new(":status", "200"),
      Header.new(":status", "204"),
      Header.new(":status", "206"),
      Header.new(":status", "304"),
      Header.new(":status", "400"),
      Header.new(":status", "404"),
      Header.new(":status", "500"),
      Header.new("accept-charset", ""),
      Header.new("accept-encoding", "gzip, deflate"),
      Header.new("accept-language", ""),
      Header.new("accept-ranges", ""),
      Header.new("accept", ""),
      Header.new("access-control-allow-origin", ""),
      Header.new("age", ""),
      Header.new("allow", ""),
      Header.new("authorization", ""),
      Header.new("cache-control", ""),
      Header.new("content-disposition", ""),
      Header.new("content-encoding", ""),
      Header.new("content-language", ""),
      Header.new("content-length", ""),
      Header.new("content-location", ""),
      Header.new("content-range", ""),
      Header.new("content-type", ""),
      Header.new("cookie", ""),
      Header.new("date", ""),
      Header.new("etag", ""),
      Header.new("expect", ""),
      Header.new("expires", ""),
      Header.new("from", ""),
      Header.new("host", ""),
      Header.new("if-match", ""),
      Header.new("if-modified-since", ""),
      Header.new("if-none-match", ""),
      Header.new("if-range", ""),
      Header.new("if-unmodified-since", ""),
      Header.new("last-modified", ""),
      Header.new("link", ""),
      Header.new("location", ""),
      Header.new("max-forwards", ""),
      Header.new("proxy-authenticate", ""),
      Header.new("proxy-authorization", ""),
      Header.new("range", ""),
      Header.new("referer", ""),
      Header.new("refresh", ""),
      Header.new("retry-after", ""),
      Header.new("server", ""),
      Header.new("set-cookie", ""),
      Header.new("strict-transport-security", ""),
      Header.new("transfer-encoding", ""),
      Header.new("user-agent", ""),
      Header.new("vary", ""),
      Header.new("via", ""),
      Header.new("www-authenticate", ""),
    }

    # The number of entries (61).
    SIZE = ENTRIES.size

    # The lowest index of each name.
    NAME_INDEX = begin
      index = {} of String => Int32
      ENTRIES.each_with_index { |entry, offset| index[entry.name] = offset + 1 unless index.has_key?(entry.name) }
      index
    end

    # The index of each entry, keyed by name and value.
    FIELD_INDEX = begin
      index = {} of {String, String} => Int32
      ENTRIES.each_with_index { |entry, offset| index[{entry.name, entry.value}] = offset + 1 }
      index
    end

    # Returns the entry at the 1-based *index* (1 to 61).
    def self.[](index : Int32) : Header
      ENTRIES[index - 1]
    end
  end
end
