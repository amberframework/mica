module Mica::Testing
  # Maps specification requirement ids to the specs that cover them.
  #
  # Each format keeps a catalog of its specification's requirements, a TSV
  # file with one requirement per line:
  #
  #     id<TAB>section<TAB>summary
  #
  # (lines starting with `#` are comments). Ids are stable strings such as
  # `XML10-2.2-Char` or `RFC8949-3.1-major-types`. Specs declare what they
  # cover; the registry then reports which requirements are covered, which
  # are not, and which ids no catalog knows (a typo or a stale id).
  #
  # ```
  # catalog = Mica::Testing::Traceability::Catalog.parse("XML10-2.2-Char\t2.2\tCharacters\n")
  # registry = Mica::Testing::Traceability::Registry.new
  # registry.record("XML10-2.2-Char", "spec/xml/hostile_bytes_spec.cr:12")
  # registry.coverage(catalog).list_of_uncovered_ids # => [] of String
  # ```
  module Traceability
    # One requirement from a catalog.
    record Requirement, id : String, section : String, summary : String

    # A format's requirement catalog.
    class Catalog
      getter list_of_requirements : Array(Requirement)

      def initialize(@list_of_requirements : Array(Requirement))
        @by_id = {} of String => Requirement
        @list_of_requirements.each do |requirement|
          raise ArgumentError.new("Duplicate requirement id #{requirement.id}") if @by_id.has_key?(requirement.id)
          @by_id[requirement.id] = requirement
        end
      end

      # Parses catalog *text* (see `Traceability`).
      def self.parse(text : String) : Catalog
        list_of_requirements = [] of Requirement
        text.each_line do |line|
          next if line.blank? || line.starts_with?('#')
          fields = line.split('\t', 3)
          raise ArgumentError.new("Malformed requirement line: #{line.inspect}") unless fields.size == 3
          list_of_requirements << Requirement.new(fields[0].strip, fields[1].strip, fields[2].strip)
        end
        new(list_of_requirements)
      end

      # Merges several catalogs into one.
      def self.merge(catalogs : Enumerable(Catalog)) : Catalog
        new(catalogs.flat_map(&.list_of_requirements))
      end

      # Returns true when the catalog lists *id*.
      def includes?(id : String) : Bool
        @by_id.has_key?(id)
      end

      # Returns the requirement *id*, or nil.
      def []?(id : String) : Requirement?
        @by_id[id]?
      end
    end

    # The coverage of a catalog by the recorded specs.
    record Coverage, covered : Hash(String, Array(String)), list_of_uncovered_ids : Array(String), unknown : Hash(String, Array(String)) do
      # Returns the share of catalog requirements covered, from 0.0 to 1.0.
      def ratio : Float64
        total = covered.size + list_of_uncovered_ids.size
        total == 0 ? 1.0 : covered.size / total
      end
    end

    # Records which spec covers which requirement.
    class Registry
      getter locations_by_id = {} of String => Array(String)

      # Records that the spec at *location* (`file:line`) covers *id*.
      def record(id : String, location : String) : Nil
        (@locations_by_id[id] ||= [] of String) << location
      end

      # Compares the recorded ids with *catalog*.
      def coverage(catalog : Catalog) : Coverage
        covered = {} of String => Array(String)
        unknown = {} of String => Array(String)
        @locations_by_id.each do |id, locations|
          if catalog.includes?(id)
            covered[id] = locations
          else
            unknown[id] = locations
          end
        end
        uncovered = catalog.list_of_requirements.map(&.id).reject { |id| covered.has_key?(id) }
        Coverage.new(covered, uncovered, unknown)
      end

      # Writes a TSV report: one line per catalog requirement with its
      # status and the covering spec locations, then unknown ids.
      def write_report(io : IO, catalog : Catalog) : Nil
        result = coverage(catalog)
        io << "id\tsection\tstatus\tspecs\n"
        catalog.list_of_requirements.each do |requirement|
          locations = result.covered[requirement.id]?
          io << requirement.id << '\t' << requirement.section << '\t' << (locations ? "covered" : "uncovered") << '\t'
          io << (locations ? locations.join(' ') : "") << '\n'
        end
        result.unknown.each do |id, locations|
          io << id << "\t\tunknown\t" << locations.join(' ') << '\n'
        end
      end
    end
  end
end
