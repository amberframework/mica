module Mica::HTTP2
  # The SETTINGS parameters this codec knows (RFC 9113 section 6.5.2,
  # RFC 8441 and RFC 9218). A SETTINGS frame drops parameters it does not
  # know, as RFC 9113 requires.
  enum SettingId : UInt16
    HeaderTableSize       = 0x1
    EnablePush            = 0x2
    MaxConcurrentStreams  = 0x3
    InitialWindowSize     = 0x4
    MaxFrameSize          = 0x5
    MaxHeaderListSize     = 0x6
    EnableConnectProtocol = 0x8
    NoRfc7540Priorities   = 0x9
  end

  # One SETTINGS parameter.
  record Setting, id : SettingId, value : UInt32
end
