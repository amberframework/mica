# Wall-clock check of the hostile input shapes, independent of Mica's own
# operation counter: times each shape at n and 4n (best of three runs) and
# prints the growth ratio. Shapes bounded by a default limit (depth,
# attributes, entity expansions) scale with n / 10 or n / 100 so both sizes
# stay within the limits. A linear parser shows a ratio near 4; a quadratic
# one near 16.
#
#   crystal-alpha build --release bench/wallclock_shapes.cr -o bin/wallclock_shapes
#   bin/wallclock_shapes [BASE_SIZE]
#
# Build with -Dmica_v0 against the pre-family API (`Mica.parse`) to measure
# an older checkout.
require "../src/mica"

module WallclockShapes
  def self.parse(text : String) : String
    {% if flag?(:mica_v0) %}
      Mica.parse(text)
    {% else %}
      Mica::XML.parse(text)
    {% end %}
    "ok"
  rescue error : Mica::Error
    "#{error.class.name.split("::").last}"
  end

  SHAPES = {
    "CVE-2024-35176 '<' in attribute"         => ->(size : Int32) { %(<a b="#{"<" * size}"/>) },
    "CVE-2024-35176 '&lt;' in attribute"      => ->(size : Int32) { %(<a b="#{"&lt;" * size}"/>) },
    "CVE-2024-39908 comment of '-x'"          => ->(size : Int32) { "<a><!--#{"-x" * size}--></a>" },
    "CVE-2024-39908 PI of '?x'"               => ->(size : Int32) { "<a><?p #{"?x" * size}?></a>" },
    "CVE-2024-39908 CDATA of ']'"             => ->(size : Int32) { "<a><![CDATA[#{"]" * size}]]></a>" },
    "CVE-2024-41123 text of ']>'"             => ->(size : Int32) { "<a>#{"]>" * size}</a>" },
    "CVE-2024-41123 text of white space"      => ->(size : Int32) { "<a>#{" " * size}x</a>" },
    "CVE-2024-43398 deep same-name attrs"     => ->(size : Int32) { (0...size // 100).join { |index| %(<e xmlns:p#{index}="u#{index}" p#{index}:x="1">) } + "</e>" * (size // 100) },
    "CVE-2024-49761 long character reference" => ->(size : Int32) { "<a>&##{"0" * size}65;</a>" },
    "CVE-2024-41946 many entity references"   => ->(size : Int32) { %(<!DOCTYPE a [<!ENTITY e "x">]><a>#{"&e;" * (size // 10)}</a>) },
    "wide element (many attributes)"          => ->(size : Int32) { "<a " + (0...size // 10).join(' ') { |index| %(a#{index}="1") } + "/>" },
    "many namespace declarations in scope"    => ->(size : Int32) { "<r " + (0...size // 10).join(' ') { |index| %(xmlns:p#{index}="u#{index}") } + ">" + (0...size // 10).join { |index| "<p#{index}:e/>" } + "</r>" },
  }

  def self.best_time(text : String) : {Float64, String}
    outcome = ""
    best = Float64::INFINITY
    3.times do
      started = Time.instant
      outcome = parse(text)
      elapsed = (Time.instant - started).total_seconds
      best = elapsed if elapsed < best
    end
    {best, outcome}
  end
end

base = (ARGV[0]? || "20000").to_i
puts "shape\tn\tseconds_n\tseconds_4n\tratio\toutcome_n\toutcome_4n"
WallclockShapes::SHAPES.each do |name, build|
  small_time, small_outcome = WallclockShapes.best_time(build.call(base))
  large_time, large_outcome = WallclockShapes.best_time(build.call(base * 4))
  ratio = small_time > 0 ? large_time / small_time : 0.0
  puts "#{name}\t#{base}\t#{small_time.round(5)}\t#{large_time.round(5)}\t#{ratio.round(2)}\t#{small_outcome}\t#{large_outcome}"
end
