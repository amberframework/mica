# Shared drawing helpers for Mica's README art: brand text as vector outlines
# (Amber's Fraunces and Manrope from the amberframework.org site, Fira Mono for
# code and digits) and the two theme palettes taken from Mica's concept art.
#
# Fonts (not committed; put them in ../fonts beside this folder, check each sha256):
#   Fraunces-Variable.woff2  e169df7559440091b2d3499a0d40f9f34baa6114bf4ce709fe53f329beeecb4a
#   Manrope-Variable.woff2   52ecbc78831e7ae0431b4a5cbe4aaaae27255c9d370659b0b0bb9bd2f19ec42b
#     both from amberframework/amberframework.org at 9b43e92a459bb02506a23e05495bc48c36454ffd, app/assets/fonts/
#   FiraMono-Regular.ttf     2e00b0cf3106a3d792f35711b7722740b76c02ee7300ea8c60f940584b7a8ac9
#   FiraMono-Medium.ttf      a5bc1a2db2f65946049de615ecc08603d788eb0c02b520f4ed95f05a5cc58532
#     both match google/fonts ofl/firamono (git blobs 558bb75d and 034b6375)
#
# Art: reading-room.jpg and portrait.jpg are Mica's concept art (amberframework.org,
#   app/assets/characters/mica-reading-room-codex.webp and mica-id-original-studio.webp).
# Build: swiftc -O textpath.swift -o textpath; then
#   /usr/bin/ruby hero.rb reading-room.jpg ../hero.svg
#   /usr/bin/ruby assets.rb ..
#   /usr/bin/ruby social.rb portrait.jpg social.svg   (render to ../social-preview.png at 1280x640)
module MicaKit
  FONTS = File.join(__dir__, '..', 'fonts')
  TEXTPATH = File.join(__dir__, 'textpath')

  FACES = {
    'Fraunces-600' => ['Fraunces-Variable.woff2', 600],
    'Fraunces-700' => ['Fraunces-Variable.woff2', 700],
    'Manrope-400' => ['Manrope-Variable.woff2', 400],
    'Manrope-500' => ['Manrope-Variable.woff2', 500],
    'Manrope-700' => ['Manrope-Variable.woff2', 700],
    'Manrope-800' => ['Manrope-Variable.woff2', 800],
    'FiraMono-Regular' => ['FiraMono-Regular.ttf', nil],
    'FiraMono-Medium' => ['FiraMono-Medium.ttf', nil]
  }.freeze

  # Ink-blue, silver and brass from Mica's hair, capelet and reading glasses;
  # amber from the Amber framework mark.
  DARK = {
    ground: '#121722', panel: '#1A2130', panel_edge: '#2C3650', grid: '#263049',
    text: '#EDEFF5', muted: '#A2AABD', faint: '#6F7891',
    brass: '#E2B65B', blue: '#7E9BEA', blue_deep: '#3E5DB8', amber: '#F7913A',
    bar_track: '#222A3C'
  }.freeze
  LIGHT = {
    ground: '#FBF8F2', panel: '#FFFFFF', panel_edge: '#E3DCCD', grid: '#E9E3D6',
    text: '#1C2231', muted: '#566074', faint: '#8B92A1',
    brass: '#8A6A1F', blue: '#2F4FA8', blue_deep: '#22397C', amber: '#A93C08',
    bar_track: '#F1ECE2'
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
    %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" role="img" aria-labelledby="t d">) +
      %(<title id="t">#{escape(title)}</title><desc id="d">#{escape(description)}</desc>)
  end

  # The Amber framework crystal (public/assets/brand/amber-crystal.svg), 64 units square.
  def amber_crystal(left, top, size)
    scale = size / 64.0
    <<~SVG
      <g transform="translate(#{left} #{top}) scale(#{scale.round(4)})">
        <path fill="#F47716" d="M22 4h25l11 20-7 28-20 9L8 46 5 19z"/>
        <path fill="#ffcc78" d="M22 4 5 19l22 6z"/><path fill="#f68a20" d="m22 4 5 21 20-21z"/>
        <path fill="#dc4c0a" d="m27 25 24 27 7-28z"/><path fill="#f57613" d="M8 46 27 25l4 36z"/>
        <path fill="#ffa53a" d="M5 19 8 46l19-21z"/><path fill="#ffb44c" d="m27 25 31-1L47 4z"/>
        <path fill="#b93708" d="m31 61 20-9-24-27z"/>
      </g>
    SVG
  end

  # Mica's loupe: the round brass lens with the fine crosshair etched in it.
  def loupe(radius, brass, extra: '')
    <<~SVG
      <g#{extra}>
        <circle r="#{radius}" fill="#FFFFFF" fill-opacity=".10" stroke="#{brass}" stroke-width="3.2"/>
        <circle r="#{radius - 5}" fill="none" stroke="#{brass}" stroke-opacity=".35" stroke-width="1"/>
        <path d="M#{-radius * 0.55} 0H#{radius * 0.55}M0 #{-radius * 0.55}V#{radius * 0.55}" stroke="#{brass}" stroke-opacity=".75" stroke-width="1.1"/>
        <circle r="2.2" fill="none" stroke="#{brass}" stroke-width="1.1"/>
      </g>
    SVG
  end
end
