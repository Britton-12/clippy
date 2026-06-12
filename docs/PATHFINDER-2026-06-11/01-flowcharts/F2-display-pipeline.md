# F2 — Display / Present Pipeline

Hotkey -> `PanelController.show` -> position (caret/mouse/center) -> reactive `ClipStore` -> `ClipListView` date-sectioned `ClipCardView` list -> keyboard nav.

`ClipStore.init` starts two GRDB `ValueObservation`s before the panel ever opens: clip window (`.immediate`, [ClipStore.swift:32-56](Sources/Clippy/UI/ClipStore.swift:32)) and categories/membership (`.async(onQueue:.main)`, [ClipStore.swift:58-77](Sources/Clippy/UI/ClipStore.swift:58)). `windowDidResignKey` deliberately no-ops ([PanelController.swift:85](Sources/Clippy/Panel/PanelController.swift:85)) — focus loss does NOT close the panel.

```mermaid
flowchart TD
    A["Cmd+Shift+V RegisterEventHotKey<br/>HotKeyCenter.swift:18-20"] --> B["InstallEventHandler callback<br/>HotKeyCenter.swift:31-45"]
    B --> C["handler dispatched to main<br/>HotKeyCenter.swift:36-38"]
    C --> D["panelController.toggle()<br/>PanelController.swift:21-27"]
    D -->|isVisible| E["hide()<br/>PanelController.swift:61-69"]
    D -->|not visible| F["show()<br/>PanelController.swift:29-59"]

    F --> G["ensurePanel() build PastePanel<br/>PanelController.swift:92-120"]
    G --> G2["PastePanel NSPanel<br/>PastePanel.swift:6-14"]
    F --> H["store.query = '' -> refilter()<br/>ClipStore.swift:35, 164-171"]
    F --> I["build ClipListView root + NSHostingView<br/>PanelController.swift:36-47"]

    F --> J["fastFrame(size:) by positionMode<br/>PanelController.swift:126-141"]
    J --> K["frame(anchoredTo:size:) + clamped<br/>PanelController.swift:175-200"]
    K --> L["makeKeyAndOrderFront<br/>PanelController.swift:54"]

    L -->|positionMode == .caret| M["repositionAtCaretAsync bg queue<br/>PanelController.swift:146-166"]
    M --> N["CaretLocator.caretScreenRect AX<br/>CaretLocator.swift:25-63"]
    N -->|rect found, delta > 4pt| O["panel.setFrame target<br/>PanelController.swift:160-163"]
    N -->|nil: AX untrusted / zero-rect| P["keep mouse anchor frame<br/>PanelController.swift:155-157"]

    subgraph STATE["ClipStore reactive state (started at launch)"]
        Q["clip ValueObservation .immediate<br/>ClipStore.swift:32-56"]
        R["category/membership ValueObservation .async main<br/>ClipStore.swift:58-77"]
        S["recents didSet -> refilter()<br/>ClipStore.swift:16-18, 164-171"]
        Q --> S
    end

    H --> S
    S --> T["store.clips published<br/>ClipStore.swift:12"]

    L --> U["ClipListView.body<br/>ClipListView.swift:40-65"]
    T --> V["visibleClips filter pinned/category<br/>ClipListView.swift:31-38"]
    R --> V
    V --> W["sections date-grouped<br/>ClipListView.swift:180-210"]
    W --> X["sectionedList ScrollView+LazyVStack<br/>ClipListView.swift:212-232"]
    X --> Y["card(for:at:) -> ClipCardView<br/>ClipListView.swift:248-303"]
    Y --> Z["ClipCardView.body render<br/>ClipCardView.swift:83-124"]
    Z --> Z2["thumbnail(for:) NSCache<br/>ClipCardView.swift:310-321"]

    V -->|empty| EE["emptyState<br/>ClipListView.swift:327-339"]

    U --> KB["search TextField onKeyPress<br/>ClipListView.swift:112-156"]
    KB -->|up/down| NAV["moveSelection clamp selectedIndex<br/>ClipListView.swift:395-398"]
    NAV --> SC["proxy.scrollTo(selected)<br/>ClipListView.swift:227-230"]
    KB -->|type query| TYQ["$store.query didSet -> searchClips<br/>ClipStore.swift:9-11, 168-169"]
    TYQ --> S
    KB -->|Return| PS["pasteSelected -> onPaste<br/>ClipListView.swift:400-405"]
    KB -->|Escape| ESC["onClose -> hide()<br/>ClipListView.swift:123"]
    KB -->|Cmd+1..9| SEL["switch selection<br/>ClipListView.swift:142-156"]
    SEL --> V

    AX["CaretLocator.requestPermission AX prompt<br/>AppDelegate.swift:61-62, CaretLocator.swift:14-19"]
```

External deps: Carbon hotkey, ApplicationServices AX (CaretLocator), AppKit panel/screen/cache, SwiftUI/Combine, GRDB ValueObservation + `searchClips` (FTS5). Consumes `AppSettings`, `Theme`/`ThemeTokens`, `CategorySidePane` (F4), `Theme` tokens (F5).
