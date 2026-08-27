// Generates assets/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconsetURL = URL(fileURLWithPath: "assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func draw(_ size: Int) -> NSImage {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()

    // macOS-style rounded rect covering ~80% of the canvas
    let inset = dimension * 0.1
    let rect = NSRect(x: inset, y: inset, width: dimension - 2 * inset, height: dimension - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        ending: NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.24, alpha: 1)
    )!
    gradient.draw(in: path, angle: -90)

    if let symbol = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: dimension * 0.42, weight: .semibold)) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let symbolRect = NSRect(
            x: (dimension - symbol.size.width) / 2,
            y: (dimension - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )
        tinted.draw(in: symbolRect)
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! representation.representation(using: .png, properties: [:])!.write(to: url)
}

for size in sizes {
    let image = draw(size)
    if size <= 512 {
        writePNG(image, pixels: size, to: iconsetURL.appendingPathComponent("icon_\(size)x\(size).png"))
    }
    if size >= 32 {
        writePNG(draw(size), pixels: size, to: iconsetURL.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}
print("iconset written; run iconutil to produce AppIcon.icns")
