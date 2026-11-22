# Each line below holds one pattern Mica leaves out; the spec expects the
# script to name every one of them, and no other line.
module Fixture
  LOOKAHEAD     = /JOIN (?!ON\b)(\w+)/i
  LOOKBEHIND    = /(?<![\w.])users\./
  BACKREFERENCE = /<(\w+)>.*<\/\1>/
  POSSESSIVE    = /[A-Z]\w*+/
  ATOMIC_GROUP  = /(?>a+)b/
  KEEP_OUT      = /foo\Kbar/
  FROM_A_STRING = Regex.new("a(?=b)")

  def self.interpolated(name : String) : Regex
    /(?<!\w)#{Regex.escape(name)}(?!\w)/
  end

  def self.never_called : Bool
    "ab".matches?(/a(?=b)/)
  end

  macro rooted(type)
    {{ type.stringify.gsub(/(?<![:\w])([A-Z]\w*)/, "::\\1") }}
  end

  macro defines_a_reader(name)
    def {{ name.id }}_reader : Regex
      /{{ name.id }}(?=:)/
    end
  end

  ACCEPTED = /\A[a-z]+(?:-[a-z]+)*\z/
end
