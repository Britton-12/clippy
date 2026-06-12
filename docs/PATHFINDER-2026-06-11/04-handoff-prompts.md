# Handoff Prompts — Clippy Unification

One ready-to-run `/make-plan` prompt per unified system. Copy a fenced block directly into `/make-plan`. Ship in the order listed (storage first — it is the highest-value, lowest-risk consolidation). Each is independent; none requires the others.

---

## System 1 — Storage ingress & membership dedup (U1, U4, U5)

```
/make-plan Unify three accidental duplications in Clippy's GRDB storage layer at /Users/jerry/Downloads/clippy. Reference flowcharts: PATHFINDER-2026-06-11/01-flowcharts/F1-capture-pipeline.md and F4-categories.md. This is an extract-and-delegate refactor only — behavior must be byte-for-byte identical, verified by the existing test suite.

Three changes:

1. ONE membership-map fold. The block `SELECT clipID, categoryID FROM clip_category` folded into [Int64: Set<Int64>] is byte-identical in two places: Sources/Clippy/Storage/ClipDatabase+Categories.swift:145-150 (membershipMap()) and Sources/Clippy/UI/ClipStore.swift:60-64 (category ValueObservation closure). Extract `func buildMembershipMap(_ db: Database) -> [Int64: Set<Int64>]` in ClipDatabase+Categories.swift taking an open Database handle. Rewrite membershipMap() to `dbQueue.read { buildMembershipMap($0) }`. Rewrite the ClipStore observation closure (which already has `db`) to call it. Confirm SettingsView.swift:614 still works through membershipMap().

2. ONE capture upsert + ONE dedupe predicate. saveCapturedClip (ClipDatabase.swift:145-165) and saveCapturedImageClip (ClipDatabase.swift:170-189) differ only in the dedupe predicate; the bump-existing block (:154-157 vs :178-181) and the insert+evictOverCap+media.delete tail are byte-identical. Extract a private `upsertCaptured(_ clip: inout Clip, cap: Int, matchedBy: QueryInterfaceRequest<Clip>)` holding that body once; make the two save methods thin wrappers. Separately, define the dedupe predicate ONCE (e.g. a `Clip.duplicate(of:)` returning the text predicate `contentText`+`contentKind==.text` or the image predicate `mediaFilename`) and reference it from BOTH the capture upsert AND the import upserts at ClipDatabase+Archive.swift:85-87 and :128.

3. Storage stops reaching the global. Remove the `cap: Int = AppSettings.shared.maxHistoryItems` default argument from saveCapturedClip/saveCapturedImageClip (ClipDatabase.swift:145, :170). The caller ClipboardMonitor (already reads AppSettings) passes cap explicitly.

HARD CONSTRAINTS / anti-pattern guards:
- Do NOT merge the four ingress methods (saveCapturedClip, saveCapturedImageClip, upsertImportedTextClip, upsertImportedImageClip) into one. They have legitimately different lifecycles: captured clips run evictOverCap; imported clips deliberately skip it (see ClipDatabase+Archive.swift:78-79). Only the bump/insert body (capture) and the dedupe predicate (capture+import) are shared.
- Do NOT introduce a registry, factory, or strategy object — pass the predicate as a plain parameter.
- Do NOT change the eviction semantics or the import-skips-eviction behavior.
- Verify with `swift test` (the repo has ClippyArchiveTests, StatusBarIconTests, etc.); all tests must pass with no behavior change.
```

---

## System 2 — Single PNG re-encode helper (U3)

```
/make-plan Remove a duplicated PNG re-encode tail in Clippy at /Users/jerry/Downloads/clippy. Reference flowcharts: PATHFINDER-2026-06-11/01-flowcharts/F1-capture-pipeline.md and F6-archive-import-export.md.

The tail `tiffRepresentation -> NSBitmapImageRep(data:) -> representation(using: .png)` is duplicated at Sources/Clippy/Capture/ClipboardMonitor.swift:180-181 and Sources/Clippy/Storage/ClipDatabase+Archive.swift:119-121. Extract one helper `MediaStore.pngData(from image: NSImage) -> Data?` (MediaStore is the image domain owner, Sources/Clippy/Storage/MediaStore.swift). 

Rewrite both call sites to keep their source-specific FRONT half and call the shared tail:
- ClipboardMonitor.swift:175-181 keeps reading the pasteboard TIFF, then calls the helper.
- ClipDatabase+Archive.swift:117-126 keeps `NSImage(data: raw)` from the file, then calls the helper.

HARD CONSTRAINTS / anti-pattern guards:
- Do NOT fold in the NSBitmapImageRep uses at PasteService.swift:31 (paste-back decode), AppIconProvider.swift:45 (icon tint), or MediaStore.swift:104 (JPEG thumbnail). Those are different concerns and are legitimately separate.
- Do NOT change the pasteboard-vs-file source handling — only the identical encode tail is shared.
- This is small; keep the diff minimal. Verify image capture AND image archive import still round-trip with `swift test`.
```

---

## System 3 — Single hex color parser (U2)

```
/make-plan Collapse two duplicate hex color parsers in Clippy at /Users/jerry/Downloads/clippy into one. Reference flowchart: PATHFINDER-2026-06-11/01-flowcharts/F5-settings-and-theming.md.

There are two complete #RGB/#RRGGBB/#RRGGBBAA parsers with the same bit-shift math, each behind its own `extension Color` initializer:
- Theme family: NSColor(themeHex:) at Sources/Clippy/Support/ThemePreset.swift:245-270, themeHexString at :273-279, and Color(themeHex:fallback:) at :232-238.
- ClipKind family: ClipKind.parseHexColor at Sources/Clippy/Storage/ClipKind.swift:80-93, and Color(hexString:) at Sources/Clippy/Support/Theme.swift:279-280.

Keep NSColor(themeHex:) as the single parser (it already handles alpha). Make ClipKind.parseHexColor delegate to it and delete the duplicate math. Merge the two `extension Color` initializers (Theme.swift:277 and ThemePreset.swift:232) into ONE that preserves the `fallback:` parameter the theme path needs. Confirm all call sites compile: CategoryEditorView.swift:106,169 (Color(hexString:)) and the ThemePreset.swift:184-194 theme path (Color(themeHex:)).

HARD CONSTRAINTS / anti-pattern guards:
- Keep themeHexString (the serializer) — it has no duplicate and stays.
- Watch the alpha detail: one parser uses CGFloat, the other Double. The merged parser must produce identical colors for both call families — that style split is exactly the drift being removed.
- Do NOT add a new ColorUtils module or namespace; put the one initializer where the surviving parser lives.
- Verify the app builds and themes render (build, then run; theme presets + custom hex colors in Settings must look unchanged).
```

---

## System 4 — Save/open panel runner (U6, optional)

```
/make-plan Optional low-priority cleanup in Clippy at /Users/jerry/Downloads/clippy. Reference flowchart: PATHFINDER-2026-06-11/01-flowcharts/F6-archive-import-export.md. Only do this if SettingsView.swift is being edited for another reason.

The scaffold (configure NSSavePanel/NSOpenPanel + `guard runModal() == .OK, let url` + `do { ... } catch { result = "...failed: \(error.localizedDescription)" }`) is repeated three times: exportTOML (Sources/Clippy/UI/SettingsView.swift:559-571), importTOML (:573-589), exportJSON (:591-644). Extract `runSavePanel(name:types:_ body: (URL) throws -> String) -> String` and `runOpenPanel(types:_ body: (URL) throws -> String) -> String` private helpers; each handler keeps its serialization body and loses the scaffold.

HARD CONSTRAINTS / anti-pattern guards:
- Keep the three handlers' serialization logic distinct (TOML hand-write, TOML parse+upsert, JSON encode) — only the panel/guard/catch scaffold is shared.
- Do NOT also touch the sortOrder/junction one-liners (D8) — below the consolidation bar.
- Skip entirely if not already in this file. Verify export and import still work end-to-end.
```
