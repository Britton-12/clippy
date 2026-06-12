# Plan: Four low-priority de-duplication cleanups (Clippy)

Source: PATHFINDER-2026-06-11 flowcharts F1, F4, F5, F6.
Type: extract-and-delegate refactors. Behavior must stay identical; the existing
test suite (`swift test`, currently 92/92) is the gate.

Each phase is self-contained: open it in a fresh context, it carries its own
verbatim current code, target code, verification, and anti-pattern guards. Phases
are independent of each other and can run in any order or in parallel.

All line numbers below were re-verified against the working tree by read-only
explorers; where the original PATHFINDER citations were off, the corrected
numbers are used and the correction is noted inline.

---

## Phase 0: Verified facts and allowed APIs

These are confirmed from the actual source, not assumed.

**GRDB (Context7 `/groue/grdb.swift` v7.5.0):**
- `Clip.filter(Column("x") == value)` returns `QueryInterfaceRequest<Clip>`; chained
  `.filter(...)` returns the same type. `request.fetchOne(db)` returns `Clip?`.
- This codebase uses the operator form `Column("name") == value` at all 9 `filter(`
  sites in `Storage/` (never the closure form). Match that style.
- `QueryInterfaceRequest<Clip>` is the correct parameter type to carry a prebuilt
  dedupe predicate.

**AppKit imaging (already in use, no new APIs):**
- `NSColor(srgbRed:green:blue:alpha:)`, `NSBitmapImageRep(data:)`,
  `rep.representation(using: .png, properties:)`, `NSImage(data:)`,
  `image.tiffRepresentation`, `NSSavePanel`/`NSOpenPanel`. All present today.

**Types being touched:**
- `MediaStore` is a `final class`. Its image helper `thumbnailJPEG(from:)` is
  `private static func` and **throws** (`throw MediaStoreError.*`).
- `ClipDatabase` owns `dbQueue`; capture saves call `Self.evictOverCap`, imports do not.
- The three SettingsView panel handlers live on `private struct
  IntegrationsSettingsTab: View` (not `SettingsView`).

**Anti-patterns to avoid (apply to every phase):**
- No new module/namespace (no `ColorUtils`, no factory/registry/strategy object).
- No invented APIs, no added parameters beyond what each phase specifies.
- Do not merge methods that have different lifecycles (see Phase 3 guard).
- Do not touch code outside the named ranges.

---

## Phase 1: Collapse the two hex-color parsers into one (F5)

**Problem.** Two complete `#RGB`/`#RRGGBB`/`#RRGGBBAA` parsers with the same
bit-shift math, differing only in component type (`CGFloat` vs `Double`) and color
space (explicit sRGB vs SwiftUI default). That CGFloat-vs-Double split is the drift
being removed.

### Current state (verbatim)

Surviving parser — `Sources/Clippy/Support/ThemePreset.swift`, inside `extension NSColor` (:244-280):
```swift
245	    convenience init?(themeHex hex: String) {
        ... handles #RGB (/15), #RRGGBB (/255), #RRGGBBAA (alpha = low byte/255) ...
269	        self.init(srgbRed: r, green: g, blue: b, alpha: a)   // CGFloat, explicit sRGB
270	    }
```

Duplicate to delete — `Sources/Clippy/Storage/ClipKind.swift` (cited :80-93, **actually :80-111**):
```swift
80	    static func parseHexColor(_ text: String) -> Color? {
81	        guard text.hasPrefix("#") else { return nil }
        ... Double math, Scanner.scanHexInt64, 3-digit string-doubling ...
110	        return Color(red: red, green: green, blue: blue, opacity: alpha)   // Double
111	    }
```

Two `extension Color` blocks to merge into one:
- `Sources/Clippy/Support/ThemePreset.swift` :232-242 — `init(themeHex:fallback:)`
  (already a thin wrapper over `NSColor(themeHex:)`) plus `var themeHexString`.
- `Sources/Clippy/Support/Theme.swift` :277-282 — `init(hexString:)` which currently
  routes through `ClipKind.parseHexColor`:
  ```swift
  279	    init(hexString: String) {
  280	        self = ClipKind.parseHexColor(hexString) ?? Color(nsColor: .systemGray)
  281	    }
  ```

Call sites that must still compile:
- `Sources/Clippy/UI/CategoryEditorView.swift` :106 `Color(hexString: hex)`, :169
  `Color(hexString: colorHex)` — fall back to `.systemGray`.
- `Sources/Clippy/Support/ThemePreset.swift` :184-194 — 11 `Color(themeHex: ..., fallback: seed.*)`
  calls — fall back to the seed color.

### What to implement

1. **Keep `NSColor(themeHex:)` exactly as-is** (already handles alpha). It is the one parser.

2. **Gut `ClipKind.parseHexColor` to delegate** — delete the Double math, keep its
   stricter `#`-required contract:
   ```swift
   /// #RGB, #RRGGBB, or #RRGGBBAA.
   static func parseHexColor(_ text: String) -> Color? {
       guard text.hasPrefix("#"), let ns = NSColor(themeHex: text) else { return nil }
       return Color(nsColor: ns)
   }
   ```
   (`NSColor(themeHex:)` already strips the leading `#` and rejects non-hex / wrong
   length, so validation is preserved. `3/15 == 0x33/255`, so values match.)

3. **Merge the two `extension Color` blocks into the one in `ThemePreset.swift`.**
   Move `init(hexString:)` there (delegating, preserving its `.systemGray` fallback);
   delete the now-empty `extension Color` in `Theme.swift`:
   ```swift
   // in ThemePreset.swift's `extension Color`, alongside init(themeHex:fallback:)
   /// #RGB, #RRGGBB, or #RRGGBBAA; falls back to system gray.
   init(hexString: String) {
       self = ClipKind.parseHexColor(hexString) ?? Color(nsColor: .systemGray)
   }
   ```
   `init(themeHex:fallback:)` needs **no change** — it already wraps `NSColor(themeHex:)`.

   Both initializers now reach the single parser; the two call families keep their
   distinct fallbacks (`.systemGray` for category colors, `seed.*`/magenta for theme
   tokens). That fallback split is intentional, not duplication.

### Decision (resolved, recommended)

"Merge into ONE" = one `extension Color` block and one parser, not one initializer
symbol. Keeping both `init(hexString:)` and `init(themeHex:fallback:)` (each now a
one-line delegation) is correct: collapsing to a single init symbol would force the
two CategoryEditorView sites onto a magenta fallback, a visible behavior change. Do
not do that.

### Verification

- `grep -rn 'parseHexColor' Sources/` — confirm every caller still resolves (the
  delegation keeps the same signature; inventory any caller beyond `init(hexString:)`).
- `swift build` clean.
- Run the app: theme presets (GitHub Dark, Dracula, Material Dark+) render
  unchanged AND custom hex colors in Settings (ColorPicker + hex fields) render
  unchanged. The whole point is byte-identical color output across both families.
- `swift test` stays green.

### Anti-pattern guards
- Keep `themeHexString` (both the `NSColor` and `Color` forms) — it is the serializer,
  has no duplicate, stays.
- No `ColorUtils` module. The one initializer lives where the surviving parser lives
  (`ThemePreset.swift`).
- Do not change `NSColor(themeHex:)`.

---

## Phase 2: Extract the duplicated PNG re-encode tail (F1 + F6)

**Problem.** The tail `tiffRepresentation -> NSBitmapImageRep(data:) ->
representation(using: .png)` is duplicated in two ingress paths.

### Current state (verbatim)

Site A — `Sources/Clippy/Capture/ClipboardMonitor.swift` (cited :175-181; encode
tail is **:180-181**, the helper is :175-182):
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
FRONT half (pasteboard-specific, keep): :176-179. Shared TAIL: :180-181. Source of
`tiff` here is raw `Data`, **not** an `NSImage`.

Site B — `Sources/Clippy/Storage/ClipDatabase+Archive.swift` (:117-125, inside
`upsertImportedImageClip` :111-143):
```swift
117	        let pngData: Data
118	        if let image = NSImage(data: raw),
119	           let tiff = image.tiffRepresentation,
120	           let rep = NSBitmapImageRep(data: tiff),
121	           let png = rep.representation(using: .png, properties: [:]) {
122	            pngData = png
123	        } else {
124	            return nil
125	        }
```
FRONT half (file decode, keep): :118-119 (`NSImage(data: raw)`). Shared TAIL: :119-121.

### What to implement

Add to `MediaStore` (the image-domain owner), next to `thumbnailJPEG`:
```swift
/// PNG bytes for an image via the AppKit imaging stack. A Clippy-exported PNG
/// passes through; other formats are normalized.
static func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}
```
`static`, non-private (both call sites are cross-file).

Rewrite the call sites, keeping each FRONT half:
- **Site A** keeps the PNG fast-path and the TIFF read + size cap, then wraps the TIFF
  into an `NSImage` to reach the helper:
  ```swift
  guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
  guard tiff.count <= AppSettings.shared.maxImageSizeMB * 4_194_304 else { return nil }
  guard let image = NSImage(data: tiff) else { return nil }
  return MediaStore.pngData(from: image)
  ```
- **Site B** keeps `NSImage(data: raw)`, then calls the helper:
  ```swift
  guard let image = NSImage(data: raw),
        let png = MediaStore.pngData(from: image) else { return nil }
  let pngData = png
  ```

### Decisions (resolved, recommended)
- **Signature is `pngData(from image: NSImage) -> Data?`** as specified. Site A's tail
  starts from raw TIFF `Data`, so A must `NSImage(data: tiff)` first — a tiff→NSImage→
  tiff round-trip. This is not guaranteed byte-identical to A's current direct
  `NSBitmapImageRep(data: tiff)`, but it produces a valid PNG; the round-trip test is
  the correctness gate. (If a future requirement demands A stay byte-identical, the
  alternative is a `Data`-input overload — not needed now.)
- **Return `Data?`, not `throws`.** Both call sites already expect an optional; matching
  the user-specified `-> Data?` keeps the call sites minimal even though it diverges
  from `thumbnailJPEG`'s throwing style. Accept the divergence.

### Verification
- `swift test` — image **capture** AND image **archive import** must still round-trip
  (ClippyArchiveTests covers import; confirm a capture test or add an assertion if the
  capture path is untested).
- `swift build` clean. Keep the diff minimal.

### Anti-pattern guards
- Do **not** fold in `PasteService.swift:31` (PNG→TIFF, reverse direction),
  `AppIconProvider.swift:45` (8x8 rep for average color, no re-encode), or
  `MediaStore.swift:104` (downscaled JPEG). Different concerns; leave them.
- Do not change pasteboard-vs-file source handling — only the encode tail is shared.

---

## Phase 3: Unify three duplications in the GRDB storage layer (F1 + F4)

**Problem.** Three accidental duplications. Extract-and-delegate only; byte-for-byte
behavior, verified by the suite.

### 3a. One membership-map fold

Current — `Sources/Clippy/Storage/ClipDatabase+Categories.swift` (full fn :143-152):
```swift
143	    func membershipMap() throws -> [Int64: Set<Int64>] {
144	        try dbQueue.read { db in
145	            let rows = try Row.fetchAll(db, sql: "SELECT clipID, categoryID FROM clip_category")
146	            var map: [Int64: Set<Int64>] = [:]
147	            for row in rows {
148	                map[row["clipID"], default: []].insert(row["categoryID"])
149	            }
150	            return map
151	        }
152	    }
```
Byte-identical fold — `Sources/Clippy/UI/ClipStore.swift` :60-64, inside a
`ValueObservation.tracking { db -> ... }` closure (:58-66) that already has `db` in scope.

Extract into `ClipDatabase+Categories.swift` (note: the fetch throws, so the helper
**throws**):
```swift
func buildMembershipMap(_ db: Database) throws -> [Int64: Set<Int64>] {
    let rows = try Row.fetchAll(db, sql: "SELECT clipID, categoryID FROM clip_category")
    var map: [Int64: Set<Int64>] = [:]
    for row in rows {
        map[row["clipID"], default: []].insert(row["categoryID"])
    }
    return map
}
```
Then:
- `membershipMap()` body becomes `try dbQueue.read { try buildMembershipMap($0) }`.
- ClipStore closure becomes `let map = try buildMembershipMap(db)` and `return
  (categories, map)`.
  - **Confirm the call path:** verify ClipStore reaches `buildMembershipMap` through its
    `ClipDatabase` reference (instance method). If ClipStore only holds a `dbQueue` and
    not the `ClipDatabase`, make `buildMembershipMap` `static` and call
    `ClipDatabase.buildMembershipMap(db)`. Pick whichever compiles with the existing refs.
- `SettingsView.swift:614` (`try database.membershipMap()`) is unchanged — `membershipMap()`
  keeps its signature.

### 3b. One capture upsert + one dedupe predicate

Current — `Sources/Clippy/Storage/ClipDatabase.swift`. `saveCapturedClip` (:145-165)
and `saveCapturedImageClip` (:170-189) differ only in the dedupe predicate; the
bump block (:154-158 vs :178-182) and the insert+evict+`media.delete` tail (:160-164
vs :184-188) are byte-identical.
```swift
145	    func saveCapturedClip(_ clip: inout Clip, cap: Int = AppSettings.shared.maxHistoryItems) throws {
146	        let newClip = clip
147	        var evicted: [String] = []
148	        try dbQueue.write { db in
149	            if var existing = try Clip
150	                .filter(Column("contentText") == newClip.contentText)
151	                .filter(Column("contentKind") == ClipContentKind.text.rawValue)
152	                .fetchOne(db)
153	            {
154	                existing.createdAt = newClip.createdAt
155	                existing.sourceAppBundleID = newClip.sourceAppBundleID
156	                existing.sourceAppName = newClip.sourceAppName
157	                try existing.update(db)
158	                return
159	            }
160	            var inserting = newClip
161	            try inserting.insert(db)
162	            evicted = try Self.evictOverCap(db, cap: cap)
163	        }
164	        media.delete(filenames: evicted)
165	    }
```
(image variant: single `.filter(Column("mediaFilename") == newClip.mediaFilename)` at :175,
otherwise identical.)

Import predicates that must reference the SAME source — `ClipDatabase+Archive.swift`:
- text :84-86 `Column("contentText") == text` + `Column("contentKind") == .text.rawValue`
- image :128 `Column("mediaFilename") == stored.mediaFilename`

**Define each dedupe predicate once** as a static request builder on `Clip` (two
builders, because text needs `contentKind` and image does not, and import passes raw
values not a `Clip` — a single `duplicate(of: Clip)` cannot serve the import sites):
```swift
extension Clip {
    static func duplicateText(of contentText: String) -> QueryInterfaceRequest<Clip> {
        Clip.filter(Column("contentText") == contentText)
            .filter(Column("contentKind") == ClipContentKind.text.rawValue)
    }
    static func duplicateImage(mediaFilename: String?) -> QueryInterfaceRequest<Clip> {
        Clip.filter(Column("mediaFilename") == mediaFilename)
    }
}
```

**Extract the shared capture body** once:
```swift
private func upsertCaptured(_ clip: inout Clip, cap: Int,
                            matchedBy request: QueryInterfaceRequest<Clip>) throws {
    let newClip = clip
    var evicted: [String] = []
    try dbQueue.write { db in
        if var existing = try request.fetchOne(db) {
            existing.createdAt = newClip.createdAt
            existing.sourceAppBundleID = newClip.sourceAppBundleID
            existing.sourceAppName = newClip.sourceAppName
            try existing.update(db)
            return
        }
        var inserting = newClip
        try inserting.insert(db)
        evicted = try Self.evictOverCap(db, cap: cap)
    }
    media.delete(filenames: evicted)
}
```
Two thin wrappers (see 3c for the dropped default):
```swift
func saveCapturedClip(_ clip: inout Clip, cap: Int) throws {
    try upsertCaptured(&clip, cap: cap, matchedBy: Clip.duplicateText(of: clip.contentText))
}
func saveCapturedImageClip(_ clip: inout Clip, cap: Int) throws {
    try upsertCaptured(&clip, cap: cap, matchedBy: Clip.duplicateImage(mediaFilename: clip.mediaFilename))
}
```
Update the two import upserts to build their predicate via the same `Clip.duplicateText(of:)`
/ `Clip.duplicateImage(mediaFilename:)` (the `if let existing = try ....fetchOne(db)` lines).

This refines the user's single-`duplicate(of:)` suggestion to two typed builders for
correctness; it still defines each predicate exactly once and passes it as a plain
`QueryInterfaceRequest<Clip>` parameter (no registry/factory/strategy).

### 3c. Storage stops reaching the global

Remove `cap: Int = AppSettings.shared.maxHistoryItems` default from
`saveCapturedClip` (:145) and `saveCapturedImageClip` (:170) — now `cap: Int`.
The caller `ClipboardMonitor` already reads `AppSettings.shared` (e.g. :134, :137),
so update its two call sites to pass `cap` explicitly:
- `ClipboardMonitor.swift:120` `try database.saveCapturedClip(&clip)` →
  `try database.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)`
- `ClipboardMonitor.swift:157` `try database.saveCapturedImageClip(&clip)` →
  `try database.saveCapturedImageClip(&clip, cap: AppSettings.shared.maxHistoryItems)`

### Verification
- `swift test` — all 92 pass, zero behavior change (ClippyArchiveTests covers import
  upsert + dedupe; confirm capture dedupe + eviction are exercised, add an assertion if not).
- `swift build` clean. `grep -rn 'saveCapturedClip\|saveCapturedImageClip' Sources/` to
  confirm no caller still relies on the removed default.

### Anti-pattern guards
- Do **not** merge the four ingress methods. `ClipDatabase+Archive.swift:77-79`
  documents that imports deliberately skip `evictOverCap`; capture evicts, import does
  not. Only the bump/insert body (capture) and the dedupe predicate (capture+import)
  are shared.
- No registry/factory/strategy — the predicate is a plain `QueryInterfaceRequest<Clip>`
  parameter.
- Do not change eviction semantics or the import-skips-eviction behavior.

---

## Phase 4: SettingsView panel-scaffold extraction (F6) — DEFERRED, do not run now

**Precondition NOT met.** This cleanup is explicitly gated: "only do this if
SettingsView.swift is being edited for another reason." None of Phases 1-3 edit
`SettingsView.swift` (Phase 3 only *calls* the unchanged `membershipMap()` at :614).
Per the spec — "Skip entirely if not already in this file" — **skip Phase 4 in this
batch.** It is documented here so a future SettingsView edit can fold it in.

Two real complications make a naive `-> String` extraction wrong, recorded so the
future implementer does not get bitten:

1. **Two `@State` targets, not one.** `IntegrationsSettingsTab` has
   `@State exportResult: String?` (:477) and `@State archiveResult: String?` (:478).
   exportTOML/importTOML write `archiveResult`; exportJSON writes `exportResult`. The
   helper cannot bind a fixed field — the caller must assign.
2. **Silent-on-cancel.** Each handler's `guard panel.runModal() == .OK, let url else
   { return }` exits assigning nothing. A non-optional `-> String` helper would force
   the cancel path to overwrite the result field — a behavior change.

Recommended shape when this is eventually done (returns `String?`; `nil` = cancelled,
caller skips assignment; helper formats the failure string in its own catch):
```swift
private func runSavePanel(name: String, types: [UTType],
                          _ body: (URL) throws -> String) -> String? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = types
    panel.nameFieldStringValue = name
    guard panel.runModal() == .OK, let url = panel.url else { return nil }   // silent cancel
    do { return try body(url) }
    catch { return "Export failed: \(error.localizedDescription)" }
}
// caller: if let msg = runSavePanel(name: "clippy.toml", types: [...]) { archiveResult = msg }
```
`runOpenPanel(types:_:)` mirrors this (single caller: importTOML; sets
`allowsMultipleSelection = false`). Note exportJSON's nested `ExportClip`/
`ExportDocument` `Encodable` structs (:592-604) precede the panel and stay in the
body closure (or move to type scope). Confirmed ranges: exportTOML :559-571,
importTOML :573-589, exportJSON **:591-645** (PATHFINDER cited :591-644, off by one).

Anti-pattern guard: there are **no** sortOrder/junction "D8" one-liners in
`SettingsView.swift` (grep clean); exportJSON is the last member, file is 646 lines.
Nothing below the consolidation bar to avoid because nothing of that kind is present.

---

## Final verification (run after Phases 1-3)

1. `swift build` — clean, no warnings introduced.
2. `swift test` — 92/92, no behavior change.
3. Run the app and confirm theme presets + custom hex colors render unchanged (Phase 1),
   image capture works (Phase 2 + 3b), and TOML/JSON archive import round-trips (Phase 2 + 3b).
4. Grep sweep for leftovers:
   - `grep -rn 'parseHexColor' Sources/` — only the delegating definition + its callers.
   - `grep -rn 'representation(using: .png' Sources/` — only `MediaStore.pngData` plus the
     two rewritten call sites referencing it (no third inline copy).
   - `grep -rn 'SELECT clipID, categoryID FROM clip_category' Sources/` — exactly one (in
     `buildMembershipMap`).
   - `grep -rn 'AppSettings.shared.maxHistoryItems' Sources/` — no longer a default arg
     on the save methods; present at the explicit ClipboardMonitor call sites.
5. Show evidence: the `swift test` summary line and the four grep results.
