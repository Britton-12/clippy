# F7 — App Shell, Menu Bar & Updates

`main.swift:6-10` boots `.accessory` `NSApplication` -> `AppDelegate.applicationDidFinishLaunching` ([:26](Sources/Clippy/AppDelegate.swift:26)) is the single composition root. Subsystems are lazy properties ([:13-24](Sources/Clippy/AppDelegate.swift:13)); decoupling is via closure callbacks, not protocols. Sparkle `SPUStandardUpdaterController` `startingUpdater:` is gated on `SUFeedURL` presence ([:13-14](Sources/Clippy/AppDelegate.swift:13)) — unbundled = inert, "Check for Updates" menu item validates disabled.

`AppIconProvider` is in the file set but has NO inbound edge from this flow; it belongs to clip-card tinting (F2/F5).

```mermaid
flowchart TD
    A["NSApplication.shared<br/>main.swift:6"] --> C["setActivationPolicy .accessory<br/>main.swift:9"]
    C --> D["app.run<br/>main.swift:10"]
    D --> E["applicationDidFinishLaunching<br/>AppDelegate.swift:26"]

    subgraph Lazy["Composition root (lazy properties)"]
        L0["database ClipDatabase.shared<br/>AppDelegate.swift:19"]
        L1["store ClipStore(database)<br/>AppDelegate.swift:20"]
        L2["monitor ClipboardMonitor(database)<br/>AppDelegate.swift:21"]
        L3["pasteService PasteService(monitor)<br/>AppDelegate.swift:22"]
        L4["panelController PanelController(store)<br/>AppDelegate.swift:23"]
        L5["editorController EditorWindowController<br/>AppDelegate.swift:24"]
        L6["updaterController SPUStandardUpdaterController<br/>AppDelegate.swift:13"]
        L0 --> L1
        L0 --> L2
        L2 --> L3
        L1 --> L4
    end

    E --> F["setupStatusItem<br/>AppDelegate.swift:27"]
    E --> G["monitor.start<br/>AppDelegate.swift:28"]
    E --> H["orphan-media sweep (utility queue)<br/>AppDelegate.swift:32"]
    E --> I["HotKeyCenter.handler -> panelController.toggle<br/>AppDelegate.swift:37"]
    E --> K["panelController.onPaste -> pasteService.paste<br/>AppDelegate.swift:42"]
    E --> M["panelController.onEdit -> editorController.open<br/>AppDelegate.swift:47"]
    E --> N["panelController.onOpenSettings -> openSettings<br/>AppDelegate.swift:55"]
    E --> O["CaretLocator.requestPermission (if untrusted)<br/>AppDelegate.swift:61"]

    F --> R["NSStatusItem create<br/>AppDelegate.swift:90"]
    R --> S["button.image = StatusBarIcon.image()<br/>AppDelegate.swift:91"]
    R --> T[".clippyDidCapture observer<br/>AppDelegate.swift:96"]
    T --> U["StatusBarIcon.bounce(button)<br/>AppDelegate.swift:102 / StatusBarIcon.swift:23"]

    F --> V["NSMenu build<br/>AppDelegate.swift:105"]
    V --> V1["Open Clipboard -> openPanel -> show()<br/>AppDelegate.swift:107,144"]
    V --> V2["Pause Capture -> togglePause + icon swap<br/>AppDelegate.swift:112,148"]
    V --> V3["Settings... -> openSettings<br/>AppDelegate.swift:118,156"]
    V --> V4["Clear Unpinned History -> deleteUnclassifiedClips<br/>AppDelegate.swift:122,174"]
    V --> V5["Check for Updates... -> updaterController (inert unbundled)<br/>AppDelegate.swift:128"]
    V --> V6["Quit -> NSApplication.terminate<br/>AppDelegate.swift:136"]

    X["AppIconProvider (standalone, not wired by this flow)<br/>AppIconProvider.swift:8"]
```

This flow wires every other flow:

| Subsystem (flow) | AppDelegate line |
|---|---|
| ClipDatabase (F1/F3/F4/F6) | :19, :33, :183 |
| ClipStore (F2/F4) | :20, :23, :52 |
| ClipboardMonitor (F1) | :21, :28, :149 |
| PasteService (F3) | :22, :45 |
| PanelController (F2) | :23, :38/44/51/56, :145 |
| EditorWindowController (F3) | :24, :51 |
| HotKeyCenter (F2) | :37, :40 |
| CaretLocator (F2) | :61-63 |
| Sparkle updates | :13, :128-133 |
| SettingsView (F5) | :166 |
| StatusBarIcon | :91, :102, :152 |

Side effects: status item creation, menu wiring, icon bounce/swap, pause toggle on monitor, updater check, orphan sweep, `deleteUnclassifiedClips`.
