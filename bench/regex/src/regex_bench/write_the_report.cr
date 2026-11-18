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
      families = Corpus.new(@corpus_directory, "").redos_document.families
      document = BuildTheReport.new(run, list_of_results, families).perform
      File.write(@json_path, document.to_pretty_json)
      File.write(@markdown_path, RenderTheMarkdown.new(document, list_of_results, @title).perform)
      document
    end
  end
end
