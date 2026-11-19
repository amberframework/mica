# Reads the approval column of the regex conformance divergence lists
# (roadmap 6.5): a divergence counts only when its row names an approver
# who owns /conformance/regex/ in .github/CODEOWNERS, written as
# `approved by @login`. A new row starts as `pending CODEOWNERS review`,
# which fails the gate until the owner approves it.
module ConformanceApproval
  CODEOWNERS_PATH = File.join(__DIR__, "..", "..", "..", ".github", "CODEOWNERS")
  OWNED_PATH      = "/conformance/regex/"
  PENDING         = "pending CODEOWNERS review"
  PREFIX          = "approved by @"

  # A divergence row: case id, reason and approval.
  record Row, id : String, reason : String, approval : String

  # The logins that own /conformance/regex/.
  def self.approvers : Set(String)
    owners = Set(String).new
    File.each_line(CODEOWNERS_PATH) do |line|
      fields = line.split
      next if fields.empty? || fields[0].starts_with?('#') || fields[0] != OWNED_PATH
      fields[1..].each { |owner| owners << owner.lchop('@') if owner.starts_with?('@') }
    end
    owners
  end

  # The rows of a divergence list at *path*, by case id.
  def self.read_rows(path : String) : Hash(String, Row)
    rows = {} of String => Row
    return rows unless File.exists?(path)
    File.each_line(path) do |line|
      next if line.starts_with?('#') || line.blank?
      fields = line.split('\t')
      rows[fields[0]] = Row.new(fields[0], fields[1]? || "", fields[2]? || "")
    end
    rows
  end

  # Returns "id: approval" for every row whose approval does not name a
  # code owner.
  def self.unapproved(rows : Hash(String, Row)) : Array(String)
    owners = approvers
    rows.values.compact_map do |row|
      login = row.approval.lchop?(PREFIX)
      next if login && owners.includes?(login)
      "#{row.id}: #{row.approval.empty? ? "no approval column" : row.approval}"
    end
  end
end
