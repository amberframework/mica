# The smallest useful Mica::XML program: parse, query, serialize. Its
# dynamic libraries are what any Mica::XML user links (see
# scripts/check_linkage.sh).
require "../../src/mica"

document = Mica::XML.parse(ARGV[0]? || "<a><b>1</b></a>")
STDOUT << document.xpath_float("count(//*)") << '\n'
STDOUT << document.to_xml << '\n'
