require "./build_the_tables"

module Mica::Regex::Static
  # When a static pattern's tables are built (or refused), then the
  # Crystal expression that stands for the pattern in the application is
  # written: a `StaticPattern` whose tables are `Slice.literal`s at the
  # narrowest integer width each allows (read-only data in the binary), or
  # a `StaticFallback` that compiles the pattern with the runtime engine
  # when the application starts.
  #
  # The output is a compile-time note, the line `%%`, then the expression
  # (see `Mica::Regex.static`).
  class WriteTheSource
    NOTE_SEPARATOR = "%%"

    def initialize(@result : PatternTables | Refusal, @output : IO)
    end

    def perform : Nil
      result = @result
      if result.is_a?(Refusal)
        excerpt = result.source.size > 60 ? "#{result.source[0, 57]}..." : result.source
        @output << "Mica::Regex.static: " << excerpt.inspect << " stays on the runtime engine: " << result.reason << '\n'
        @output << NOTE_SEPARATOR << '\n'
        @output << "::Mica::Regex::StaticFallback.new(" << result.source.inspect << ", ::Mica::Regex::CompileOptions.new("
        @output << result.options.value << "_u32), " << result.reason.inspect << ")\n"
      else
        @output << NOTE_SEPARATOR << '\n'
        write_pattern(result)
      end
    end

    private def write_pattern(tables : PatternTables) : Nil
      forward_type = type_for(tables.forward.largest_entry)
      reverse_type = type_for(tables.reverse.largest_entry)
      nfa = tables.nfa
      nfa_type = nfa ? type_for(largest_of(nfa)) : "UInt8"
      @output << "::Mica::Regex::StaticPattern(" << forward_type << ", " << reverse_type << ", " << nfa_type << ", "
      @output << tables.scratch_words << ").new(\n"
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
      @output << "  budget_states: " << tables.program_state_count << ", slot_count: " << tables.slot_count << ")\n"
    end

    private def write_direction(type : String, tables : DirectionTables) : Nil
      @output << "::Mica::Regex::StaticDirection(" << type << ").new(stride: " << tables.stride
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

    private def write_slice(type : String, list_of_values : Array(Int)) : Nil
      if list_of_values.empty?
        @output << "Slice(" << type << ").empty"
        return
      end
      @output << "Slice(" << type << ").literal("
      list_of_values.join(@output, ", ")
      @output << ')'
    end

    private def largest_of(nfa : NfaTables) : Int32
      {nfa.list_of_next_states, nfa.list_of_alternates, nfa.list_of_arguments, nfa.list_of_sparse_targets}
        .max_of { |list| list.max? || 0 }
    end

    private def type_for(largest : Int32) : String
      case BuildTheTables.width_of(largest)
      when 1 then "UInt8"
      when 2 then "UInt16"
      else        "UInt32"
      end
    end
  end
end
