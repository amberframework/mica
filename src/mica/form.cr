require "./core"

# `application/x-www-form-urlencoded` bodies and URL query strings:
# `Pairs` parses them into ordered name and value pairs (WHATWG URL
# Standard, section 5), and `NestedKeys` turns bracket and dot keys
# (`user[address][city]`, `tags[]`, `user.name`) into a nested `Value`
# under explicit limits.
#
# Every entry point takes a required `limits:` argument (see `Limits`).
#
# ```
# value = Mica::Form.parse("user[name]=Ada&user[tags][]=x&user[tags][]=y", limits: Mica::Form::Limits::REQUEST_BODY)
# value["user"]["name"].as_s             # => "Ada"
# value["user"]["tags"].as_a.map(&.as_s) # => ["x", "y"]
# ```
#
# Invalid UTF-8 is rejected with `Mica::EncodingError` unless the call
# passes `invalid_utf8: :replace_like_browsers` (see `InvalidUTF8Handling`).
module Mica::Form
  # Parses *source* into pairs and builds their nested value, both under
  # one work meter (*meter*, or a new one from `limits.work_budget`).
  #
  # *invalid_utf8* says what happens to bytes that are not valid UTF-8
  # (see `InvalidUTF8Handling`): `:reject` (the default) raises
  # `Mica::EncodingError`, and `:replace_like_browsers` turns each invalid
  # sequence into U+FFFD the way browsers do; the returned value's
  # `Value#has_replaced_invalid_bytes?` then says whether that happened.
  #
  # ```
  # value = Mica::Form.parse("name=Jos%E9", limits: Mica::Form::Limits::REQUEST_BODY, invalid_utf8: :replace_like_browsers)
  # value["name"].as_s                # => "Jos\uFFFD"
  # value.has_replaced_invalid_bytes? # => true
  # ```
  #
  # Raises `Mica::EncodingError` for invalid UTF-8 under `:reject`,
  # `Mica::Form::KeySyntaxError` and `Mica::Form::KeyConflictError` for
  # keys that break the grammar or contradict each other, and
  # `Mica::LimitExceededError` (or its budget and deadline subclasses)
  # when a limit trips.
  def self.parse(source : String | Bytes | IO, *, limits : Limits, meter : Core::WorkMeter? = nil,
                 options : NestedKeys::Options = NestedKeys::Options.new,
                 invalid_utf8 : InvalidUTF8Handling = InvalidUTF8Handling::Reject) : Value
    meter ||= Core::WorkMeter.new(limits.work_budget)
    builder = NestedKeys.new(limits: limits, meter: meter, options: options, invalid_utf8: invalid_utf8)
    Pairs.each(source, limits: limits, meter: meter, invalid_utf8: invalid_utf8) { |pair| builder.add(pair) }
    builder.finish
  end

  # Raised when a form key does not follow the bracket or dot grammar
  # (see `NestedKeys`). The position is the offset of the pair.
  class KeySyntaxError < Mica::ParseError
  end

  # Raised when two form keys need different kinds of value at the same
  # path, or (with `NestedKeys::DuplicateLeaves::Reject`) when a key
  # repeats. The position is the offset of the later pair.
  class KeyConflictError < Mica::ParseError
  end

  # :nodoc:
  module Metering
    # Most operations charged at once, and the window a search reads
    # between charges.
    SCAN_CHUNK = 64 * 1024

    # Charges *count* operations to *meter* in pieces of at most
    # `SCAN_CHUNK`, so a refused charge records at most one piece past
    # the allowance. The block gives the error position.
    def self.charge(meter : Core::WorkMeter, count : Int, & : -> Core::Position) : Nil
      remaining = count.to_i64
      while remaining > 0
        piece = Math.min(remaining, SCAN_CHUNK.to_i64)
        meter.enforce { yield } if meter.charge(piece)
        remaining -= piece
      end
    end
  end
end

require "./form/limits"
require "./form/invalid_utf8_handling"
require "./form/pairs"
require "./form/value"
require "./form/nested_keys"
