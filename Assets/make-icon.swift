// Draws the DropS3 app icon (1024×1024 PNG). Usage: swift Assets/make-icon.swift out.png
import AppKit

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Rounded-square body on the standard macOS icon grid (824 pt inside 1024, soft drop shadow).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.30))
ctx.addPath(shape)
ctx.setFillColor(color(0.10, 0.40, 0.92))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(0.25, 0.78, 0.98), color(0.09, 0.33, 0.88)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// subtle top highlight
let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
ctx.restoreGState()

let white = color(1, 1, 1)
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0.02, 0.15, 0.45, 0.35))

// Bucket
let bucket = CGMutablePath()
bucket.move(to: CGPoint(x: 296, y: 500))
bucket.addLine(to: CGPoint(x: 728, y: 500))
bucket.addArc(tangent1End: CGPoint(x: 678, y: 236), tangent2End: CGPoint(x: 346, y: 236), radius: 46)
bucket.addArc(tangent1End: CGPoint(x: 346, y: 236), tangent2End: CGPoint(x: 296, y: 500), radius: 46)
bucket.closeSubpath()
ctx.addPath(bucket)
ctx.setFillColor(white)
ctx.fillPath()

// Rim
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: 284, y: 462, width: 456, height: 78))
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(color(0.09, 0.36, 0.86, 0.55))
ctx.fillEllipse(in: CGRect(x: 312, y: 478, width: 400, height: 46))

// Band on the bucket
ctx.saveGState()
ctx.addPath(bucket)
ctx.clip()
ctx.setFillColor(color(0.09, 0.36, 0.86, 0.16))
ctx.fill(CGRect(x: 280, y: 330, width: 470, height: 44))
ctx.restoreGState()

// Drop
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0.02, 0.15, 0.45, 0.35))
let center = CGPoint(x: 512, y: 668), radius: CGFloat = 84
let drop = CGMutablePath()
drop.move(to: CGPoint(x: 512, y: 850))
drop.addCurve(to: CGPoint(x: center.x + radius, y: center.y),
              control1: CGPoint(x: 512, y: 790), control2: CGPoint(x: center.x + radius, y: 736))
drop.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi, clockwise: true)
drop.addCurve(to: CGPoint(x: 512, y: 850),
              control1: CGPoint(x: center.x - radius, y: 736), control2: CGPoint(x: 512, y: 790))
drop.closeSubpath()
ctx.addPath(drop)
ctx.setFillColor(white)
ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
