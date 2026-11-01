require "../spec_helper"

private def tight_budget_error(xml : String) : Mica::WorkBudgetExceededError
  budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 100_000)
  options = Mica::XML::ParserOptions.new(work_budget: budget)
  expect_raises(Mica::WorkBudgetExceededError) { Mica::XML.parse(xml, options) }
end

# Regression specs for the thirty-fourth Codex code review of 2026-10-24.
describe "Codex review 34 findings" do
  it "1: stops long runs of stop bytes inside one token at the budget" do
    count = 1_000_000
    {
      "<r a=\"#{"'" * count}\"/>",
      "<r>#{"]" * count}</r>",
      "<r><?pi #{"?" * count}?></r>",
    }.each do |xml|
      tight_budget_error(xml).byte_offset.should be < 400_000
    end
  end

  it "2: stops a declaration of many short members at the budget" do
    definitions = (1..100_000).join(' ') { |number| "a#{number} CDATA #IMPLIED" }
    members = (1..100_000).join('|') { |number| "t#{number}" }
    {
      "<!DOCTYPE r [<!ATTLIST r #{definitions}>]><r/>",
      "<!DOCTYPE r [<!ATTLIST r a (#{members}) #IMPLIED>]><r/>",
      "<!DOCTYPE r [<!ELEMENT r (#PCDATA|#{members})*>]><r/>",
      "<!DOCTYPE r [<!ELEMENT r (#{members})>]><r/>",
    }.each do |xml|
      tight_budget_error(xml).byte_offset.should be < xml.bytesize // 2
    end
  end

  it "6: rejects negative limits when options are built" do
    expect_raises(ArgumentError, /max_input_bytes/) { Mica::XML::ParserOptions.new(max_input_bytes: Int64::MIN) }
    expect_raises(ArgumentError, /max_token_bytes/) { Mica::XML::ParserOptions.new(max_token_bytes: -1) }
  end
end
