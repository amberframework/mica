module RegexBench
  # When a run directory holds results.jsonl and run.json, then the report
  # is built and written as Markdown and JSON.
  class WriteTheReport
    def initialize(@run_directory : String, @corpus_directory : String, @markdown_path : String, @json_path : String,
                   @title : String)
    end

    def perform : ReportDocument
      run = RunRecord.from_json(File.read(File.join(@run_directory, "run.json")))
      list_of_results = File.read_lines(File.join(@run_directory, "results.jsonl"))
        .reject(&.blank?)
        .map { |line| CaseResult.from_json(line) }
      # The driver runs cases in a shuffled order; the report lists them by
      # corpus, group and size, as the corpora define them.
      list_of_results.sort_by! do |case_result|
        {Corpus::LIST_OF_CORPORA.index(case_result.corpus) || Corpus::LIST_OF_CORPORA.size, case_result.group,
         case_result.case_id.sub(/@.*\z/, ""), case_result.size_units, case_result.engine}
      end
      families = Corpus.new(@corpus_directory, "").redos_document.families
      document = BuildTheReport.new(run, list_of_results, families).perform
      File.write(@json_path, document.to_pretty_json)
      File.write(@markdown_path, RenderTheMarkdown.new(document, list_of_results, @title).perform)
      document
    end
  end
end
