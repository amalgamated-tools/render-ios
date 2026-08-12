// Build the app icon variants from the Render brand-kit logomark.
//
//   swift Scripts/make-app-icon.swift <logomark-black.png> <logomark-white.png> <output-dir>
//
// Writes the three 1024×1024 PNGs an iOS 18 single-size app icon wants:
//
//   AppIcon.png         black mark on white          — "Any Appearance"
//   AppIcon-Dark.png    white mark, transparent      — the system draws the dark backdrop
//   AppIcon-Tinted.png  white mark, transparent      — the system applies the user's tint
//
// The source art is a mark floating in a much larger transparent canvas, and it isn't centred in it,
// so the alpha bounding box is measured and the mark re-centred rather than scaling the file as-is.
// Kept as a script (and committed) so a brand-kit refresh is one command, not a Photoshop session.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024.0
/// Fraction of the canvas the mark's longer side occupies. Apple's icon grid leaves generous
/// margins; at much above this the mark collides with the corner radius on the home screen.
let markScale = 0.54

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("!!! \(message)\n".utf8))
    exit(1)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("Could not read image at \(path)") }
    return image
}

/// The tightest rectangle containing every pixel with non-zero alpha.
func opaqueBounds(of image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("Could not create a bitmap context") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { fail("Image is fully transparent") }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Draws `image`'s opaque region centred on a square canvas, optionally over a solid background.
func renderIcon(_ image: CGImage, background: CGColor?, to path: String) {
    guard let context = CGContext(
        data: nil,
        width: Int(canvas),
        height: Int(canvas),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("Could not create the icon context") }

    if let background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    }

    let bounds = opaqueBounds(of: image)
    guard let mark = image.cropping(to: bounds) else { fail("Could not crop to the mark") }

    let scale = (canvas * markScale) / max(bounds.width, bounds.height)
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    let origin = CGPoint(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2)
    context.interpolationQuality = .high
    context.draw(mark, in: CGRect(origin: origin, size: size))

    guard let output = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else { fail("Could not encode \(path)") }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Could not write \(path)") }
    print("  wrote \(path)")
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: make-app-icon.swift <logomark-black.png> <logomark-white.png> <output-dir>")
}
let blackMark = loadImage(arguments[1])
let whiteMark = loadImage(arguments[2])
let outputDirectory = arguments[3]

let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

print("==> Rendering app icon variants")
renderIcon(blackMark, background: white, to: "\(outputDirectory)/AppIcon.png")
// Dark and tinted variants are composited by the system over its own backdrop, so they ship
// transparent — filling a black background here would show as a black square inside the icon.
renderIcon(whiteMark, background: nil, to: "\(outputDirectory)/AppIcon-Dark.png")
renderIcon(whiteMark, background: nil, to: "\(outputDirectory)/AppIcon-Tinted.png")
