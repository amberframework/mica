require "./build_the_tables"

module Mica::Regex::Static
  # When a static pattern's tables are built (or refused), then the
  # Crystal expression that stands for the pattern in the application is
  # written: a `StaticPattern` whose tables are `Slice.literal`s with state
  # ids at the narrowest width each allows (read-only data in the binary),
  # or a `StaticFallback` that compiles the pattern with the runtime engine
  # when the application first reads it.
  #
  # The output is three parts (see `Mica::Regex.static`): a line naming
  # the kind (`static`, `fallback`, or `error` for a pattern the runtime
  # compiler rejects, which the macro raises as a compile error), a line
  # holding the compile-time note (empty for a pattern the static path
  # holds), the line `%%`, then the expression.
  class WriteTheSource
    NOTE_SEPARATOR = "%%"

    def initialize(@result : PatternTables | Refusal, @output : IO)
    end

    def perform : Nil
      result = @result
      if result.is_a?(Refusal)
        if result.compile_error
          write_header("error", result.reason)
          @output << "nil\n"
          return
        end
        excerpt = result.source.size > 60 ? "#{result.source[0, 57]}..." : result.source
        write_header("fallback", "Mica::Regex.static: #{excerpt.inspect} stays on the runtime engine: #{result.reason}")
        @output << "::Mica::Regex::StaticFallback.new(" << result.source.inspect << ", ::Mica::Regex::CompileOptions.new("
        @output << result.options.value << "_u32), " << result.reason.inspect << ")\n"
      else
        write_header("static", "")
        write_pattern(result)
      end
    end

    private def write_header(kind : String, note : String) : Nil
      @output << kind << '\n' << note.tr("\n", " ") << '\n' << NOTE_SEPARATOR << '\n'
    end

    private def write_pattern(tables : PatternTables) : Nil
      forward_type = type_for(tables.forward.largest_entry)
      reverse_type = type_for(tables.reverse.largest_entry)
      nfa = tables.nfa
      nfa_type = nfa ? type_for(nfa.largest_entry) : "UInt8"
      @output << "::Mica::Regex::StaticPattern(" << forward_type << ", " << reverse_type << ", " << nfa_type << ", "
      @output << tables.scratch_words << ").new(::Mica::Regex::StaticMatcher(" << forward_type << ", " << reverse_type
      @output << ", " << nfa_type << ").new(\n"
      @output << "  source: " << tables.source.inspect << ",\n"
      @output << "  options: ::Mica::Regex::CompileOptions.new(" << tables.options.value << "_u32),\n"
      @output << "  classes: "
      write_slice("UInt8", tables.list_of_classes)
      @output << ",\n  forward: "
      write_direction(forward_type, tables.forward)
      @output << ",\n  reverse: "
      write_direction(reverse_type, tables.reverse)
      @output << ",\n  program: "
      write_program(nfa_type, nfa)
      @output << ",\n  one_pass: "
      write_one_pass(tables.one_pass)
      @output << ",\n  unicode_words: " << tables.unicode_words << ", final_lf: " << tables.final_lf
      @output << ", anchored_start: " << tables.anchored_start << ",\n"
      @output << "  budget_states: " << tables.program_state_count << ", slot_count: " << tables.slot_count << ",\n"
      @output << "  prefilter: "
      write_prefilter(tables.prefilter)
      @output << ",\n  required_bytes: "
      write_slice("UInt8", tables.list_of_required_bytes)
      @output << "))\n"
    end

    private def write_direction(type : String, tables : DirectionTables) : Nil
      @output << "::Mica::Regex::StaticDirection(" << type << ").new(shift: " << tables.shift
      @output << ", relevant_flags: " << tables.relevant_flags << ", context_mask: " << tables.context_mask
      @output << ", special_limit: " << tables.special_limit << ", accel_limit: " << tables.accel_limit << ",\n    table: "
      write_slice(type, tables.list_of_entries)
      @output << ",\n    starts: "
      write_slice(type, tables.list_of_starts)
      @output << ",\n    accel_bytes: "
      write_slice("Int32", tables.list_of_accel_bytes)
      @output << ')'
    end

    private def write_program(type : String, nfa : NfaTables?) : Nil
      unless nfa
        @output << "::Mica::Regex::StaticProgram(" << type << ").empty"
        return
      end
      @output << "::Mica::Regex::StaticProgram(" << type << ").new(start_state: " << nfa.start_state << ",\n    kinds: "
      write_slice("UInt8", nfa.list_of_kinds)
      @output << ",\n    lows: "
      write_slice("UInt8", nfa.list_of_lows)
      @output << ",\n    highs: "
      write_slice("UInt8", nfa.list_of_highs)
      @output << ",\n    next_states: "
      write_slice(type, nfa.list_of_next_states)
      @output << ",\n    alternates: "
      write_slice(type, nfa.list_of_alternates)
      @output << ",\n    arguments: "
      write_slice(type, nfa.list_of_arguments)
      @output << ",\n    sparse_lows: "
      write_slice("UInt8", nfa.list_of_sparse_lows)
      @output << ",\n    sparse_highs: "
      write_slice("UInt8", nfa.list_of_sparse_highs)
      @output << ",\n    sparse_targets: "
      write_slice(type, nfa.list_of_sparse_targets)
      @output << ",\n    class_count: " << nfa.class_count << ", class_targets: "
      write_slice(type, nfa.list_of_class_targets)
      @output << ')'
    end

    private def write_one_pass(one_pass : OnePassTables?) : Nil
      unless one_pass
        @output << "::Mica::Regex::StaticOnePass.empty"
        return
      end
      @output << "::Mica::Regex::StaticOnePass.new(class_count: " << one_pass.class_count << ",\n    steps: "
      write_slice("Int32", one_pass.list_of_steps)
      @output << ",\n    cells: "
      write_slice("Int32", one_pass.list_of_cells)
      @output << ",\n    match_edges: "
      write_slice("Int32", one_pass.list_of_match_edges)
      @output << ",\n    edge_slots: "
      write_slice("UInt64", one_pass.list_of_edge_slots)
      @output << ",\n    edge_looks: "
      write_slice("UInt32", one_pass.list_of_edge_looks)
      @output << ",\n    ascii_loops: "
      write_slice("UInt8", one_pass.list_of_ascii_loops)
      @output << ')'
    end

    private def write_prefilter(prefilter : PrefilterTables?) : Nil
      unless prefilter
        @output << "::Mica::Regex::StaticPrefilter.none"
        return
      end
      @output << "::Mica::Regex::StaticPrefilter.new(kind: " << prefilter.kind << ", exact: " << prefilter.exact
      @output << ", needle: " << prefilter.needle << ", needle_offset: " << prefilter.needle_offset
      @output << ", pair_gap: " << prefilter.pair_gap << ", mask_width: " << prefilter.mask_width
      @output << ", minimum_length: " << prefilter.minimum_length << ",\n    literal_bytes: "
      write_slice("UInt8", prefilter.list_of_literal_bytes)
      @output << ",\n    literal_ends: "
      write_slice("Int32", prefilter.list_of_literal_ends)
      {starting_with: prefilter.list_of_starting_with, words: prefilter.list_of_words,
       word_masks: prefilter.list_of_word_masks, masks: prefilter.list_of_masks,
       pair_tests: prefilter.list_of_pair_tests, narrow_tests: prefilter.list_of_narrow_tests,
       dense_tests: prefilter.list_of_dense_tests}.each do |name, list_of_values|
        @output << ",\n    " << name << ": "
        write_slice("UInt64", list_of_values)
      end
      @output << ')'
    end

    private def write_slice(type : String, list_of_values : Array(Int)) : Nil
      if list_of_values.empty?
        @output << "Slice(" << type << ").empty"
        return
      end
      @output << "Slice(" << type << ").literal("
      # A 64-bit value past `Int64::MAX` needs its suffix.
      suffix = type == "UInt64" ? "_u64" : ""
      list_of_values.each_with_index do |value, index|
        @output << ", " if index > 0
        @output << value << suffix
      end
      @output << ')'
    end

    private def type_for(largest : Int32) : String
      case BuildTheTables.width_of(largest)
      when 1 then "UInt8"
      when 2 then "UInt16"
      else        raise Mica::Error.new("internal error: #{largest} does not fit a static table")
      end
    end
  end
end
