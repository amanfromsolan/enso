import AppKit

/// Renders AppIcon.icns — the index header's dark squircle with the white
/// terminal glyph, scaled to the macOS icon grid.
/// Usage: swift scripts/make-icon.swift <output.icns>

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(1)
}
let outputPath = CommandLine.arguments[1]

func renderMaster() -> NSBitmapImageRep {
    let canvas = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Big Sur icon grid: the squircle fills ~824pt of the 1024 canvas.
    let side: CGFloat = 1024
    let inset: CGFloat = 100
    let box = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let squircle = NSBezierPath(roundedRect: box, xRadius: 186, yRadius: 186)

    NSGradient(
        starting: NSColor(calibratedWhite: 0.18, alpha: 1),
        ending: NSColor(calibratedWhite: 0.08, alpha: 1)
    )!.draw(in: squircle, angle: -90)

    NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
    squircle.lineWidth = 6
    squircle.stroke()

    // White terminal glyph, pre-tinted so the fill doesn't wash the squircle.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor(calibratedWhite: 1, alpha: 0.9).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let width: CGFloat = 500
        let height = width * symbol.size.height / symbol.size.width
        tinted.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func run(_ launchPath: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}

let workDir = NSTemporaryDirectory() + "EnsoLabIcon-\(ProcessInfo.processInfo.processIdentifier)"
let iconset = workDir + "/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: workDir) }

let master = workDir + "/master.png"
try! renderMaster().representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: master))

// Downscale the 1024 master into every slot iconutil expects.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master, "--out", "\(iconset)/\(name)"])
}
run("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", outputPath])
