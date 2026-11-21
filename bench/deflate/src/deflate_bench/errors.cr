module DeflateBench
  class Error < Exception
  end

  # The command line of a runner was not one of its commands.
  class UsageError < Error
  end

  # A decode produced bytes other than the original file's.
  class OutputMismatchError < Error
  end

  # System zlib returned a status the harness does not expect.
  class ZlibError < Error
  end
end
