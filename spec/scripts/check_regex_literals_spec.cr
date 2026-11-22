require "spec"

# Runs scripts/check_regex_literals.cr over fixture trees with the compiler
# that runs the suite (`CRYSTAL`, or `crystal`).
private ROOT     = File.expand_path("../..", __DIR__)
private FIXTURES = File.join(__DIR__, "check_regex_literals_fixtures")

private record ScriptRun, exit_code : Int32, output : String

private def crystal_command : String
  ENV["CRYSTAL"]? || "crystal"
end

private def run_script(fixture_name : String) : ScriptRun
  output = IO::Memory.new
  search_path = "#{File.join(ROOT, "src")}:#{`#{crystal_command} env CRYSTAL_PATH`.strip}"
  status = Process.run(crystal_command,
    ["run", File.join(ROOT, "scripts", "check_regex_literals.cr"), "--", fixture_name],
    env: {"CRYSTAL_PATH" => search_path}, chdir: FIXTURES, output: output, error: output)
  ScriptRun.new(status.exit_code, output.to_s)
end

describe "scripts/check_regex_literals.cr" do
  it "names every pattern Mica cannot run, with its file and line, and exits 1" do
    script_run = run_script("offending")
    script_run.exit_code.should eq(1), script_run.output

    list_of_reported_lines = script_run.output.lines.compact_map do |line|
      match = line.match(/\Aoffending\/patterns\.cr:(\d+):\d+: /)
      match ? match[1].to_i : nil
    end
    # LOOKAHEAD through FROM_A_STRING, the interpolated literal, the literal
    # in a method nothing calls, the literal a macro expression runs and the
    # literal in the text of a macro body.
    list_of_reported_lines.sort.should eq([4, 5, 6, 7, 8, 9, 10, 13, 17, 21, 26])

    script_run.output.should contain("lookahead (at 5) is not supported")
    script_run.output.should contain("lookbehind (at 0) is not supported")
    script_run.output.should contain("a backreference")
    script_run.output.should contain("a possessive quantifier")
    script_run.output.should contain("an atomic group")
    script_run.output.should contain("11 patterns Mica cannot run in 1 file ")
  end

  it "exits 0 for patterns Mica runs and passes over a pattern marked as PCRE2 only" do
    script_run = run_script("clean")
    script_run.exit_code.should eq(0), script_run.output
    script_run.output.should contain("0 patterns Mica cannot run in 1 file ")
  end
end
