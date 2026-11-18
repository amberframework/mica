module Mica::Regex
  # Translates a syntax tree (with its classes lowered) into `Hir`. Runs
  # after the size preflight, so every repetition it records has already
  # been bounded; it does not expand repetitions (the compiler does, in R2).
  module Translator
    # Returns the `Hir::Pattern` for *pattern* in *dialect*.
    def self.translate(pattern : Ast::Pattern, dialect : Dialect, ledger : AllocationLedger,
                       meter : Core::WorkMeter) : Hir::Pattern
      list_of_results = [] of Hir::Node
      Ast.each_post_order(pattern.root, ledger) do |node, child_count|
        offset = node.offset
        meter.enforce { Core::Position.new(offset.to_i64) } if meter.charge(1)
        children = list_of_results.pop(child_count)
        hir = translate_node(node, children, dialect, ledger)
        ledger.charge(16, "a translation stack entry", offset)
        list_of_results << hir
      end
      root = list_of_results.pop? || Hir::Empty.new
      Hir::Pattern.new(root, pattern.capture_count, pattern.list_of_group_names, pattern.options, dialect)
    end

    private def self.translate_node(node : Ast::Node, children : Array(Hir::Node), dialect : Dialect,
                                    ledger : AllocationLedger) : Hir::Node
      offset = node.offset
      case node
      when Ast::Literal
        members = ClassLowering.literal(node.code_point, node.options, dialect)
        if members.size == 1
          ledger.charge(instance_sizeof(Hir::Literal), "a Hir literal", offset)
          return Hir::Literal.new(node.code_point)
        end
        ledger.charge(instance_sizeof(Hir::Class) + instance_sizeof(CodePointSet) + members.size * 8, "a Hir class", offset)
        Hir::Class.new(CodePointSet.new(members.map { |member| {member, member} }))
      when Ast::CharClass
        set = node.lowered_set || raise SyntaxError.new("internal error: class not lowered before translation",
          Core::Position.new(offset.to_i64))
        ledger.charge(instance_sizeof(Hir::Class), "a Hir class", offset)
        Hir::Class.new(set)
      when Ast::AnyCharacter
        ledger.charge(instance_sizeof(Hir::Class) + instance_sizeof(CodePointSet) + 64, "a Hir class", offset)
        Hir::Class.new(ClassLowering.any_character(node.matches_newline?))
      when Ast::LineBreak
        ledger.charge(instance_sizeof(Hir::LineBreak), "a Hir line break", offset)
        Hir::LineBreak.new(node.any_crlf?)
      when Ast::Assertion
        ledger.charge(instance_sizeof(Hir::Look), "a Hir assertion", offset)
        Hir::Look.new(node.assertion_kind, node.ascii_word?)
      when Ast::Empty
        ledger.charge(instance_sizeof(Hir::Empty), "a Hir empty node", offset)
        Hir::Empty.new
      when Ast::Concatenation
        ledger.charge(instance_sizeof(Hir::Concatenation) + children.size * 8, "a Hir concatenation", offset)
        Hir::Concatenation.new(children)
      when Ast::Alternation
        ledger.charge(instance_sizeof(Hir::Alternation) + children.size * 8, "a Hir alternation", offset)
        Hir::Alternation.new(children)
      when Ast::Group
        child = children.first? || Hir::Empty.new
        return child unless node.capturing?
        ledger.charge(instance_sizeof(Hir::Capture), "a Hir capture", offset)
        Hir::Capture.new(node.capture_index, node.group_name, child)
      when Ast::Repetition
        child = children.first? || Hir::Empty.new
        ledger.charge(instance_sizeof(Hir::Repetition), "a Hir repetition", offset)
        Hir::Repetition.new(node.minimum, node.maximum, node.greedy?, child)
      else
        raise SyntaxError.new("internal error: unknown syntax node #{node.class}", Core::Position.new(offset.to_i64))
      end
    end
  end
end
