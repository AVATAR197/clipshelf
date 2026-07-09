// Renders the ClipShelf app icon as a 1024x1024 PNG.
// Usage: swift Scripts/generate-icon.swift <output.png>
// Run Scripts/generate-icon.sh to produce Resources/AppIcon.icns.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: swift generate-icon.swift <output.png>\n", stderr)
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])

let canvasSize = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("error: could not create drawing context\n", stderr)
    exit(1)
}
rep.size = NSSize(width: canvasSize, height: canvasSize)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// Standard macOS icon grid: 824pt squircle centered on a 1024pt canvas.
let backgroundRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(calibratedRed: 0.40, green: 0.46, blue: 0.99, alpha: 1),
    ending: NSColor(calibratedRed: 0.18, green: 0.13, blue: 0.55, alpha: 1)
)!.draw(in: backgroundPath, angle: -70)

NSGraphicsContext.saveGraphicsState()
backgroundPath.addClip()

// Shelf bar the cards stand on.
NSColor.white.withAlphaComponent(0.28).setFill()
NSBezierPath(roundedRect: NSRect(x: 236, y: 206, width: 552, height: 30), xRadius: 15, yRadius: 15).fill()

// Three clip cards, headers in the app's category palette.
struct Card {
    let x: CGFloat
    let height: CGFloat
    let header: NSColor
}
let cards = [
    Card(x: 203, height: 340, header: NSColor(calibratedRed: 0.96, green: 0.40, blue: 0.34, alpha: 1)),
    Card(x: 417, height: 395, header: NSColor(calibratedRed: 0.95, green: 0.67, blue: 0.18, alpha: 1)),
    Card(x: 631, height: 315, header: NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.78, alpha: 1))
]
let cardWidth: CGFloat = 190
let cardBottom: CGFloat = 221
let headerHeight: CGFloat = 62

for card in cards {
    let rect = NSRect(x: card.x, y: cardBottom, width: cardWidth, height: card.height)
    let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 26
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    card.header.setFill()
    NSRect(x: rect.minX, y: rect.maxY - headerHeight, width: rect.width, height: headerHeight).fill()

    // Placeholder text lines under the header.
    NSColor(calibratedWhite: 0.87, alpha: 1).setFill()
    var lineTop = rect.maxY - headerHeight - 34
    for inset: CGFloat in [48, 82, 60] {
        guard lineTop - 16 > rect.minY + 24 else { break }
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 24, y: lineTop - 16, width: rect.width - inset, height: 16),
            xRadius: 8,
            yRadius: 8
        ).fill()
        lineTop -= 42
    }
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("error: could not encode PNG\n", stderr)
    exit(1)
}
try png.write(to: outputURL)
print(outputURL.path)
