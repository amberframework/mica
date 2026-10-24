# Generates the benchmark inputs into bench/data (deterministic, seeded).
#
#   crystal-alpha run --release bench/generate.cr
require "file_utils"

DATA_DIRECTORY = File.join(__DIR__, "data")
FileUtils.mkdir_p(DATA_DIRECTORY)

WORDS = %w[alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec
  romeo sierra tango uniform victor whiskey xray yankee zulu crystal amber grant micrate storage bucket object]

def words(random : Random, count : Int32) : String
  String.build do |io|
    count.times do |index|
      io << ' ' if index > 0
      io << WORDS[random.rand(WORDS.size)]
    end
  end
end

def write(name : String, & : File ->) : Nil
  path = File.join(DATA_DIRECTORY, name)
  File.open(path, "w") { |file| yield file }
  puts "#{name}: #{File.size(path)} bytes"
end

# 10 MB S3 ListObjectsV2 response.
write("s3_list_objects.xml") do |io|
  random = Random.new(1001)
  io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
  io << %(<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\n)
  io << "  <Name>example-bucket</Name>\n  <Prefix></Prefix>\n  <KeyCount>1000</KeyCount>\n  <MaxKeys>1000</MaxKeys>\n  <IsTruncated>true</IsTruncated>\n"
  index = 0
  while io.pos < 10_000_000
    io << "  <Contents>\n"
    io << "    <Key>photos/2026/" << words(random, 2).gsub(' ', '-') << '/' << index << ".jpg</Key>\n"
    io << "    <LastModified>2026-10-" << (1 + random.rand(28)).to_s.rjust(2, '0') << "T12:" << random.rand(60).to_s.rjust(2, '0') << ":00.000Z</LastModified>\n"
    io << "    <ETag>&quot;" << random.hex(16) << "&quot;</ETag>\n"
    io << "    <Size>" << random.rand(10_000_000) << "</Size>\n"
    io << "    <Owner>\n      <ID>" << random.hex(32) << "</ID>\n      <DisplayName>owner-" << random.rand(100) << "</DisplayName>\n    </Owner>\n"
    io << "    <StorageClass>STANDARD</StorageClass>\n"
    io << "  </Contents>\n"
    index += 1
  end
  io << "  <NextContinuationToken>" << random.hex(40) << "</NextContinuationToken>\n"
  io << "</ListBucketResult>\n"
end

# 1 MB RSS 2.0 feed with escaped HTML and CDATA descriptions.
write("rss_feed.xml") do |io|
  random = Random.new(2002)
  io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
  io << %(<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/">\n)
  io << "<channel>\n  <title>Amber Weekly</title>\n  <link>https://example.com/</link>\n  <description>News &amp; notes</description>\n"
  io << %(  <atom:link href="https://example.com/feed.xml" rel="self" type="application/rss+xml"/>\n)
  index = 0
  while io.pos < 1_000_000
    io << "  <item>\n"
    io << "    <title>" << words(random, 6).capitalize << " &amp; " << words(random, 2) << "</title>\n"
    io << "    <link>https://example.com/posts/" << index << "</link>\n"
    io << "    <guid isPermaLink=\"false\">urn:uuid:" << random.hex(16) << "</guid>\n"
    io << "    <pubDate>Sat, 24 Oct 2026 0" << random.rand(10) << ":00:00 GMT</pubDate>\n"
    io << "    <dc:creator>" << words(random, 2) << "</dc:creator>\n"
    io << "    <category>" << WORDS[random.rand(WORDS.size)] << "</category>\n"
    io << "    <description>&lt;p&gt;" << words(random, 30) << "&lt;/p&gt;</description>\n"
    io << "    <content:encoded><![CDATA[<p>" << words(random, 60) << "</p><p><a href=\"https://example.com\">more</a></p>]]></content:encoded>\n"
    io << "  </item>\n"
    index += 1
  end
  io << "</channel>\n</rss>\n"
end

# 50 MB synthetic document: mixed content, attributes, namespaces,
# comments, entity and character references.
write("synthetic_50mb.xml") do |io|
  random = Random.new(3003)
  io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
  io << %(<catalog xmlns="urn:example:catalog" xmlns:x="urn:example:extra">\n)
  index = 0
  while io.pos < 50_000_000
    io << %(  <record id=") << index << %(" kind=") << WORDS[random.rand(WORDS.size)] << %(" x:rank=") << random.rand(1000) << %(">\n)
    io << "    <title>" << words(random, 5) << "</title>\n"
    io << "    <summary>" << words(random, 25) << " &amp; " << words(random, 5) << " &#169; 2026</summary>\n"
    io << %(    <price currency="EUR">) << random.rand(10_000) << '.' << random.rand(100).to_s.rjust(2, '0') << "</price>\n"
    io << "    <tags>"
    3.times { io << "<tag>" << WORDS[random.rand(WORDS.size)] << "</tag>" }
    io << "</tags>\n"
    io << "    <!-- record " << index << " -->\n" if index % 10 == 0
    io << "    <note>Größe: " << random.rand(100) << " — café</note>\n" if index % 7 == 0
    io << "  </record>\n"
    index += 1
  end
  io << "</catalog>\n"
end

# Deep nesting: repeated chains 250 levels deep (libxml2's default limit is 256).
write("deep_nesting.xml") do |io|
  io << %(<?xml version="1.0" encoding="UTF-8"?>\n<root>\n)
  while io.pos < 10_000_000
    249.times { |level| io << "<n" << (level % 10) << '>' }
    io << "leaf"
    249.times { |level| io << "</n" << ((248 - level) % 10) << '>' }
    io << '\n'
  end
  io << "</root>\n"
end

# Attribute-heavy: 30 attributes per element.
write("attribute_heavy.xml") do |io|
  random = Random.new(5005)
  io << %(<?xml version="1.0" encoding="UTF-8"?>\n<rows>\n)
  index = 0
  while io.pos < 10_000_000
    io << "  <row"
    30.times { |column| io << " c" << column << %(=") << WORDS[random.rand(WORDS.size)] << random.rand(1000) << '"' }
    io << " id=\"" << index << "\"/>\n"
    index += 1
  end
  io << "</rows>\n"
end
