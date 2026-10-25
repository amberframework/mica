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
module Mica::Form
  # Parses *source* into pairs and builds their nested value, both under
  # one work meter (*meter*, or a new one from `limits.work_budget`).
  #
  # Raises `Mica::EncodingError` for invalid UTF-8,
  # `Mica::Form::KeySyntaxError` and `Mica::Form::KeyConflictError` for
  # keys that break the grammar or contradict each other, and
  # `Mica::LimitExceededError` (or its budget and deadline subclasses)
  # when a limit trips.
  def self.parse(source : String | Bytes | IO, *, limits : Limits, meter : Core::WorkMeter? = nil,
                 options : NestedKeys::Options = NestedKeys::Options.new) : Value
    meter ||= Core::WorkMeter.new(limits.work_budget)
    builder = NestedKeys.new(limits: limits, meter: meter, options: options)
    Pairs.each(source, limits: limits, meter: meter) { |pair| builder.add(pair) }
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
require "./form/pairs"
require "./form/value"
require "./form/nested_keys"
