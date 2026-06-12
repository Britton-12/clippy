#!/usr/bin/env swift
//
// generate-icon.swift
// Builds assets/AppIcon.icns from img/Clippy.png.
//
// Run from the repository root:
//   swift assets/generate-icon.swift
//
// Requirements: macOS with Xcode Command Line Tools (AppKit, CoreGraphics,
//   and iconutil are all standard). No third-party dependencies.
//
// Design: modern macOS full-bleed "squircle" icon presentation.
//   Canvas:        1024 x 1024 px, fully filled (no transparent border)
//   Squircle:      rounded rect covering the whole canvas
//   Corner radius: ~229 px  (22.37% of side — Apple's macOS icon-grid ratio)
//   Fill:          the master's own background color, sampled from a corner
//                  pixel so the scaled-down mascot blends with no seam
//   Mascot:        scaled DOWN and centered with a comfortable margin on all
//                  four sides so nothing touches an edge or corner
//
// WHY this shape: the master art (img/Clippy.png) is full-bleed — the mascot
// touches all four edges with ~0 px margin. Drawing it edge-to-edge let the
// rounded corners slice the legs and hand flat ("cut off"). The fix is to
// fill the squircle with the same solid background the master uses, then drop
// the mascot in smaller and centered. Because the fill color matches the
// master's own background, the composite is seamless.
//
// Pipeline:
//   1. NSImage loads img/Clippy.png via the OS codec.
//   2. Sample the master's corner pixel for the background fill color.
//   3. CoreGraphics fills a full-canvas squircle and draws the mascot scaled
//      down + centered inside the safe area.
//   4. sips resamples the 1024 master to each required pixel size.
//   5. iconutil assembles the .icns.

import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Paths — all relative to repo root (cwd when invoked via make-app or directly)
// ---------------------------------------------------------------------------

let repoRoot: String = {
    // When run as `swift assets/generate-icon.swift` from repo root, cwd is root.
    // When run as `./assets/generate-icon.swift`, same.
    FileManager.default.currentDirectoryPath
}()

let sourcePath  = "\(repoRoot)/img/Clippy.png"
let iconsetDir  = "\(repoRoot)/assets/AppIcon.iconset"
let icnsOut     = "\(repoRoot)/assets/AppIcon.icns"

// ---------------------------------------------------------------------------
// Geometry constants
// ---------------------------------------------------------------------------

let CANVAS:  Int = 1024          // total icon canvas in pixels (fully filled)
// Apple's macOS icon-grid corner ratio for a full-bleed icon: ~22.37% of side.
let CORNER_RATIO: CGFloat = 0.2237
let RADIUS: CGFloat = CGFloat(CANVAS) * CORNER_RATIO   // ~229 px at 1024
// Fraction of the canvas the mascot occupies. ~0.74 leaves ~13% margin per
// side so the waving hand, the loop top, and the legs all stay clear of the
// squircle edges and corners.
let MASCOT_SCALE: CGFloat = 0.74

// Standard macOS iconset entries: (logical_pt, scale_factor)
let iconSizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func run(_ args: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = args
    try! task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        fputs("error: command failed: \(args.joined(separator: " "))\n", stderr)
        exit(1)
    }
}

// ---------------------------------------------------------------------------
// Step 1: Load the source image through the OS codec.
// NSImage handles JPEG data stored with a .png extension transparently.
// ---------------------------------------------------------------------------

guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    fputs("error: could not load source image: \(sourcePath)\n", stderr)
    exit(1)
}

// Obtain a CGImage at the native resolution (1024x1024 expected).
guard let sourceCG: CGImage = {
    var rect = NSRect(x: 0, y: 0, width: sourceImage.size.width, height: sourceImage.size.height)
    return sourceImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}() else {
    fputs("error: could not obtain CGImage from source\n", stderr)
    exit(1)
}

print("Source loaded: \(sourceCG.width)x\(sourceCG.height)  [\(sourcePath)]")

// ---------------------------------------------------------------------------
// Step 2: Composite the mascot into a full-canvas squircle.
//
// We draw into an RGBA bitmap context:
//   a. Sample the master's corner pixel -> background fill color.
//   b. Clip to a full-canvas rounded-rect (squircle) and fill it with that color.
//   c. Draw the mascot scaled DOWN (MASCOT_SCALE) and centered, with margin on
//      all four sides so no limb touches an edge or corner.
//
// Because the fill color equals the master's own background, the scaled-down
// mascot drops in with no visible seam.
// ---------------------------------------------------------------------------

// Sample the master's top-left corner for the background fill. The master is
// full-bleed light-blue with no alpha, so the corner is pure background.
func sampleCornerColor(_ image: CGImage) -> CGColor {
    let w = image.width, h = image.height
    var pixel = [UInt8](repeating: 0, count: 4)
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    if let c = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                         bytesPerRow: 4, space: space, bitmapInfo: info) {
        // Draw the source offset so its top-left pixel lands in our 1x1 context.
        c.draw(image, in: CGRect(x: 0, y: CGFloat(-(h - 1)), width: CGFloat(w), height: CGFloat(h)))
    }
    return CGColor(red: CGFloat(pixel[0]) / 255.0,
                   green: CGFloat(pixel[1]) / 255.0,
                   blue: CGFloat(pixel[2]) / 255.0,
                   alpha: 1.0)
}
let fillColor = sampleCornerColor(sourceCG)

let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
guard let ctx = CGContext(
    data: nil,
    width: CANVAS,
    height: CANVAS,
    bitsPerComponent: 8,
    bytesPerRow: CANVAS * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: bitmapInfo.rawValue
) else {
    fputs("error: could not create CGContext\n", stderr)
    exit(1)
}

// Clear to transparent (outside the squircle stays transparent).
ctx.clear(CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS))

// Full-canvas squircle: fills the whole icon, rounded corners only.
let canvasRect = CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS)
let clipPath = CGPath(roundedRect: canvasRect, cornerWidth: RADIUS, cornerHeight: RADIUS, transform: nil)

ctx.saveGState()
ctx.addPath(clipPath)
ctx.clip()

// Fill the squircle with the sampled background color so the scaled mascot
// blends seamlessly.
ctx.setFillColor(fillColor)
ctx.fill(canvasRect)

// Draw the mascot scaled DOWN and centered. WHY: the master is full-bleed, so
// drawing it edge-to-edge let the rounded corners slice the legs and hand.
// Scaling to MASCOT_SCALE of the canvas keeps a comfortable margin on all
// sides; the matching fill hides the mascot's own background.
ctx.interpolationQuality = .high
let srcAspect = CGFloat(sourceCG.width) / CGFloat(sourceCG.height)
let target = CGFloat(CANVAS) * MASCOT_SCALE
var drawW = target
var drawH = target / srcAspect
if drawH > target {
    drawH = target
    drawW = target * srcAspect
}
let drawRect = CGRect(
    x: (CGFloat(CANVAS) - drawW) / 2,
    y: (CGFloat(CANVAS) - drawH) / 2,
    width: drawW,
    height: drawH
)
ctx.draw(sourceCG, in: drawRect)

ctx.restoreGState()

guard let masterCG = ctx.makeImage() else {
    fputs("error: could not make master CGImage\n", stderr)
    exit(1)
}

// Write the 1024x1024 master PNG to a temp file; sips will resample from it.
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clippy-icon-\(ProcessInfo.processInfo.processIdentifier)")
try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
let masterPath = tmpDir.appendingPathComponent("master_1024.png").path

let masterDest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: masterPath) as CFURL,
    UTType.png.identifier as CFString,
    1, nil
)!
CGImageDestinationAddImage(masterDest, masterCG, nil)
guard CGImageDestinationFinalize(masterDest) else {
    fputs("error: could not write master PNG\n", stderr)
    exit(1)
}
print("Master PNG written: \(masterPath)")

// ---------------------------------------------------------------------------
// Step 3: Create the iconset directory and resample to each required size.
// ---------------------------------------------------------------------------

try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// Track already-produced pixel sizes to avoid redundant resampling.
var produced: [Int: String] = [:]

for (logical, scale) in iconSizes {
    let px   = logical * scale
    let suffix = scale == 2 ? "@2x" : ""
    let fname  = "icon_\(logical)x\(logical)\(suffix).png"
    let dest   = "\(iconsetDir)/\(fname)"

    if let existing = produced[px] {
        // Same pixel size already resampled — copy rather than re-run sips.
        try? FileManager.default.removeItem(atPath: dest)
        try! FileManager.default.copyItem(atPath: existing, toPath: dest)
        print("  \(fname)  (\(px)px) — copied")
    } else {
        run([
            "sips",
            "--resampleHeightWidth", "\(px)", "\(px)",
            masterPath,
            "--out", dest,
        ])
        produced[px] = dest
        print("  \(fname)  (\(px)px)")
    }
}

// ---------------------------------------------------------------------------
// Step 4: Assemble the .icns via iconutil.
// ---------------------------------------------------------------------------

print("\nRunning iconutil -> \(icnsOut)")
run(["iconutil", "--convert", "icns", "--output", icnsOut, iconsetDir])

let attrs = try! FileManager.default.attributesOfItem(atPath: icnsOut)
let bytes = attrs[.size] as! Int
print("AppIcon.icns written (\(bytes / 1024) KB, \(bytes) bytes)")

// Clean up the temp master.
try? FileManager.default.removeItem(at: tmpDir)
