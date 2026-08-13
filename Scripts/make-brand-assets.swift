// Build every branded asset in the catalog from the Render brand kit.
//
//   swift Scripts/make-brand-assets.swift <brand-kit-logos-dir> [repo-root]
//
// e.g. swift Scripts/make-brand-assets.swift "$HOME/Downloads/Render Brand Kit/Logos"
//
// Writes into App/Assets.xcassets:
//
//   AppIcon.appiconset/
//     AppIcon.png              black mark on white          — "Any Appearance"
//     AppIcon-Dark.png         white mark, transparent      — the system draws the dark backdrop
//     AppIcon-Tinted.png       white mark, transparent      — the system applies the user's tint
//   Logomark.imageset/         white mark, template-rendered, 120pt base
//   Wordmark.imageset/         white mark + wordmark, template-rendered, 160pt base
//   LaunchLogomark.imageset/   white mark, ORIGINAL rendering, exactly 96pt
//
// Two things the asset catalog does that shape all of this.
//
// A *template* asset throws away RGB and keeps only alpha, so the single white source renders
// correctly in light mode, dark mode, tinted, and knocked out of a violet hero — no
// appearance-qualified variants needed. That is right for everything drawn by our own code.
//
// The launch screen is the exception, and it is the reason LaunchLogomark exists separately.
// `UILaunchScreen` runs before any of our code, so there is no tint colour to apply: it must be a
// non-template white PNG. It is also drawn *centred at its natural point size and never scaled*, so
// the asset has to be authored at the exact size it should appear — 96pt. That number is duplicated
// in App/DesignSystem/SplashView.swift, which reproduces this frame; the two must agree or the
// handoff from launch screen to first SwiftUI frame visibly jumps.
//
// The source art is a mark floating in a much larger transparent canvas, and it isn't centred in
// it, so the alpha bounding box is measured and the mark re-centred rather than scaling the file
// as-is. Kept as a script (and committed) so a brand-kit refresh is one command, not a Photoshop
// session — which is also why this generates the Contents.json files rather than leaving them to
// drift by hand.
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

func writePNG(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fail("Could not encode \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Could not write \(path)") }
    print("  wrote \(path)")
}

func makeDirectory(_ path: String) {
    try? FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true
    )
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

    guard let output = context.makeImage() else { fail("Could not render \(path)") }
    writePNG(output, to: path)
}

/// Crops `image` to its opaque region and resamples it so the longer side is exactly
/// `longestSide` pixels. No padding: an image set entry should be the art and nothing else, so
/// SwiftUI's own frame and the launch screen's centring both have something predictable to work
/// with.
func renderTrimmed(_ image: CGImage, longestSide: Int, to path: String) {
    let bounds = opaqueBounds(of: image)
    guard let mark = image.cropping(to: bounds) else { fail("Could not crop to the mark") }

    let scale = Double(longestSide) / max(bounds.width, bounds.height)
    let width = max(1, Int((bounds.width * scale).rounded()))
    let height = max(1, Int((bounds.height * scale).rounded()))

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("Could not create a context for \(path)") }

    context.interpolationQuality = .high
    context.draw(mark, in: CGRect(x: 0, y: 0, width: Double(width), height: Double(height)))

    guard let output = context.makeImage() else { fail("Could not render \(path)") }
    writePNG(output, to: path)
}

/// Emits a 1x/2x/3x image set. `pointSize` is the longer side in points; `isTemplate` decides
/// whether the catalog keeps the artwork's colour or reduces it to an alpha mask.
func renderImageSet(
    _ image: CGImage,
    named name: String,
    pointSize: Int,
    isTemplate: Bool,
    in catalog: String
) {
    let directory = "\(catalog)/\(name).imageset"
    makeDirectory(directory)

    var entries: [String] = []
    for scale in 1...3 {
        let filename = scale == 1 ? "\(name).png" : "\(name)@\(scale)x.png"
        renderTrimmed(image, longestSide: pointSize * scale, to: "\(directory)/\(filename)")
        entries.append("""
            {
              "filename" : "\(filename)",
              "idiom" : "universal",
              "scale" : "\(scale)x"
            }
        """)
    }

    // Omitting the properties block entirely leaves the default rendering intent (original), which
    // is what the launch screen needs — see the header note.
    let properties = isTemplate ? """
        ,
          "properties" : {
            "template-rendering-intent" : "template"
          }
        """ : ""

    let contents = """
        {
          "images" : [
        \(entries.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }\(properties)
        }

        """
    do {
        try contents.write(toFile: "\(directory)/Contents.json", atomically: true, encoding: .utf8)
    } catch {
        fail("Could not write \(directory)/Contents.json: \(error)")
    }
    print("  wrote \(directory)/Contents.json")
}

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else {
    fail("usage: make-brand-assets.swift <brand-kit-logos-dir> [repo-root]")
}
// The brand kit's filenames are stable, so the script derives its four sources from one directory.
// Four positional paths would be a footgun for a command run once a year.
let logosDirectory = arguments[1]
let repositoryRoot = arguments.count == 3 ? arguments[2] : FileManager.default.currentDirectoryPath

let blackMark = loadImage("\(logosDirectory)/Black/Render logomark - Black.png")
let whiteMark = loadImage("\(logosDirectory)/White/Render logomark - White.png")
let whiteLogo = loadImage("\(logosDirectory)/White/Render logo - White.png")

let catalog = "\(repositoryRoot)/App/Assets.xcassets"
let appIcon = "\(catalog)/AppIcon.appiconset"
guard FileManager.default.fileExists(atPath: catalog) else {
    fail("No asset catalog at \(catalog) — pass the repository root as the second argument")
}

let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

print("==> Rendering app icon variants")
renderIcon(blackMark, background: white, to: "\(appIcon)/AppIcon.png")
// Dark and tinted variants are composited by the system over its own backdrop, so they ship
// transparent — filling a black background here would show as a black square inside the icon.
renderIcon(whiteMark, background: nil, to: "\(appIcon)/AppIcon-Dark.png")
renderIcon(whiteMark, background: nil, to: "\(appIcon)/AppIcon-Tinted.png")

print("==> Rendering in-app marks")
renderImageSet(whiteMark, named: "Logomark", pointSize: 120, isTemplate: true, in: catalog)
renderImageSet(whiteLogo, named: "Wordmark", pointSize: 160, isTemplate: true, in: catalog)

print("==> Rendering the launch-screen mark")
// Non-template, and 96pt exactly. See SplashView.logoSize.
renderImageSet(whiteMark, named: "LaunchLogomark", pointSize: 96, isTemplate: false, in: catalog)
