// Makes every pixel of a square app icon opaque. Each pixel that is not fully opaque takes the color of the first opaque pixel in its row toward the middle, or on the line toward the center when the row has none, so the rounded corners fill with the colors next to them.
// macOS 26 and later shrink an icon onto a gray plate unless its edge pixels are opaque, and the plate shows wherever the icon's corners differ from the system shape. An opaque square is clipped to the system shape instead. Earlier macOS versions show the square as it is.
// Usage: swift scripts/opaque_icon.swift <input.png> <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = context.data else {
    FileHandle.standardError.write(Data("usage: swift opaque_icon.swift <input.png> <output.png>\n".utf8))
    exit(1)
}
let width = image.width
let height = image.height
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
// Lookups read this copy so that filled pixels never feed other pixels.
let original = Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))
let centerX = Double(width - 1) / 2
let centerY = Double(height - 1) / 2

/// Returns the offset of the first opaque pixel on the line from (x, y) to the target point, or nil if there is none.
func firstOpaque(fromX x: Int, y: Int, toX targetX: Double, y targetY: Double) -> Int? {
    let distance = ((targetX - Double(x)) * (targetX - Double(x)) + (targetY - Double(y)) * (targetY - Double(y))).squareRoot()
    var step = 1.0
    while step <= distance {
        let sampleX = Int((Double(x) + (targetX - Double(x)) * step / distance).rounded())
        let sampleY = Int((Double(y) + (targetY - Double(y)) * step / distance).rounded())
        let sample = (sampleY * width + sampleX) * 4
        if original[sample + 3] == 255 { return sample }
        step += 1
    }
    return nil
}

for y in 0..<height {
    for x in 0..<width where original[(y * width + x) * 4 + 3] < 255 {
        guard let sample = firstOpaque(fromX: x, y: y, toX: centerX, y: Double(y)) ?? firstOpaque(fromX: x, y: y, toX: centerX, y: centerY) else { continue }
        let target = (y * width + x) * 4
        pixels[target] = original[sample]
        pixels[target + 1] = original[sample + 1]
        pixels[target + 2] = original[sample + 2]
        pixels[target + 3] = 255
    }
}

guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("cannot write \(arguments[2])\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("cannot write \(arguments[2])\n".utf8))
    exit(1)
}
