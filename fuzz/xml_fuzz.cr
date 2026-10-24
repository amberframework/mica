# The XML layer over Mica::Testing::ByteMutator and FuzzCampaign, shared by
# spec/xml/fuzz_spec.cr, fuzz/campaign.cr and fuzz/differential.cr.
require "../src/mica"
require "../src/mica/testing"

module XMLFuzz
  SEEDS = [
    %(<?xml version="1.0" encoding="UTF-8"?>\n<root a="1" b='two'><child>text</child><empty/></root>),
    %(<!DOCTYPE r [<!ENTITY e "<i>x</i>&amp;"><!ENTITY t "plain"><!ATTLIST r d CDATA "def" n NMTOKENS #IMPLIED>]><r n=" a  b ">&e;&t;&#65;&#x42;</r>),
    %(<r xmlns="urn:d" xmlns:p="urn:p"><p:e p:a="1" b="2"><x xmlns=""/></p:e></r>),
    %(<a><![CDATA[<not>markup]]]]><![CDATA[>]]><!-- comment --><?pi data?></a>),
    %(<a>line1\r\nline2\rline3\n<b attr="x\ty\r\nz"/></a>),
    %(<?xml version="1.0" standalone="yes"?><!DOCTYPE a [<!ELEMENT a (b|c)*><!ELEMENT b EMPTY><!ATTLIST b id ID #REQUIRED><!NOTATION n PUBLIC "pub">]><a><b id="i1"/></a>),
    %(<!DOCTYPE a [<!ENTITY % pe "<!ENTITY g 'from-pe'>">%pe;<!ENTITY ext SYSTEM "ext.xml">]><a>&g;&ext;</a>),
    %(<feed><title>Café — Größe 😀</title><entry id="1"><summary>a &lt; b &gt; c</summary></entry></feed>),
    %(<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Contents><Key>a.txt</Key><ETag>&quot;abc&quot;</ETag><Size>1</Size></Contents></ListBucketResult>),
    %(<rss version="2.0"><channel><item><title>T</title><description><![CDATA[<p>Hi</p>]]></description></item></channel></rss>),
    %(<a b="&#x10FFFF;&#9;" c='"'><d e="'"/></a>),
    %(<!DOCTYPE doc [<!ELEMENT doc (#PCDATA|e)*><!ENTITY x "&#60;e/&#62;">]><doc>&x;</doc>),
    %(<root>#{"<n>" * 40}deep#{"</n>" * 40}</root>),
    %(<?xml version="1.0"?><!-- c --><?pi?><r/><!-- after --><?pi after?>),
    %(<?xml version="1.1"?><r a="x\u0085y">&#x1;&#x85;line\u0085next end\r\u0085</r>),
    %(<?xml version="1.1"?><r xmlns:p="urn:p"><p:a><b xmlns:p=""/></p:a></r>),
    %(<?xml version="1.0" encoding="ISO-8859-1"?><r>plain</r>),
    %(<?xml version="1.0" encoding="US-ASCII"?><r a="b">c</r>),
  ].map(&.to_slice)

  TOKENS = ["<", ">", "&", ";", "&amp;", "&#", "&#x", "&#0", "]]>", "<!--", "-->", "<![CDATA[", "<?", "?>", "</",
            "/>", "\"", "'", "=", " ", "\t", "\r", "\n", "<!ENTITY ", "<!DOCTYPE ", "<!ATTLIST ", "%", "&e;",
            "xmlns:", "xmlns=\"\"", "xmlns:p=\"\"", ":", "<a>", "</a>", "\u0085", " ", "&#x85;", "&#x1;",
            %(<?xml version="1.1"?>), %(<?xml version="1.0" encoding="UTF-16"?>), %(<?xml version="1.0" encoding="ISO-8859-1"?>),
            %(<?xml version="1.0" encoding="US-ASCII"?>), %(<?xml version="1.0" encoding="UTF-32"?>)].map(&.to_slice)

  MUTATOR = Mica::Testing::ByteMutator.new(SEEDS, TOKENS)

  # Most work the reader does between two budget checks: a scan chunk, a
  # name, and the per-token bookkeeping around them.
  OVERRUN_SLACK = 200_000_i64

  # A tight budget used for one case in four, so budget trips happen and
  # their containment is checked.
  TIGHT_BUDGET = Mica::Core::WorkBudget.new(operations_per_unit: 2, base_operations: 100)

  # Parses *bytes* in memory and through a trickle IO, compares the two,
  # and checks that an accepted document round-trips stably. Raises
  # (making the campaign record a crash) on anything but a Mica::Error.
  def self.trial(bytes : Bytes, iteration : Int32) : Mica::Testing::FuzzCampaign::Trial
    tight = iteration % 4 == 3
    budget = tight ? TIGHT_BUDGET : Mica::XML::ParserOptions::DEFAULT_WORK_BUDGET
    options = Mica::XML::ParserOptions.new(work_budget: budget)
    meter = Mica::Core::WorkMeter.new(budget)
    in_memory = full_events(Mica::XML::Reader.new(bytes, options, meter))
    chunk = 1 + iteration % 7
    streamed = full_events(Mica::XML::Reader.new(TrickleIO.new(bytes, chunk), options))
    failures = [] of String
    if in_memory[0] != streamed[0] && !budget_error?(in_memory[1]) && !budget_error?(streamed[1])
      failures << "String and #{chunk}-byte IO disagree: #{in_memory[0][0, 200].inspect} vs #{streamed[0][0, 200].inspect}"
    end
    error = in_memory[1]
    if error.nil? && !tight
      first = Mica::XML.parse(bytes).to_xml(indent: 0)
      second = Mica::XML.parse(first).to_xml(indent: 0)
      failures << "round trip not stable" unless first == second
    end
    Mica::Testing::FuzzCampaign::Trial.new(in_memory[0], error, meter, failures)
  end

  # Events plus the error position, so String and IO runs must agree on
  # where they failed too.
  private def self.full_events(reader : Mica::XML::Reader) : {String, Mica::Error?}
    text = String::Builder.new
    failure = nil
    begin
      while reader.read
        text << reader.node_type << ':' << reader.depth << ':' << reader.name << '=' << reader.value.inspect
        if reader.move_to_first_attribute
          loop do
            text << " @" << reader.name << '=' << reader.value.inspect
            break unless reader.move_to_next_attribute
          end
          reader.move_to_element
        end
        text << '\n'
      end
    rescue error : Mica::Error
      failure = error
      text << error.class << ": " << error.message
    end
    {text.to_s, failure}
  end

  private def self.budget_error?(error : Mica::Error?) : Bool
    error.is_a?(Mica::WorkBudgetExceededError) || error.is_a?(Mica::DeadlineExceededError)
  end

  # An IO that returns at most *chunk* bytes per read, to exercise refills
  # and compaction at every byte boundary.
  class TrickleIO < IO
    def initialize(@bytes : Bytes, @chunk : Int32)
      @offset = 0
    end

    def read(slice : Bytes) : Int32
      count = Math.min(Math.min(@chunk, slice.size), @bytes.size - @offset)
      return 0 if count <= 0
      slice[0, count].copy_from(@bytes[@offset, count])
      @offset += count
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("read-only")
    end
  end
end
