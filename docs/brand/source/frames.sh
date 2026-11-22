#!/bin/zsh
# frames.sh <svg> <width> <height> <ms...>: renders the inline SVG with every animation seeked to each time
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
svg=$1; w=$2; h=$3; shift 3
for t in "$@"; do
  html=$(mktemp -t frame).html
  { print "<html><body style='margin:0;background:#888'><div style='width:${w}px'>"; sed 's/width="[0-9]*" height="[0-9]*" role/width="100%" role/' $svg; print "</div><script>document.getAnimations().forEach(a=>{a.pause();a.currentTime=$t});</script></body></html>"; } > $html
  "$CH" --headless=new --disable-gpu --hide-scrollbars --window-size=$w,$h --virtual-time-budget=500 --screenshot=${svg:r}-$t.png file://$html >/dev/null 2>&1
  echo ${svg:r}-$t.png
done
