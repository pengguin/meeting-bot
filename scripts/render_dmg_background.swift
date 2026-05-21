import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "background.png"
let canvasSize = NSSize(width: 640, height: 420)
let image = NSImage(size: canvasSize)

image.lockFocus()
NSColor.windowBackgroundColor.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

let lineColor = NSColor(calibratedWhite: 0.42, alpha: 0.9)
lineColor.setStroke()
let shaft = NSBezierPath()
shaft.lineWidth = 5
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 255, y: 210))
shaft.line(to: NSPoint(x: 385, y: 210))
shaft.stroke()

let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineJoinStyle = .round
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 360, y: 232))
arrow.line(to: NSPoint(x: 385, y: 210))
arrow.line(to: NSPoint(x: 360, y: 188))
arrow.stroke()
image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("failed to render dmg background\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
