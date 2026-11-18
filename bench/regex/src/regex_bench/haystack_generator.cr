module RegexBench
  # Generates the Amber-ecosystem haystacks: realistic text for each pattern
  # family, filled line by line to a target size. Output depends only on the
  # generator name and the size (a fixed-seed SplitMix64 drives every
  # choice), so every engine process searches identical bytes and a run can
  # be repeated exactly. `checksum` (FNV-1a, 64-bit) is recorded with each
  # result so a drift in the generator is visible.
  class HaystackGenerator
    LIST_OF_GENERATORS = %w[routes contacts markdown logs csv identifiers templates]

    LIST_OF_WORDS = %w[amber grant micrate crystal router request response session cookie token
      invoice customer account profile settings report export import upload storage bucket
      queue worker schedule billing payment refund order product catalog search index admin]

    LIST_OF_FIRST_NAMES = %w[ada grace linus ken dennis barbara margaret alan edsger donald
      frances john radia guido yukihiro ary seth brian rob]

    LIST_OF_DOMAINS = %w[example.com example.org amberframework.org mail.example.net
      agentc.consulting test.example.co.uk]

    @state : UInt64

    def initialize(@generator_name : String, @target_bytes : Int64)
      unless LIST_OF_GENERATORS.includes?(@generator_name)
        raise CorpusError.new("unknown haystack generator #{@generator_name}")
      end
      @state = 0x9E3779B97F4A7C15_u64 ^ @generator_name.bytes.sum(0_u64) { |byte| byte.to_u64 }
    end

    def generate : String
      String.build(@target_bytes.to_i32 + 256) do |io|
        written = 0_i64
        while written < @target_bytes
          line = next_line
          break if written + line.bytesize > @target_bytes && written > 0
          io << line
          written += line.bytesize
        end
      end
    end

    # FNV-1a over the bytes of *text*.
    def self.checksum(text : String) : UInt64
      hash = 0xcbf29ce484222325_u64
      text.each_byte do |byte|
        hash = (hash ^ byte) &* 0x100000001b3_u64
      end
      hash
    end

    private def next_line : String
      case @generator_name
      when "routes"      then route_line
      when "contacts"    then contact_line
      when "markdown"    then markdown_line
      when "logs"        then log_line
      when "csv"         then csv_line
      when "identifiers" then identifier_line
      else                    template_line
      end
    end

    private def next_random : UInt64
      @state = @state &+ 0x9E3779B97F4A7C15_u64
      mixed = @state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9_u64
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB_u64
      mixed ^ (mixed >> 31)
    end

    private def below(limit : Int32) : Int32
      (next_random % limit.to_u64).to_i32
    end

    private def pick(list : Array(String)) : String
      list[below(list.size)]
    end

    private def hex(digits : Int32) : String
      String.build(digits) do |io|
        digits.times { io << "0123456789abcdef"[below(16)] }
      end
    end

    private def word : String
      pick(LIST_OF_WORDS)
    end

    private def sentence(word_count : Int32) : String
      String.build do |io|
        word_count.times do |index|
          io << ' ' if index > 0
          io << word
        end
      end
    end

    # Path segments and host headers, one per line, as a router sees them.
    private def route_line : String
      case below(10)
      when 0, 1 then "#{hex(8)}-#{hex(4)}-#{hex(4)}-#{hex(4)}-#{hex(12)}\n"
      when 2    then "#{hex(8).upcase}-#{hex(4)}-#{hex(4)}-#{hex(4)}-#{hex(12)}\n"
      when 3, 4 then "#{word}-#{word}-#{below(1000)}\n"
      when 5    then "#{below(10_000_000)}\n"
      when 6    then "#{word}_#{word} #{word}\n"
      when 7    then "#{pick(LIST_OF_DOMAINS)}:#{3000 + below(6000)}\n"
      when 8    then "/#{word}s/#{below(100_000)}/#{word}s/#{hex(8)}-#{hex(4)}-#{hex(4)}-#{hex(4)}-#{hex(12)}/edit\n"
      else           "#{word}.#{word}-#{hex(3)}\n"
      end
    end

    # Email addresses and URLs, one per line, valid and invalid, as a form
    # validator sees them.
    private def contact_line : String
      name = pick(LIST_OF_FIRST_NAMES)
      case below(8)
      when 0, 1 then "#{name}.#{word}@#{pick(LIST_OF_DOMAINS)}\n"
      when 2    then "#{name}+#{word}#{below(100)}@#{pick(LIST_OF_DOMAINS)}\n"
      when 3    then "#{name} at #{pick(LIST_OF_DOMAINS)}\n"
      when 4    then "https://www.#{pick(LIST_OF_DOMAINS)}/#{word}/#{below(10_000)}?ref=#{word}&page=#{below(50)}\n"
      when 5    then "http://#{pick(LIST_OF_DOMAINS)}/#{word}s/#{word}-#{word}\n"
      when 6    then "ftp://#{pick(LIST_OF_DOMAINS)}/#{word}.tar.gz\n"
      else           "#{name}@@#{word}\n"
      end
    end

    # A Markdown document: headings, paragraphs with inline markup, links,
    # autolinks, entities, breaks and footnote definitions.
    private def markdown_line : String
      case below(14)
      when 0 then "#{"#" * (1 + below(6))} #{sentence(3 + below(4)).capitalize}\n\n"
      when 1 then "***\n\n"
      when 2 then "[^#{word}]: #{sentence(6 + below(10))}.\n"
      when 3 then "Contact <#{pick(LIST_OF_FIRST_NAMES)}@#{pick(LIST_OF_DOMAINS)}> or see <https://#{pick(LIST_OF_DOMAINS)}/#{word}>.\n"
      when 4 then "Prices &amp; terms: &#36;#{below(500)}, &#x2014; #{sentence(5)} &copy; #{2000 + below(27)}.\n"
      when 5 then "- #{sentence(4 + below(6))}, with `#{word}_#{word}` and *#{word}*.\n"
      when 6 then "> #{sentence(8 + below(8))}!\n"
      else        "#{sentence(10 + below(20)).capitalize}, **#{word}** and _#{word}_ (see [#{word}](https://#{pick(LIST_OF_DOMAINS)}/#{word}#section-#{below(9)})).\n"
      end
    end

    # Crystal backtraces and Grant SQL log lines, as an Amber app logs them.
    private def log_line : String
      case below(8)
      when 0 then "src/controllers/#{word}_controller.cr:#{1 + below(400)}:#{1 + below(80)} in '#{word}'\n"
      when 1 then "lib/amber/src/amber/router/#{word}.cr:#{1 + below(400)}:#{1 + below(40)} in '*Amber::Router::#{word.capitalize}#call<HTTP::Server::Context>:Nil' at 0x#{hex(9)}\n"
      when 2 then "~procProc(HTTP::Server::Context, Nil)@lib/amber/src/amber/server.cr:#{1 + below(300)} at 0x#{hex(9)}\n"
      when 3 then "[0x#{hex(9)}] *Fiber#run:(IO::FileDescriptor | Nil) +#{below(200)} (#{1 + below(9)} times)\n"
      when 4 then "SELECT \"#{word}s\".* FROM \"#{word}s\" WHERE \"#{word}s\".\"id\" = $1 AND \"#{word}s\".\"status\" = '#{word}' LIMIT #{1 + below(100)}\n"
      when 5 then "INSERT INTO #{word}s (#{word}_id, #{word}, created_at) VALUES ($1, $2, '2026-11-#{10 + below(18)} 12:#{10 + below(50)}:00')\n"
      when 6 then "UPDATE #{word}s SET #{word} = '#{word} #{word}',   updated_at = now() WHERE id = #{below(1_000_000)}\n"
      else        "2026-11-18T12:#{10 + below(50)}:#{10 + below(50)}Z INFO - amber.request: GET /#{word}s/#{below(10_000)} 200 #{below(900)}ms\n"
      end
    end

    # Comma-separated rows with irregular spacing.
    private def csv_line : String
      separator = below(3) == 0 ? ", " : ","
      String.build do |io|
        io << below(1_000_000) << separator << pick(LIST_OF_FIRST_NAMES) << separator
        io << pick(LIST_OF_FIRST_NAMES) << '@' << pick(LIST_OF_DOMAINS) << separator
        io << "2026-" << (1 + below(12)) << '-' << (1 + below(28)) << separator
        io << below(1000) << '.' << below(100) << separator << word << '\n'
      end
    end

    # Names as amber_cli turns them into slugs and Crystal type names.
    private def identifier_line : String
      case below(5)
      when 0 then "#{word.capitalize}#{word.capitalize}Controller\n"
      when 1 then "My #{word.capitalize} App #{below(10)}\n"
      when 2 then "#{word}_#{word}-v#{below(5)}\n"
      when 3 then "#{word.capitalize}#{word.capitalize}#{word.capitalize}Job\n"
      else        "  #{word.upcase} #{word}.#{word}  \n"
      end
    end

    # Template text with {{ placeholders }}.
    private def template_line : String
      case below(4)
      when 0 then "Hello {{ #{word}_name }}, your {{#{word}}} is ready.\n"
      when 1 then "#{sentence(8 + below(10))}.\n"
      when 2 then "<a href=\"{{ #{word}_url }}\">{{ #{word} }}</a> {{#{word}.#{word}}}\n"
      else        "{ not a placeholder } #{sentence(4)} {{ #{word}\n"
      end
    end
  end
end
