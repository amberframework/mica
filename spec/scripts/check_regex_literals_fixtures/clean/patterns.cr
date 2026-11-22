# Nothing here stops a program whose Regex engine is Mica.
module Fixture
  WORD        = /\A[A-Za-z_]\w*\z/
  NAMED       = /(?<year>\d{4})-(?<month>\d{2})/
  FROM_STRING = Regex.new("^(?:a|b)+$")

  def self.interpolated(name : String) : Regex
    /(?:^|[^\w])#{Regex.escape(name)}(?:$|[^\w])/i
  end

  {% if flag?(:use_pcre2) %}
    # mica: pcre2 only
    ONLY_ON_PCRE2 = /a(?=b)/
  {% end %}

  # mica: pcre2 only
  REFERENCE = Regex.new("(?<!a)b")
end
