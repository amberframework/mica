// textpath <font> <size> <tracking-em> <text>  -> prints: width<TAB>svg path d (y down, baseline at 0). WGHT and OPSZ in the environment pick a variable-font instance.
import CoreText
import Foundation
let a = CommandLine.arguments
let url = URL(fileURLWithPath: a[1]) as CFURL
let size = CGFloat(Double(a[2])!)
let tracking = CGFloat(Double(a[3])!) * size
let text = a[4]
let descs = CTFontManagerCreateFontDescriptorsFromURL(url) as! [CTFontDescriptor]
var desc = descs[0]
let env = ProcessInfo.processInfo.environment
if let w = env["WGHT"], let v = Double(w) { desc = CTFontDescriptorCreateCopyWithVariation(desc, NSNumber(value: 0x77676874) as CFNumber, CGFloat(v)) }
if let o = env["OPSZ"], let v = Double(o) { desc = CTFontDescriptorCreateCopyWithVariation(desc, NSNumber(value: 0x6F70737A) as CFNumber, CGFloat(v)) }
let font = CTFontCreateWithFontDescriptor(desc, size, nil)
let attr = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTKernAttributeName as NSAttributedString.Key: tracking])
let line = CTLineCreateWithAttributedString(attr)
var d = ""
func f(_ v: CGFloat) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".0", with: "") }
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
  let n = CTRunGetGlyphCount(run)
  var glyphs = [CGGlyph](repeating: 0, count: n); var pos = [CGPoint](repeating: .zero, count: n)
  CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs); CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
  let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
  for i in 0..<n {
    guard let p = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
    let ox = pos[i].x
    p.applyWithBlock { el in
      let e = el.pointee; let pts = e.points
      func pt(_ k: Int) -> String { "\(f(pts[k].x + ox)) \(f(-pts[k].y))" }
      switch e.type {
      case .moveToPoint: d += "M\(pt(0))"
      case .addLineToPoint: d += "L\(pt(0))"
      case .addQuadCurveToPoint: d += "Q\(pt(0)) \(pt(1))"
      case .addCurveToPoint: d += "C\(pt(0)) \(pt(1)) \(pt(2))"
      case .closeSubpath: d += "Z"
      @unknown default: break
      }
    }
  }
}
let w = CTLineGetTypographicBounds(line, nil, nil, nil) - Double(tracking)
print("\(f(CGFloat(w)))\t\(d)")
