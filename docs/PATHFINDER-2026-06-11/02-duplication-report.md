# Duplication Report — Clippy

Two passes: within-feature (inside one flow) and cross-feature (spanning flows). Every claim cites >= 2 `file:line` locations. Each is classified ACCIDENTAL (unify) or LEGITIMATE SPECIALIZATION (keep).

## Verdict table

| # | Concern | Locations | Verdict | Value |
|---|---------|-----------|---------|-------|
| D1 | Membership-map builder, byte-identical | [ClipStore.swift:60-64](Sources/Clippy/UI/ClipStore.swift:60) + [ClipDatabase+Categories.swift:145-150](Sources/Clippy/Storage/ClipDatabase+Categories.swift:145) | ACCIDENTAL | High |
| D2 | Two hex color parsers behind two `Color` extensions | [ClipKind.swift:80-93](Sources/Clippy/Storage/ClipKind.swift:80) + [ThemePreset.swift:245-270](Sources/Clippy/Support/ThemePreset.swift:245); extensions [Theme.swift:277](Sources/Clippy/Support/Theme.swift:277) + [ThemePreset.swift:232](Sources/Clippy/Support/ThemePreset.swift:232) | ACCIDENTAL | High |
| D3 | PNG re-encode tail (tiff -> NSBitmapImageRep -> .png) | [ClipboardMonitor.swift:180-181](Sources/Clippy/Capture/ClipboardMonitor.swift:180) + [ClipDatabase+Archive.swift:119-121](Sources/Clippy/Storage/ClipDatabase+Archive.swift:119) | ACCIDENTAL (shared tail only) | Medium |
| D4 | Capture save twins — byte-identical bump block | [ClipDatabase.swift:145-165](Sources/Clippy/Storage/ClipDatabase.swift:145) + [ClipDatabase.swift:170-189](Sources/Clippy/Storage/ClipDatabase.swift:170) | ACCIDENTAL (within F1) | High |
| D5 | Clip dedupe predicate duplicated capture vs import | [ClipDatabase.swift:150-151,175](Sources/Clippy/Storage/ClipDatabase.swift:150) + [ClipDatabase+Archive.swift:85-87,128](Sources/Clippy/Storage/ClipDatabase+Archive.swift:85) | ACCIDENTAL (predicate only) | Medium |
| D6 | Storage layer reaches `AppSettings.shared` in default args | [ClipDatabase.swift:145](Sources/Clippy/Storage/ClipDatabase.swift:145) + [ClipDatabase.swift:170](Sources/Clippy/Storage/ClipDatabase.swift:170) | ACCIDENTAL (storage seam) | Medium |
| D7 | NSSavePanel/NSOpenPanel + guard + catch-to-result scaffold | [SettingsView.swift:559-571](Sources/Clippy/UI/SettingsView.swift:559) + [:573-589](Sources/Clippy/UI/SettingsView.swift:573) + [:591-644](Sources/Clippy/UI/SettingsView.swift:591) | ACCIDENTAL (within F6) | Medium |
| D8 | next-sortOrder query + clip_category INSERT/DELETE pair | [ClipDatabase+Categories.swift:35,88](Sources/Clippy/Storage/ClipDatabase+Categories.swift:35) + [:105/110,128/133](Sources/Clippy/Storage/ClipDatabase+Categories.swift:105) | ACCIDENTAL (low value) | Low |
| L1 | Four clip-ingress methods (capture vs import) | [ClipDatabase.swift:145,170](Sources/Clippy/Storage/ClipDatabase.swift:145) + [ClipDatabase+Archive.swift:80,111](Sources/Clippy/Storage/ClipDatabase+Archive.swift:80) | LEGITIMATE (lifecycle: cap-bounded vs cap-exempt) | — |
| L2 | `Clip(...)` struct literals | [ClipboardMonitor.swift:109,141](Sources/Clippy/Capture/ClipboardMonitor.swift:109) + [ClipDatabase+Archive.swift:95,131](Sources/Clippy/Storage/ClipDatabase+Archive.swift:95) | LEGITIMATE (trust model / data source differ) | — |
| L3 | Date formatting (TOML ISO / JSON .iso8601 / relative buckets) | [ClippyArchive.swift:115](Sources/Clippy/Storage/ClippyArchive.swift:115) + [SettingsView.swift:638](Sources/Clippy/UI/SettingsView.swift:638) + [ClipListView.swift:199](Sources/Clippy/UI/ClipListView.swift:199) | LEGITIMATE (3 distinct output targets) | — |
| L4 | `setClip` membership write | [ClipDatabase+Categories.swift:101](Sources/Clippy/Storage/ClipDatabase+Categories.swift:101) reused by [ClipStore.swift:114,118](Sources/Clippy/UI/ClipStore.swift:114) + [ClippyArchive.swift:225,234](Sources/Clippy/Storage/ClippyArchive.swift:225) | LEGITIMATE — correctly centralized (the model D1 should follow) | — |

## Detail on the accidental finds

**D1 — Membership map (strongest).** The same three lines (`SELECT clipID, categoryID FROM clip_category` -> fold into `[Int64: Set<Int64>]`) exist character-for-character in two places. A reusable `membershipMap()` already exists and is consumed by [SettingsView.swift:614](Sources/Clippy/UI/SettingsView.swift:614); `ClipStore` reimplemented it inline only because its copy runs against the `db` handle inside a `ValueObservation.tracking` closure. The fold loop, not the read wrapper, is the unifiable unit.

**D2 — Two hex parsers.** Two complete `#RGB`/`#RRGGBB`/`#RRGGBBAA` parsers with the same bit-shift math, each backing a different `extension Color` initializer (`Color(hexString:)` via `ClipKind.parseHexColor`; `Color(themeHex:)` via `NSColor(themeHex:)`). Split-brain: "how does Color parse hex" has two answers. Drift risk is real (alpha handled in CGFloat vs Double).

**D3 — PNG re-encode.** Source halves differ legitimately (live pasteboard TIFF vs file read with `NSImage(data:)`), but the tail `tiffRepresentation -> NSBitmapImageRep -> .png representation` is identical. Note `MediaStore.store` decodes the bytes a third time at [MediaStore.swift:37](Sources/Clippy/Storage/MediaStore.swift:37).

**D4 — Capture save twins.** `saveCapturedClip` and `saveCapturedImageClip` differ only in the dedupe predicate; the 4-line "bump existing row" block ([:154-157](Sources/Clippy/Storage/ClipDatabase.swift:154) vs [:178-181](Sources/Clippy/Storage/ClipDatabase.swift:178)) is byte-identical, as is the insert+evict+media.delete tail.

**D5/D6/D7/D8** are smaller seams documented in the table; see citations.

## What is NOT duplication (do not touch)

L1, L2, L3, L4 are legitimate. The four ingress methods serve different lifecycles (captured clips are transient and cap-bounded; imported clips are about to be categorized and cap-exempt, [ClipDatabase+Archive.swift:78-79](Sources/Clippy/Storage/ClipDatabase+Archive.swift:78)). The `Clip(...)` literals diverge by trust model (capture stamps the live front app + `Date()`; import preserves archive-supplied nil bundle ID, title, and timestamp). Forcing these into one factory would need so many parameters it would not reduce surface area.

## Confidence + gaps

High confidence on D1-D5 and the L-classifications (write paths, parsers, and construction sites read in full). Not exhaustively read: large SwiftUI bodies (`ClipListView`, `ClipCardView`) where line-level ripgrep could miss view-builder repeats; `AppIconProvider`, `CaptureSound`/`SoundCatalog`, `HotKeyCenter`, `CaretLocator` internals (symbol-scan only, no within-flow dup surfaced). The `.shared` count (29) is a raw grep total; the "unify" verdict applies specifically to the two storage-layer default arguments, not blanket removal.
