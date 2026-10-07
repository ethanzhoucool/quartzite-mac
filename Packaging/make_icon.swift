import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(bg); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.42, alpha: 1).cgColor,
             NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.70, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
// grid dots
ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
var gx: CGFloat = 140
while gx < 924 { var gy: CGFloat = 140; while gy < 924 { ctx.fillEllipse(in: CGRect(x: gx, y: gy, width: 8, height: 8)); gy += 56 }; gx += 56 }
// AND gate
ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(34); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let g = CGMutablePath()
g.move(to: CGPoint(x: 360, y: 320)); g.addLine(to: CGPoint(x: 360, y: 704)); g.addLine(to: CGPoint(x: 520, y: 704))
g.addArc(center: CGPoint(x: 520, y: 512), radius: 192, startAngle: .pi/2, endAngle: -.pi/2, clockwise: true)
g.closeSubpath()
ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
ctx.addPath(g); ctx.fillPath(); ctx.addPath(g); ctx.strokePath()
let leads = CGMutablePath()
for y in [420.0, 604.0] { leads.move(to: CGPoint(x: 210, y: y)); leads.addLine(to: CGPoint(x: 360, y: y)) }
leads.move(to: CGPoint(x: 712, y: 512)); leads.addLine(to: CGPoint(x: 830, y: 512))
ctx.addPath(leads); ctx.strokePath()
ctx.setFillColor(NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.75, alpha: 1).cgColor)
for p in [CGPoint(x: 210, y: 420), CGPoint(x: 210, y: 604), CGPoint(x: 830, y: 512)] {
    ctx.fillEllipse(in: CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
