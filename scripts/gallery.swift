// Composes app icons into a 10-column gallery PNG with a transparent background, as in docs/icons.png.
// Usage: swift scripts/gallery.swift out.png icon1.png icon2.png ...
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count > 1 else { print("usage: gallery.swift out.png icons..."); exit(1) }
let icons = args.dropFirst().compactMap { NSImage(contentsOfFile: $0) }
let cell = 172, cols = 10
let rows = (icons.count + cols - 1) / cols
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cell * cols, pixelsHigh: cell * rows, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
for (i, icon) in icons.enumerated() {
    let x = (i % cols) * cell + 6, y = (rows - 1 - i / cols) * cell + 6
    icon.draw(in: NSRect(x: x, y: y, width: 160, height: 160))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[0]))
