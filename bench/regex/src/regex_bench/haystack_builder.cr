module RegexBench
  # Builds the haystack string a `HaystackSpec` describes. Every engine
  # process builds it with this same code, so all engines search identical
  # bytes.
  class HaystackBuilder
    def initialize(@spec : HaystackSpec, @rebar_haystack_directory : String)
    end

    def build : String
      text = read_source
      text = text.scrub if @spec.utf8_lossy?
      text = text.strip if @spec.trim?
      text = select_lines(text) if @spec.has_line_range?
      text = text * @spec.repeat if @spec.repeat != 1
      text = @spec.prepend + text + @spec.append unless @spec.prepend.empty? && @spec.append.empty?
      text
    end

    private def read_source : String
      if @spec.uses_a_generator?
        return HaystackGenerator.new(@spec.generator, @spec.target_bytes).generate
      end
      return @spec.contents unless @spec.reads_a_file?

      file_path = File.join(@rebar_haystack_directory, @spec.path)
      unless File.exists?(file_path)
        raise CorpusError.new("haystack #{file_path} is missing; run bench/regex/scripts/rebar_corpus.rb fetch")
      end
      # Read as bytes: the file may hold invalid UTF-8, which `utf8_lossy`
      # repairs and which otherwise reaches the engine unchanged.
      String.new(File.read(file_path).to_slice)
    end

    # Keeps lines [line_start, line_end), each with its terminator, as rebar
    # does.
    private def select_lines(text : String) : String
      first = @spec.line_start == HaystackSpec::NO_LINE_LIMIT ? 0_i64 : @spec.line_start
      last = @spec.line_end == HaystackSpec::NO_LINE_LIMIT ? Int64::MAX : @spec.line_end
      String.build do |io|
        line_number = 0_i64
        text.each_line(chomp: false) do |line|
          io << line if line_number >= first && line_number < last
          line_number += 1
          break if line_number >= last
        end
      end
    end
  end
end
