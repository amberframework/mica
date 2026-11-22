module Mica::YAML
  # How plain scalars become values (YAML 1.2.2, chapter 10).
  #
  # - `FailSafe`: every scalar is a string.
  # - `JSON`: `null`, `true`, `false`, decimal integers and floats as JSON
  #   writes them; everything else is a string.
  # - `Core` (the default): the JSON forms plus `~`, `Null`, `TRUE`,
  #   octal (`0o17`) and hexadecimal (`0x1F`) integers, `.inf` and `.nan`.
  #
  # Only plain, untagged scalars are resolved; a quoted or block scalar is
  # a string. The tags `!!str`, `!!int`, `!!float`, `!!bool` and `!!null`
  # choose a type, and `!` keeps the text.
  enum Schema
    FailSafe
    JSON
    Core

    # Returns the value of a plain untagged scalar with the text *text*.
    def resolve(text : String) : Nil | Bool | Int64 | Float64 | String
      return text if fail_safe?
      bytes = text.to_slice
      case bytes.size
      when 0
        return core? ? nil : text
      when 1
        return nil if core? && bytes[0] == 0x7E
      when 4
        return nil if text == "null" || (core? && (text == "Null" || text == "NULL"))
        return true if text == "true" || (core? && (text == "True" || text == "TRUE"))
      when 5
        return false if text == "false" || (core? && (text == "False" || text == "FALSE"))
      else
        # numbers are checked below
      end
      first = bytes[0]
      # Numbers start with a digit, a sign or a dot.
      return text unless (first >= 0x30 && first <= 0x39) || first == 0x2D || first == 0x2B || first == 0x2E
      resolve_number(text, bytes)
    end

    private def resolve_number(text : String, bytes : Bytes) : Int64 | Float64 | String
      if core? && bytes.size > 2 && bytes[0] == 0x30 && (bytes[1] == 0x6F || bytes[1] == 0x78)
        base = bytes[1] == 0x6F ? 8 : 16
        return prefixed_integer(text, bytes, base) || text
      end
      index = 0
      if bytes[0] == 0x2D || (core? && bytes[0] == 0x2B)
        index = 1
      end
      return special_float(text, bytes, index) if core? && index < bytes.size && bytes[index] == 0x2E && !digit?(bytes, index + 1)
      digits_start = index
      while digit?(bytes, index)
        index += 1
      end
      integer_digits = index - digits_start
      if index == bytes.size && integer_digits > 0
        return text if json? && integer_digits > 1 && bytes[digits_start] == 0x30
        return text.to_i64? || text
      end
      fraction_digits = 0
      if index < bytes.size && bytes[index] == 0x2E
        index += 1
        fraction_start = index
        while digit?(bytes, index)
          index += 1
        end
        fraction_digits = index - fraction_start
      end
      return text if integer_digits == 0 && fraction_digits == 0
      return text if json? && (integer_digits == 0 || (integer_digits > 1 && bytes[digits_start] == 0x30))
      if index < bytes.size && (bytes[index] == 0x65 || bytes[index] == 0x45)
        index += 1
        index += 1 if index < bytes.size && (bytes[index] == 0x2D || bytes[index] == 0x2B)
        exponent_start = index
        while digit?(bytes, index)
          index += 1
        end
        return text if index == exponent_start
      end
      return text unless index == bytes.size
      text.to_f64? || text
    end

    private def digit?(bytes : Bytes, index : Int32) : Bool
      index < bytes.size && bytes[index] >= 0x30 && bytes[index] <= 0x39
    end

    private def prefixed_integer(text : String, bytes : Bytes, base : Int32) : Int64?
      value = 0_i64
      index = 2
      while index < bytes.size
        byte = bytes[index]
        digit = if byte >= 0x30 && byte <= 0x39
                  (byte - 0x30).to_i32
                elsif byte >= 0x61 && byte <= 0x66
                  (byte - 0x61).to_i32 + 10
                elsif byte >= 0x41 && byte <= 0x46
                  (byte - 0x41).to_i32 + 10
                else
                  return nil
                end
        return nil if digit >= base
        return nil if value > (Int64::MAX - digit) // base
        value = value * base + digit
        index += 1
      end
      value
    end

    private def special_float(text : String, bytes : Bytes, sign_width : Int32) : Float64 | String
      rest = bytes[sign_width, bytes.size - sign_width]
      if rest == ".inf".to_slice || rest == ".Inf".to_slice || rest == ".INF".to_slice
        return bytes[0] == 0x2D ? -Float64::INFINITY : Float64::INFINITY
      end
      if sign_width == 0 && (rest == ".nan".to_slice || rest == ".NaN".to_slice || rest == ".NAN".to_slice)
        return Float64::NAN
      end
      text
    end
  end
end
