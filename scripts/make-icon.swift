// Draws Pinna's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns] [preview.png]
import AppKit

let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Resources/AppIcon.icns")
let preview = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The macOS icon shape: a superellipse, 824 points across on the 1024 grid.
func squircle(center: CGPoint, radius: CGFloat, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = center.x + radius * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = center.y + radius * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Draws the icon on the 1024-point grid.
func drawIcon(_ context: CGContext) {
    let body = squircle(center: CGPoint(x: 512, y: 512), radius: 412)

    // The body: a deep blue gradient, with a soft shadow below it.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    context.addPath(body)
    context.setFillColor(color(0x3B46D6))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    linearGradient(context, [color(0x6F8DFF), color(0x4A4FE0), color(0x3330B8)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // A gentle glow from the top.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: nil)!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 380, y: 900), startRadius: 0,
                               endCenter: CGPoint(x: 380, y: 900), endRadius: 620, options: [])
    context.restoreGState()

    // Selection corners, like a screenshot being taken.
    let frame = CGRect(x: 216, y: 236, width: 592, height: 470)
    let arm: CGFloat = 70
    context.saveGState()
    context.setStrokeColor(color(0xFFFFFF, 0.55))
    context.setLineWidth(18)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
                             (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0)] {
        context.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        context.addLine(to: corner)
        context.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    }
    context.strokePath()
    context.restoreGState()

    // The pinned screenshot: a white card, tilted a little.
    context.saveGState()
    context.translateBy(x: 512, y: 452)
    context.rotate(by: -6 * .pi / 180)
    let card = CGRect(x: -236, y: -176, width: 472, height: 352)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 34, cornerHeight: 34, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: color(0x10124A, 0.45))
    context.addPath(cardPath)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    // Inside the card: a picture of hills under a sky.
    let picture = card.insetBy(dx: 30, dy: 30)
    let picturePath = CGPath(roundedRect: picture, cornerWidth: 16, cornerHeight: 16, transform: nil)
    context.saveGState()
    context.addPath(picturePath)
    context.clip()
    linearGradient(context, [color(0xCFDCFF), color(0xEEF2FF)], from: CGPoint(x: 0, y: picture.maxY), to: CGPoint(x: 0, y: picture.minY))
    context.setFillColor(color(0xFFC94D))
    context.fillEllipse(in: CGRect(x: picture.maxX - 118, y: picture.maxY - 112, width: 66, height: 66))
    let back = CGMutablePath()
    back.move(to: CGPoint(x: picture.minX - 20, y: picture.minY))
    back.addLine(to: CGPoint(x: picture.minX + 120, y: picture.minY + 170))
    back.addQuadCurve(to: CGPoint(x: picture.minX + 170, y: picture.minY + 170), control: CGPoint(x: picture.minX + 145, y: picture.minY + 200))
    back.addLine(to: CGPoint(x: picture.minX + 330, y: picture.minY))
    back.closeSubpath()
    context.addPath(back)
    context.setFillColor(color(0x8EA4FF))
    context.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: picture.minX + 120, y: picture.minY))
    front.addLine(to: CGPoint(x: picture.minX + 290, y: picture.minY + 120))
    front.addQuadCurve(to: CGPoint(x: picture.minX + 340, y: picture.minY + 120), control: CGPoint(x: picture.minX + 315, y: picture.minY + 145))
    front.addLine(to: CGPoint(x: picture.maxX + 40, y: picture.minY))
    front.closeSubpath()
    context.addPath(front)
    context.setFillColor(color(0x5B6EF0))
    context.fillPath()
    context.restoreGState()

    // The pin, seen from above, holding the card at the top.
    let pinCenter = CGPoint(x: 0, y: card.maxY - 6)
    let radius: CGFloat = 62
    context.saveGState()
    context.setShadow(offset: CGSize(width: 12, height: -16), blur: 20, color: color(0x10124A, 0.45))
    context.setFillColor(color(0xE23B3B))
    context.fillEllipse(in: CGRect(x: pinCenter.x - radius, y: pinCenter.y - radius, width: radius * 2, height: radius * 2))
    context.restoreGState()

    context.saveGState()
    context.addEllipse(in: CGRect(x: pinCenter.x - radius, y: pinCenter.y - radius, width: radius * 2, height: radius * 2))
    context.clip()
    let head = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFF8A7A), color(0xF04A43), color(0xC22A2E)] as CFArray, locations: [0, 0.55, 1])!
    context.drawRadialGradient(head, startCenter: CGPoint(x: pinCenter.x - 20, y: pinCenter.y + 22), startRadius: 0,
                               endCenter: pinCenter, endRadius: radius, options: [.drawsAfterEndLocation])
    // A shine on the top-left.
    context.setFillColor(color(0xFFFFFF, 0.55))
    context.fillEllipse(in: CGRect(x: pinCenter.x - 38, y: pinCenter.y + 10, width: 36, height: 24))
    context.restoreGState()
    context.restoreGState()
}

func render(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(context)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Pinna-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if let preview {
    writePNG(render(pixels: 1024), to: preview)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
