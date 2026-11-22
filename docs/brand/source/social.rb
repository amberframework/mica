#!/usr/bin/ruby
# Builds docs/brand/source/social.svg, the 1280x640 link preview card.
# Usage: social.rb <portrait.jpg> <out.svg>
require 'base64'
require_relative 'mica_kit'
include MicaKit

PORTRAIT = ARGV[0] or abort 'usage: social.rb <portrait.jpg> <out.svg>'
OUT = ARGV[1]
portrait = Base64.strict_encode64(File.binread(PORTRAIT))
palette = LIGHT
left = 700

chips = ['Regex', 'gzip · zlib · DEFLATE', 'XML', 'UTF-8']
chip_parts = []
cursor = left
chips.each do |label|
  width = text_width('FiraMono-Medium', 17, 0.06, label) + 30
  chip_parts << %(<rect x="#{cursor}" y="420" width="#{width.round(1)}" height="40" rx="20" fill="#FFFFFF" stroke="#{palette[:blue]}" stroke-opacity=".55" stroke-width="1.5"/>)
  chip_parts << text_at('FiraMono-Medium', 17, 0.06, label, left: cursor + width / 2.0, baseline: 446, fill: palette[:blue], anchor: :middle)
  cursor += width + 12
end

svg = svg_open(1280, 640, 'Mica: pure-Crystal parsing for Amber',
               'Mica, the Amber crew\'s reader, with brass reading glasses and an open ink-blue book, beside the words Mica, reads untrusted bytes, never guesses.') + <<~SVG
  <defs>
    <linearGradient id="fade" x1="0" x2="1" y1="0" y2="0">
      <stop offset=".72" stop-color="#{palette[:ground]}" stop-opacity="0"/>
      <stop offset="1" stop-color="#{palette[:ground]}" stop-opacity="1"/>
    </linearGradient>
  </defs>
  <rect width="1280" height="640" fill="#{palette[:ground]}"/>
  <image x="0" y="0" width="640" height="640" href="data:image/jpeg;base64,#{portrait}"/>
  <rect x="0" width="640" height="640" fill="url(#fade)"/>
  #{text_at('FiraMono-Medium', 18, 0.2, 'AMBER FRAMEWORK', left: left + 2, baseline: 132, fill: palette[:brass])}
  #{amber_crystal(left, 160, 76)}
  #{text_at('Fraunces-700', 104, -0.01, 'Mica', left: left + 92, baseline: 232, fill: palette[:text])}
  #{text_at('Fraunces-600', 44, -0.005, 'Reads untrusted bytes.', left: left, baseline: 312, fill: palette[:text])}
  #{text_at('Fraunces-600', 44, -0.005, 'Never guesses.', left: left, baseline: 366, fill: palette[:text])}
  #{chip_parts.join("\n")}
  #{text_at('Manrope-500', 21, 0, 'Pure Crystal. Linear time. Work budgets and deadlines.', left: left + 2, baseline: 520, fill: palette[:muted])}
  #{text_at('FiraMono-Regular', 18, 0, 'github.com/amberframework/mica', left: left + 2, baseline: 576, fill: palette[:faint])}
</svg>
SVG

File.write(OUT, svg)
puts "#{OUT}: #{File.size(OUT)} bytes"
