#!/usr/bin/ruby
# Builds docs/brand/hero-light.svg and hero-dark.svg: Mica's animated README banner.
# Usage: hero.rb <art-dir> <out-dir>
require_relative 'mica_kit'
include MicaKit

ART = ARGV[0] or abort 'usage: hero.rb <art-dir> <out-dir>'
OUT = ARGV[1] or abort 'usage: hero.rb <art-dir> <out-dir>'
photo = data_uri(File.join(ART, 'reading-room.jpg'))
mark = File.join(ART, 'mica-mark.png')

left = 640
strip_top = 318
strip_height = 62
strip_width = 600
strip_mid = strip_top + strip_height / 2.0

pattern = '/\d{4}-\d{2}-\d{2}/'
haystack = 'GET /posts/2026-11-21/mica HTTP/1.1'
match_text = '2026-11-21'
code_face = 'Manrope-600'
code_size = 17

chip_left = left + 14
chip_text_left = chip_left + 12
chip_width = text_width('Manrope-700', 15, 0, pattern) + 24
hay_left = chip_left + chip_width + 20
hay_width = text_width(code_face, code_size, 0, haystack)
match_at = haystack.index(match_text)
match_left = hay_left + text_width(code_face, code_size, 0, haystack[0, match_at])
match_width = text_width(code_face, code_size, 0, match_text)

# Timeline (percent of a 9 s loop): the loupe sweeps from 6% to 70%.
sweep_from = hay_left - 6
sweep_to = hay_left + hay_width + 6
sweep_start = 6.0
sweep_end = 70.0
at = lambda { |position_x| (sweep_start + (position_x - sweep_from) / (sweep_to - sweep_from) * (sweep_end - sweep_start)).round(1) }
match_on = at.call(match_left + match_width)

THEMES = {
  'dark' => {
    ground: '#241A15', strip: '#171311', strip_alpha: '.94', text: '#FFF7ED', muted: '#CDBEB4', faint: '#AA9A90',
    accent: '#FFBD74', loupe: '#FFC777', scan: '#FFAD5C', edge: '#4B3B32', photo_dim: 0
  },
  'light' => {
    ground: '#FFF9EF', strip: '#FFFDF9', strip_alpha: '.96', text: '#211914', muted: '#453930', faint: '#76675D',
    accent: '#A93D08', loupe: '#D95B0A', scan: '#F47A16', edge: '#D9AD7E', photo_dim: 0
  }
}.freeze

THEMES.each do |name, theme|
  ground = theme[:ground]
  mark_height = 84
  mark_width = image_width(mark, mark_height)
  word_left = left + mark_width + 6
  svg = <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1280 440" width="1280" height="440" role="img" aria-labelledby="title desc">
      <title id="title">Mica: reads untrusted bytes, never guesses. Pure-Crystal parsing for the Amber framework.</title>
      <desc id="desc">Mica, the Amber crew's reader, at a lectern in a library with glowing byte tiles rising from her book. Beside her, Mica's character mark and name, and a loupe that sweeps once across the request line GET /posts/2026-11-21/mica HTTP/1.1 and lights up the date that the pattern \\d{4}-\\d{2}-\\d{2} matches.</desc>
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
          <stop offset=".30" stop-color="#{ground}" stop-opacity="0"/>
          <stop offset=".47" stop-color="#{ground}" stop-opacity=".86"/>
          <stop offset=".57" stop-color="#{ground}" stop-opacity="1"/>
          <stop offset="1" stop-color="#{ground}" stop-opacity="1"/>
        </linearGradient>
        <linearGradient id="scan" x1="0" x2="1" y1="0" y2="0">
          <stop offset="0" stop-color="#{theme[:scan]}" stop-opacity=".05"/>
          <stop offset="1" stop-color="#{theme[:scan]}" stop-opacity=".22"/>
        </linearGradient>
      </defs>

      <g clip-path="url(#card)">
        <rect width="1280" height="440" fill="#{ground}"/>
        <image x="-14" y="-62" width="1002" height="560" preserveAspectRatio="xMidYMid slice" href="#{photo}"/>
        <rect width="1280" height="440" fill="url(#shade)"/>

        #{text_at('Manrope-800', 13.5, 0.13, 'AMBER FRAMEWORK  ·  PURE CRYSTAL PARSING', left: left + 2, baseline: 56, fill: theme[:accent])}
        #{image_at(mark, left: left - 4, top: 64, height: mark_height)}
        #{text_at('Fraunces-700', 70, -0.01, 'Mica', left: word_left, baseline: 136, fill: theme[:text])}
        #{text_at('Fraunces-600', 36, -0.005, 'Reads untrusted bytes.', left: left, baseline: 192, fill: theme[:text])}
        #{text_at('Fraunces-600', 36, -0.005, 'Never guesses.', left: left, baseline: 236, fill: theme[:text])}
        #{text_at('Manrope-500', 17.5, 0, 'Regex, gzip, zlib, DEFLATE, XML and UTF-8 with no C libraries.', left: left + 1, baseline: 274, fill: theme[:muted])}
        #{text_at('Manrope-500', 17.5, 0, 'Linear-time searches under work budgets and deadlines.', left: left + 1, baseline: 298, fill: theme[:muted])}

        <!-- the live search -->
        <rect x="#{left}" y="#{strip_top}" width="#{strip_width}" height="#{strip_height}" rx="14" fill="#{theme[:strip]}" fill-opacity="#{theme[:strip_alpha]}" stroke="#{theme[:edge]}" stroke-width="1.2"/>
        <rect x="#{chip_left}" y="#{strip_mid - 16}" width="#{chip_width.round(1)}" height="32" rx="8" fill="#{theme[:accent]}" fill-opacity=".12" stroke="#{theme[:accent]}" stroke-opacity=".6"/>
        #{text_at('Manrope-700', 15, 0, pattern, left: chip_text_left, baseline: strip_mid + 5, fill: theme[:accent])}
        <rect class="scanned" x="#{hay_left - 6}" y="#{strip_mid - 17}" width="#{(hay_width + 12).round(1)}" height="34" rx="6" fill="url(#scan)"/>
        <rect class="hit" x="#{(match_left - 4).round(1)}" y="#{strip_mid - 16}" width="#{(match_width + 8).round(1)}" height="32" rx="6" fill="#{theme[:scan]}" fill-opacity=".2" stroke="#{theme[:accent]}" stroke-width="1.4"/>
        #{text_at(code_face, code_size, 0, haystack, left: hay_left, baseline: strip_mid + 6, fill: theme[:text])}
        #{text_at(code_face, code_size, 0, match_text, left: match_left, baseline: strip_mid + 6, fill: theme[:accent], extra: ' class="hit"')}
        #{loupe(25, theme[:loupe], extra: ' class="loupe"')}

        #{text_at('Manrope-800', 12.5, 0.13, 'ONE PASS  ·  LINEAR TIME  ·  BUDGETED', left: left + 2, baseline: 410, fill: theme[:faint])}
        #{text_at('Manrope-800', 12.5, 0.13, "MATCH AT BYTE #{match_at}", left: left + strip_width - 2, baseline: 410, fill: theme[:accent], anchor: :end, extra: ' class="result"')}
      </g>
      <rect x=".75" y=".75" width="1278.5" height="438.5" rx="21.5" fill="none" stroke="#{theme[:edge]}" stroke-width="1.5"/>
    </svg>
  SVG
  path = File.join(OUT, "hero-#{name}.svg")
  File.write(path, svg)
  puts "#{path}: #{File.size(path)} bytes; match lights at #{match_on}%"
end
