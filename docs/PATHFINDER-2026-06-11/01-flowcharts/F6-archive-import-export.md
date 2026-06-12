# F6 — Archive Import / Export

TOML round-trip + a separate JSON export. Three UI handlers in `SettingsView`: `exportTOML` ([:559](Sources/Clippy/UI/SettingsView.swift:559)), `importTOML` ([:573](Sources/Clippy/UI/SettingsView.swift:573)), `exportJSON` ([:591](Sources/Clippy/UI/SettingsView.swift:591)).

Asymmetry worth flagging: export hand-assembles TOML by string concatenation (`pair`/`clipPair`/`quote`, [ClippyArchive.swift:181](Sources/Clippy/Storage/ClippyArchive.swift:181)); import uses the real `TOMLKit` parser ([:201](Sources/Clippy/Storage/ClippyArchive.swift:201)). JSON export has no import counterpart and a different shape (clips carry `categories: [String]` instead of nesting).

**Second ingress call-out:** the archive layer is a distinct read+write path over the same clip/category data as F1+F4. Import upserts deliberately bypass the capture pipeline's eviction cap ([ClipDatabase+Archive.swift:78-79](Sources/Clippy/Storage/ClipDatabase+Archive.swift:78)) and create their own clip rows / media files via dedicated `upsertImported*` methods. There are now two independent ways clip/category rows get written, and two ways image media files get written (F1 `media.store` and F6 `upsertImportedImageClip` -> `media.store`).

```mermaid
flowchart TD
    A["exportTOML (UI handler)<br/>SettingsView.swift:559"] --> B["NSSavePanel clippy.toml<br/>SettingsView.swift:560-563"]
    B --> C["ClippyArchive.exportTOML from:now:<br/>ClippyArchive.swift:127"]
    C --> D["clipsGroupedByCategory (DB read)<br/>ClipDatabase+Archive.swift:16"]
    D --> F["per-category SQL JOIN clip_category<br/>ClipDatabase+Archive.swift:22-31"]
    F --> H["per category [[category]] block via pair<br/>ClippyArchive.swift:137-143"]
    H --> I{"clip.contentKind == .text?<br/>ClippyArchive.swift:151"}
    I -->|text| J["text = quote(contentText)<br/>ClippyArchive.swift:152"]
    I -->|image w/ mediaFilename| K["image_path = quote(media path)<br/>ClippyArchive.swift:153-154"]
    J --> L["quote: multiline vs escaped string<br/>ClippyArchive.swift:181-194"]
    K --> L
    L --> N["toml.write atomically utf8 (FILE WRITE)<br/>SettingsView.swift:566"]

    P["importTOML (UI handler)<br/>SettingsView.swift:573"] --> R["String(contentsOf:url) (FILE READ)<br/>SettingsView.swift:579"]
    R --> S["ClippyArchive.importTOML into:<br/>ClippyArchive.swift:200"]
    S --> T["TOMLDecoder.decode (TOMLKit)<br/>ClippyArchive.swift:201"]
    T --> U["loop document.category<br/>ClippyArchive.swift:205"]
    U --> V["upsertImportedCategory (DB WRITE)<br/>ClipDatabase+Archive.swift:43"]
    V --> W{"existing by name?<br/>ClipDatabase+Archive.swift:52"}
    W -->|yes| X["update in place<br/>ClipDatabase+Archive.swift:53-58"]
    W -->|no| Y["insert (starter only if none exists)<br/>ClipDatabase+Archive.swift:60-73"]
    X --> Z["loop category.clip ?? [] (optional array)<br/>ClippyArchive.swift:216"]
    Y --> Z
    Z --> AA{"clip.kind == image?<br/>ClippyArchive.swift:218"}
    AA -->|image| AB["upsertImportedImageClip fromFileAt<br/>ClipDatabase+Archive.swift:111"]
    AB --> AC["FileManager.contents (FILE READ)<br/>ClipDatabase+Archive.swift:114"]
    AC --> AD["NSImage->PNG re-encode<br/>ClipDatabase+Archive.swift:118-125"]
    AD --> AE["media.store pngData (FILE WRITE)<br/>ClipDatabase+Archive.swift:126"]
    AE --> AF{"reuse by mediaFilename else insert (DB WRITE)<br/>ClipDatabase+Archive.swift:127-141"}
    AB -->|nil: missing/not image| AG["skippedImages += 1; continue<br/>ClippyArchive.swift:224"]
    AA -->|text| AH["upsertImportedTextClip<br/>ClipDatabase+Archive.swift:80"]
    AH --> AI{"reuse identical contentText else insert (DB WRITE)<br/>ClipDatabase+Archive.swift:84-103"}
    AF --> AJ["setClip inCategory true (DB WRITE)<br/>ClippyArchive.swift:225"]
    AI --> AK["setClip inCategory true (DB WRITE)<br/>ClippyArchive.swift:234"]

    BA["exportJSON (UI handler)<br/>SettingsView.swift:591"] --> BC["categories + membershipMap + allClips (DB READ)<br/>SettingsView.swift:613-620"]
    BC --> BD["map to ExportClip w/ category names<br/>SettingsView.swift:620-632"]
    BD --> BE["JSONEncoder iso8601 pretty sorted<br/>SettingsView.swift:637-639"]
    BE --> BF["encode().write(to:url) (FILE WRITE)<br/>SettingsView.swift:640"]
```

External deps: TOMLKit (import only), GRDB, AppKit (`NSImage`/`NSBitmapImageRep`, save/open panels), Foundation (`FileManager`, `ISO8601DateFormatter`, `JSONEncoder`), `ClipDatabase.media`.
