# Generates src/mica/regex/unicode/tables.cr from the Unicode Character
# Database named in manifest.json (fetched once, checked against its
# sha256, cached under tmp/regex-corpora/).
#
#   /usr/bin/ruby scripts/unicode/generate_tables.rb
#
# The property sets follow PCRE2 10.49's own generator (maint/GenerateUcd.py,
# GenerateCommon.py and GenerateUcpTables.py), because the Crystal dialect of
# Mica::Regex accepts exactly the property names PCRE2 accepts:
#
# - general categories from extracted/DerivedGeneralCategory.txt (Cn default);
# - scripts from Scripts.txt (Unknown default) and script extensions from
#   ScriptExtensions.txt; a script that appears in no extension list is
#   script-only, as in PCRE2;
# - Bidi classes from extracted/DerivedBidiClass.txt, @missing lines included;
# - Boolean properties named in PropList.txt, DerivedCoreProperties.txt and
#   emoji/emoji-data.txt (except Other_* and Hyphen), plus ASCII and
#   Bidi_Mirrored (from BidiMirroring.txt);
# - case-insensitive orbits from the C and S lines of CaseFolding.txt.
#
# When the pinned PCRE2 archive has been unpacked by
# conformance/regex/pcre2/convert_testdata.rb, the loose-name table is
# compared with PCRE2's src/pcre2_ucptables_inc.h and any difference stops
# the script.
require "json"
require "digest"
require "fileutils"
require "open3"
require "set"

ROOT = File.expand_path("../..", __dir__)
MANIFEST = JSON.parse(File.read(File.join(__dir__, "manifest.json")))
CACHE = File.join(ROOT, "tmp", "regex-corpora")
UCD = File.join(CACHE, "ucd-#{MANIFEST.fetch("version")}")
OUTPUT = File.join(ROOT, "src", "mica", "regex", "unicode", "tables.cr")
PCRE2_TABLE = File.join(CACHE, "pcre2-10.49", "src", "pcre2_ucptables_inc.h")
MAX = 0x110000

def fetch_ucd
  FileUtils.mkdir_p(CACHE)
  archive = File.join(CACHE, MANIFEST.fetch("archive"))
  unless File.exist?(archive)
    _, status = Open3.capture2("curl", "-sSfL", "-A", "AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)",
      "-o", archive, MANIFEST.fetch("url"))
    abort("download failed: #{MANIFEST.fetch("url")}") unless status.success?
  end
  actual = Digest::SHA256.file(archive).hexdigest
  if actual != MANIFEST.fetch("sha256")
    File.delete(archive)
    abort("sha256 mismatch for #{archive}: expected #{MANIFEST.fetch("sha256")}, got #{actual}")
  end
  unless Dir.exist?(UCD)
    FileUtils.mkdir_p(UCD)
    _, status = Open3.capture2("unzip", "-q", archive, "-d", UCD)
    abort("unzip failed for #{archive}") unless status.success?
  end
end

def ucd_lines(relative)
  File.readlines(File.join(UCD, relative), encoding: "UTF-8")
end

# Yields (first, last, fields) for each data line; *keep_missing* turns
# "# @missing:" lines into data, as PCRE2 does for DerivedBidiClass.txt.
def each_entry(relative, keep_missing: false)
  ucd_lines(relative).each do |raw|
    line = keep_missing ? raw.sub("# @missing: ", "") : raw
    line = line.sub(/#.*/, "")
    fields = line.split(";").map(&:strip)
    next if fields.size <= 1
    match = fields[0].match(/\A([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\z/)
    abort("bad code point field in #{relative}: #{raw}") unless match
    first = match[1].to_i(16)
    last = match[2] ? match[2].to_i(16) : first
    yield first, last, fields
  end
end

# A per-code-point table filled from a file, last assignment winning.
def read_table(relative, default, keep_missing: false)
  table = Array.new(MAX, default)
  each_entry(relative, keep_missing: keep_missing) do |first, last, fields|
    value = yield(fields)
    next if value.nil?
    (first..last).each { |code_point| table[code_point] = value }
  end
  table
end

# Sorted, merged ranges of the code points where the block is true.
def ranges_where
  ranges = []
  start = nil
  MAX.times do |code_point|
    if yield(code_point)
      start ||= code_point
    elsif start
      ranges << [start, code_point - 1]
      start = nil
    end
  end
  ranges << [start, MAX - 1] if start
  ranges
end

def ranges_of_list(code_points)
  sorted = code_points.uniq.sort
  ranges = []
  sorted.each do |code_point|
    if ranges.any? && ranges.last[1] + 1 == code_point
      ranges.last[1] = code_point
    else
      ranges << [code_point, code_point]
    end
  end
  ranges
end

def stdname(name)
  name.downcase.delete("_")
end

fetch_ucd

# ---- General category ----------------------------------------------------
CATEGORIES = %w[Cc Cf Cn Co Cs Ll Lm Lo Lt Lu Mc Me Mn Nd Nl No Pc Pd Pe Pf Pi Po Ps Sc Sk Sm So Zl Zp Zs].freeze
category = read_table("extracted/DerivedGeneralCategory.txt", "Cn") { |fields| fields[1] }
abort("unknown category") unless (category.uniq - CATEGORIES).empty?

# ---- Scripts -------------------------------------------------------------
script_names = ["Unknown"]
ucd_lines("Scripts.txt").each do |line|
  match = line.match(/\A[0-9A-F]{4,6}(?:\.\.[0-9A-F]{4,6})? +; ([A-Za-z_]+) #/)
  next unless match
  script_names << match[1] unless script_names.last == match[1] || script_names.include?(match[1])
end
script_of = read_table("Scripts.txt", "Unknown") { |fields| fields[1] }

abbreviations = {}
ucd_lines("PropertyValueAliases.txt").each do |line|
  match = line.match(/\A *([A-Za-z_]+) *; *([A-Za-z_]+) *; *([A-Za-z_]+)(?: *; *([A-Za-z_ ]+))?/)
  next unless match && match[1] == "sc"
  abbreviations[match[3]] = if match[2] == match[3]
                              []
                            elsif match[4].nil?
                              [match[2]]
                            else
                              [match[2], match[4]]
                            end
end
script_abbreviation = {}
script_names.each do |name|
  list = abbreviations.fetch(name)
  script_abbreviation[name] = list.empty? ? name : list.first
end
by_abbreviation = script_abbreviation.invert

extension_abbreviations = Set.new
extensions = Array.new(MAX)
each_entry("ScriptExtensions.txt") do |first, last, fields|
  list = fields[1].split(" ")
  list.each { |abbreviation| extension_abbreviations << abbreviation }
  (first..last).each { |code_point| extensions[code_point] = list.map { |abbreviation| by_abbreviation.fetch(abbreviation) } }
end

# ---- Bidi classes ----------------------------------------------------------
BIDI = {
  "AL" => "Arabic_Letter", "AN" => "Arabic_Number", "B" => "Paragraph_Separator",
  "BN" => "Boundary_Neutral", "CS" => "Common_Separator", "EN" => "European_Number",
  "ES" => "European_Separator", "ET" => "European_Terminator", "FSI" => "First_Strong_Isolate",
  "L" => "Left_To_Right", "LRE" => "Left_To_Right_Embedding", "LRI" => "Left_To_Right_Isolate",
  "LRO" => "Left_To_Right_Override", "NSM" => "Nonspacing_Mark", "ON" => "Other_Neutral",
  "PDF" => "Pop_Directional_Format", "PDI" => "Pop_Directional_Isolate", "R" => "Right_To_Left",
  "RLE" => "Right_To_Left_Embedding", "RLI" => "Right_To_Left_Isolate", "RLO" => "Right_To_Left_Override",
  "S" => "Segment_Separator", "WS" => "White_Space",
}.freeze
bidi_by_long = BIDI.invert
bidi = read_table("extracted/DerivedBidiClass.txt", "L", keep_missing: true) do |fields|
  fields[1].size > 3 ? bidi_by_long.fetch(fields[1]) : (BIDI.key?(fields[1]) ? fields[1] : abort("bidi #{fields[1]}"))
end

# ---- Boolean properties ------------------------------------------------------
BOOL_FILES = ["PropList.txt", "DerivedCoreProperties.txt", "emoji/emoji-data.txt"].freeze
bool_names = []
BOOL_FILES.each do |file|
  last = ""
  ucd_lines(file).each do |raw|
    fields = raw.sub(/#.*/, "").split(";").map(&:strip)
    next if fields.size <= 1 || fields[1] == last
    last = fields[1]
    next if last =~ /\AOther_/ || last == "Hyphen"
    bool_names << last unless bool_names.include?(last)
  end
end
bool_names += %w[ASCII Bidi_Mirrored]
bool_names.sort!
bool_members = Hash.new { |hash, key| hash[key] = [] }
BOOL_FILES.each do |file|
  each_entry(file) do |first, last, fields|
    next unless bool_names.include?(fields[1])
    bool_members[fields[1]] << [first, last]
  end
end
bool_members["ASCII"] << [0, 127]
each_entry("BidiMirroring.txt") { |first, _last, _fields| bool_members["Bidi_Mirrored"] << [first, first] }
ucd_lines("PropertyAliases.txt").each do |line|
  match = line.match(/\A *([A-Za-z_]+) *; *([A-Za-z_]+)(?: *; *([A-Za-z_]+))?/)
  next unless match && match[2] != match[1] && bool_names.include?(match[2])
  abbreviations[match[2]] = match[3] ? [match[1], match[3]] : [match[1]]
end

def merge(ranges)
  merged = []
  ranges.sort.each do |first, last|
    if merged.any? && first <= merged.last[1] + 1
      merged.last[1] = last if last > merged.last[1]
    else
      merged << [first, last]
    end
  end
  merged
end

# ---- Sets --------------------------------------------------------------------
list_of_sets = []
set_ids = {}
add_set = lambda do |key, ranges|
  set_ids[key] = list_of_sets.size
  list_of_sets << merge(ranges)
end

CATEGORIES.each { |name| add_set.call("gc:#{name}", ranges_where { |code_point| category[code_point] == name }) }
%w[C L M N P S Z].each do |group|
  add_set.call("gcg:#{group}", ranges_where { |code_point| category[code_point].start_with?(group) })
end
add_set.call("lamp", ranges_where { |code_point| %w[Lu Ll Lt].include?(category[code_point]) })
script_names.each do |name|
  add_set.call("sc:#{name}", ranges_where { |code_point| script_of[code_point] == name })
  if extension_abbreviations.include?(script_abbreviation[name])
    add_set.call("scx:#{name}", ranges_where do |code_point|
      list = extensions[code_point]
      list ? list.include?(name) : script_of[code_point] == name
    end)
  end
end
BIDI.keys.each { |short| add_set.call("bidi:#{short}", ranges_where { |code_point| bidi[code_point] == short }) }
bool_names.each { |name| add_set.call("bool:#{name}", bool_members[name]) }

HSPACE = [0x09, 0x20, 0xa0, 0x1680, 0x180e, *0x2000..0x200a, 0x202f, 0x205f, 0x3000].freeze
VSPACE = [0x0a, 0x0b, 0x0c, 0x0d, 0x85, 0x2028, 0x2029].freeze
add_set.call("any", [[0, MAX - 1]])
add_set.call("xan", ranges_where { |code_point| "LN".include?(category[code_point][0]) })
add_set.call("xsp", ranges_where { |code_point| category[code_point][0] == "Z" || HSPACE.include?(code_point) || VSPACE.include?(code_point) })
add_set.call("xwd", ranges_where { |code_point| "LN".include?(category[code_point][0]) || %w[Mn Pc].include?(category[code_point]) })
add_set.call("xuc", ranges_of_list([0x24, 0x40, 0x60]) + [[0xa0, 0xd7ff], [0xe000, MAX - 1]])
add_set.call("hspace", ranges_of_list(HSPACE))
add_set.call("vspace", ranges_of_list(VSPACE))
graph_exceptions = [0x061c, 0x180e, *0x2066..0x2069]
add_set.call("pxgraph", ranges_where do |code_point|
  name = category[code_point]
  name[0] != "Z" && (name[0] != "C" || (name == "Cf" && !graph_exceptions.include?(code_point)))
end)
print_exceptions = [0x061c, *0x2066..0x2069]
add_set.call("pxprint", ranges_where do |code_point|
  name = category[code_point]
  name != "Zl" && name != "Zp" && (name[0] != "C" || (name == "Cf" && !print_exceptions.include?(code_point)))
end)
add_set.call("pxpunct", ranges_where { |code_point| category[code_point][0] == "P" || (code_point < 128 && category[code_point][0] == "S") })
add_set.call("pxxdigit", [[0x30, 0x39], [0x41, 0x46], [0x61, 0x66], [0xff10, 0xff19], [0xff21, 0xff26], [0xff41, 0xff46]])

# ---- Loose names, as GenerateUcpTables.py builds them ------------------------
names = {}
add_name = lambda do |loose, value|
  if names.key?(loose) && names[loose] != value
    abort("loose name #{loose} maps to two properties: #{names[loose].inspect} and #{value.inspect}")
  end
  names[loose] = value
end
script_names.each do |name|
  extended = extension_abbreviations.include?(script_abbreviation[name])
  value = extended ? ["ScriptExtensions", "scx:#{name}", "sc:#{name}"] : ["Script", "sc:#{name}", "sc:#{name}"]
  add_name.call(stdname(name), value)
  abbreviations.fetch(name).each { |abbreviation| add_name.call(stdname(abbreviation), value) }
end
CATEGORIES.each { |name| add_name.call(stdname(name), ["GeneralCategory", "gc:#{name}", "gc:#{name}"]) }
%w[C L M N P S Z].each { |group| add_name.call(stdname(group), ["GeneralCategoryGroup", "gcg:#{group}", "gcg:#{group}"]) }
BIDI.keys.each { |short| add_name.call(stdname("bidi#{short}"), ["BidiClass", "bidi:#{short}", "bidi:#{short}"]) }
bool_names.each do |name|
  value = ["Boolean", "bool:#{name}", "bool:#{name}"]
  add_name.call(stdname(name), value)
  (abbreviations[name] || []).each { |abbreviation| add_name.call(stdname(abbreviation), value) }
end
add_name.call("any", %w[Any any any])
add_name.call("l&", %w[LetterAmpersand lamp lamp])
add_name.call("lc", %w[LetterAmpersand lamp lamp])
add_name.call("xan", %w[Alnum xan xan])
add_name.call("xps", %w[Space xsp xsp])
add_name.call("xsp", %w[Space xsp xsp])
add_name.call("xuc", %w[UniversalName xuc xuc])
add_name.call("xwd", %w[Word xwd xwd])

if File.exist?(PCRE2_TABLE)
  pcre2_names = File.read(PCRE2_TABLE).scan(/^#define STRING_(\S+)0 /).flatten.map { |name| name.sub("_AMPERSAND", "&") }
  missing = pcre2_names - names.keys
  extra = names.keys - pcre2_names
  abort("loose names differ from PCRE2: missing #{missing.inspect}, extra #{extra.inspect}") unless missing.empty? && extra.empty?
  puts "loose names match PCRE2 10.49 (#{pcre2_names.size})"
else
  puts "PCRE2 table not unpacked; skipped the name cross-check"
end

# ---- Case folding orbits -------------------------------------------------------
parent = {}
find = lambda do |code_point|
  root = code_point
  root = parent[root] while parent.key?(root) && parent[root] != root
  root
end
each_entry("CaseFolding.txt") do |first, _last, fields|
  next unless %w[C S].include?(fields[1])
  folded = fields[2].to_i(16)
  [first, folded].each { |code_point| parent[code_point] ||= code_point }
  left = find.call(first)
  right = find.call(folded)
  parent[left] = right unless left == right
end
orbits = parent.keys.group_by { |code_point| find.call(code_point) }.values.map(&:sort)
next_in_orbit = {}
orbits.each do |orbit|
  orbit.each_with_index { |code_point, index| next_in_orbit[code_point] = orbit[(index + 1) % orbit.size] }
end
largest_orbit = orbits.map(&:size).max

# ---- Output ---------------------------------------------------------------------
# Every table is a read-only `Slice(Int32).literal` (or a string literal):
# static data in the binary, read in place, so the tables cost no heap,
# no decoding and no work at program start.

# The values of `Mica::Regex::Unicode::PropertyKind`, in its declaration
# order (src/mica/regex/unicode.cr); `PROPERTY_NAMES` stores each kind as
# its value.
PROPERTY_KINDS = %w[GeneralCategory GeneralCategoryGroup LetterAmpersand Script ScriptExtensions BidiClass Boolean Any
  Alnum Space UniversalName Word].freeze

def string_literal(io, data, indent)
  data.scan(/.{1,96}/).each_with_index do |chunk, index|
    io << (index.zero? ? "" : " \\\n#{indent}") << "\"" << chunk << "\""
  end
end

# Writes `Slice(Int32).literal(...)` of *values*, *per_line* to a line.
def int_slice_literal(io, values, per_line, indent, &format)
  io << "Slice(Int32).literal(\n"
  values.each_slice(per_line) do |line|
    io << indent << "  " << line.map { |value| format ? format.call(value) : value.to_s }.join(", ") << ",\n"
  end
  io << indent << ")"
end

def hex(value)
  format("0x%X", value)
end

range_values = []
set_values = []
list_of_sets.each do |ranges|
  set_values << range_values.size / 2 << ranges.size
  ranges.each { |first, last| range_values << first << last }
end
fold_values = []
next_in_orbit.keys.sort.each { |code_point| fold_values << code_point << next_in_orbit[code_point] }
# One bit per code point below U+10000 for the UCP word set (`xwd`).
word_bits = Array.new(1024, 0)
list_of_sets[set_ids.fetch("xwd")].each do |first, last|
  next if first >= 0x10000
  (first..[last, 0xFFFF].min).each { |code_point| word_bits[code_point >> 6] |= 1 << (code_point & 63) }
end
name_text = +""
name_values = []
names.keys.sort.each do |loose|
  kind, set, script_set = names[loose]
  kind_value = PROPERTY_KINDS.index(kind) || abort("unknown property kind #{kind}")
  name_values << name_text.bytesize << loose.bytesize << kind_value << set_ids.fetch(set) << set_ids.fetch(script_set)
  name_text << loose
end

FileUtils.mkdir_p(File.dirname(OUTPUT))
File.open(OUTPUT, "w") do |io|
  io << "# GENERATED by scripts/unicode/generate_tables.rb from the Unicode Character\n"
  io << "# Database #{MANIFEST.fetch("version")} (#{MANIFEST.fetch("url")},\n"
  io << "# sha256 #{MANIFEST.fetch("sha256")}). Do not edit by hand.\n"
  io << "module Mica::Regex::Unicode\n"
  io << "  # :nodoc:\n"
  io << "  module Tables\n"
  io << "    VERSION = #{MANIFEST.fetch("version").inspect}\n"
  io << "    UCD_SHA256 = #{MANIFEST.fetch("sha256").inspect}\n\n"
  io << "    # The ranges of every set, as `first, last` code point pairs.\n"
  io << "    RANGES = "
  int_slice_literal(io, range_values, 12, "    ") { |value| hex(value) }
  io << "\n\n    # Each set as `first range index, range count`.\n"
  io << "    SETS = "
  int_slice_literal(io, set_values, 12, "    ")
  io << "\n\n    # The number of sets.\n"
  io << "    SET_COUNT = #{list_of_sets.size}\n\n"
  set_ids.each do |key, id|
    constant = "SET_" + key.upcase.gsub(/[^A-Z0-9]+/, "_")
    io << "    #{constant} = #{id}\n" if key =~ /\A(gc|gcg|lamp|any|xan|xsp|xwd|xuc|hspace|vspace|px|bool:(ASCII|White_Space)\z)/
  end
  io << "\n    # One bit per code point below U+10000, set for the UCP word set\n"
  io << "    # (`SET_XWD`): bit `c & 63` of word `c >> 6`.\n"
  io << "    WORD_BITS = Slice(UInt64).literal(\n"
  word_bits.each_slice(4) do |line|
    io << "      " << line.map { |value| format("0x%016X_u64", value) }.join(", ") << ",\n"
  end
  io << "    )\n"
  io << "\n    # Loose property names (lower case, no underscores, as PCRE2 matches\n"
  io << "    # them), sorted by byte and written one after another.\n"
  io << "    PROPERTY_NAME_TEXT = "
  string_literal(io, name_text, "      ")
  io << "\n\n    # Each loose name, in `PROPERTY_NAME_TEXT` order, as its byte offset there,\n"
  io << "    # its bytesize, its `PropertyKind` value, its set and its script-only set.\n"
  io << "    PROPERTY_NAMES = "
  int_slice_literal(io, name_values, 15, "    ")
  io << "\n\n    # The number of loose names.\n"
  io << "    PROPERTY_NAME_COUNT = #{names.size}\n\n"
  io << "    # Simple case folding orbits (CaseFolding.txt C and S) as `code point,\n"
  io << "    # next member of its orbit` pairs sorted by code point (the members form\n"
  io << "    # a cycle).\n"
  io << "    LARGEST_ORBIT = #{largest_orbit}\n"
  io << "    FOLD_ORBITS = "
  int_slice_literal(io, fold_values, 12, "    ") { |value| hex(value) }
  io << "\n  end\nend\n"
end
# The committed file is in crystal-alpha tool format layout, so a rerun
# reproduces it byte for byte.
formatted = system("crystal-alpha", "tool", "format", OUTPUT)
abort "crystal-alpha tool format failed on #{OUTPUT}" unless formatted
puts "wrote #{OUTPUT.sub(ROOT + "/", "")}: #{list_of_sets.size} sets, #{range_values.size / 2} ranges, " \
     "#{names.size} names, #{next_in_orbit.size} folding entries in #{orbits.size} orbits (largest #{largest_orbit})"
