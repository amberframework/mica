# The yaml-test-suite cases and their event notation, shared by
# conformance/run_yaml.cr and conformance/run_yaml_libyaml.cr.
module YAMLSuite
  # One case: its id ("229Q", or "2G84/00" for a case with variants), its
  # description, the input, the events the suite expects and whether the
  # input must be rejected.
  record Case, id : String, description : String, input : Bytes, expected : String, is_invalid : Bool

  # Returns every case under *root* (the extracted data branch). The
  # name/ and tags/ directories hold links to the same cases and are not
  # read.
  def self.list_of_cases(root : String) : Array(Case)
    list_of_cases = [] of Case
    Dir.children(root).sort!.each do |name|
      directory = File.join(root, name)
      next unless File.directory?(directory) && name.size == 4 && name.each_char.all? { |char| char.ascii_uppercase? || char.ascii_number? }
      if File.exists?(File.join(directory, "in.yaml"))
        list_of_cases << read_case(name, directory)
      else
        Dir.children(directory).sort!.each do |variant|
          nested = File.join(directory, variant)
          list_of_cases << read_case("#{name}/#{variant}", nested) if File.exists?(File.join(nested, "in.yaml"))
        end
      end
    end
    list_of_cases
  end

  private def self.read_case(id : String, directory : String) : Case
    description_path = File.join(directory, "===")
    description = File.exists?(description_path) ? File.read(description_path).strip : ""
    Case.new(id, description, File.read(File.join(directory, "in.yaml")).to_slice,
      File.read(File.join(directory, "test.event")), File.exists?(File.join(directory, "error")))
  end

  # Writes a scalar's content the way test.event files do.
  def self.escape(io : IO, value : String) : Nil
    value.each_char do |char|
      case char
      when '\\' then io << "\\\\"
      when '\0' then io << "\\0"
      when '\b' then io << "\\b"
      when '\n' then io << "\\n"
      when '\r' then io << "\\r"
      when '\t' then io << "\\t"
      else           io << char
      end
    end
  end

  # Compares an outcome with a case's expectation. *events* is nil when
  # the parser rejected the input. Returns "pass", or the kind of failure.
  def self.verdict(kase : Case, events : String?) : String
    if kase.is_invalid
      events ? "accepted-invalid" : "pass"
    elsif events.nil?
      "rejected-valid"
    elsif events == kase.expected
      "pass"
    else
      "wrong-events"
    end
  end

  # Prints the per-verdict summary and writes one row per case to
  # *results_path* when given.
  def self.report(label : String, list_of_results : Array({Case, String, String}), results_path : String?) : Nil
    counts = Hash(String, Int32).new(0)
    list_of_results.each { |_, verdict, _| counts[verdict] += 1 }
    valid = list_of_results.count { |kase, _, _| !kase.is_invalid }
    invalid = list_of_results.size - valid
    valid_passed = list_of_results.count { |kase, verdict, _| !kase.is_invalid && verdict == "pass" }
    invalid_passed = list_of_results.count { |kase, verdict, _| kase.is_invalid && verdict == "pass" }
    puts "#{label}: #{counts["pass"]}/#{list_of_results.size} pass " \
         "(valid inputs: #{valid_passed}/#{valid} with the expected events; " \
         "invalid inputs: #{invalid_passed}/#{invalid} rejected; " \
         "wrong-events #{counts["wrong-events"]}, rejected-valid #{counts["rejected-valid"]}, " \
         "accepted-invalid #{counts["accepted-invalid"]}, crash #{counts["crash"]})"
    list_of_results.each do |kase, verdict, detail|
      puts "  #{verdict} #{kase.id} #{kase.description}#{detail.empty? ? "" : " (#{detail})"}" unless verdict == "pass"
    end
    return unless results_path
    File.open(results_path, "w") do |file|
      file << "id\texpectation\tverdict\tdescription\tdetail\n"
      list_of_results.each do |kase, verdict, detail|
        file << kase.id << '\t' << (kase.is_invalid ? "invalid" : "valid") << '\t' << verdict << '\t'
        file << kase.description << '\t' << detail << '\n'
      end
    end
  end
end
