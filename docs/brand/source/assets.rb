#!/usr/bin/ruby
# Builds Mica's README art in light and dark: badges, the benchmark charts and
# the ReDoS panel. Every number below is quoted from the verified benchmark
# reports (regex: R3-verify-12 at commit f0bb0f6, the code tagged v0.2.0;
# Inflate: Z1 run full-20261121T133443Z-6232bc9, merged in #18).
# Usage: assets.rb <out-dir>
require_relative 'mica_kit'
include MicaKit

OUT = ARGV[0] or abort 'usage: assets.rb <out-dir>'

def fmt_factor(value)
  value >= 10 ? value.round.to_s : format('%.1f', value)
end

# ---------------------------------------------------------------- badges
def badges(palette)
  plates = [
    ['PURE CRYSTAL', palette[:blue]],
    ['NO PCRE2 · NO LIBZ · NO LIBXML2', palette[:brass]],
    ['LINEAR-TIME SEARCH', palette[:blue]],
    ['WORK BUDGETS + DEADLINES', palette[:brass]],
    ['v0.2.0', palette[:amber]],
    ['MIT', palette[:muted]]
  ]
  gap = 10
  size = 12.5
  pad = 16
  widths = plates.map { |label, _| text_width('FiraMono-Medium', size, 0.1, label) + pad * 2 }
  total = widths.inject(:+) + gap * (plates.size - 1)
  height = 34
  parts = []
  cursor = 0.0
  plates.each_with_index do |(label, color), index|
    width = widths[index]
    parts << %(<rect x="#{(cursor + 0.75).round(2)}" y=".75" width="#{(width - 1.5).round(2)}" height="#{height - 1.5}" rx="#{(height - 1.5) / 2}" fill="#{palette[:panel]}" stroke="#{color}" stroke-opacity=".7" stroke-width="1.2"/>)
    parts << text_at('FiraMono-Medium', size, 0.1, label, left: cursor + width / 2.0, baseline: 21.5, fill: color, anchor: :middle)
    cursor += width + gap
  end
  svg_open(total.ceil, height, 'Mica at a glance',
           'Pure Crystal. No PCRE2, no libz, no libxml2. Linear-time search. Work budgets and deadlines. Version 0.2.0. MIT license.') +
    parts.join("\n") + '</svg>'
end

# ---------------------------------------------------------------- chart frame
def chart_frame(palette, width, height, title, subtitle_lines)
  body = []
  body << %(<rect x=".75" y=".75" width="#{width - 1.5}" height="#{height - 1.5}" rx="18" fill="#{palette[:panel]}" stroke="#{palette[:panel_edge]}" stroke-width="1.5"/>)
  body << text_at('Fraunces-600', 30, -0.005, title, left: 48, baseline: 64, fill: palette[:text])
  subtitle_lines.each_with_index do |line, index|
    body << text_at('Manrope-400', 16.5, 0, line, left: 49, baseline: 96 + index * 24, fill: palette[:muted])
  end
  body
end

def legend(palette, entries, left, baseline)
  cursor = left
  entries.map do |label, color|
    swatch = %(<rect x="#{cursor}" y="#{baseline - 12}" width="14" height="14" rx="3" fill="#{color}"/>)
    text = text_at('Manrope-500', 15, 0, label, left: cursor + 22, baseline: baseline, fill: palette[:text])
    cursor += 22 + text_width('Manrope-500', 15, 0, label) + 34
    swatch + text
  end.join("\n")
end

# ---------------------------------------------------------------- regex chart
# [metric, note, runtime [mica, pcre2], static [mica, pcre2]] in microseconds.
REGEX_ROWS = [
  ['Warm search', 'pattern compiled, caches warm', [29.85, 72.39], [20.66, 40.64]],
  ['Compile', 'pattern text to a ready program', [2.58, 4.38], [0.1593, 3.86]],
  ['Cold first search', 'compile plus one search', [27.70, 82.39], [5.44, 61.31]],
  ['Process-cold', 'first regex work of a new process', [134.19, 305.24], [43.68, 269.96]]
].freeze

def time_label(microseconds)
  return "#{format('%.1f', microseconds * 1000)} ns" if microseconds < 1
  "#{format('%.2f', microseconds)} µs"
end

def regex_chart(palette)
  width = 1280
  row_height = 104
  top = 196
  height = top + REGEX_ROWS.size * row_height + 70
  axis_left = 380
  axis_width = 800
  max_factor = 30.0
  scale = lambda { |factor| axis_left + Math.log(factor) / Math.log(max_factor) * axis_width }
  body = chart_frame(palette, width, height, 'Mica::Regex against PCRE2 with JIT',
                     ['How many times as fast as Crystal\'s stdlib Regex (PCRE2 10.49, JIT on). Geometric means over 479 cases',
                      '(412 for static patterns) from rebar, Amber\'s own patterns and ReDoS families. Longer is better.'])
  body << legend(palette, [['Mica::Regex, compiled at run time', palette[:blue]], ['Mica::Regex.static, compiled while the app builds', palette[:brass]]], 49, 170)
  [1, 2, 5, 10, 20].each do |tick|
    tick_x = scale.call(tick.to_f).round(1)
    body << %(<line x1="#{tick_x}" x2="#{tick_x}" y1="#{top - 6}" y2="#{top + REGEX_ROWS.size * row_height - 10}" stroke="#{palette[:grid]}" stroke-width="#{tick == 1 ? 2 : 1}"/>)
    body << text_at('FiraMono-Regular', 13, 0, "#{tick}×", left: tick_x, baseline: top + REGEX_ROWS.size * row_height + 12, fill: palette[:faint], anchor: :middle)
  end
  body << text_at('Manrope-400', 13.5, 0, '1× = PCRE2-JIT (log scale)', left: axis_left, baseline: top + REGEX_ROWS.size * row_height + 36, fill: palette[:faint])
  REGEX_ROWS.each_with_index do |(metric, note, runtime, static), index|
    row_top = top + index * row_height
    body << text_at('Manrope-700', 18, 0, metric, left: 49, baseline: row_top + 30, fill: palette[:text])
    body << text_at('Manrope-400', 14, 0, note, left: 49, baseline: row_top + 52, fill: palette[:muted])
    [[runtime, palette[:blue], 6], [static, palette[:brass], 46]].each do |(times, color, offset)|
      factor = times[1] / times[0]
      bar_top = row_top + offset
      bar_end = scale.call(factor)
      label = "#{fmt_factor(factor)}× as fast"
      detail = "#{time_label(times[0])} vs #{time_label(times[1])}"
      body << %(<rect x="#{axis_left}" y="#{bar_top}" width="#{(bar_end - axis_left).round(1)}" height="32" rx="6" fill="#{color}"/>)
      label_width = text_width('Manrope-700', 16, 0, label)
      if bar_end - axis_left > label_width + text_width('FiraMono-Regular', 12.5, 0, detail) + 60
        body << text_at('Manrope-700', 16, 0, label, left: bar_end - 14, baseline: bar_top + 22, fill: palette[:panel], anchor: :end)
        body << text_at('FiraMono-Regular', 12.5, 0, detail, left: axis_left + 14, baseline: bar_top + 21, fill: palette[:panel])
      else
        body << text_at('Manrope-700', 16, 0, label, left: bar_end + 12, baseline: bar_top + 22, fill: palette[:text])
        body << text_at('FiraMono-Regular', 12.5, 0, detail, left: bar_end + 24 + label_width, baseline: bar_top + 21, fill: palette[:muted])
      end
    end
  end
  svg_open(width, height, 'Mica::Regex against PCRE2 with JIT',
           'Geometric means over 479 cases, times as fast as PCRE2 with JIT. Run-time patterns: warm search 2.4 times as fast (29.85 µs vs 72.39 µs), compile 1.7 times (2.58 µs vs 4.38 µs), cold first search 3.0 times (27.70 µs vs 82.39 µs), process-cold 2.3 times (134.19 µs vs 305.24 µs). Static patterns over 412 cases: warm search 2.0 times (20.66 µs vs 40.64 µs), compile 24 times (159.3 ns vs 3.86 µs), cold first search 11 times (5.44 µs vs 61.31 µs), process-cold 6.2 times (43.68 µs vs 269.96 µs).') +
    body.join("\n") + '</svg>'
end

# ---------------------------------------------------------------- Amber patterns chart
AMBER_ROWS = [
  ['Routes', 'slug, UUID, numeric and host:port constraints', 16, 227.77, 561.00],
  ['Templates', 'mustache placeholders', 4, 192.20, 502.32],
  ['Markdown', 'inline and block rules', 32, 204.55, 567.11],
  ['Logs', 'backtrace frames, SQL normalizers', 28, 205.72, 535.44],
  ['CSV', 'CSV and Accept separators', 8, 194.03, 527.85],
  ['Contacts', "Grant's email and URL validators", 8, 283.05, 594.83],
  ['Identifiers', 'camelCase boundaries, non-alphanumeric runs', 8, 189.31, 551.21]
].freeze

def amber_chart(palette)
  width = 1280
  row_height = 54
  top = 176
  height = top + AMBER_ROWS.size * row_height + 86
  axis_left = 450
  axis_width = 720
  max_factor = 3.5
  scale = lambda { |factor| axis_left + factor / max_factor * axis_width }
  body = chart_frame(palette, width, height, 'The patterns Amber apps run, on first use',
                     ['26 patterns from Amber V2, Grant and amber_cli source, over 104 cases. Process-cold: compile plus the first',
                      'search, as the first regex work of a new process. Times as fast as PCRE2 with JIT. Longer is better.'])
  [0, 1, 2, 3].each do |tick|
    tick_x = scale.call(tick.to_f).round(1)
    body << %(<line x1="#{tick_x}" x2="#{tick_x}" y1="#{top - 8}" y2="#{top + AMBER_ROWS.size * row_height}" stroke="#{tick == 1 ? palette[:faint] : palette[:grid]}" stroke-width="#{tick == 1 ? 1.5 : 1}"#{tick == 1 ? ' stroke-dasharray="4 4"' : ''}/>)
    body << text_at('FiraMono-Regular', 13, 0, "#{tick}×", left: tick_x, baseline: top + AMBER_ROWS.size * row_height + 22, fill: palette[:faint], anchor: :middle)
  end
  body << text_at('Manrope-400', 13.5, 0, '1× = PCRE2-JIT', left: scale.call(1.0) + 8, baseline: top - 14, fill: palette[:faint])
  AMBER_ROWS.each_with_index do |(group, note, cases, mica, pcre), index|
    row_top = top + index * row_height
    factor = pcre / mica
    body << text_at('Manrope-700', 17, 0, group, left: 49, baseline: row_top + 22, fill: palette[:text])
    body << text_at('Manrope-400', 13.5, 0, "#{note} · #{cases} cases", left: 49, baseline: row_top + 41, fill: palette[:muted])
    bar_end = scale.call(factor)
    body << %(<rect x="#{axis_left}" y="#{row_top + 6}" width="#{(bar_end - axis_left).round(1)}" height="30" rx="6" fill="#{palette[:blue]}"/>)
    body << text_at('FiraMono-Regular', 12.5, 0, "#{format('%.2f', mica)} µs vs #{format('%.2f', pcre)} µs", left: axis_left + 14, baseline: row_top + 26, fill: palette[:panel])
    body << text_at('Manrope-700', 16, 0, "#{format('%.1f', factor)}× as fast", left: bar_end + 12, baseline: row_top + 27, fill: palette[:text])
  end
  total = 552.64 / 210.91
  body << text_at('Manrope-700', 17, 0, "All 104 Amber cases: #{format('%.1f', total)}× as fast (210.91 µs vs 552.64 µs).", left: 49, baseline: height - 30, fill: palette[:text])
  svg_open(width, height, 'The patterns Amber apps run, on first use',
           'Process-cold times, Mica::Regex against PCRE2 with JIT. ' +
           AMBER_ROWS.map { |group, _, cases, mica, pcre| "#{group} (#{cases} cases): #{format('%.1f', pcre / mica)} times as fast, #{mica} µs vs #{pcre} µs" }.join('; ') +
           ". All 104 cases: #{format('%.1f', total)} times as fast.") +
    body.join("\n") + '</svg>'
end

# ---------------------------------------------------------------- ReDoS panel
def redos_panel(palette)
  width = 1280
  height = 250
  body = chart_frame(palette, width, height, 'Hostile patterns finish',
                     ['112 ReDoS cases from 13 families: (a+)+$, the OWASP email pattern, Cloudflare 2019, Stack Overflow 2016 and more.'])
  stats = [
    ['8.8×', 'as fast, warm search', '330.1 ns vs 2.91 µs per search', palette[:blue]],
    ['0', 'limits hit by Mica::Regex', 'PCRE2-JIT stopped on a limit 28 times and timed out once', palette[:brass]],
    ['13 of 13', 'families inside 1,000 ms', 'growth slopes 0.81 to 1.0: linear in the input', palette[:amber]]
  ]
  column = (width - 96) / 3.0
  stats.each_with_index do |(big, label, detail, color), index|
    left = 49 + index * column
    body << %(<rect x="#{left.round(1)}" y="128" width="4" height="84" rx="2" fill="#{color}"/>)
    body << text_at('Fraunces-700', 44, -0.01, big, left: left + 20, baseline: 172, fill: color)
    body << text_at('Manrope-700', 16, 0, label, left: left + 20, baseline: 196, fill: palette[:text])
    body << text_at('Manrope-400', 13.5, 0, detail, left: left + 20, baseline: 216, fill: palette[:muted])
  end
  svg_open(width, height, 'Hostile patterns finish',
           'Across 112 ReDoS cases, Mica::Regex is 8.8 times as fast on warm search (330.1 ns vs 2.91 µs) and hits no limit; PCRE2 with JIT stopped on its match or JIT stack limit 28 times and timed out once. All 13 ReDoS families finish within 1,000 ms, with growth slopes from 0.81 to 1.0.') +
    body.join("\n") + '</svg>'
end

# ---------------------------------------------------------------- Inflate chart
INFLATE_ROWS = [
  ['One-shot', 'zlib allocating its output per decode, as Mica does', 1.45, 0.691, 0.678, 0.705],
  ['Streaming', 'readers with 64 KiB buffers', 1.83, 0.548, 0.531, 0.566],
  ['One-shot, zlib at its best', 'zlib reusing one output buffer', 1.86, 0.538, 0.520, 0.556]
].freeze

def inflate_chart(palette)
  width = 1280
  row_height = 70
  top = 176
  height = top + INFLATE_ROWS.size * row_height + 92
  axis_left = 440
  axis_width = 680
  max_factor = 2.5
  scale = lambda { |factor| axis_left + factor / max_factor * axis_width }
  body = chart_frame(palette, width, height, 'Inflate against system zlib',
                     ['Mica::Gzip, Mica::Zlib and Mica::Deflate decode time against zlib, geometric means over 93 cases (Canterbury,',
                      'Silesia and real HTTP bodies, each as gzip, zlib and raw DEFLATE). Shorter is better: zlib is still faster.'])
  [0, 1, 2].each do |tick|
    tick_x = scale.call(tick.to_f).round(1)
    body << %(<line x1="#{tick_x}" x2="#{tick_x}" y1="#{top - 8}" y2="#{top + INFLATE_ROWS.size * row_height}" stroke="#{tick.zero? ? palette[:grid] : palette[:faint]}" stroke-width="1.5"#{tick.zero? ? '' : ' stroke-dasharray="4 4"'}/>)
  end
  body << text_at('Manrope-400', 13.5, 0, 'zlib', left: scale.call(1.0), baseline: top - 14, fill: palette[:faint], anchor: :middle)
  body << text_at('Manrope-400', 13.5, 0, 'Z1 bar: 2× slower', left: scale.call(2.0), baseline: top - 14, fill: palette[:faint], anchor: :middle)
  INFLATE_ROWS.each_with_index do |(mode, note, factor, speed, low, high), index|
    row_top = top + index * row_height
    body << text_at('Manrope-700', 17, 0, mode, left: 49, baseline: row_top + 26, fill: palette[:text])
    body << text_at('Manrope-400', 13.5, 0, note, left: 49, baseline: row_top + 46, fill: palette[:muted])
    zlib_end = scale.call(1.0)
    bar_end = scale.call(factor)
    body << %(<rect x="#{axis_left}" y="#{row_top + 10}" width="#{(zlib_end - axis_left).round(1)}" height="34" rx="6" fill="#{palette[:bar_track]}" stroke="#{palette[:panel_edge]}"/>)
    body << %(<rect x="#{zlib_end.round(1)}" y="#{row_top + 10}" width="#{(bar_end - zlib_end).round(1)}" height="34" rx="0" fill="#{palette[:brass]}" fill-opacity=".85"/>)
    body << %(<rect x="#{axis_left}" y="#{row_top + 10}" width="#{(bar_end - axis_left).round(1)}" height="34" rx="6" fill="none" stroke="#{palette[:brass]}" stroke-width="1.5"/>)
    body << text_at('FiraMono-Regular', 12.5, 0, 'zlib time', left: axis_left + 14, baseline: row_top + 32, fill: palette[:muted])
    body << text_at('Manrope-700', 16, 0, "#{format('%.2f', factor)}× slower", left: [bar_end, scale.call(2.0)].max + 14, baseline: row_top + 27, fill: palette[:text])
    body << text_at('FiraMono-Regular', 12, 0, "95%: #{format('%.2f', 1 / high)} to #{format('%.2f', 1 / low)}", left: [bar_end, scale.call(2.0)].max + 14, baseline: row_top + 45, fill: palette[:muted])
  end
  body << text_at('Manrope-400', 15, 0, 'The Z1 milestone allowed up to 2× slower than zlib one-shot, and every mode is inside it.', left: 49, baseline: height - 32, fill: palette[:muted])
  svg_open(width, height, 'Inflate against system zlib',
           'Decode time relative to system zlib, geometric means over 93 cases. One-shot: 1.45 times slower. Streaming with 64 KiB buffers: 1.83 times slower. Against zlib reusing one output buffer: 1.86 times slower. The Z1 bar was no more than 2 times slower.') +
    body.join("\n") + '</svg>'
end

{ 'light' => LIGHT, 'dark' => DARK }.each do |name, palette|
  File.write(File.join(OUT, "badges-#{name}.svg"), badges(palette))
  File.write(File.join(OUT, "regex-speed-#{name}.svg"), regex_chart(palette))
  File.write(File.join(OUT, "amber-patterns-#{name}.svg"), amber_chart(palette))
  File.write(File.join(OUT, "redos-#{name}.svg"), redos_panel(palette))
  File.write(File.join(OUT, "inflate-#{name}.svg"), inflate_chart(palette))
end
puts Dir[File.join(OUT, '*.svg')].sort.map { |path| "#{File.basename(path)} #{File.size(path)}" }
