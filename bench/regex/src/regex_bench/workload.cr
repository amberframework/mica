module RegexBench
  # rebar's benchmark models, written once over `CompiledPattern#find`, so
  # every engine does the same work per iteration. Iteration advances like
  # `String#scan`: after an empty match it steps over one character.
  struct Workload
    LIST_OF_MODELS = %w[compile count count-spans count-captures grep grep-captures first-match]

    def initialize(@compiled : CompiledPattern, @haystack : String, @model : String)
      unless LIST_OF_MODELS.includes?(@model)
        raise UnsupportedCaseError.new("model #{@model} is not implemented")
      end
    end

    # Runs one iteration over *haystack* and returns the model's
    # verification count. *haystack* is equal to the one the workload was
    # built with; a timed run passes its own copy (see `HaystackCopies`).
    def run(haystack : String = @haystack) : Int64
      case @model
      when "count", "compile" then count_matches(haystack) { 1_i64 }
      when "count-spans"      then count_matches(haystack) { |span| (span.finish - span.start).to_i64 }
      when "count-captures"   then count_matches(haystack, count_groups: true) { |span| span.groups_matched.to_i64 }
      when "grep"             then count_matching_lines(haystack)
      when "grep-captures"    then count_groups_per_line(haystack)
      else                         first_match(haystack)
      end
    end

    private def count_matches(text : String, count_groups : Bool = false, & : Span -> Int64) : Int64
      total = 0_i64
      byte_offset = 0
      first_search = true
      while byte_offset <= text.bytesize
        span = @compiled.find(text, byte_offset, first_search, count_groups)
        break unless span
        first_search = false
        total += yield span
        byte_offset = next_offset_after(text, span)
      end
      total
    end

    private def next_offset_after(text : String, span : Span) : Int32
      return span.finish if span.finish > span.start
      return text.bytesize + 1 if span.finish >= text.bytesize
      span.finish + Char::Reader.new(text, pos: span.finish).current_char_width
    end

    private def count_matching_lines(haystack : String) : Int64
      total = 0_i64
      haystack.each_line(chomp: true) do |line|
        total += 1 if @compiled.find(line, 0, true, false)
      end
      total
    end

    private def count_groups_per_line(haystack : String) : Int64
      total = 0_i64
      haystack.each_line(chomp: true) do |line|
        total += count_matches(line, count_groups: true) { |span| span.groups_matched.to_i64 }
      end
      total
    end

    private def first_match(haystack : String) : Int64
      @compiled.find(haystack, 0, true, false) ? 1_i64 : 0_i64
    end
  end
end
