import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("output path required") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LidKeep.iconset")
try? FileManager.default.removeItem(at: temporary)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 512
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    let background = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 456, height: 456), xRadius: 104, yRadius: 104)
    NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.27, alpha: 1).setFill()
    background.fill()

    let screen = NSBezierPath(roundedRect: NSRect(x: 132, y: 156, width: 248, height: 204), xRadius: 20, yRadius: 20)
    NSColor(calibratedRed: 0.76, green: 0.75, blue: 1, alpha: 1).setStroke()
    screen.lineWidth = 20
    screen.stroke()

    let base = NSBezierPath()
    base.move(to: NSPoint(x: 88, y: 135))
    base.line(to: NSPoint(x: 424, y: 135))
    base.lineWidth = 24
    base.lineCapStyle = .round
    base.stroke()

    let dot = NSBezierPath(ovalIn: NSRect(x: 316, y: 306, width: 80, height: 80))
    NSColor(calibratedRed: 0.44, green: 0.92, blue: 0.62, alpha: 1).setFill()
    dot.fill()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("icon render failed") }
    let name: String
    switch size {
    case 16: name = "icon_16x16.png"
    case 32: name = "icon_16x16@2x.png"
    case 64: name = "icon_32x32@2x.png"
    case 128: name = "icon_128x128.png"
    case 256: name = "icon_128x128@2x.png"
    case 512: name = "icon_256x256@2x.png"
    default: name = "icon_512x512@2x.png"
    }
    try png.write(to: temporary.appendingPathComponent(name))
    if size == 32 { try png.write(to: temporary.appendingPathComponent("icon_32x32.png")) }
    if size == 256 { try png.write(to: temporary.appendingPathComponent("icon_256x256.png")) }
    if size == 512 { try png.write(to: temporary.appendingPathComponent("icon_512x512.png")) }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", temporary.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: temporary)
