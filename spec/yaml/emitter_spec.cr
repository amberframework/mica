require "../spec_helper"
require "../../src/mica/yaml/emitter"

# Every expected string below is what libyaml 0.2.5 wrote for the same
# events, driven through the standard library's YAML::Builder (and, for the
# flags the Builder does not expose, through the same libyaml calls).
# fuzz/yaml_emitter_differential.cr compares the two emitters on generated
# event sequences.

# Returns what the emitter writes for one stream; the block adds the
# events between STREAM-START and STREAM-END.
private def emitted(& : Mica::YAML::Emitter ->) : String
  io = IO::Memory.new
  emitter = Mica::YAML::Emitter.new(io)
  emitter.stream_start
  yield emitter
  emitter.stream_end
  io.to_s
end

# An IO that records the size of every write it receives.
private class ChunkRecorder < IO
  getter list_of_write_sizes = [] of Int32
  getter written = IO::Memory.new

  def read(slice : Bytes) : Int32
    raise IO::Error.new("write-only")
  end

  def write(slice : Bytes) : Nil
    @list_of_write_sizes << slice.size
    @written.write(slice)
  end
end

describe Mica::YAML::Emitter do
  describe "documents" do
    it "writes an empty stream as nothing" do
      output = emitted do |emitter|
      end
      output.should eq("")
    end

    it "starts an explicit document with ---" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a")
        emitter.document_end
      end
      output.should eq("--- a\n")
    end

    it "leaves --- out of an implicit first document" do
      output = emitted do |emitter|
        emitter.document_start(implicit: true)
        emitter.scalar("a")
        emitter.document_end
      end
      output.should eq("a\n")
    end

    it "ends an explicit document with ..." do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a")
        emitter.document_end(implicit: false)
      end
      output.should eq("--- a\n...\n")
    end

    it "starts every later document with ---" do
      output = emitted do |emitter|
        emitter.document_start(implicit: true)
        emitter.scalar("a")
        emitter.document_end
        emitter.document_start(implicit: true)
        emitter.scalar("b")
        emitter.document_end
        emitter.document_start
        emitter.scalar("c")
        emitter.document_end
      end
      output.should eq("a\n--- b\n--- c\n")
    end

    it "separates explicitly ended documents" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a")
        emitter.document_end(implicit: false)
        emitter.document_start
        emitter.scalar("b")
        emitter.document_end(implicit: false)
      end
      output.should eq("--- a\n...\n--- b\n...\n")
    end

    it "writes an empty plain scalar as an empty document" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("")
        emitter.document_end
      end
      output.should eq("---\n")
    end

    it "writes an empty plain scalar in an implicit document as a blank line" do
      output = emitted do |emitter|
        emitter.document_start(implicit: true)
        emitter.scalar("")
        emitter.document_end
      end
      output.should eq("\n")
    end

    it "puts a root collection on the line after ---" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- a\n")
    end

    it "puts a root flow collection on the --- line" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start(style: :flow)
        emitter.scalar("a")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("--- [a]\n")
    end
  end

  describe "plain scalars and the choice of style" do
    it "keeps ordinary words plain" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("word")
        emitter.scalar("two words")
        emitter.scalar("a-b_c.d")
        emitter.scalar("x:y")
        emitter.scalar("a#b")
        emitter.scalar("-1")
        emitter.scalar("?x")
        emitter.scalar(":x")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- word\n- two words\n- a-b_c.d\n- x:y\n- a#b\n- -1\n- ?x\n- :x\n")
    end

    it "keeps number, boolean and null look-alikes plain (resolving is the caller's job)" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("123")
        emitter.scalar("3.14")
        emitter.scalar("true")
        emitter.scalar("null")
        emitter.scalar("~")
        emitter.scalar("0x1F")
        emitter.scalar("2001-01-01")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- 123\n- 3.14\n- true\n- null\n- ~\n- 0x1F\n- 2001-01-01\n")
    end

    it "single-quotes a scalar that starts with an indicator" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("#a")
        emitter.scalar(",a")
        emitter.scalar("[a")
        emitter.scalar("]a")
        emitter.scalar("{a")
        emitter.scalar("}a")
        emitter.scalar("&a")
        emitter.scalar("*a")
        emitter.scalar("!a")
        emitter.scalar("|a")
        emitter.scalar(">a")
        emitter.scalar("'a")
        emitter.scalar("\"a")
        emitter.scalar("%a")
        emitter.scalar("@a")
        emitter.scalar("`a")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- '#a'\n- ',a'\n- '[a'\n- ']a'\n- '{a'\n- '}a'\n- '&a'\n- '*a'\n- '!a'\n- '|a'\n- '>a'\n- '''a'\n- '\"a'\n- '%a'\n- '@a'\n- '`a'\n")
    end

    it "single-quotes indicators followed by a space" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("- a")
        emitter.scalar("? a")
        emitter.scalar(": a")
        emitter.scalar("-")
        emitter.scalar("?")
        emitter.scalar(":")
        emitter.scalar("a: b")
        emitter.scalar("a #b")
        emitter.scalar("a:")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- '- a'\n- '? a'\n- ': a'\n- '-'\n- '?'\n- ':'\n- 'a: b'\n- 'a #b'\n- 'a:'\n")
    end

    it "single-quotes document markers" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("---")
        emitter.scalar("...")
        emitter.scalar("--- a")
        emitter.scalar("...a")
        emitter.scalar("--")
        emitter.scalar("..")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- '---'\n- '...'\n- '--- a'\n- '...a'\n- --\n- ..\n")
    end

    it "single-quotes leading and trailing spaces" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar(" a")
        emitter.scalar("a ")
        emitter.scalar(" ")
        emitter.scalar("  a  b  ")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- ' a'\n- 'a '\n- ' '\n- '  a  b  '\n")
    end

    it "treats a tab and a NUL as white space after an indicator" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("-\ta")
        emitter.scalar("a:\tb")
        emitter.scalar("a\t#b")
        emitter.scalar("-\u0000")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- \"-\\ta\"\n- \"a:\\tb\"\n- \"a\\t#b\"\n- \"-\\0\"\n")
    end

    it "writes an empty scalar plain in a block sequence and quoted as a key or in flow" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("")
        emitter.mapping_start
        emitter.scalar("")
        emitter.scalar("")
        emitter.mapping_end
        emitter.sequence_start(style: :flow)
        emitter.scalar("")
        emitter.sequence_end
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n-\n- '':\n- ['']\n")
    end

    it "single-quotes flow indicators only inside flow collections" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a,b")
        emitter.scalar("a[b]")
        emitter.scalar("a{b}")
        emitter.scalar("a?b")
        emitter.sequence_start(style: :flow)
        emitter.scalar("a,b")
        emitter.scalar("a[b]")
        emitter.scalar("a{b}")
        emitter.scalar("a?b")
        emitter.scalar("a:b")
        emitter.sequence_end
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- a,b\n- a[b]\n- a{b}\n- a?b\n- ['a,b', 'a[b]', 'a{b}', 'a?b', 'a:b']\n")
    end

    it "honors a requested quoted style" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a", style: :single_quoted)
        emitter.scalar("a", style: :double_quoted)
        emitter.scalar("a", style: :plain)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- 'a'\n- \"a\"\n- a\n")
    end

    it "single-quotes a plain scalar that is not plain implicit" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a", plain_implicit: false)
        emitter.scalar("a", plain_implicit: false, style: :plain)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- 'a'\n- 'a'\n")
    end

    it "writes a ! tag for a quoted scalar that is not quoted implicit" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a", quoted_implicit: false)
        emitter.scalar("a b", quoted_implicit: false, style: :single_quoted)
        emitter.scalar("- a", quoted_implicit: false)
        emitter.scalar("a", quoted_implicit: false, style: :literal)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- a\n- ! 'a b'\n- ! '- a'\n- ! |-\n  a\n")
    end
  end

  describe "single-quoted scalars" do
    it "doubles single quotes" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("it's 'quoted'", style: :single_quoted)
        emitter.document_end
      end
      output.should eq("--- 'it''s ''quoted'''\n")
    end

    it "writes line breaks as blank lines" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a\nb", style: :single_quoted)
        emitter.scalar("a\n\nb", style: :single_quoted)
        emitter.scalar("\na\n", style: :single_quoted)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- 'a\n\n  b'\n- 'a\n\n\n  b'\n- '\n\n  a\n\n  '\n")
    end

    it "falls back to double quotes for a space next to a line break" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a \nb", style: :single_quoted)
        emitter.scalar("a\n b", style: :single_quoted)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- \"a \\nb\"\n- \"a\\n b\"\n")
    end

    it "falls back to double quotes for special characters" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a\tb", style: :single_quoted)
        emitter.scalar("a\ab", style: :single_quoted)
        emitter.scalar("😀", style: :single_quoted)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- \"a\\tb\"\n- \"a\\ab\"\n- \"\\U0001F600\"\n")
    end

    it "copies NEL, LS and PS line breaks as they are" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a\u2028b", style: :single_quoted)
        emitter.scalar("a\u2029b", style: :single_quoted)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- 'a\u2028  b'\n- 'a\u2029  b'\n")
    end
  end

  describe "double-quoted scalars" do
    it "escapes quotes and backslashes" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("say \"hi\" \\ bye", style: :double_quoted)
        emitter.document_end
      end
      output.should eq("--- \"say \\\"hi\\\" \\\\ bye\"\n")
    end

    it "uses the short escapes" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("\u0000\a\b\t\n\v\f\r\e\u0085\u2028\u2029", style: :double_quoted)
        emitter.document_end
      end
      output.should eq("--- \"\\0\\a\\b\\t\\n\\v\\f\\r\\e\\N\\L\\P\"\n")
    end

    it "escapes control characters as \\x, \\u and \\U" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("\u0001\u001F\u007F\u0080\u009F\uFEFF\uFFFE\uFFFF\u{10000}😀\u{10FFFF}", style: :double_quoted)
        emitter.document_end
      end
      output.should eq("--- \"\\x01\\x1F\\x7F\\x80\\x9F\\uFEFF\\uFFFE\\uFFFF\\U00010000\\U0001F600\\U0010FFFF\"\n")
    end

    it "leaves printable Unicode unescaped" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("café \u00A0 日本語 \uD7FF \uE000 \uFFFD", style: :double_quoted)
        emitter.document_end
      end
      output.should eq("--- \"café \u00A0 日本語 \uD7FF \uE000 \uFFFD\"\n")
    end

    it "keeps a multi-line key on one line" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("a\nb")
        emitter.scalar("c")
        emitter.scalar("d\ne", style: :literal)
        emitter.scalar("f")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\n? 'a\n\n  b'\n: c\n? |-\n  d\n  e\n: f\n")
    end

    it "quotes a plain scalar with a line break" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a\nb")
        emitter.scalar("a\rb")
        emitter.scalar("a\r\nb")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- 'a\n\n  b'\n- \"a\\rb\"\n- \"a\\r\\nb\"\n")
    end
  end

  describe "literal scalars" do
    it "strips with - when the text has no final line break" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a\nb", style: :literal)
        emitter.document_end
      end
      output.should eq("--- |-\n  a\n  b\n")
    end

    it "clips when the text ends in one line break" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a\nb\n", style: :literal)
        emitter.document_end
      end
      output.should eq("--- |\n  a\n  b\n")
    end

    it "keeps with + and ends the stream with ... when the text ends in several" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a\nb\n\n", style: :literal)
        emitter.document_end
      end
      output.should eq("--- |+\n  a\n  b\n\n...\n")
    end

    it "keeps a text that is only a line break" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("\n", style: :literal)
        emitter.document_end
      end
      output.should eq("--- |2+\n\n...\n")
    end

    it "writes an indentation indicator before a leading space or line break" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar(" a\nb\n", style: :literal)
        emitter.scalar("\na\n", style: :literal)
        emitter.scalar("\n\n", style: :literal)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- |2\n   a\n  b\n- |2\n\n  a\n- |2+\n\n\n...\n")
    end

    it "indents a nested literal under its key" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("key")
        emitter.mapping_start
        emitter.scalar("text")
        emitter.scalar("one\n  two\nthree\n", style: :literal)
        emitter.mapping_end
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\nkey:\n  text: |\n    one\n      two\n    three\n")
    end

    it "falls back to double quotes for trailing spaces, special characters, keys and flow" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a ", style: :literal)
        emitter.scalar("a\tb", style: :literal)
        emitter.scalar("a \nb", style: :literal)
        emitter.scalar("", style: :literal)
        emitter.sequence_start(style: :flow)
        emitter.scalar("a\n", style: :literal)
        emitter.sequence_end
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- \"a \"\n- \"a\\tb\"\n- \"a \\nb\"\n- \"\"\n- [\"a\\n\"]\n")
    end

    it "does not fold a long literal line" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n", style: :literal)
        emitter.document_end
      end
      output.should eq("--- |\n  Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n")
    end

    it "copies other line breaks as they are" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a\u2028b\u0085c\r\nd\n", style: :literal)
        emitter.document_end
      end
      output.should eq("--- \"a\\Lb\\Nc\\r\\nd\\n\"\n")
    end

    it "omits ... after a kept literal when another document follows" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a\n\n", style: :literal)
        emitter.document_end
        emitter.document_start
        emitter.scalar("b")
        emitter.document_end
      end
      output.should eq("--- |+\n  a\n\n--- b\n")
    end
  end

  describe "folded scalars" do
    it "writes a short text on one line" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("a b c\n", style: :folded)
        emitter.document_end
      end
      output.should eq("--- >\n  a b c\n")
    end

    it "doubles a line break between text lines" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("one\ntwo\n\nthree\n", style: :folded)
        emitter.document_end
      end
      output.should eq("--- >\n  one\n\n  two\n\n\n  three\n")
    end

    it "does not double a line break next to an indented line" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("one\n  two\nthree\n four\n", style: :folded)
        emitter.document_end
      end
      output.should eq("--- >\n  one\n    two\n  three\n   four\n")
    end

    it "folds a long line at the first space past column 80" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n", style: :folded)
        emitter.document_end
      end
      output.should eq("--- >\n  Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt\n  ut labore et dolore magna aliqua. Lorem ipsum dolor sit amet, consectetur adipiscing\n  elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n")
    end

    it "does not fold at a run of spaces" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  y  zzzzzzzzzz end", style: :folded)
        emitter.document_end
      end
      output.should eq("--- >-\n  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \n  y  zzzzzzzzzz end\n")
    end

    it "writes hints like a literal" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a", style: :folded)
        emitter.scalar("a\n\n", style: :folded)
        emitter.scalar(" a\n", style: :folded)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- >-\n  a\n- >+\n  a\n\n- >2\n   a\n")
    end
  end

  describe "line folding at 80 columns" do
    it "folds a long plain scalar" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.")
        emitter.document_end
      end
      output.should eq("--- Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor\n  incididunt ut labore et dolore magna aliqua. Lorem ipsum dolor sit amet, consectetur\n  adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n")
    end

    it "folds a long plain value under its key" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("key")
        emitter.scalar("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\nkey: Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor\n  incididunt ut labore et dolore magna aliqua.\n")
    end

    it "does not fold a plain scalar at a run of spaces" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  y zzzzz")
        emitter.document_end
      end
      output.should eq("--- xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  y\n  zzzzz\n")
    end

    it "does not fold a word that has no space" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx y")
        emitter.document_end
      end
      output.should eq("--- xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n  y\n")
    end

    it "folds a long single-quoted scalar" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.", style: :single_quoted)
        emitter.document_end
      end
      output.should eq("--- 'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor\n  incididunt ut labore et dolore magna aliqua. Lorem ipsum dolor sit amet, consectetur\n  adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.'\n")
    end

    it "folds a long double-quoted scalar and escapes a space that starts a line" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  y zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz end", style: :double_quoted)
        emitter.document_end
      end
      output.should eq("--- \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n  \\ y zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n  end\"\n")
    end

    it "never folds a simple key" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
        emitter.scalar("v")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\nkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk: v\n")
    end

    it "writes a key longer than 128 bytes as a complex key" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
        emitter.scalar("v")
        emitter.scalar("kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
        emitter.scalar("v")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\n? kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk\n: v\nkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk: v\n")
    end

    it "breaks a long flow sequence after the item that passes column 80" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start(style: :flow)
        emitter.scalar("item1")
        emitter.scalar("item2")
        emitter.scalar("item3")
        emitter.scalar("item4")
        emitter.scalar("item5")
        emitter.scalar("item6")
        emitter.scalar("item7")
        emitter.scalar("item8")
        emitter.scalar("item9")
        emitter.scalar("item10")
        emitter.scalar("item11")
        emitter.scalar("item12")
        emitter.scalar("item13")
        emitter.scalar("item14")
        emitter.scalar("item15")
        emitter.scalar("item16")
        emitter.scalar("item17")
        emitter.scalar("item18")
        emitter.scalar("item19")
        emitter.scalar("item20")
        emitter.scalar("item21")
        emitter.scalar("item22")
        emitter.scalar("item23")
        emitter.scalar("item24")
        emitter.scalar("item25")
        emitter.scalar("item26")
        emitter.scalar("item27")
        emitter.scalar("item28")
        emitter.scalar("item29")
        emitter.scalar("item30")
        emitter.scalar("item31")
        emitter.scalar("item32")
        emitter.scalar("item33")
        emitter.scalar("item34")
        emitter.scalar("item35")
        emitter.scalar("item36")
        emitter.scalar("item37")
        emitter.scalar("item38")
        emitter.scalar("item39")
        emitter.scalar("item40")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("--- [item1, item2, item3, item4, item5, item6, item7, item8, item9, item10, item11,\n  item12, item13, item14, item15, item16, item17, item18, item19, item20, item21,\n  item22, item23, item24, item25, item26, item27, item28, item29, item30, item31,\n  item32, item33, item34, item35, item36, item37, item38, item39, item40]\n")
    end

    it "breaks a long flow mapping" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start(style: :flow)
        emitter.scalar("key1")
        emitter.scalar("value1")
        emitter.scalar("key2")
        emitter.scalar("value2")
        emitter.scalar("key3")
        emitter.scalar("value3")
        emitter.scalar("key4")
        emitter.scalar("value4")
        emitter.scalar("key5")
        emitter.scalar("value5")
        emitter.scalar("key6")
        emitter.scalar("value6")
        emitter.scalar("key7")
        emitter.scalar("value7")
        emitter.scalar("key8")
        emitter.scalar("value8")
        emitter.scalar("key9")
        emitter.scalar("value9")
        emitter.scalar("key10")
        emitter.scalar("value10")
        emitter.scalar("key11")
        emitter.scalar("value11")
        emitter.scalar("key12")
        emitter.scalar("value12")
        emitter.scalar("key13")
        emitter.scalar("value13")
        emitter.scalar("key14")
        emitter.scalar("value14")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("--- {key1: value1, key2: value2, key3: value3, key4: value4, key5: value5, key6: value6,\n  key7: value7, key8: value8, key9: value9, key10: value10, key11: value11, key12: value12,\n  key13: value13, key14: value14}\n")
    end

    it "counts characters, not bytes, toward the width" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.scalar("éééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé éé 日日日日日 end")
        emitter.document_end
      end
      output.should eq("--- éééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé\n  éé 日日日日日 end\n")
    end
  end

  describe "block collections" do
    it "nests sequences and mappings" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("list")
        emitter.sequence_start
        emitter.scalar("a")
        emitter.sequence_start
        emitter.scalar("b")
        emitter.scalar("c")
        emitter.sequence_end
        emitter.mapping_start
        emitter.scalar("k")
        emitter.scalar("v")
        emitter.scalar("l")
        emitter.scalar("w")
        emitter.mapping_end
        emitter.sequence_end
        emitter.scalar("map")
        emitter.mapping_start
        emitter.scalar("inner")
        emitter.mapping_start
        emitter.scalar("deep")
        emitter.scalar("x")
        emitter.mapping_end
        emitter.mapping_end
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\nlist:\n- a\n- - b\n  - c\n- k: v\n  l: w\nmap:\n  inner:\n    deep: x\n")
    end

    it "writes a sequence under a key without extra indentation" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("a")
        emitter.sequence_start
        emitter.scalar("1")
        emitter.scalar("2")
        emitter.sequence_end
        emitter.scalar("b")
        emitter.scalar("3")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\na:\n- 1\n- 2\nb: 3\n")
    end

    it "writes empty collections in flow style" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("a")
        emitter.sequence_start
        emitter.sequence_end
        emitter.scalar("b")
        emitter.mapping_start
        emitter.mapping_end
        emitter.scalar("c")
        emitter.sequence_start
        emitter.sequence_start
        emitter.sequence_end
        emitter.mapping_start
        emitter.mapping_end
        emitter.sequence_end
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\na: []\nb: {}\nc:\n- []\n- {}\n")
    end

    it "writes a collection as a complex key" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.sequence_start
        emitter.scalar("a")
        emitter.scalar("b")
        emitter.sequence_end
        emitter.scalar("v")
        emitter.mapping_start
        emitter.scalar("k")
        emitter.scalar("w")
        emitter.mapping_end
        emitter.scalar("x")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\n? - a\n  - b\n: v\n? k: w\n: x\n")
    end

    it "uses an empty collection as a simple key" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.sequence_start
        emitter.sequence_end
        emitter.scalar("a")
        emitter.mapping_start
        emitter.mapping_end
        emitter.scalar("b")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\n[]: a\n{}: b\n")
    end

    it "indents a sequence inside a sequence inside a mapping" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.mapping_start
        emitter.scalar("a")
        emitter.sequence_start
        emitter.sequence_start
        emitter.scalar("x")
        emitter.sequence_end
        emitter.sequence_end
        emitter.mapping_end
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- a:\n  - - x\n")
    end
  end

  describe "flow collections" do
    it "writes a flow sequence and mapping" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("seq")
        emitter.sequence_start(style: :flow)
        emitter.scalar("a")
        emitter.scalar("b")
        emitter.sequence_end
        emitter.scalar("map")
        emitter.mapping_start(style: :flow)
        emitter.scalar("k")
        emitter.scalar("v")
        emitter.scalar("l")
        emitter.scalar("w")
        emitter.mapping_end
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\nseq: [a, b]\nmap: {k: v, l: w}\n")
    end

    it "forces every nested collection into flow style" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start(style: :flow)
        emitter.sequence_start(style: :block)
        emitter.scalar("a")
        emitter.sequence_end
        emitter.mapping_start(style: :block)
        emitter.scalar("k")
        emitter.sequence_start(style: :block)
        emitter.scalar("x")
        emitter.sequence_end
        emitter.mapping_end
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("--- [[a], {k: [x]}]\n")
    end

    it "writes a complex key in a flow mapping with ?" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start(style: :flow)
        emitter.sequence_start
        emitter.scalar("a")
        emitter.sequence_end
        emitter.scalar("v")
        emitter.scalar("a\nb")
        emitter.scalar("c")
        emitter.scalar("kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
        emitter.scalar("w")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("--- {? [a] : v, ? 'a\n\n    b' : c, ? kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk\n  : w}\n")
    end

    it "quotes an empty scalar in flow" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start(style: :flow)
        emitter.scalar("")
        emitter.scalar("")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("--- {'': ''}\n")
    end
  end

  describe "anchors, aliases and tags" do
    it "writes anchors and aliases" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("base")
        emitter.mapping_start(anchor: "base")
        emitter.scalar("a")
        emitter.scalar("1")
        emitter.mapping_end
        emitter.scalar("copy")
        emitter.alias("base")
        emitter.scalar("list")
        emitter.sequence_start
        emitter.scalar("x", anchor: "x")
        emitter.alias("x")
        emitter.sequence_end
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\nbase: &base\n  a: 1\ncopy: *base\nlist:\n- &x x\n- *x\n")
    end

    it "writes an alias key with a space before the colon" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("a", anchor: "k")
        emitter.scalar("1")
        emitter.alias("k")
        emitter.scalar("2")
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\n&k a: 1\n*k : 2\n")
    end

    it "writes an anchor on an empty scalar and on flow collections" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("", anchor: "a")
        emitter.sequence_start(anchor: "b", style: :flow)
        emitter.scalar("x")
        emitter.sequence_end
        emitter.mapping_start(anchor: "c")
        emitter.mapping_end
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- &a\n- &b [x]\n- &c {}\n")
    end

    it "shortens tags with the ! and !! handles" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a", tag: "!local", plain_implicit: false, quoted_implicit: false)
        emitter.scalar("1", tag: "tag:yaml.org,2002:int", plain_implicit: false, quoted_implicit: false)
        emitter.scalar("a", tag: "!!str", plain_implicit: false, quoted_implicit: false)
        emitter.scalar("a", tag: "!", plain_implicit: false, quoted_implicit: false)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- !local a\n- !!int 1\n- !%21str a\n- !<%21> a\n")
    end

    it "writes other tags verbatim and escapes their odd characters" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a", tag: "tag:example.com,2000:app/foo", plain_implicit: false, quoted_implicit: false)
        emitter.scalar("a", tag: "x y", plain_implicit: false, quoted_implicit: false)
        emitter.scalar("a", tag: "!café", plain_implicit: false, quoted_implicit: false)
        emitter.scalar("a", tag: "!a!b{c}", plain_implicit: false, quoted_implicit: false)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- !<tag:example.com,2000:app/foo> a\n- !<x%20y> a\n- !caf%C3%A9 a\n- !a%21b%7Bc%7D a\n")
    end

    it "writes tags on collections" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("a")
        emitter.sequence_start(tag: "!!set", implicit: false)
        emitter.scalar("x")
        emitter.sequence_end
        emitter.scalar("b")
        emitter.mapping_start(tag: "!thing", implicit: false)
        emitter.scalar("k")
        emitter.scalar("v")
        emitter.mapping_end
        emitter.scalar("c")
        emitter.sequence_start(tag: "!e", implicit: false)
        emitter.sequence_end
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\na: !%21set\n- x\nb: !thing\n  k: v\nc: !e []\n")
    end

    it "leaves the tag out of an implicit scalar" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a", tag: "!t")
        emitter.scalar("a", tag: "!t", quoted_implicit: false)
        emitter.scalar("a", tag: "!t", plain_implicit: false)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- a\n- a\n- 'a'\n")
    end

    it "writes anchor before tag before a block scalar" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.mapping_start
        emitter.scalar("k")
        emitter.scalar("a\n", anchor: "anc", tag: "!t", plain_implicit: false, quoted_implicit: false, style: :literal)
        emitter.mapping_end
        emitter.document_end
      end
      output.should eq("---\nk: &anc !t |\n  a\n")
    end

    it "reads an anchor and a tag up to a NUL byte, as libyaml's C strings do" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a", anchor: "one\u0000two")
        emitter.scalar("b", tag: "!x\u0000y", plain_implicit: false, quoted_implicit: false)
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- &one a\n- !x b\n")
    end
  end

  describe "events libyaml rejects" do
    it "requires STREAM-START first" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "expected STREAM-START") do
        emitter.document_start
        emitter.scalar("a")
        emitter.document_end
      end
    end

    it "rejects a second STREAM-START" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "expected DOCUMENT-START or STREAM-END") do
        emitter.stream_start
        emitter.stream_start
      end
    end

    it "rejects a node outside a document" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "expected DOCUMENT-START or STREAM-END") do
        emitter.stream_start
        emitter.scalar("a")
      end
    end

    it "rejects an event after STREAM-END" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "expected nothing after STREAM-END") do
        emitter.stream_start
        emitter.stream_end
        emitter.stream_start
      end
    end

    it "rejects a document without a node" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "expected SCALAR, SEQUENCE-START, MAPPING-START, or ALIAS") do
        emitter.stream_start
        emitter.document_start(implicit: true)
        emitter.document_end
        emitter.stream_end
      end
    end

    it "rejects a second root node" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "expected DOCUMENT-END") do
        emitter.stream_start
        emitter.document_start(implicit: true)
        emitter.scalar("a")
        emitter.scalar("b")
      end
    end

    it "rejects SEQUENCE-END inside a mapping" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "expected SCALAR, SEQUENCE-START, MAPPING-START, or ALIAS") do
        emitter.stream_start
        emitter.document_start(implicit: true)
        emitter.mapping_start
        emitter.sequence_end
        emitter.stream_end
      end
    end

    it "rejects MAPPING-END where a value is due" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "expected SCALAR, SEQUENCE-START, MAPPING-START, or ALIAS") do
        emitter.stream_start
        emitter.document_start(implicit: true)
        emitter.mapping_start
        emitter.scalar("k")
        emitter.mapping_end
        emitter.document_end
        emitter.stream_end
      end
    end

    it "rejects an empty anchor" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "anchor value must not be empty") do
        emitter.stream_start
        emitter.document_start
        emitter.scalar("a", anchor: "")
        emitter.document_end
      end
    end

    it "rejects an anchor with other than letters, digits, _ and -" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "anchor value must contain alphanumerical characters only") do
        emitter.stream_start
        emitter.document_start
        emitter.scalar("a", anchor: "a b")
        emitter.document_end
      end
    end

    it "rejects an empty alias" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "alias value must not be empty") do
        emitter.stream_start
        emitter.document_start
        emitter.alias("")
        emitter.document_end
      end
    end

    it "rejects an alias with other than letters, digits, _ and -" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "alias value must contain alphanumerical characters only") do
        emitter.stream_start
        emitter.document_start
        emitter.alias("café")
        emitter.document_end
      end
    end

    it "rejects an empty tag" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "tag value must not be empty") do
        emitter.stream_start
        emitter.document_start
        emitter.scalar("a", tag: "", plain_implicit: false, quoted_implicit: false)
        emitter.document_end
      end
    end

    it "rejects a scalar with neither a tag nor an implicit flag" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      expect_raises(Mica::YAML::EmitError, "neither tag nor implicit flags are specified") do
        emitter.stream_start
        emitter.document_start
        emitter.scalar("a", plain_implicit: false, quoted_implicit: false)
        emitter.document_end
      end
    end
  end

  describe "UTF-8 checks" do
    it "rejects a scalar value that is not UTF-8" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      emitter.stream_start
      emitter.document_start
      [Bytes[0xFF], Bytes[0x61, 0xC3], Bytes[0xC0, 0x80], Bytes[0xE0, 0x80, 0x80], Bytes[0x80], Bytes[0xF8, 0x88, 0x80, 0x80, 0x80]].each do |bytes|
        expect_raises(Mica::YAML::EmitError, "scalar value is not valid UTF-8") do
          emitter.scalar(String.new(bytes))
        end
      end
    end

    it "rejects an anchor, an alias and a tag that are not UTF-8" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      invalid = String.new(Bytes[0x61, 0xFF])
      expect_raises(Mica::YAML::EmitError, "anchor is not valid UTF-8") { emitter.scalar("a", anchor: invalid) }
      expect_raises(Mica::YAML::EmitError, "anchor is not valid UTF-8") { emitter.sequence_start(anchor: invalid) }
      expect_raises(Mica::YAML::EmitError, "anchor is not valid UTF-8") { emitter.mapping_start(anchor: invalid) }
      expect_raises(Mica::YAML::EmitError, "anchor is not valid UTF-8") { emitter.alias(invalid) }
      expect_raises(Mica::YAML::EmitError, "tag is not valid UTF-8") { emitter.scalar("a", tag: invalid) }
      expect_raises(Mica::YAML::EmitError, "tag is not valid UTF-8") { emitter.sequence_start(tag: invalid) }
      expect_raises(Mica::YAML::EmitError, "tag is not valid UTF-8") { emitter.mapping_start(tag: invalid) }
    end

    it "leaves a rejected event out of the stream" do
      output = emitted do |emitter|
        emitter.document_start
        emitter.sequence_start
        emitter.scalar("a")
        expect_raises(Mica::YAML::EmitError) { emitter.scalar(String.new(Bytes[0xFF])) }
        emitter.scalar("b")
        emitter.sequence_end
        emitter.document_end
      end
      output.should eq("---\n- a\n- b\n")
    end

    it "is a Mica::Error" do
      Mica::YAML::EmitError.new("problem").should be_a(Mica::Error)
    end
  end

  describe "look-ahead and buffering" do
    it "reports a problem when the look-ahead reaches the event, which can be a later call" do
      emitter = Mica::YAML::Emitter.new(IO::Memory.new)
      emitter.stream_start
      emitter.document_start
      emitter.mapping_start
      emitter.scalar("key", anchor: "not valid")
      emitter.scalar("value")
      expect_raises(Mica::YAML::EmitError, "anchor value must contain alphanumerical characters only") do
        emitter.scalar("next")
      end
    end

    it "writes to the IO at the end of each document and on flush" do
      io = ChunkRecorder.new
      emitter = Mica::YAML::Emitter.new(io)
      emitter.stream_start
      emitter.document_start
      emitter.scalar("one")
      io.list_of_write_sizes.should be_empty
      emitter.document_end
      io.written.to_s.should eq("--- one\n")
      emitter.document_start
      emitter.scalar("tail")
      emitter.flush
      io.written.to_s.should eq("--- one\n--- tail")
      emitter.document_end
      emitter.stream_end
      io.written.to_s.should eq("--- one\n--- tail\n")
      io.list_of_write_sizes.should eq([8, 8, 1])
    end

    it "writes a large document in the chunks libyaml's 16 KiB buffer produces" do
      io = ChunkRecorder.new
      emitter = Mica::YAML::Emitter.new(io)
      emitter.stream_start
      emitter.document_start
      emitter.sequence_start
      4000.times { |index| emitter.scalar("item é日 #{index}") }
      emitter.sequence_end
      emitter.document_end
      emitter.stream_end
      io.list_of_write_sizes.should eq([16379, 16379, 16379, 16379, 5378])
      expected = String.build do |text|
        text << "---\n"
        4000.times { |index| text << "- item é日 " << index << '\n' }
      end
      io.written.to_s.should eq(expected)
    end

    it "nests 20,000 levels deep without recursion" do
      depth = 20_000
      output = emitted do |emitter|
        emitter.document_start
        depth.times { emitter.sequence_start }
        emitter.scalar("a")
        emitter.scalar("b")
        depth.times { emitter.sequence_end }
        emitter.document_end
      end
      output.should eq("---\n" + "- " * depth + "a\n" + " " * (2 * (depth - 1)) + "- b\n")
    end
  end
end
