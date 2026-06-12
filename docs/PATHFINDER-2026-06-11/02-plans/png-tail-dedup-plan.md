# Plan: Remove the duplicated PNG re-encode tail (F1 + F6)

Source: PATHFINDER-2026-06-11 flowcharts F1-capture-pipeline, F6-archive-import-export.
Type: single extract-and-delegate refactor. Behavior stays identical; `swift test`
(image capture + archive import round-trip) is the gate. Keep the diff minimal.

The tail `tiffRepresentation -> NSBitmapImageRep(data:) -> representation(using: .png)`
is copied into two ingress paths. Extract it once into `MediaStore` (the image-domain
owner) and rewrite both call sites to keep their source-specific FRONT half.

All line numbers verified read-only against the working tree. Where PATHFINDER's
citation was off, the corrected number is used and noted.

---

## Phase 0: Verified facts and allowed APIs

Confirmed from source, not assumed.

**AppKit imaging (all already in use, no new APIs):**
- `image.tiffRepresentation` (`NSImage`), `NSBitmapImageRep(data:)`,
  `rep.representation(using: .png, properties:)`, `NSImage(data:)`.

**`MediaStore` shape** (`Sources/Clippy/Storage/MediaStore.swift`):
- `final class MediaStore`. Errors: `enum MediaStoreError: Error { case undecodableImage; case thumbnailFailed }`.
- Existing image helper is `private static func thumbnailJPEG(from rep: NSBitmapImageRep) throws -> Data`
  (~:83-108) — it **throws** (`throw MediaStoreError.thumbnailFailed`) rather than
  returning an optional, and uses `representation(using:properties:)`. Style template
  for the new helper; the throw-vs-optional difference is a deliberate decision below.
- Both call sites already reference `MediaStore` (`database.media` / `media`), so a new
  `static func` on `MediaStore` is reachable cross-file.

**Anti-patterns to avoid:**
- No new module/namespace. The helper lives on `MediaStore`.
- Do not invent APIs or add parameters beyond the specified signature.
- Do not touch the three legitimately-separate `NSBitmapImageRep` uses (see guards).

---

## Phase 1: Extract `MediaStore.pngData(from:)` and rewrite both call sites

### Current state (verbatim, confirmed)

**Site A** — `Sources/Clippy/Capture/ClipboardMonitor.swift`. PATHFINDER cited the
encode tail at :180-181 (correct); the enclosing private helper is :175-182:
```swift
175	    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
176	        if let png = pasteboard.data(forType: .png) { return png }
177	        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
178	        // TIFF is rarely more than ~4x the eventual PNG; skip clearly-over-cap data.
179	        guard tiff.count <= AppSettings.shared.maxImageSizeMB * 4_194_304 else { return nil }
180	        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
181	        return rep.representation(using: .png, properties: [:])
182	    }
```
- FRONT half (pasteboard-specific, KEEP): :176-179 — PNG fast-path, TIFF read, size cap.
- Shared TAIL (:180-181). Source of `tiff` here is raw `Data`, **not** an `NSImage`.
- Caller: `captureImageIfPresent(from:)` at :133-136 calls `Self.pngData(from: pasteboard)`.

**Site B** — `Sources/Clippy/Storage/ClipDatabase+Archive.swift`, inside
`upsertImportedImageClip` (:111-143). PATHFINDER cited :117-126; the encode block is :117-125:
```swift
114	        guard let raw = FileManager.default.contents(atPath: path) else { return nil }
115	        // Normalize to PNG via the imaging stack; a Clippy-exported PNG passes
116	        // through unchanged, other formats are converted.
117	        let pngData: Data
118	        if let image = NSImage(data: raw),
119	           let tiff = image.tiffRepresentation,
120	           let rep = NSBitmapImageRep(data: tiff),
121	           let png = rep.representation(using: .png, properties: [:]) {
122	            pngData = png
123	        } else {
124	            return nil
125	        }
126	        let stored = try media.store(pngData: pngData)
```
- FRONT half (file decode, KEEP): :118 (`NSImage(data: raw)`).
- Shared TAIL (:119-121). Source already has an `NSImage`.

### What to implement

**1. Add the shared tail to `MediaStore`** (next to `thumbnailJPEG`):
```swift
/// PNG bytes for an image via the AppKit imaging stack. A Clippy-exported PNG
/// passes through; other formats are normalized.
static func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}
```
`static`, non-private (cross-file callers). Returns `Data?` (see decision below).

**2. Rewrite Site A** — keep the PNG fast-path + TIFF read + size cap, then wrap the
TIFF into an `NSImage` to reach the helper:
```swift
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        // TIFF is rarely more than ~4x the eventual PNG; skip clearly-over-cap data.
        guard tiff.count <= AppSettings.shared.maxImageSizeMB * 4_194_304 else { return nil }
        guard let image = NSImage(data: tiff) else { return nil }
        return MediaStore.pngData(from: image)
    }
```

**3. Rewrite Site B** — keep `NSImage(data: raw)`, then call the helper:
```swift
        guard let raw = FileManager.default.contents(atPath: path) else { return nil }
        // Normalize to PNG via the imaging stack; a Clippy-exported PNG passes
        // through unchanged, other formats are converted.
        guard let image = NSImage(data: raw),
              let pngData = MediaStore.pngData(from: image) else { return nil }
        let stored = try media.store(pngData: pngData)
```
(Replaces the :117-125 `let pngData: Data` / `if ... else { return nil }` block; the
`media.store(pngData:)` line at :126 is unchanged.)

### Decisions (resolved, recommended)

- **Signature `pngData(from image: NSImage) -> Data?`** as specified. Site A's tail
  starts from raw TIFF `Data`, so it must `NSImage(data: tiff)` first — a tiff→NSImage→
  tiff round-trip rather than today's direct `NSBitmapImageRep(data: tiff)`. This yields
  a valid PNG but is not guaranteed byte-identical at Site A; the `swift test` round-trip
  is the correctness gate. (If byte-identity at Site A is ever required, the fallback is
  a second `Data`-input overload — not needed now, and would widen the diff.)
- **Return `Data?`, not `throws`.** Both call sites already expect an optional and use
  `else { return nil }`. Matching the specified `-> Data?` keeps the diff minimal even
  though it diverges from `thumbnailJPEG`'s throwing style. Accept the divergence.

### Verification checklist

- `swift build` — clean.
- `swift test` — image **capture** AND image **archive import** still round-trip
  (ClippyArchiveTests exercises the import path; if no test exercises the capture
  encode, add one assertion rather than assuming).
- `grep -rn 'representation(using: .png' Sources/` — exactly three hits: the new
  `MediaStore.pngData` definition plus the two call sites *referencing* `MediaStore.pngData`
  (no third inline copy of the tail remains).
- Diff is minimal: one new helper, two rewritten call sites, nothing else.

### Anti-pattern guards

- Do **not** fold in these three — different concerns, leave them exactly as-is:
  - `Sources/Clippy/Paste/PasteService.swift:31` — paste-back decode, **reverse** direction
    (PNG → `.tiff` for AppKit-only readers), not a PNG re-encode.
  - `Sources/Clippy/Support/AppIconProvider.swift:45` — builds an 8×8
    `NSBitmapImageRep(bitmapDataPlanes:...)` to average pixels for icon tint; no
    `tiffRepresentation`, no `.png` re-encode.
  - `Sources/Clippy/Storage/MediaStore.swift:104` — downscaled **JPEG** thumbnail
    (compressionFactor 0.8) via a `CGContext` resize pipeline; different output format.
- Do **not** change the pasteboard-vs-file source handling — only the identical encode
  tail is shared. Site A stays pasteboard-driven, Site B stays file-driven.

---

## Final verification

1. `swift build` clean, no new warnings.
2. `swift test` green — capture and archive-import image round-trips pass.
3. `grep -rn 'representation(using: .png' Sources/` returns the three expected hits only.
4. `grep -rn 'NSBitmapImageRep' Sources/` still shows the three separate-concern sites
   (PasteService, AppIconProvider, MediaStore JPEG) untouched.
5. Show evidence: the `swift test` summary line and both grep results.
