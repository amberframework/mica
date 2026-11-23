require "../spec_helper"
require "file_utils"

private REPOSITORY_ROOT = File.expand_path(File.join(__DIR__, "..", ".."))
private VENDOR_SCRIPT   = File.join(REPOSITORY_ROOT, "scripts", "vendor_into.rb")

private def run_vendor_script(*arguments : String) : {Int32, String}
  output = IO::Memory.new
  status = Process.run("ruby", [VENDOR_SCRIPT] + arguments.to_a, output: output, error: output)
  {status.exit_code, output.to_s}
end

private def with_a_vendored_copy(&)
  destination = File.join(Dir.tempdir, "mica-vendor-into-#{Random::Secure.hex(8)}")
  begin
    exit_code, output = run_vendor_script("--commit", "HEAD", "--component", "deflate", "--namespace", "Carrier",
      "--destination", destination)
    fail "vendor_into.rb failed: #{output}" unless exit_code == 0
    yield destination
  ensure
    FileUtils.rm_rf(destination)
  end
end

describe "scripts/vendor_into.rb" do
  it "copies the deflate component under the carrier's namespace and pins every file" do
    with_a_vendored_copy do |destination|
      deflate_source = File.read(File.join(destination, "mica", "deflate.cr"))
      deflate_source.should contain("module Carrier::Mica::Deflate")
      File.read(File.join(destination, "mica", "gzip.cr")).should contain("module Carrier::Mica::Gzip")
      File.exists?(File.join(destination, "MICA_LICENSE")).should be_true
      File.exists?(File.join(destination, "mica", "regex.cr")).should be_false

      manifest = File.read(File.join(destination, "MICA_VENDORED.json"))
      manifest.should contain(%("namespace": "Carrier::Mica"))
      manifest.should contain(%("component": "deflate"))
      manifest.should contain(%("path": "mica/deflate/inflater.cr"))

      exit_code, output = run_vendor_script("--check", "--destination", destination)
      output.should contain("files match")
      exit_code.should eq(0)
    end
  end

  it "copies the compression component, Brotli's dictionary byte for byte" do
    destination = File.join(Dir.tempdir, "mica-vendor-into-#{Random::Secure.hex(8)}")
    begin
      exit_code, output = run_vendor_script("--commit", "HEAD", "--component", "compression", "--namespace", "Carrier",
        "--destination", destination)
      fail "vendor_into.rb failed: #{output}" unless exit_code == 0
      File.read(File.join(destination, "mica", "brotli.cr")).should contain("module Carrier::Mica::Brotli")
      File.read(File.join(destination, "mica", "brotli", "dictionary.bin")).to_slice
        .should eq(File.read(File.join(REPOSITORY_ROOT, "src", "mica", "brotli", "dictionary.bin")).to_slice)
      File.read(File.join(destination, "MICA_VENDORED.json")).should contain(%("component": "compression"))
      exit_code, output = run_vendor_script("--check", "--destination", destination)
      output.should contain("files match")
      exit_code.should eq(0)
    ensure
      FileUtils.rm_rf(destination)
    end
  end

  it "fails the check when a pinned file is edited" do
    with_a_vendored_copy do |destination|
      File.write(File.join(destination, "mica", "gzip.cr"), "# edited\n", mode: "a")
      exit_code, output = run_vendor_script("--check", "--destination", destination)
      output.should contain("does not match its pin")
      exit_code.should eq(1)
    end
  end

  it "fails the check when a file has no pin" do
    with_a_vendored_copy do |destination|
      File.write(File.join(destination, "mica", "added.cr"), "# added\n")
      exit_code, output = run_vendor_script("--check", "--destination", destination)
      output.should contain("files with no pin: mica/added.cr")
      exit_code.should eq(1)
    end
  end

  it "refuses a component it does not know" do
    exit_code, output = run_vendor_script("--commit", "HEAD", "--component", "everything", "--namespace", "Carrier",
      "--destination", File.join(Dir.tempdir, "mica-vendor-into-unused"))
    output.should contain("everything is not a component")
    exit_code.should eq(1)
  end
end
