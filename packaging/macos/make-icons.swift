// make-icons.swift -- generate UxPlay's app icon and menu-bar template image.
//
// No external dependencies: everything is drawn into an offscreen
// CGBitmapContext with Core Graphics (works headless, no window server), and
// written as PNG with ImageIO.  Run it with the Swift interpreter:
//
//     xcrun swift make-icons.swift <outdir>
//
// It writes, into <outdir>:
//   * AppIcon.iconset/   -- 16/32/128/256/512 pt PNGs (each @1x and @2x, i.e.
//                           pixel sizes 16,32,64,128,256,512,1024)
//   * AppIcon.icns       -- produced from the iconset with /usr/bin/iconutil
//   * menubarTemplate.png / menubarTemplate@2x.png
//                        -- monochrome (black + alpha) 18x18 / 36x36 status
//                           bar image, loaded by the app as a template NSImage.
//
// Design: a macOS "squircle" app icon with a blue -> teal vertical gradient
// and, centered in white, the classic AirPlay glyph -- a rounded-rectangle
// "screen" outline with an upward-pointing solid triangle overlapping its
// lower edge.  The same glyph, in black, is the menu-bar template.

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Bitmap helpers

/// Create a premultiplied-RGBA bitmap context of `size` x `size` pixels.
func makeContext(_ size: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create \(size)x\(size) bitmap context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

func writePNG(_ ctx: CGContext, to url: URL) {
    guard let image = ctx.makeImage() else { fatalError("makeImage failed for \(url.path)") }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("could not create PNG destination \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

// MARK: - The AirPlay glyph (shared by the app icon and the menu-bar template)

/// Draw the AirPlay glyph filling `box`, in `color`:
///   * a rounded-rectangle "screen" outline occupying the top of the box, and
///   * a solid upward-pointing triangle whose base sits on the bottom of the
///     box and whose apex overlaps the screen's lower edge.
/// `lineWidth` is the stroke width of the screen outline.
/// The context uses a bottom-left origin, so larger y is higher on screen.
func drawAirPlayGlyph(_ ctx: CGContext, box: CGRect, color: CGColor, lineWidth: CGFloat) {
    let w = box.width, h = box.height

    // Screen: rounded-rect outline, top-aligned in the box.
    let screenH = h * 0.66
    let inset = lineWidth / 2                    // keep the stroke inside the box
    let screen = CGRect(x: box.minX + inset,
                        y: box.maxY - screenH + inset,
                        width: w - lineWidth,
                        height: screenH - lineWidth)
    let radius = min(screen.width, screen.height) * 0.16
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineWidth)
    ctx.setLineJoin(.round)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()

    // Triangle: solid, apex up, base on the bottom edge of the box, apex a
    // little above the screen's lower edge so the two overlap.
    let triW = w * 0.64
    let cx = box.midX
    let baseY = box.minY
    let apexY = screen.minY + h * 0.13
    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx, y: apexY))
    ctx.addLine(to: CGPoint(x: cx - triW / 2, y: baseY))
    ctx.addLine(to: CGPoint(x: cx + triW / 2, y: baseY))
    ctx.closePath()
    ctx.setFillColor(color)
    ctx.fillPath()
}

// MARK: - The app icon

func drawAppIcon(_ ctx: CGContext, size s: CGFloat) {
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Rounded-rect ("squircle") body, following macOS icon proportions:
    // ~10% margin all round and a corner radius of ~0.224 of the body side.
    let margin = s * 0.0977
    let side = s - 2 * margin
    let body = CGRect(x: margin, y: margin, width: side, height: side)
    let corner = side * 0.2237
    let bodyPath = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Blue (top) -> teal (bottom) vertical gradient, clipped to the body.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [rgba(0.043, 0.42, 0.98), rgba(0.13, 0.80, 0.74)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY),
                           options: [])
    // Soft diagonal sheen for a little depth.
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [rgba(1, 1, 1, 0.14), rgba(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY),
                           options: [])
    ctx.restoreGState()

    // White AirPlay glyph, centered (nudged up slightly so the triangle's
    // weight does not make it look low).
    let glyphW = side * 0.52
    let glyphH = glyphW * 0.95
    let glyphBox = CGRect(x: body.midX - glyphW / 2,
                          y: body.midY - glyphH / 2 + side * 0.015,
                          width: glyphW, height: glyphH)
    drawAirPlayGlyph(ctx, box: glyphBox, color: rgba(1, 1, 1), lineWidth: max(2, side * 0.030))
}

// MARK: - The menu-bar template image

func drawMenubarTemplate(_ ctx: CGContext, size s: CGFloat) {
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    let inset = s * 0.06
    let glyphW = s - 2 * inset
    let glyphH = glyphW * 0.95
    let box = CGRect(x: (s - glyphW) / 2, y: (s - glyphH) / 2, width: glyphW, height: glyphH)
    // Template images are pure black + alpha; AppKit recolors them for the bar.
    drawAirPlayGlyph(ctx, box: box, color: rgba(0, 0, 0), lineWidth: max(1.2, s * 0.075))
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icons.swift <outdir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let fm = FileManager.default
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

// 1. Icon set (standard iconutil names).
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let iconEntries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in iconEntries {
    let ctx = makeContext(px)
    drawAppIcon(ctx, size: CGFloat(px))
    writePNG(ctx, to: iconset.appendingPathComponent(name))
}

// 2. AppIcon.icns via iconutil.
let icns = outDir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (\(iconutil.terminationStatus))\n".utf8))
    exit(1)
}

// 3. Menu-bar template images.
for (name, px) in [("menubarTemplate.png", 18), ("menubarTemplate@2x.png", 36)] {
    let ctx = makeContext(px)
    drawMenubarTemplate(ctx, size: CGFloat(px))
    writePNG(ctx, to: outDir.appendingPathComponent(name))
}

print("icons written to \(outDir.path)")
