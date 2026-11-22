# Checks every regex in a tree of Crystal source against Mica's Crystal
# dialect, the way a compiler whose default `Regex` engine is Mica checks a
# literal while it expands it. The compiler only checks literals the program
# reaches; this script reads every file, so a pattern in a method no spec
# calls is found too.
#
# ```console
# $ CRYSTAL_PATH="path/to/mica/src:$(crystal env CRYSTAL_PATH)" \
#     crystal run path/to/mica/scripts/check_regex_literals.cr -- src spec
# src/app/joins.cr:18:21: "JOIN (?!ON\b)(\w+)" lookahead (at 5) is not supported
# 1 pattern Mica cannot run in 412 files (1093 checked)
# ```
#
# What is checked:
#
# - regex literals, with their `i`, `m` and `x` options; an interpolated
#   literal is checked with `x` standing in for each `#{...}`
# - `Regex.new("...")` with a string literal
# - literals inside macro expressions (`{{ name.gsub(/.../, "") }}`), which
#   the compiler itself runs
# - the text of macro bodies: it is parsed as Crystal with `x` standing in
#   for each `{{ ... }}`; a body that does not parse that way is searched
#   for the constructs Mica leaves out
#
# A pattern that is only compiled on PCRE2 (inside
# `{% if flag?(:use_pcre2) %}`) is passed over when the line it starts on,
# or the line above, holds the comment `# mica: pcre2 only`.
#
# Exits 1 when a pattern is found, 0 otherwise.
require "compiler/crystal/syntax"
require "mica/regex"

module CheckRegexLiterals
  MARKER_FOR_PCRE2_ONLY = "# mica: pcre2 only"
  PLACEHOLDER           = "x"

  # Constructs Mica leaves out, as they appear in pattern text. Used only on
  # a macro body that cannot be parsed.
  CONSTRUCTS_IN_TEXT = {
    "(?="   => "lookahead",
    "(?!"   => "lookahead",
    "(?<="  => "lookbehind",
    "(?<!"  => "lookbehind",
    "(?>"   => "an atomic group",
    "\\K"   => "\\K (reset the match start)",
    "(?R)"  => "recursion or a subroutine call",
    "(?("   => "a conditional group",
    "\\k<"  => "a backreference",
    "\\g{"  => "a backreference",
    "(?P="  => "a backreference",
    "(*F"   => "a backtracking verb",
    "(*SK"  => "a backtracking verb",
    "(*PR"  => "a backtracking verb",
    "(*CO"  => "a backtracking verb",
    "(*TH"  => "a backtracking verb",
    "(*ACC" => "a backtracking verb",
  }

  record Finding, path : String, line_number : Int32, column_number : Int32, pattern : String, reason : String

  class Scan < Crystal::Visitor
    getter list_of_findings = [] of Finding
    getter count_of_patterns_checked = 0

    @list_of_lines : Array(String)

    def initialize(@path : String, source : String, @line_offset : Int32 = 0)
      @list_of_lines = source.lines
      @macro_depth = 0
    end

    def visit(node : Crystal::RegexLiteral)
      value = node.value
      if value.is_a?(Crystal::StringLiteral)
        check(value.value, node.options, node)
      elsif value.is_a?(Crystal::StringInterpolation)
        pattern = value.expressions.join do |piece|
          piece.is_a?(Crystal::StringLiteral) ? piece.value : PLACEHOLDER
        end
        check(pattern, node.options, node)
      end
      true
    end

    def visit(node : Crystal::Call)
      receiver = node.obj
      first_argument = node.args.first?
      if node.name == "new" && receiver.is_a?(Crystal::Path) && receiver.names == ["Regex"] && first_argument.is_a?(Crystal::StringLiteral)
        check(first_argument.value, Regex::CompileOptions::None, node)
      end
      true
    end

    def visit(node : Crystal::Macro | Crystal::MacroIf | Crystal::MacroFor)
      scan_macro_text(node) if @macro_depth == 0
      @macro_depth += 1
      true
    end

    def end_visit(node : Crystal::Macro | Crystal::MacroIf | Crystal::MacroFor)
      @macro_depth -= 1
    end

    def visit(node : Crystal::ASTNode)
      true
    end

    private def check(pattern : String, options : Regex::CompileOptions, node : Crystal::ASTNode) : Nil
      location = node.location
      line_number = (location ? location.line_number : 1) + @line_offset
      column_number = location ? location.column_number : 1
      return if marked_pcre2_only?(line_number)

      @count_of_patterns_checked += 1
      error = Mica::Regex::Syntax.error?(pattern, dialect: :crystal,
        compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: mica_options(options))
      return unless error

      reason = if error.is_a?(Mica::Regex::UnsupportedConstructError)
                 "#{error.construct} (at #{error.byte_offset}) is not supported"
               else
                 error.message || error.class.name
               end
      @list_of_findings << Finding.new(@path, line_number, column_number, pattern, reason)
    end

    private def marked_pcre2_only?(line_number : Int32) : Bool
      {line_number - 1, line_number - 2}.any? do |index|
        line = index >= 0 ? @list_of_lines[index]? : nil
        line ? line.includes?(MARKER_FOR_PCRE2_ONLY) : false
      end
    end

    private def mica_options(options : Regex::CompileOptions) : Mica::Regex::CompileOptions
      flags = Mica::Regex::CompileOptions::None
      flags |= Mica::Regex::CompileOptions::IgnoreCase if options.ignore_case?
      if options.multiline?
        flags |= Mica::Regex::CompileOptions::Multiline | Mica::Regex::CompileOptions::DotAll
      end
      flags |= Mica::Regex::CompileOptions::Extended if options.extended?
      flags
    end

    # The text a macro body produces is Crystal source the parser keeps as
    # strings. It is put back together with a placeholder for each
    # `{{ ... }}` and scanned as a program of its own.
    private def scan_macro_text(node : Crystal::ASTNode) : Nil
      text = String.build { |io| append_macro_text(node, io) }
      return if text.blank?

      first_line = node.location.try(&.line_number) || 1
      begin
        parsed = Crystal::Parser.new(text).parse
      rescue Crystal::SyntaxException
        search_macro_text(text, first_line)
        return
      end
      # The text of a `macro` starts on the line after its name; the text of
      # a `{% if %}` or `{% for %}` starts on the line that opens it.
      lines_before_text = node.is_a?(Crystal::Macro) ? first_line : first_line - 1
      inner = Scan.new(@path, @list_of_lines.join('\n'), lines_before_text + @line_offset)
      inner.skip_macro_text!
      parsed.accept(inner)
      @count_of_patterns_checked += inner.count_of_patterns_checked
      @list_of_findings.concat(inner.list_of_findings)
    end

    protected def skip_macro_text! : Nil
      @macro_depth = 1
    end

    private def append_macro_text(node : Crystal::ASTNode, io : IO) : Nil
      if node.is_a?(Crystal::Macro)
        append_macro_text(node.body, io)
      elsif node.is_a?(Crystal::Expressions)
        node.expressions.each { |expression| append_macro_text(expression, io) }
      elsif node.is_a?(Crystal::MacroLiteral)
        io << node.value
      elsif node.is_a?(Crystal::MacroExpression)
        io << PLACEHOLDER if node.output?
      elsif node.is_a?(Crystal::MacroIf)
        append_macro_text(node.then, io)
        append_macro_text(node.else, io)
      elsif node.is_a?(Crystal::MacroFor)
        append_macro_text(node.body, io)
      elsif node.is_a?(Crystal::MacroVerbatim)
        append_macro_text(node.exp, io)
      end
    end

    private def search_macro_text(text : String, first_line : Int32) : Nil
      text.each_line.with_index do |line, index|
        CONSTRUCTS_IN_TEXT.each do |token, construct|
          column = line.index(token)
          next unless column
          line_number = first_line + index + @line_offset
          next if marked_pcre2_only?(line_number)
          @list_of_findings << Finding.new(@path, line_number, column + 1, line.strip,
            "#{construct} appears in a macro body that could not be parsed on its own")
        end
      end
    end
  end

  def self.list_of_source_files(list_of_roots : Array(String)) : Array(String)
    list_of_roots.flat_map do |root|
      if File.file?(root)
        [root]
      else
        Dir.glob(File.join(root, "**", "*.cr")).reject { |path| Path[path].relative_to(root).parts.includes?("lib") }
      end
    end.sort!.uniq!
  end

  def self.run(list_of_roots : Array(String)) : Int32
    list_of_findings = [] of Finding
    count_of_patterns_checked = 0
    list_of_unparsed_files = [] of String
    list_of_files = list_of_source_files(list_of_roots)

    list_of_files.each do |path|
      source = File.read(path)
      begin
        parser = Crystal::Parser.new(source)
        parser.filename = path
        parsed = parser.parse
      rescue error : Crystal::SyntaxException
        list_of_unparsed_files << "#{path}: #{error.message}"
        next
      end
      scan = Scan.new(path, source)
      parsed.accept(scan)
      count_of_patterns_checked += scan.count_of_patterns_checked
      list_of_findings.concat(scan.list_of_findings)
    end

    list_of_findings = list_of_findings.uniq { |finding| {finding.path, finding.line_number, finding.pattern} }
    list_of_findings.each do |finding|
      puts "#{finding.path}:#{finding.line_number}:#{finding.column_number}: #{finding.pattern.inspect} #{finding.reason}"
    end
    list_of_unparsed_files.each { |line| STDERR.puts "not parsed: #{line}" }
    noun_for_patterns = list_of_findings.size == 1 ? "pattern" : "patterns"
    noun_for_files = list_of_files.size == 1 ? "file" : "files"
    puts "#{list_of_findings.size} #{noun_for_patterns} Mica cannot run in #{list_of_files.size} #{noun_for_files} (#{count_of_patterns_checked} checked)"
    return 0 if list_of_findings.empty?

    puts "Rewrite each one (docs/regex.md lists the rewrites), or mark a pattern that only PCRE2 compiles with `#{MARKER_FOR_PCRE2_ONLY}`."
    1
  end
end

list_of_roots = ARGV.empty? ? ["src"] : ARGV.to_a
exit CheckRegexLiterals.run(list_of_roots)
