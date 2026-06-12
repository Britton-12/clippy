# F4 — Categories / Pinboards

Tag model: a clip is "pinned" iff it belongs to >= 1 category. "Pinned" is NOT a stored flag on a clip; it is derived from `clip_category` junction membership ([ClipStore.isPinned:90-93](Sources/Clippy/UI/ClipStore.swift:90)). The starter category literally named "Pinned" is just one category among many; Cmd+P toggles membership in it via `toggleStarterMembership` ([ClipDatabase+Categories.swift:118](Sources/Clippy/Storage/ClipDatabase+Categories.swift:118)), which auto-recreates it if deleted ([:85-99](Sources/Clippy/Storage/ClipDatabase+Categories.swift:85)).

Reorder persistence is per-row `update(db)` inside one write transaction, not a bulk statement ([:75-78](Sources/Clippy/Storage/ClipDatabase+Categories.swift:75)). All store actions swallow errors with `try?`.

```mermaid
flowchart TD
    LV["ClipListView hosts pane<br/>ClipListView.swift:49"]
    VC["visibleClips filter<br/>ClipListView.swift:31-38"]
    PANE["CategorySidePane body<br/>CategorySidePane.swift:18-39"]
    CROW["categoryRow ForEach categories<br/>CategorySidePane.swift:27,57-117"]
    NEWROW["New Category row<br/>CategorySidePane.swift:119-136"]
    EDITOR["CategoryEditorView name/color/icon<br/>CategoryEditorView.swift:6,53-98"]
    PICK["Symbols/Emoji/Apps grid<br/>CategoryEditorView.swift:70-158"]

    DRAG["draggable cat:id<br/>CategorySidePane.swift:99"]
    DROP["dropDestination prefix split<br/>CategorySidePane.swift:105-115"]
    CTX["context menu Edit/Delete<br/>CategorySidePane.swift:71-81"]

    SCREATE["store.createCategory<br/>ClipStore.swift:121-124"]
    SUPDATE["store.updateCategory<br/>ClipStore.swift:126-128"]
    SDELETE["store.deleteCategory<br/>ClipStore.swift:130-133"]
    SMOVE["store.moveCategory<br/>ClipStore.swift:136-138"]
    SADD["store.addClip toCategory<br/>ClipStore.swift:117-119"]
    SPIN["store.togglePin<br/>ClipStore.swift:107-110"]

    DBCREATE["createCategory maxOrder+1 insert<br/>ClipDatabase+Categories.swift:27-49"]
    DBUPDATE["updateCategory row update<br/>ClipDatabase+Categories.swift:51-55"]
    DBDELETE["deleteCategory + cache nil<br/>ClipDatabase+Categories.swift:57-63"]
    DBMOVE["moveCategory reinsert+renumber<br/>ClipDatabase+Categories.swift:67-81"]
    DBSET["setClip INSERT OR IGNORE/DELETE<br/>ClipDatabase+Categories.swift:101-115"]
    DBTOGGLE["toggleStarterMembership<br/>ClipDatabase+Categories.swift:118-138"]
    DBENSURE["ensureStarterCategoryID recreate<br/>ClipDatabase+Categories.swift:85-99"]

    CATTBL[("category table<br/>Category.swift:22")]
    JUNCTBL[("clip_category table<br/>Category.swift:35")]

    OBS["categoryObservation fetch+map<br/>ClipStore.swift:58-77"]
    PUBCAT["@Published categories<br/>ClipStore.swift:13"]
    PUBMEM["@Published membership<br/>ClipStore.swift:14"]
    ISPIN["isPinned >=1 membership<br/>ClipStore.swift:90-93"]
    COUNT["clipCount inCategory<br/>ClipStore.swift:100-102"]

    LV --> PANE
    PANE --> CROW
    PANE --> NEWROW
    NEWROW --> EDITOR
    CROW --> CTX
    CROW --> DRAG
    CROW --> DROP
    EDITOR --> PICK
    CTX -->|Edit| EDITOR
    CTX -->|Delete| SDELETE
    NEWROW -->|Create| SCREATE
    EDITOR -->|Save edit| SUPDATE
    DROP -->|cat: prefix| SMOVE
    DROP -->|clipID| SADD

    SCREATE --> DBCREATE
    SUPDATE --> DBUPDATE
    SDELETE --> DBDELETE
    SMOVE --> DBMOVE
    SADD --> DBSET
    SPIN --> DBTOGGLE
    DBTOGGLE --> DBENSURE

    DBCREATE --> CATTBL
    DBUPDATE --> CATTBL
    DBDELETE --> CATTBL
    DBMOVE --> CATTBL
    DBENSURE --> CATTBL
    DBSET --> JUNCTBL
    DBTOGGLE --> JUNCTBL

    CATTBL --> OBS
    JUNCTBL --> OBS
    OBS --> PUBCAT
    OBS --> PUBMEM
    PUBCAT --> CROW
    PUBMEM --> ISPIN
    PUBMEM --> COUNT
    ISPIN --> VC
    COUNT --> CROW
    VC --> LV
```

External deps: GRDB (ValueObservation, raw SQL), Combine, SwiftUI drag/drop/popover, `AppIconProvider`, `CategoryPalette`, `Color(hexString:)`, `ThemeTokens`.

Gap: migration v2 schema for `category`/`clip_category` (and any `ON DELETE CASCADE`) is referenced ([:19-20](Sources/Clippy/Storage/ClipDatabase+Categories.swift:19)) but defined in `ClipDatabase.makeMigrator`, not read in full.
