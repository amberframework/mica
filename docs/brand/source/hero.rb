#!/usr/bin/ruby
# Builds docs/brand/hero.svg: Mica's animated README banner.
# Usage: hero.rb <reading-room.jpg> <out.svg>
require 'base64'
require_relative 'mica_kit'
include MicaKit

PHOTO = ARGV[0] or abort 'usage: hero.rb <reading-room.jpg> <out.svg>'
OUT = ARGV[1]
photo = Base64.strict_encode64(File.binread(PHOTO))

INK = '#0E1320'
SILVER = '#EEF0F6'
MUTED = '#B9C0D2'
BRASS = '#E2B65B'
BLUE = '#8FA8EE'

left = 640
strip_top = 318
strip_height = 62
strip_width = 600
strip_mid = strip_top + strip_height / 2.0

pattern = '/\d{4}-\d{2}-\d{2}/'
haystack = 'GET /posts/2026-11-21/mica HTTP/1.1'
match_text = '2026-11-21'
mono_size = 17

chip_left = left + 14
chip_text_left = chip_left + 12
chip_width = text_width('FiraMono-Medium', 15, 0, pattern) + 24
hay_left = chip_left + chip_width + 20
hay_width = text_width('FiraMono-Regular', mono_size, 0, haystack)
match_at = haystack.index(match_text)
match_left = hay_left + text_width('FiraMono-Regular', mono_size, 0, haystack[0, match_at])
match_width = text_width('FiraMono-Regular', mono_size, 0, match_text)

# Timeline (percent of a 9 s loop): the loupe sweeps from 6% to 70%.
sweep_from = hay_left - 6
sweep_to = hay_left + hay_width + 6
sweep_start = 6.0
sweep_end = 70.0
at = lambda { |position_x| (sweep_start + (position_x - sweep_from) / (sweep_to - sweep_from) * (sweep_end - sweep_start)).round(1) }
match_on = at.call(match_left + match_width)

svg = <<~SVG
  <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1280 440" width="1280" height="440" role="img" aria-labelledby="title desc">
    <title id="title">Mica: reads untrusted bytes, never guesses. Pure-Crystal parsing for Amber.</title>
    <desc id="desc">Mica, the Amber crew's reader, at a lectern in a sunlit library with glowing byte tiles rising from her book. Beside her, a brass loupe sweeps once across the request line GET /posts/2026-11-21/mica HTTP/1.1 and lights up the date that the pattern \\d{4}-\\d{2}-\\d{2} matches.</desc>
    <style>
      .loupe { animation: sweep 9s linear infinite; }
      .scanned { animation: scanned 9s linear infinite; transform-box: fill-box; transform-origin: left center; transform: scaleX(0); }
      .hit { animation: hit 9s ease-out infinite; opacity: 0; }
      .result { animation: result 9s ease-out infinite; opacity: 0; }
      @keyframes sweep {
        0% { transform: translate(#{sweep_from}px, #{strip_mid}px); opacity: 0; }
        #{sweep_start}% { transform: translate(#{sweep_from}px, #{strip_mid}px); opacity: 1; }
        #{sweep_end}% { transform: translate(#{sweep_to}px, #{strip_mid}px); opacity: 1; }
        76%, 100% { transform: translate(#{sweep_to}px, #{strip_mid}px); opacity: 0; }
      }
      @keyframes scanned { 0%, #{sweep_start}% { transform: scaleX(0); opacity: 1; } #{sweep_end}% { transform: scaleX(1); opacity: 1; } 90% { transform: scaleX(1); opacity: 1; } 97%, 100% { transform: scaleX(1); opacity: 0; } }
      @keyframes hit { 0%, #{(match_on - 0.5).round(1)}% { opacity: 0; } #{(match_on + 2).round(1)}%, 90% { opacity: 1; } 97%, 100% { opacity: 0; } }
      @keyframes result { 0%, 72% { opacity: 0; } 78%, 90% { opacity: 1; } 97%, 100% { opacity: 0; } }
      @media (prefers-reduced-motion: reduce) {
        .loupe { animation: none; opacity: 0; }
        .scanned { animation: none; transform: scaleX(1); }
        .hit, .result { animation: none; opacity: 1; }
      }
    </style>
    <defs>
      <clipPath id="card"><rect width="1280" height="440" rx="22"/></clipPath>
      <linearGradient id="shade" x1="0" x2="1" y1="0" y2="0">
        <stop offset=".30" stop-color="#{INK}" stop-opacity="0"/>
        <stop offset=".46" stop-color="#{INK}" stop-opacity=".82"/>
        <stop offset=".58" stop-color="#{INK}" stop-opacity=".95"/>
        <stop offset="1" stop-color="#{INK}" stop-opacity=".97"/>
      </linearGradient>
      <linearGradient id="floor" x1="0" x2="0" y1="0" y2="1">
        <stop offset=".62" stop-color="#{INK}" stop-opacity="0"/>
        <stop offset="1" stop-color="#{INK}" stop-opacity=".55"/>
      </linearGradient>
      <linearGradient id="scan" x1="0" x2="1" y1="0" y2="0">
        <stop offset="0" stop-color="#{BLUE}" stop-opacity=".05"/>
        <stop offset="1" stop-color="#{BLUE}" stop-opacity=".22"/>
      </linearGradient>
    </defs>

    <g clip-path="url(#card)">
      <rect width="1280" height="440" fill="#{INK}"/>
      <image x="-14" y="-62" width="1002" height="560" preserveAspectRatio="xMidYMid slice" href="data:image/jpeg;base64,#{photo}" xlink:href="data:image/jpeg;base64,#{photo}"/>
      <rect width="1280" height="440" fill="url(#shade)"/>
      <rect width="1280" height="440" fill="url(#floor)"/>

      #{text_at('FiraMono-Medium', 14, 0.2, 'AMBER FRAMEWORK  ·  PURE CRYSTAL PARSING', left: left + 2, baseline: 66, fill: BRASS)}
      #{amber_crystal(left, 88, 52)}
      #{text_at('Fraunces-700', 70, -0.01, 'Mica', left: left + 64, baseline: 138, fill: SILVER)}
      #{text_at('Fraunces-600', 36, -0.005, 'Reads untrusted bytes.', left: left, baseline: 192, fill: SILVER)}
      #{text_at('Fraunces-600', 36, -0.005, 'Never guesses.', left: left, baseline: 236, fill: SILVER)}
      #{text_at('Manrope-500', 17.5, 0, 'Regex, gzip, zlib, DEFLATE, XML and UTF-8 with no C libraries.', left: left + 1, baseline: 274, fill: MUTED)}
      #{text_at('Manrope-500', 17.5, 0, 'Linear-time searches under work budgets and deadlines.', left: left + 1, baseline: 298, fill: MUTED)}

      <!-- the live search -->
      <rect x="#{left}" y="#{strip_top}" width="#{strip_width}" height="#{strip_height}" rx="14" fill="#141B2B" fill-opacity=".92" stroke="#{BRASS}" stroke-opacity=".35" stroke-width="1.2"/>
      <rect x="#{chip_left}" y="#{strip_mid - 16}" width="#{chip_width.round(1)}" height="32" rx="8" fill="#{BRASS}" fill-opacity=".14" stroke="#{BRASS}" stroke-opacity=".55"/>
      #{text_at('FiraMono-Medium', 15, 0, pattern, left: chip_text_left, baseline: strip_mid + 5, fill: BRASS)}
      <rect class="scanned" x="#{hay_left - 6}" y="#{strip_mid - 17}" width="#{(hay_width + 12).round(1)}" height="34" rx="6" fill="url(#scan)"/>
      <rect class="hit" x="#{(match_left - 4).round(1)}" y="#{strip_mid - 16}" width="#{(match_width + 8).round(1)}" height="32" rx="6" fill="#{BRASS}" fill-opacity=".22" stroke="#{BRASS}" stroke-width="1.4"/>
      #{text_at('FiraMono-Regular', mono_size, 0, haystack, left: hay_left, baseline: strip_mid + 6, fill: SILVER)}
      #{text_at('FiraMono-Regular', mono_size, 0, match_text, left: match_left, baseline: strip_mid + 6, fill: BRASS, extra: ' class="hit"')}
      #{loupe(25, BRASS, extra: ' class="loupe"')}

      #{text_at('FiraMono-Medium', 12.5, 0.16, 'ONE PASS  ·  LINEAR TIME  ·  BUDGETED', left: left + 2, baseline: 410, fill: '#8F98AE')}
      #{text_at('FiraMono-Medium', 12.5, 0.12, "MATCH AT BYTE #{match_at}", left: left + strip_width - 2, baseline: 410, fill: BRASS, anchor: :end, extra: ' class="result"')}
    </g>
    <rect x=".75" y=".75" width="1278.5" height="438.5" rx="21.5" fill="none" stroke="#{BRASS}" stroke-opacity=".35" stroke-width="1.5"/>
  </svg>
SVG

File.write(OUT, svg)
puts "#{OUT}: #{File.size(OUT)} bytes; match lights at #{match_on}%"
