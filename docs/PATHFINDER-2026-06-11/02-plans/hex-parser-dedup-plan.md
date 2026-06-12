# Plan: Collapse the two hex-color parsers into one (F5)

Source: PATHFINDER-2026-06-11 flowchart F5-settings-and-theming.
Type: single extract-and-delegate refactor. Color output must stay identical for both
call families; gate is `swift build` + a visual check (theme presets and custom hex
colors in Settings render unchanged).

Two complete `#RGB`/`#RRGGBB`/`#RRGGBBAA` parsers exist with the same bit-shift math,
differing only in component type (`CGFloat` vs `Double`) and color-space construction
(explicit sRGB vs SwiftUI default). That split is the drift being removed. Keep
`NSColor(themeHex:)` as the one parser; make everything else reach it.

All line numbers verified read-only against the working tree. PATHFINDER's citations
were off in several places; corrected numbers are used and the correction is noted.

---

## Phase 0: Verified facts and allowed APIs

Confirmed from source, not assumed.

**The surviving parser** — `Sources/Clippy/Support/ThemePreset.swift`, in
`extension NSColor` (:244-280), cited :245-270, **confirmed :245-270**:
```swift
245	    convenience init?(themeHex hex: String) {
246	        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
247	        if s.hasPrefix("#") { s.removeFirst() }
248	        guard let value = UInt64(s, radix: 16) else { return nil }
249	        let r, g, b, a: CGFloat
250	        switch s.count {
251	        case 3:   r = CGFloat((value >> 8) & 0xF)/15; g = CGFloat((value >> 4) & 0xF)/15; b = CGFloat(value & 0xF)/15; a = 1
256	        case 6:   r = CGFloat((value >> 16) & 0xFF)/255; g = CGFloat((value >> 8) & 0xFF)/255; b = CGFloat(value & 0xFF)/255; a = 1
261	        case 8:   r = ...>>24; g = ...>>16; b = ...>>8; a = CGFloat(value & 0xFF)/255
266	        default:  return nil
268	        }
269	        self.init(srgbRed: r, green: g, blue: b, alpha: a)
270	    }
```
- Handles alpha (`case 8`), strips an optional leading `#`, rejects non-hex / wrong
  length (returns `nil`). `CGFloat`, explicit sRGB.

**The duplicate to gut** — `Sources/Clippy/Storage/ClipKind.swift`, cited :80-93,
**actually :80-111** (the citation truncated the function; full body is :80-111, doc
comment :79):
```swift
80	    static func parseHexColor(_ text: String) -> Color? {
81	        guard text.hasPrefix("#") else { return nil }
        ... Scanner.scanHexInt64, 3-digit string-doubling, Double math ...
110	        return Color(red: red, green: green, blue: blue, opacity: alpha)   // Double, default color space
111	    }
```
- Returns SwiftUI `Color?` directly, `Double` components. Also handles alpha. Stricter
  contract: requires a leading `#` (returns nil without it).
- Note: 3-digit handling differs mechanically (string-double then `/255`) but is
  numerically equal to NSColor's `/15` (`0x33/255 == 3/15`).

**The two `extension Color` blocks to merge into one:**
- `ThemePreset.swift` :232-242 — cited :232-238 (the citation starts at the
  `extension Color {` line; the init body is :235-238):
  ```swift
  232	extension Color {
  235	    init(themeHex hex: String, fallback: Color = Color(red: 1, green: 0, blue: 1)) {
  236	        guard let ns = NSColor(themeHex: hex) else { self = fallback; return }
  237	        self = Color(nsColor: ns)
  238	    }
  240	    var themeHexString: String { NSColor(self).themeHexString }   // serializer — KEEP
  242	}
  ```
  `init(themeHex:fallback:)` already delegates to `NSColor(themeHex:)`. No change needed.
- `Theme.swift` :277-282 — cited :279-280 (body :279-281):
  ```swift
  277	extension Color {
  279	    init(hexString: String) {
  280	        self = ClipKind.parseHexColor(hexString) ?? Color(nsColor: .systemGray)
  281	    }
  282	}
  ```
  Routes through the `Double` parser, and falls back to `.systemGray`.

**The serializer to keep** (no duplicate): `NSColor.themeHexString` — cited :273-279,
**confirmed :273-279** (doc comment :272), RGB-only output. Plus the `Color`
forwarder `var themeHexString` (ThemePreset.swift :240-241). Both stay.

**Call sites that must still compile (both labels must survive):**
- `Sources/Clippy/UI/CategoryEditorView.swift` — path is `UI/`, not `Views/`.
  - :106 `.fill(Color(hexString: hex))`
  - :169 `... AnyShapeStyle(Color(hexString: colorHex).opacity(0.25)) ...`
  Both rely on the `.systemGray` fallback.
- `Sources/Clippy/Support/ThemePreset.swift` :184-194 — 11
  `Color(themeHex: s.custom*Hex, fallback: seed.*)` calls inside
  `customTokens(_:)`. Rely on the `seed.*` fallback.

**Anti-patterns:**
- No `ColorUtils` module/namespace. The one initializer lives where the surviving
  parser lives (`ThemePreset.swift`).
- Do not change `NSColor(themeHex:)`. Do not delete `themeHexString`.

---

## Phase 1: Delegate the Double parser, merge into one `extension Color` block

### What to implement

**1. Gut `ClipKind.parseHexColor` to delegate** — delete the Double math, keep its
stricter `#`-required contract:
```swift
/// #RGB, #RRGGBB, or #RRGGBBAA.
static func parseHexColor(_ text: String) -> Color? {
    guard text.hasPrefix("#"), let ns = NSColor(themeHex: text) else { return nil }
    return Color(nsColor: ns)
}
```
`NSColor(themeHex:)` already strips the leading `#` and validates length/hex, so the
nil-on-invalid behavior is preserved. After this, both families parse through one place.

**2. Merge the two `extension Color` blocks into the one in `ThemePreset.swift`.**
Move `init(hexString:)` there (next to `init(themeHex:fallback:)` and `themeHexString`),
preserving its `.systemGray` fallback, and **delete the now-empty `extension Color`
in `Theme.swift`**:
```swift
// in ThemePreset.swift's existing `extension Color`
/// #RGB, #RRGGBB, or #RRGGBBAA; falls back to system gray.
init(hexString: String) {
    self = ClipKind.parseHexColor(hexString) ?? Color(nsColor: .systemGray)
}
```
`init(themeHex:fallback:)` and both `themeHexString` accessors are unchanged.

After this both initializers reach the single `NSColor(themeHex:)` parser
(`hexString` via the now-delegating `parseHexColor`, `themeHex` directly), and the
`Double`/default-color-space path is gone — so both call families produce
byte-identical colors (CGFloat sRGB → `Color(nsColor:)`).

### Decision (resolved, recommended)

"Merge the two `extension Color` initializers into ONE" reads as **one `extension Color`
block and one parser**, not one init *symbol*. Both `init(hexString:)` and
`init(themeHex:fallback:)` must survive because the spec itself lists both
`Color(hexString:)` (CategoryEditorView) and `Color(themeHex:)` (theme path) as call
sites that must compile, and the two carry deliberately different fallbacks
(`.systemGray` for category colors, `seed.*`/magenta for theme tokens). Collapsing to a
single init symbol would force the two CategoryEditorView sites onto a magenta fallback
— a visible behavior change. Do not do that. The duplication being removed is the
parsing **math**, not the init count.

### Before editing — one grep that affects step 2

`grep -rn 'parseHexColor' Sources/` to inventory callers. If `init(hexString:)` is the
only caller, keeping it routed through the delegating `parseHexColor` is still correct
(the spec says "make parseHexColor delegate," i.e. keep it). If there are other callers,
they automatically benefit from the delegation. Either way `parseHexColor` stays and
delegates; do not delete it.

### Verification checklist

- `grep -rn 'parseHexColor' Sources/` — every caller still resolves; the only math now
  lives in `NSColor(themeHex:)`.
- `grep -rn 'extension Color' Sources/Clippy/Support/Theme.swift` — gone (the block was
  moved out).
- `swift build` — clean.
- Run the app and confirm color output is unchanged:
  - Theme presets (GitHub Dark, Dracula, Material Dark+) render identically.
  - Custom hex colors in Settings (ColorPicker + hex text fields, the 11 `customTokens`
    paths) render identically.
  - A category color via `Color(hexString:)` renders identically, and a bad/empty hex
    still falls back to system gray (not magenta).
- `swift test` stays green.

### Anti-pattern guards

- Keep `NSColor.themeHexString` and `Color.themeHexString` — serializers, no duplicate.
- No `ColorUtils` module. The one initializer block lives in `ThemePreset.swift`.
- Do not touch `NSColor(themeHex:)`. Do not change either fallback policy
  (`.systemGray` vs `seed.*`/magenta) — that split is intentional, not duplication.

---

## Final verification

1. `swift build` clean, no new warnings.
2. Grep proof:
   - `grep -rn 'extension Color' Sources/` — a single block (in `ThemePreset.swift`).
   - No `Double` hex bit-shift math remains in `ClipKind.swift` (`parseHexColor` is the
     two-line delegation).
3. Run the app: theme presets + custom hex colors look unchanged; bad hex → system gray
   for category colors, → seed/magenta for theme tokens.
4. `swift test` green.
5. Show evidence: the grep results and the `swift build` / `swift test` summary lines.
