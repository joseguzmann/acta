import AppKit
import CoreGraphics
import Foundation

// Draws Acta's icon and writes an .iconset, which `iconutil` turns into .icns.
//
// Generated rather than committed as a binary: it stays diffable, it can be
// rebuilt at any size, and the design lives in the repo instead of in whichever
// machine happened to export it.
//
// The mark is the app's own layout — two columns of a conversation split down
// the middle, the call on the left and you on the right.

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = URL(fileURLWithPath: "Acta.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func draw(size: Int) -> CGImage? {
  let s = CGFloat(size)
  guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }

  // macOS icons sit inside the canvas rather than filling it.
  let inset = s * 0.055
  let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
  let radius = rect.width * 0.2237   // the squircle proportion Apple uses
  let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

  ctx.saveGState()
  ctx.addPath(shape)
  ctx.clip()
  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(red: 0.24, green: 0.24, blue: 0.26, alpha: 1),
             CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)] as CFArray,
    locations: [0, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY),
                         end: CGPoint(x: 0, y: rect.minY), options: [])

  // The divider: the one line that says this app separates two sides.
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
  let dividerWidth = max(1, s * 0.012)
  ctx.fill(CGRect(x: s / 2 - dividerWidth / 2, y: rect.minY + rect.height * 0.18,
                  width: dividerWidth, height: rect.height * 0.64))

  // Waveform bars: muted on the call's side, blue on yours.
  let heights: [CGFloat] = [0.26, 0.46, 0.34, 0.62, 0.42, 0.72, 0.38, 0.54]
  let barWidth = rect.width * 0.052
  let gap = rect.width * 0.038
  let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
  var x = rect.midX - total / 2

  for (i, h) in heights.enumerated() {
    let isYours = i >= heights.count / 2
    ctx.setFillColor(isYours
      ? CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
      : CGColor(red: 0.62, green: 0.63, blue: 0.67, alpha: 1))
    let barHeight = rect.height * h
    let bar = CGRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2,
                       cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
    x += barWidth + gap
  }
  ctx.restoreGState()
  return ctx.makeImage()
}

func write(_ image: CGImage, to name: String) {
  let url = outDir.appendingPathComponent(name)
  guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
  else { return }
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
}

for size in sizes {
  guard let image = draw(size: size) else { continue }
  if size <= 512 { write(image, to: "icon_\(size)x\(size).png") }
  if size >= 32 { write(image, to: "icon_\(size / 2)x\(size / 2)@2x.png") }
}
print("wrote \(outDir.path)")
