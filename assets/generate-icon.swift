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
// Design: macOS Big Sur rounded-square icon presentation.
//   Canvas:        1024 x 1024 pt
//   Tile size:     824 pt (centered; 100 pt transparent padding each side)
//   Corner radius: 185 pt on the 824 pt tile  (~22.5%, continuous-corner ratio)
//   Outside tile:  fully transparent
//   Inside tile:   mascot scaled to fill the tile, anti-aliased
//
// Pipeline:
//   1. NSImage loads img/Clippy.png via the OS codec — handles JPEG data
//      regardless of file extension, no hand-rolled decoder.
//   2. CoreGraphics composites the mascot into the rounded-rect tile with
//      anti-aliased edge feathering via a soft SDF mask.
//   3. sips resamples the 1024 master to each required pixel size.
//   4. iconutil assembles the .icns.

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

let CANVAS:  Int = 1024          // total icon canvas in pixels
let TILE:    Int = 824           // mascot tile size (Big Sur grid: 824/1024)
let TILE_PAD = (CANVAS - TILE) / 2  // 100 px transparent padding each side
let RADIUS: CGFloat = 185        // continuous-corner radius on the 824-pt tile

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
// Step 2: Composite the mascot into the 1024x1024 rounded-rect tile.
//
// We draw into an RGBA bitmap context:
//   a. Fill transparent.
//   b. Clip to the rounded-rect path (corner radius RADIUS, tile origin TILE_PAD).
//   c. Draw the source image scaled to fill the tile exactly.
//
// CoreGraphics clips and anti-aliases the edges automatically; no manual
// SDF mask needed because addRoundedRect already uses sub-pixel AA.
// ---------------------------------------------------------------------------

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

// Clear to transparent.
ctx.clear(CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS))

// Build the rounded-rect clip path.
// CGContext's coordinate origin is bottom-left, so y is measured from bottom.
let tileRect = CGRect(x: TILE_PAD, y: TILE_PAD, width: TILE, height: TILE)
let clipPath = CGPath(roundedRect: tileRect, cornerWidth: RADIUS, cornerHeight: RADIUS, transform: nil)

ctx.saveGState()
ctx.addPath(clipPath)
ctx.clip()

// Draw the mascot inset inside the tile. WHY: the full-bleed source fills
// 1024x1024 with zero margin, so drawing it edge-to-edge let the rounded
// corners slice off the art; insetting keeps breathing room inside the curve.
ctx.interpolationQuality = .high
let artRect = tileRect.insetBy(dx: 90, dy: 90)
// scaledToFit: preserve aspect ratio, center within artRect (square source -> exact fit).
let srcAspect = CGFloat(sourceCG.width) / CGFloat(sourceCG.height)
var drawW = artRect.width
var drawH = artRect.width / srcAspect
if drawH > artRect.height {
    drawH = artRect.height
    drawW = artRect.height * srcAspect
}
let drawRect = CGRect(
    x: artRect.midX - drawW / 2,
    y: artRect.midY - drawH / 2,
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
