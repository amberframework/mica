# Shared drawing helpers for Mica's README art, in the Amber framework's brand
# (amberframework.org, app/assets/css/amber-brand.css): Amber's two typefaces,
# Fraunces for display and Manrope for everything else, drawn as vector outlines,
# and the site's own light and dark palettes.
#
# Fonts (not committed; put them in ../fonts beside this folder, check each sha256):
#   Fraunces-Variable.woff2  e169df7559440091b2d3499a0d40f9f34baa6114bf4ce709fe53f329beeecb4a
#   Manrope-Variable.woff2   52ecbc78831e7ae0431b4a5cbe4aaaae27255c9d370659b0b0bb9bd2f19ec42b
#     both from amberframework/amberframework.org, app/assets/fonts/ (SIL OFL)
#
# Art (not committed; the built SVGs embed it):
#   reading-room.jpg  Mica's reading-room scene, 1400 px wide, from the Amberverse canon
#                     (amberverse-roadmap-3d, branch character/mica, research/mica_concepts/codex/selected/
#                     mica-reading-room-scene.png, sha256 38067b28ef9e2f78f9dfdd8501e5456354d71872ddc6b40248ad70e64293025e)
#   portrait.jpg      Mica's identity original, 640 px (same folder, mica-id-original-studio.png,
#                     sha256 56ee023950921310d41784c80eb1a4866b45c6ef161762e67c4d3538c00a11cb)
#   mica-mark.png     Mica's chibi character mark, trimmed, 240 px tall (mica-chibi-hero-mark.png,
#                     sha256 0fbd41fa1d27b992384ca64bd3e60400082da92a99fd3be866c0b596b03ae3e6)
#   amber-mark.png    Amber's primary character mark, trimmed, 200 px tall (amberframework.org
#                     app/assets/characters/amber-chibi-hero-mark-v2.webp,
#                     sha256 16048f5601f3c5688e54824f1cf9007a9417145f78f1af6135e43008d4611dd8)
# Build: swiftc -O textpath.swift -o textpath; then
#   /usr/bin/ruby hero.rb <art-dir> ..
#   /usr/bin/ruby assets.rb <art-dir> ..
#   /usr/bin/ruby social.rb <art-dir> social.svg   (render to ../social-preview.png at 1280x640)
require 'base64'

module MicaKit
  FONTS = File.join(__dir__, '..', 'fonts')
  TEXTPATH = File.join(__dir__, 'textpath')

  FACES = {
    'Fraunces-600' => ['Fraunces-Variable.woff2', 600],
    'Fraunces-700' => ['Fraunces-Variable.woff2', 700],
    'Fraunces-730' => ['Fraunces-Variable.woff2', 730],
    'Manrope-400' => ['Manrope-Variable.woff2', 400],
    'Manrope-500' => ['Manrope-Variable.woff2', 500],
    'Manrope-600' => ['Manrope-Variable.woff2', 600],
    'Manrope-700' => ['Manrope-Variable.woff2', 700],
    'Manrope-800' => ['Manrope-Variable.woff2', 800]
  }.freeze

  # Light: the site's canvas, paper, ink and amber scale.
  # Dark: the site's footer, dark sections and terminal window.
  LIGHT = {
    ground: '#FFF9EF', panel: '#FFFDF9', panel_edge: '#D9AD7E', grid: '#E9D3B9',
    text: '#211914', muted: '#76675D', faint: '#76675D',
    accent: '#A93D08',                   # amber-700: small text and labels
    series: '#F47A16', on_series: '#211914',   # amber-500 bars, ink labels
    series2: '#A93D08', on_series2: '#FFFDF9', # amber-700 bars, paper labels
    third: '#453930',                    # ink-soft
    bar_track: '#FFF0D7', loupe: '#D95B0A'
  }.freeze
  DARK = {
    ground: '#241A15', panel: '#241A15', panel_edge: '#4B3B32', grid: '#3D302A',
    text: '#FFF7ED', muted: '#CDBEB4', faint: '#AA9A90',
    accent: '#FFBD74',
    series: '#F47A16', on_series: '#211914',
    series2: '#FFC777', on_series2: '#211914', # amber-300 bars, ink labels
    third: '#FFF7ED',
    bar_track: '#30221C', loupe: '#FFC777'
  }.freeze

  module_function

  def text_shape(face, size, tracking, words)
    file, weight = FACES.fetch(face)
    env = weight ? { 'WGHT' => weight.to_s } : {}
    output = IO.popen(env, [TEXTPATH, File.join(FONTS, file), size.to_s, tracking.to_s, words], &:read)
    width, path_data = output.strip.split("\t", 2)
    [width.to_f, path_data.to_s]
  end

  def text_width(face, size, tracking, words)
    text_shape(face, size, tracking, words).first
  end

  def text_at(face, size, tracking, words, left:, baseline:, fill:, anchor: :start, extra: '')
    width, path_data = text_shape(face, size, tracking, words)
    left -= width / 2 if anchor == :middle
    left -= width if anchor == :end
    %(<path transform="translate(#{left.round(2)} #{baseline})" fill="#{fill}" d="#{path_data}"#{extra}/>)
  end

  def escape(text)
    text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end

  def svg_open(width, height, title, description)
    %(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" role="img" aria-labelledby="t d">) +
      %(<title id="t">#{escape(title)}</title><desc id="d">#{escape(description)}</desc>)
  end

  def data_uri(path)
    type = path.end_with?('.png') ? 'image/png' : 'image/jpeg'
    "data:#{type};base64,#{Base64.strict_encode64(File.binread(path))}"
  end

  # A raster from the art folder, placed by its top-left corner and height.
  def image_at(path, left:, top:, height:, extra: '')
    pixel_width, pixel_height = File.binread(path, 24)[16, 8].unpack('NN') if path.end_with?('.png')
    width = pixel_width ? (height * pixel_width.to_f / pixel_height).round(1) : height
    uri = data_uri(path)
    %(<image x="#{left}" y="#{top}" width="#{width}" height="#{height}" href="#{uri}"#{extra}/>)
  end

  def image_width(path, height)
    pixel_width, pixel_height = File.binread(path, 24)[16, 8].unpack('NN')
    (height * pixel_width.to_f / pixel_height).round(1)
  end

  # Mica's loupe: a round lens with the fine crosshair etched in it.
  def loupe(radius, color, extra: '')
    <<~SVG
      <g#{extra}>
        <circle r="#{radius}" fill="#FFFFFF" fill-opacity=".10" stroke="#{color}" stroke-width="3.2"/>
        <circle r="#{radius - 5}" fill="none" stroke="#{color}" stroke-opacity=".35" stroke-width="1"/>
        <path d="M#{-radius * 0.55} 0H#{radius * 0.55}M0 #{-radius * 0.55}V#{radius * 0.55}" stroke="#{color}" stroke-opacity=".75" stroke-width="1.1"/>
        <circle r="2.2" fill="none" stroke="#{color}" stroke-width="1.1"/>
      </g>
    SVG
  end
end
