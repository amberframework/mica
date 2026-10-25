module Mica::Form
  # :nodoc:
  # The fix every invalid UTF-8 rejection message names.
  INVALID_UTF8_REJECTION_HINT = "pass invalid_utf8: :replace_like_browsers to accept it the way browsers do " \
                                "(each invalid sequence becomes U+FFFD)"

  # What a form parse does when percent-decoded bytes are not valid UTF-8.
  # Every parse entry point (`Mica::Form.parse`, `Pairs.parse`,
  # `Pairs.each`, `NestedKeys.build` and `NestedKeys.new`) takes it as the
  # `invalid_utf8:` argument, and a symbol works in its place:
  #
  # ```
  # limits = Mica::Form::Limits::REQUEST_BODY
  #
  # # The default: refuse the input.
  # Mica::Form::Pairs.parse("name=%FF", limits: limits) # raises Mica::EncodingError
  #
  # # Accept it the way browsers do.
  # pairs = Mica::Form::Pairs.parse("name=%FF", limits: limits, invalid_utf8: :replace_like_browsers)
  # pairs["name"]                     # => "\uFFFD"
  # pairs.has_replaced_invalid_bytes? # => true
  # ```
  #
  # Pick `Reject` (the default) for APIs, webhooks and anything signed or
  # hashed: no byte is ever swapped for U+FFFD, so the text your code sees
  # decodes exactly what was sent, or the parse fails. Pick
  # `ReplaceLikeBrowsers` when you must accept what a browser would
  # accept, such as real-world forms from legacy pages that send Latin-1
  # or Windows-1252 bytes, and check
  # `has_replaced_invalid_bytes?` on the result when you want to log or
  # refuse altered input.
  enum InvalidUTF8Handling
    # Raises `Mica::EncodingError` at the input byte where the first
    # invalid sequence starts (for a `Pair` built in code and given to
    # `NestedKeys`, at the pair's `byte_offset`, with the byte within the
    # name or value in the message). Its message names
    # `invalid_utf8: :replace_like_browsers`. The default.
    Reject
    # Replaces each invalid sequence with U+FFFD, exactly as the WHATWG
    # `application/x-www-form-urlencoded` parser (and so every browser)
    # does: one U+FFFD per maximal subpart (see
    # `Mica::Core::UTF8.replace_invalid_sequences_like_browsers`). The
    # parse result then answers `has_replaced_invalid_bytes?` with true.
    ReplaceLikeBrowsers
  end
end
