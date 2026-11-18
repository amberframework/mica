module Mica::Regex
  # Validates and translates patterns without building a matching program.
  #
  # `check` runs the whole compile front half: the dialect parser, class
  # lowering with case folding, the size preflight and the translation to
  # `Hir`, under the given `CompileLimits`. It is what schema loaders, rule
  # packs and the stdlib shim call to reject a pattern when it is loaded
  # rather than when it is first used.
  #
  # ```
  # limits = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN
  # Mica::Regex::Syntax.check("[a-z]+@\\w+", dialect: :crystal, compile_limits: limits).capture_count # => 0
  # Mica::Regex::Syntax.error?("a(?=b)", dialect: :crystal, compile_limits: limits).try(&.message)
  # # => "lookahead is outside the Mica::Regex dialect (see docs/regex.md, \"Excluded constructs\") (byte 1)"
  # ```
  module Syntax
    # The default compile work budget: compile work is linear in the
    # pattern (one operation per byte, node, class range, fold visit and
    # sequence), and a class escape such as `\p{L}` (three bytes, about 650
    # ranges) is the densest construct, so the allowance per byte is wide.
    COMPILE_WORK_BUDGET = Core::WorkBudget.new(operations_per_unit: 4_096, base_operations: 1_000_000)

    # What a successful check found.
    record Report,
      # Capturing groups (the highest group number).
      capture_count : Int32,
      # Named groups in definition order.
      list_of_group_names : Array(Ast::GroupName),
      # The preflight's bound on program states.
      state_estimate : Int64,
      # Bytes charged to the allocation ledger.
      compile_bytes : Int64,
      # Work operations charged.
      operations : Int64

    # Checks *pattern* in *dialect*. Returns a `Report`; raises
    # `SyntaxError` (or its `UnsupportedConstructError` subclass) for a
    # pattern the dialect rejects or leaves out, `CompileLimitError` when a
    # limit trips, and `Mica::WorkBudgetExceededError` or
    # `Mica::DeadlineExceededError` from *meter* (by default a meter on
    # `COMPILE_WORK_BUDGET`).
    def self.check(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                   options : CompileOptions = CompileOptions::None, meter : Core::WorkMeter? = nil) : Report
      work_meter = meter || Core::WorkMeter.new(COMPILE_WORK_BUDGET)
      ledger = new_ledger(compile_limits, meter)
      parsed, estimate = front_half(pattern, dialect, compile_limits, options, ledger, work_meter)
      Translator.translate(parsed, dialect, ledger, work_meter)
      Report.new(parsed.capture_count, parsed.list_of_group_names, estimate, ledger.bytes, work_meter.operations)
    end

    # Returns the error `check` would raise for *pattern*, or nil when the
    # pattern is accepted (like stdlib `Regex.error?`, but returning the
    # positioned `Mica::Error`).
    def self.error?(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                    options : CompileOptions = CompileOptions::None) : Mica::Error?
      check(pattern, dialect: dialect, compile_limits: compile_limits, options: options)
      nil
    rescue error : Mica::Error
      error
    end

    # Parses, checks and translates *pattern*, returning its `Hir`.
    def self.translate(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                       options : CompileOptions = CompileOptions::None, meter : Core::WorkMeter? = nil) : Hir::Pattern
      work_meter = meter || Core::WorkMeter.new(COMPILE_WORK_BUDGET)
      ledger = new_ledger(compile_limits, meter)
      parsed, _estimate = front_half(pattern, dialect, compile_limits, options, ledger, work_meter)
      Translator.translate(parsed, dialect, ledger, work_meter)
    end

    # Compiles *pattern* into the `Program` the engines run: the front half,
    # the translation to `Hir`, and the NFA compiler, all charged to one
    # allocation ledger under *compile_limits*. The compiler's work is
    # bounded by the preflight's state estimate, which is added to the
    # meter's units. `Expression.new` is the public way in.
    def self.compile(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                     options : CompileOptions = CompileOptions::None, meter : Core::WorkMeter? = nil) : Program
      work_meter = meter || Core::WorkMeter.new(COMPILE_WORK_BUDGET)
      ledger = new_ledger(compile_limits, meter)
      parsed, estimate = front_half(pattern, dialect, compile_limits, options, ledger, work_meter)
      hir = Translator.translate(parsed, dialect, ledger, work_meter)
      work_meter.add_units(estimate)
      Compiler.compile(hir, estimate, compile_limits, ledger, work_meter)
    end

    # Parses *pattern* into its syntax tree (no class lowering or preflight).
    def self.parse(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                   options : CompileOptions = CompileOptions::None, meter : Core::WorkMeter? = nil) : Ast::Pattern
      work_meter = meter || Core::WorkMeter.new(COMPILE_WORK_BUDGET)
      ledger = new_ledger(compile_limits, meter)
      parser_for(pattern, dialect, compile_limits, options, ledger, work_meter).parse
    end

    private def self.front_half(pattern : String | Bytes, dialect : Dialect, limits : CompileLimits,
                                options : CompileOptions, ledger : AllocationLedger,
                                meter : Core::WorkMeter) : {Ast::Pattern, Int64}
      parsed = parser_for(pattern, dialect, limits, options, ledger, meter).parse
      lower_sets(parsed, dialect, limits, ledger, meter)
      estimate = Preflight.estimate(parsed, dialect, limits, ledger, meter)
      meter.enforce_deadline { Core::Position.new(0_i64) }
      {parsed, estimate}
    end

    private def self.parser_for(pattern : String | Bytes, dialect : Dialect, limits : CompileLimits,
                                options : CompileOptions, ledger : AllocationLedger, meter : Core::WorkMeter) : Parser
      unless dialect.parser_available?
        milestone = dialect.ecma262? ? "R6" : "R7"
        raise ArgumentError.new("The #{dialect} dialect's parser arrives in milestone #{milestone}")
      end
      bytes = pattern.is_a?(String) ? pattern.to_slice : pattern
      meter.enforce_deadline { Core::Position.new(0_i64) }
      Parser.new(bytes, options, limits, ledger, meter)
    end

    # Lowers every class and case-folded literal in the tree once, so the
    # preflight counts exactly the sets the translator will use.
    private def self.lower_sets(parsed : Ast::Pattern, dialect : Dialect, limits : CompileLimits,
                                ledger : AllocationLedger, meter : Core::WorkMeter) : Nil
      Ast.each_post_order(parsed.root, parsed.node_count, ledger) do |node, _child_count|
        if node.is_a?(Ast::CharClass)
          node.lowered_set = ClassLowering.lower(node, dialect, limits, ledger, meter)
        elsif node.is_a?(Ast::Literal)
          node.folded_set = ClassLowering.fold_literal(node, dialect, limits, ledger, meter)
        end
      end
    end

    # The ledger for one compilation, charged first with the fixed objects
    # every compilation allocates: the ledger, a meter when the caller gave
    # none, the parser with its two lists and three name tables, the
    # parsed pattern and the report.
    private def self.new_ledger(limits : CompileLimits, meter : Core::WorkMeter?) : AllocationLedger
      ledger = AllocationLedger.new(limits.max_compile_bytes)
      fixed = AllocationLedger.granules(instance_sizeof(AllocationLedger)) +
              AllocationLedger.granules(instance_sizeof(Parser)) +
              AllocationLedger.granules(instance_sizeof(Array(Int32))) * 2 +
              AllocationLedger.granules(instance_sizeof(Hash(String, Int32))) * 3 +
              AllocationLedger.granules(instance_sizeof(Ast::Pattern)) +
              AllocationLedger.granules(sizeof(Report))
      fixed += AllocationLedger.granules(instance_sizeof(Core::WorkMeter)) unless meter
      ledger.charge(fixed, "a compilation", 0)
      ledger
    end
  end
end
