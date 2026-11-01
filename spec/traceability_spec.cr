require "./spec_helper"

# Checks the requirement catalogs in spec/requirements/ against the ids the
# specs declare with `it_satisfies`. Ids are recorded when spec files load,
# so this sees every spec compiled into the same binary. Set
# MICA_TRACEABILITY_REPORT to a path to write the coverage table as TSV.
describe "Requirement traceability" do
  catalog = Mica::Testing::Traceability::Catalog.merge(
    Dir.glob(File.join(__DIR__, "requirements", "*.tsv")).sort!.map { |path| Mica::Testing::Traceability::Catalog.parse(File.read(path)) }
  )

  it_satisfies "MICA-TESTING-TRACEABILITY", "covers every catalog requirement with a spec and uses only catalog ids" do
    coverage = REQUIREMENTS.coverage(catalog)
    if path = ENV["MICA_TRACEABILITY_REPORT"]?
      File.open(path, "w") { |file| REQUIREMENTS.write_report(file, catalog) }
    end
    coverage.unknown.keys.should eq([] of String)
    # The full suite covers every id; a partial build (one spec file) only
    # checks that the ids it uses exist.
    if REQUIREMENTS.locations_by_id.size >= catalog.list_of_requirements.size
      coverage.list_of_uncovered_ids.should eq([] of String)
    end
  end
end
