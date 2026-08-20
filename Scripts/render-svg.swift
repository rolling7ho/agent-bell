import AppKit
import Foundation

enum RenderError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidSize(String)
    case unreadableImage(String)
    case bitmapCreationFailed
    case pngEncodingFailed

    var description: String {
        switch self {
        case .invalidArguments:
            return "Usage: render-svg <input.svg> <output.png> <square-size>"
        case let .invalidSize(value):
            return "Invalid square size: \(value)"
        case let .unreadableImage(path):
            return "AppKit could not decode SVG: \(path)"
        case .bitmapCreationFailed:
            return "Could not create the output bitmap"
        case .pngEncodingFailed:
            return "Could not encode the output PNG"
        }
    }
}

func render() throws {
    guard CommandLine.arguments.count == 4 else {
        throw RenderError.invalidArguments
    }

    let inputPath = CommandLine.arguments[1]
    let outputPath = CommandLine.arguments[2]
    let sizeValue = CommandLine.arguments[3]

    guard let size = Int(sizeValue), size > 0 else {
        throw RenderError.invalidSize(sizeValue)
    }
    guard let image = NSImage(contentsOfFile: inputPath) else {
        throw RenderError.unreadableImage(inputPath)
    }
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw RenderError.bitmapCreationFailed
    }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw RenderError.bitmapCreationFailed
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill(using: .copy)
    image.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw RenderError.pngEncodingFailed
    }
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
}

do {
    try render()
} catch {
    FileHandle.standardError.write(Data("render-svg: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
