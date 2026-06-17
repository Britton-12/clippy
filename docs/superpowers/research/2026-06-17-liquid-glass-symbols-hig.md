# macOS 26 (Tahoe) SwiftUI Design Modernization Reference

Scope: native SwiftUI menubar/utility app. Grounded in Apple SwiftUI docs (via Context7 index of developer.apple.com/documentation/swiftui) and the iOS/macOS 26 Liquid Glass adoption skill. Availability tags below come from the Apple symbol-availability metadata. The HIG HTML pages are SPA-rendered (plain fetch returns title only); HIG points below are corroborated against the SwiftUI API docs and the adoption skill rather than scraped prose, so treat HIG-specific spacing numbers as directional and confirm against the live HIG in Xcode 26 docs.

Verified-source legend: [API] = Apple SwiftUI doc (signature + availability confirmed); [skill] = iOS/macOS 26 Liquid Glass adoption skill; [unverified] = could not scrape live HIG prose, stated from API behavior.

---

## 1. Liquid Glass in SwiftUI

`.glassEffect(_:in:)` is the core entry point. Availability: iOS 26.0+ / macOS 26.0+ / iPadOS 26 / Mac Catalyst 26 / tvOS 26 / watchOS 26. [API]

```swift
// Signature [API]
func glassEffect(_ glass: Glass = .regular,
                 in shape: some Shape = DefaultGlassEffectShape()) -> some View
// DefaultGlassEffectShape is a Capsule. The glass is anchored to the view's
// bounds and fills the whole frame, INCLUDING padding.
```

```swift
Text("Hello").font(.title).padding().glassEffect()                       // default capsule
Text("Hello").padding().glassEffect(in: .rect(cornerRadius: 16))         // custom shape
Text("Hello").padding().glassEffect(.regular.tint(.orange).interactive())// tinted + interactive
```
Source: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views and https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)

`Glass` configuration [API/skill]:
- Variants: `.regular` (default), `.clear`, `.identity`.
- `.tint(_:)` adds a color, `.interactive()` makes it respond to touch/pointer.
- Chainable: `.regular.tint(.blue).interactive()`.

`GlassEffectContainer` (iOS/macOS 26.0+) [API/skill]: groups multiple glass shapes so they share one sampling region and blend/morph correctly. Without it, adjacent glass surfaces sample independently and look inconsistent.
```swift
GlassEffectContainer(spacing: 16) {
    HStack(spacing: 16) {
        Button("One") {}.glassEffect()
        Button("Two") {}.glassEffect()
    }
}
```
Source: https://developer.apple.com/documentation/swiftui/glasseffectcontainer

`glassEffectID(_:in:)` (iOS/macOS 26.0+) [API]: associates an identity inside a `GlassEffectContainer` so SwiftUI morphs shapes into each other across transitions.
```swift
// Signature [API]
func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
```
```swift
@State private var isExpanded = false
@Namespace private var namespace
GlassEffectContainer(spacing: 40) {
    HStack(spacing: 40) {
        Image(systemName: "scribble.variable").frame(width: 80, height: 80)
            .glassEffect().glassEffectID("pencil", in: namespace)
        if isExpanded {
            Image(systemName: "eraser.fill").frame(width: 80, height: 80)
                .glassEffect().glassEffectID("eraser", in: namespace)
        }
    }
}
Button("Toggle") { withAnimation { isExpanded.toggle() } }.buttonStyle(.glass)
```
Source: https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)

`.buttonStyle(.glass)` and `.buttonStyle(.glass(_:))` (iOS/macOS 26.0+) [API]: applies a context-aware Liquid Glass button style. `.glass(_:)` takes a `Glass` config, e.g. `.buttonStyle(.glass(.clear))`.
Source: https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass(_:)

Glass vs Material — when to use which [skill]:
- Liquid Glass: foreground/interactive chrome that floats over content (toolbars, bars, controls, badges, floating action clusters). It is dynamic, refracts and reflects, and is meant to be sparse.
- Material (`.ultraThinMaterial` etc.): background separation layers behind content (panels, cards, list backgrounds, legibility scrims). Use as the pre-26 fallback for glass.
- Rule of thumb: glass = controls layer; material = background layer. Do not stack glass on glass outside a container.

Automatic adoption on macOS 26 [skill/API]:
- Standard `.toolbar`, sidebars (`NavigationSplitView`), sheets, `.inspector`, and `MenuBarExtra(.window)` chrome adopt Liquid Glass automatically when the app builds against the macOS 26 SDK. You usually do NOT hand-apply `.glassEffect` to those. Reserve manual `.glassEffect` for custom floating controls.

---

## 2. Materials

`Material` hierarchy (thin -> thick scale) [API]:
`.ultraThin`, `.thin`, `.regular`, `.thick`, `.ultraThick`, plus `.bar` (matches system toolbars).
Source: https://developer.apple.com/documentation/swiftui/material

Apply via background modifiers [API]:
```swift
Label("Flag", systemImage: "flag.fill").padding().background(.regularMaterial)
// shaped material:
view.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
// safe-area control: background(_:ignoresSafeAreaEdges:)
```
Notes [API]: a material is not a view; it inserts a translucent frosted layer (platform blend, not plain opacity). Foreground content gets automatic vibrancy. Setting a custom `foregroundStyle(_:)` (other than the hierarchical styles like `.secondary`) DISABLES vibrancy — keep `.secondary`/`.tertiary` for vibrant text on material.

`backgroundExtensionEffect()` [skill]: extends/mirrors the underlying content behind the bar/sidebar region so edge-to-edge content reads through the glass/material rather than abruptly clipping. Used for full-bleed hero imagery under translucent chrome (the Landmarks sample pattern). (Live API page 404'd on direct slug; confirm exact signature in Xcode 26 docs.)

Scroll edge effects [skill]: `scrollEdgeEffectStyle(_:for:)` adds a soft blur/fade where scrolling content meets the bar.
```swift
ScrollView { /* content */ }
    .scrollEdgeEffectStyle(.soft, for: .top)   // styles: .soft, .hard (and .automatic)
```

Deprecated / discouraged now [skill/API]:
- Do NOT chase the visual with manual `.opacity` + blur stacks; use `Material` or glass.
- Avoid `.thickMaterial` as a default panel — prefer `.regular`/`.thin` so content stays legible; reserve thick for heavy overlays.
- On macOS 26, hand-built translucent toolbar backgrounds are redundant: let the system glass toolbar render. `.toolbarBackground(...)` is for opting OUT of/overriding, not for re-creating glass.
- `WindowStyle.plain` (macOS 15.0+) opts a window OUT of the default chrome/glass — use only when you fully custom-draw.

---

## 3. SF Symbols 7 (symbolEffect)

Two trigger forms [API]:
```swift
// Indefinite effect, toggled by isActive (iOS17/macOS14+ base API)
func symbolEffect<T>(_ effect: T, options: SymbolEffectOptions = .default,
                     isActive: Bool = true) -> some View
// Discrete effect, fires each time `value` changes
func symbolEffect<T, U: Equatable>(_ effect: T, options: SymbolEffectOptions = .default,
                                   value: U) -> some View
```
```swift
Image(systemName: "bolt.slash.fill").symbolEffect(.pulse)             // indefinite
Image(systemName: "folder.fill").symbolEffect(.bounce, value: counter) // discrete
```
Source: https://developer.apple.com/documentation/swiftui/view/symboleffect(_:options:isactive:)

Effect availability:
- `.variableColor`, `.pulse`, `.bounce`, `.appear`, `.disappear`, `.scale` — iOS 17 / macOS 14+ (SF Symbols 5/6 era). [API]
- `.replace` (Magic Replace) — content transition, iOS 17 / macOS 14+; SF Symbols 7 improves continuity so matching sub-elements (badges, slashes) morph instead of cross-fading. [API]
  ```swift
  Image(systemName: isOn ? "speaker.wave.3" : "speaker.slash")
      .contentTransition(.symbolEffect(.replace))
  ```
- `.drawOn` / `.drawOff` (DrawOn/DrawOffSymbolEffect) — NEW in SF Symbols 7, iOS 26 / macOS 26+. Animates the symbol's strokes drawing in/out; used as a transition. [API/skill]
  ```swift
  Image(systemName: "checkmark.circle")
      .transition(.symbolEffect(.drawOn))   // DrawOn / DrawOff
  ```
  `SymbolEffectTransition` enumerates Appear, Disappear, DrawOn, DrawOff. [API]
- `.breathe`, `.wiggle`, `.rotate` — newer continuous effects (SF Symbols 7 / 26 generation). Treat as iOS 26 / macOS 26 for safety and gate with `#available`. [skill]
  ```swift
  Image(systemName: "bell").symbolEffect(.wiggle)
  Image(systemName: "arrow.trianglehead.clockwise").symbolEffect(.rotate)
  Image(systemName: "heart").symbolEffect(.breathe)
  ```

`symbolRenderingMode(_:)` [API/skill]:
```swift
Image(systemName: "star.fill")
    .symbolRenderingMode(.hierarchical)   // single hue, layered opacity
    .symbolRenderingMode(.palette)        // explicit per-layer colors
    .symbolRenderingMode(.multicolor)     // symbol's own brand colors
    .symbolRenderingMode(.monochrome)     // flat single color
```
Palette + gradient on symbols [skill]: pass multiple styles to `.foregroundStyle(_:_:_:)` for palette mode; gradients work as a fill:
```swift
Image(systemName: "person.crop.circle.badge.plus")
    .symbolRenderingMode(.palette)
    .foregroundStyle(.white, .blue.gradient)
```
`renderingMode(.original)` keeps a symbol's built-in colors; `.template` forces tinting. Source: https://developer.apple.com/documentation/swiftui/image/renderingmode(_:)

`symbolEffectsRemoved(_:)` [API]: strip inherited symbol effects from a subtree.

---

## 4. HIG for macOS 26 menubar / utility apps

Menubar app scene wiring [skill/API]:
```swift
MenuBarExtra("Status", systemImage: "chart.bar") { DashboardView() }
    .menuBarExtraStyle(.window)   // popover-style panel; .menu = classic dropdown
```
- `.menuBarExtraStyle(.window)` gives a real SwiftUI popover panel (custom content, scroll, grids). `.menu` is the classic list-of-commands dropdown. [skill/API]
- The popover chrome adopts Liquid Glass automatically on macOS 26 — do not paint your own glass background on it. [skill]
Source: https://developer.apple.com/documentation/swiftui/menubarextra

Utility / floating panels [skill]:
```swift
UtilityWindow("Photo Info", id: "photo-info") { PhotoInfoViewer() }  // floating tool palette
```
`UtilityWindow` is a non-activating floating panel scene for tool palettes/inspectors; pairs with `@FocusedValue` to track the focused main window.

Settings window [skill/API]:
```swift
Settings { SettingsView() }   // standard macOS Settings scene
```
Use the `Settings` scene rather than a hand-rolled window so it docks under the app menu and gets system chrome/glass.

Sidebar + inspector patterns [skill/API]:
```swift
NavigationSplitView { Sidebar() } detail: { Detail() }   // sidebar gets glass on 26
content.inspector(isPresented: $show) {                  // trailing inspector
    InspectorView().inspectorColumnWidth(min: 200, ideal: 250, max: 400)
}
```
Inspector is a trailing-edge supplementary panel, toggled from the toolbar.

Concentric corner radii [skill/API]:
```swift
Button("Confirm") {}.clipShape(.rect(cornerRadius: 12, style: .concentric))
```
- `RoundedRectangle`/`.rect` accepts `style: .concentric` so a nested control's corners stay concentric with its container's corner — the macOS 26 design language (controls hug their glass container). Prefer concentric over guessing radii. [skill]
- `containerRelativeFrame(_:)` for sizing relative to the container instead of `GeometryReader`. [skill]

Spacing / layout [unverified — confirm against live HIG]:
- Keep menubar popovers compact; prefer system control spacing (8/12/16 pt rhythm) and let glass/material provide separation instead of hairlines.
- Don't crowd glass: glass needs breathing room and a `GlassEffectContainer` spacing value to blend.

---

## 5. Liquid Glass migration gotchas

- Over-applying glass [skill]: glass is for the controls/chrome layer only, sparingly. Glass-on-glass, or glassing entire content panes, kills the effect and legibility. Use `Material` for backgrounds, glass for floating controls.
- Missing `GlassEffectContainer` [skill]: independent `.glassEffect` views sample the background separately and blend inconsistently; group related glass in one container with a `spacing:` value. The container is also where morphing (`glassEffectID`) works.
- Performance [skill]: each glass sampling region has cost. Batch sibling glass into one `GlassEffectContainer` instead of many standalone ones; avoid deeply nested containers and animating large glass regions every frame.
- Accessibility / Reduce Transparency [skill]: under Reduce Transparency (and Increase Contrast), glass and materials fall back to more opaque/solid surfaces. Verify your foreground contrast holds in BOTH states; don't rely on the blur for separation. Keep hierarchical foreground styles (`.secondary`) so vibrancy/contrast adapts.
- Don't disable vibrancy unintentionally [API]: a custom `foregroundStyle` on material content turns off vibrancy; prefer the hierarchical styles for legible text over glass/material.
- Version gating [skill]: glass APIs are 26.0-only. Gate and provide a `Material` fallback:
  ```swift
  if #available(macOS 26, *) { view.glassEffect(.regular, in: shape) }
  else { view.background(.ultraThinMaterial, in: shape) }
  ```
  A reusable `glassEffectWithFallback(_:in:fallbackMaterial:)` view extension keeps call sites clean.
- Let the system do the chrome [skill/API]: on macOS 26, toolbars/sidebars/sheets/inspector/`MenuBarExtra(.window)` already render glass when built on the 26 SDK. Manually reglassing them is redundant and can double-render. Reserve manual glass for genuinely custom floating UI.

---

## Sources
- https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)
- https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass(_:)
- https://developer.apple.com/documentation/swiftui/material
- https://developer.apple.com/documentation/swiftui/view/symboleffect(_:options:isactive:)
- https://developer.apple.com/documentation/swiftui/contenttransition/symboleffect(_:options:)
- https://developer.apple.com/documentation/swiftui/transition/symboleffect(_:options:)
- https://developer.apple.com/documentation/swiftui/image/renderingmode(_:)
- https://developer.apple.com/documentation/swiftui/menubarextra
- https://developer.apple.com/documentation/swiftui/windowstyle/plain
- https://developer.apple.com/design/human-interface-guidelines/materials (SPA; title only via fetch)
- https://developer.apple.com/sf-symbols/
- iOS/macOS 26 Liquid Glass adoption skill (avdlee/swiftui-agent-skill, references/liquid-glass.md, latest-apis.md, macos-window-styling.md, macos-scenes.md, image-optimization.md)
