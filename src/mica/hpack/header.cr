module Mica::HPACK
  # One header field. *never_indexed* marks a field sent or received as a
  # never-indexed literal (RFC 7541, section 6.2.3): an intermediary must
  # forward it the same way, and an encoder never adds it to a table.
  record Header, name : String, value : String, never_indexed : Bool = false do
    # Returns true for a never-indexed field.
    def never_indexed? : Bool
      @never_indexed
    end

    # Returns the size RFC 7541 section 4.1 gives the field: its name and
    # value bytes plus `ENTRY_OVERHEAD`.
    def size : Int32
      @name.bytesize + @value.bytesize + ENTRY_OVERHEAD
    end
  end
end
