# Clippy Feature Inventory

Native macOS menu-bar clipboard manager. Swift (SwiftPM, tools 6.0, macOS 14+). GRDB storage, SwiftUI panel/settings, AppKit shell + floating panel, Sparkle updates, TOMLKit archive.

Single composition root: `main.swift:6` boots an `.accessory` `NSApplication`; `AppDelegate.applicationDidFinishLaunching` ([AppDelegate.swift:26](Sources/Clippy/AppDelegate.swift:26)) constructs and wires every subsystem via lazy properties + closure callbacks. No DI container; `ClipDatabase.shared` is the shared dependency.

## Raw features (17, from discovery)

| # | Feature | Entry point | Core files |
|---|---------|-------------|------------|
| 1 | App Shell & Menu Bar | [AppDelegate.swift:89](Sources/Clippy/AppDelegate.swift:89) `setupStatusItem` | AppDelegate, main, Support/StatusBarIcon, Support/AppIconProvider |
| 2 | Clipboard Capture | [ClipboardMonitor.swift:38](Sources/Clippy/Capture/ClipboardMonitor.swift:38) `start()` | Capture/ClipboardMonitor |
| 3 | Storage & Persistence | [ClipDatabase.swift:8](Sources/Clippy/Storage/ClipDatabase.swift:8) `shared` | Storage/ClipDatabase, Clip, ClipKind |
| 4 | Media Store | [MediaStore.swift:36](Sources/Clippy/Storage/MediaStore.swift:36) `store(pngData:)` | Storage/MediaStore |
| 5 | Categories / Pinboards | [ClipDatabase+Categories.swift:6](Sources/Clippy/Storage/ClipDatabase+Categories.swift:6) | Storage/Category, ClipDatabase+Categories, UI/CategorySidePane, UI/CategoryEditorView |
| 6 | Reactive Clip Store | [ClipStore.swift:23](Sources/Clippy/UI/ClipStore.swift:23) `init` | UI/ClipStore |
| 7 | Paste Panel | [PanelController.swift:29](Sources/Clippy/Panel/PanelController.swift:29) `show()` | Panel/PanelController, Panel/PastePanel, UI/PanelSelection |
| 8 | Clip List UI | [ClipListView.swift:40](Sources/Clippy/UI/ClipListView.swift:40) `body` | UI/ClipListView, ClipCardView, ThemedBackground, SelectAllTextField, PlainTextEditor |
| 9 | Paste-back Service | [PasteService.swift:16](Sources/Clippy/Paste/PasteService.swift:16) `paste()` | Paste/PasteService |
| 10 | Clip Editor | [EditorWindowController.swift:9](Sources/Clippy/Panel/EditorWindowController.swift:9) `open()` | Panel/EditorWindowController, UI/ClipEditorView |
| 11 | Global Hotkey | [HotKeyCenter.swift:18](Sources/Clippy/Support/HotKeyCenter.swift:18) | Support/HotKeyCenter |
| 12 | Caret Positioning | [CaretLocator.swift:25](Sources/Clippy/Positioning/CaretLocator.swift:25) | Positioning/CaretLocator |
| 13 | Settings & Preferences | [SettingsView.swift:6](Sources/Clippy/UI/SettingsView.swift:6) | UI/SettingsView, Support/AppSettings |
| 14 | Theming & Appearance | [Theme.swift:215](Sources/Clippy/Support/Theme.swift:215) | Support/Theme, ThemePreset, UI/ThemedBackground |
| 15 | Capture Sounds | [CaptureSound.swift:133](Sources/Clippy/Support/CaptureSound.swift:133) | Support/CaptureSound, SoundCatalog |
| 16 | Archive Import/Export | [ClippyArchive.swift:127](Sources/Clippy/Storage/ClippyArchive.swift:127) | Storage/ClippyArchive, ClipDatabase+Archive |
| 17 | In-App Updates (Sparkle) | [AppDelegate.swift:13](Sources/Clippy/AppDelegate.swift:13) | AppDelegate |

## Consolidated flows for flowcharting (7)

Micro-features (hotkey, caret, sounds, media, status icon, Sparkle) fold into the pipeline that drives them.

| Flow | Rolls up raw features | Why grouped |
|------|----------------------|-------------|
| **F1 Capture pipeline** | 2, 3, 4, 15 | Poll -> classify -> persist (text + image/media) -> sound. One write path. |
| **F2 Display pipeline** | 6, 7, 8, 11, 12 | Hotkey/caret -> panel show -> reactive store -> list render. One read/present path. |
| **F3 Paste & Edit** | 9, 10 | Selection -> pasteboard write + keystroke; or open editor -> save. |
| **F4 Categories / Pinboards** | 5 | Category CRUD, membership (= pinning), reorder, side pane + editor. |
| **F5 Settings & Theming** | 13, 14 | UserDefaults-backed prefs + theme token resolution consumed app-wide. |
| **F6 Archive Import/Export** | 16 | TOML/JSON round-trip backup, upsert-on-import. |
| **F7 App Shell & Updates** | 1, 17 | Menu bar status item, menu actions, capture bounce, Sparkle. |

Cross-cutting dependency: `ClipDatabase.shared` (storage) and `AppSettings.shared` / `Theme` tokens touch nearly every flow. Decoupling is via `NotificationCenter` (`.clippyDidCapture`) and closure callbacks, not protocols.
