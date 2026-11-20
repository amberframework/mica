require "json"

{% if flag?(:darwin) %}
  # The dyld calls that list the images loaded into this process.
  lib LibDyld
    fun _dyld_image_count : UInt32
    fun _dyld_get_image_header(image_index : UInt32) : Void*
    fun _dyld_get_image_vmaddr_slide(image_index : UInt32) : LibC::Long
  end
{% end %}

module RegexBench
  # What a page-in pass touched. `checksum` sums one byte of every page, so
  # the reads cannot be optimized away.
  record PageInSummary, image_count : Int32, page_count : Int64, checksum : UInt64 do
    include JSON::Serializable
  end

  # When a runner is started with `--page-in`, then it reads one byte of
  # every file-backed page of its own executable and of every library it
  # loaded from outside the shared system cache, and does no regex work.
  #
  # Why: the first time any process touches a page of a freshly built
  # binary, the kernel brings it into the page cache and, on macOS, checks
  # it against the code signature. That cost is paid once per binary, so
  # without this pass it lands inside the process-cold clock of whichever
  # case happens to run first (rebar/captures/contiguous-letters, whose
  # Mica process-cold read 6.4x to 6.9x PCRE2-JIT for this reason alone).
  # The driver runs this pass, untimed, before every runner process it
  # times, identically for every engine.
  class PageInTheRunnerImage
    PAGE_BYTES = 4096

    {% if flag?(:darwin) %}
      LC_SEGMENT_64     =       0x19_u32
      MH_DYLIB_IN_CACHE = 0x80000000_u32
      MACH_HEADER_BYTES =             32
    {% end %}

    @image_count = 0
    @page_count = 0_i64
    @checksum = 0_u64

    def perform : PageInSummary
      touch_every_loaded_image
      PageInSummary.new(@image_count, @page_count, @checksum)
    end

    {% if flag?(:darwin) %}
      private def touch_every_loaded_image : Nil
        LibDyld._dyld_image_count.times do |image_index|
          header = LibDyld._dyld_get_image_header(image_index).as(UInt8*)
          next if header.null?
          flags = (header + 24).as(UInt32*).value
          # Images in the shared system cache are already resident and shared
          # by every process on the machine.
          next if flags & MH_DYLIB_IN_CACHE != 0
          touch_segments(header, LibDyld._dyld_get_image_vmaddr_slide(image_index).to_i64)
          @image_count += 1
        end
      end

      # Walks the image's load commands and touches each file-backed
      # LC_SEGMENT_64 (every segment with a non-zero file size).
      private def touch_segments(header : UInt8*, slide : Int64) : Nil
        command_count = (header + 16).as(UInt32*).value
        command = header + MACH_HEADER_BYTES
        command_count.times do
          kind = command.as(UInt32*).value
          size = (command + 4).as(UInt32*).value
          if kind == LC_SEGMENT_64
            vm_address = (command + 24).as(UInt64*).value
            file_bytes = (command + 48).as(UInt64*).value
            touch(Pointer(UInt8).new((vm_address.to_i64 + slide).to_u64), file_bytes.to_i64) if file_bytes > 0
          end
          command += size
        end
      end
    {% else %}
      # Reads /proc/self/maps and touches every readable mapping backed by a
      # file. Parsed with `String#split`: stdlib `Regex` would link PCRE2
      # into the Mica runner.
      private def touch_every_loaded_image : Nil
        list_of_paths = Set(String).new
        File.each_line("/proc/self/maps") do |line|
          fields = line.split(' ', remove_empty: true)
          next unless fields.size >= 6 && fields[1].starts_with?('r') && fields[5].starts_with?('/')
          range = fields[0].split('-')
          start = range[0].to_u64(16)
          finish = range[1].to_u64(16)
          touch(Pointer(UInt8).new(start), (finish - start).to_i64)
          list_of_paths << fields[5]
        end
        @image_count = list_of_paths.size
      end
    {% end %}

    private def touch(start : UInt8*, byte_count : Int64) : Nil
      offset = 0_i64
      while offset < byte_count
        @checksum &+= start[offset].to_u64
        @page_count += 1
        offset += PAGE_BYTES
      end
    end
  end
end
