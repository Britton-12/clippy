# Clippy Panel Redesign: Category Side Pane, Image Support, Readable Legend

Date: 2026-06-10
Status: Approved by user (design discussion in session)

## Problem

1. Pinning a clip hoists it into a "Pinned" section at the top of the single
   scrolling History column. Pinned items need their own home, not a wedge in
   the timeline.
2. The clipboard monitor captures text only. Copied images never appear.
3. The footer shortcut legend is barely readable: 9pt key glyphs and 9.5pt
   labels in tertiary gray.

The Paste mac app served as a quality reference during design. The result is
deliberately NOT a Paste clone: Clippy keeps its caret-positioned compact
panel, left color stripe cards, and its own visual identity.

## Decisions Made With User

| Decision | Choice |
| --- | --- |
| Category model | Tags: a pinned clip can belong to multiple categories |
| Side pane | Right side, always visible, ~25% of panel width, min 150pt |
| Image support | Full: capture, store, thumbnail display, paste back |
| Implementation approach | Evolve current panel in place (no NavigationSplitView, no second window) |
| Visual identity | Keep Clippy card anatomy (stripe + header + preview); do not copy Paste's header-band cards |

## 1. Layout and Navigation

The floating panel keeps caret positioning, material background, and the
frameless look. The History/Pinned tab bar is removed.

- Main pane (left, 75%): search bar on top, content area below. Default
  content is History: the date-sectioned chronological list. Pinned clips are
  NO LONGER hoisted to a top section; they appear in chronological order with
  a small category color dot.
- Side pane (right, 25%, always visible): vertical list of categories. Each
  row: color, icon, name, clip count. "History" row at top (home target),
  "+ New Category" row at bottom.

Navigation: clicking a category slides its clips into the main pane from the
right (history exits left); History slides back the other way. 200ms ease-out,
suppressed when `accessibilityReduceMotion` is set.

Keyboard:
- Up/Down arrows: move card selection (unchanged)
- Return / Shift+Return: paste default / inverted mode (unchanged)
- Cmd+1: return to History
- Cmd+2 ... Cmd+9: jump to the first eight categories (side pane order)
- Escape: closes the panel (unchanged; never repurposed as "back")
- Cmd+P: pin (add to starter category)

Default panel width increases to 640pt. Existing width/height sliders and
position modes in Settings continue to apply.

## 2. Categories (Tag Model)

### Data model (GRDB)

- `category`: id, name, colorHex, iconKind (`symbol` | `emoji` | `appLogo`),
  iconValue, sortOrder, createdAt
- `clip_category`: clipID, categoryID, addedAt; composite primary key;
  cascading delete on either side

A clip is "pinned" iff it has at least one `clip_category` row. The legacy
`isPinned` flag is replaced by this derivation.

### Migration

Additive and in-place: create both tables, create a starter category named
"Pinned", insert a junction row for every clip with the legacy pinned flag.
No data loss. Pinned clips keep their existing cap exemption (clips in any
category never count against `maxHistoryItems` and survive Clear Unpinned
History).

### Interactions

- Pin button on card / Cmd+P: adds clip to the starter category (one
  keystroke, fast path preserved). If already in it, removes it (toggle).
- Context menu: "Add to Category >" submenu listing all categories with
  checkmarks for membership, plus "New Category...".
- Drag a card onto a side pane category row to add it.
- Category row context menu: Rename, Edit Color & Icon, Delete.
- Deleting a category never deletes clips. A clip whose last category is
  removed becomes a normal history item again.

### Customization editor

Popover anchored to the category row:
- Name field
- Color palette: the same swatch set used for accent themes
- Icon picker, three tabs:
  1. Symbols: curated set of friendly SF Symbols
  2. Emoji: emoji grid
  3. App logos: icons of apps already seen in history, via AppIconProvider

## 3. Card Design

Keep current anatomy: left color stripe (4pt), header row (app icon, app
name, metadata/hover actions), preview text. Changes:

- Kind icon and pin/category indicators: 9pt -> 12pt
- Timestamp: moves from tertiary to secondary contrast
- All icon-only buttons gain `.accessibilityLabel` (card actions, settings
  gear, category rows, swatches) while these views are rebuilt
- Cards get `.accessibilityElement(children: .combine)` so VoiceOver reads
  one sensible element per clip

## 4. Image Support (Full)

### Capture

ClipboardMonitor checks for image data (PNG, TIFF) on pasteboard changes.
Dedupe by content hash. Skip images above a size cap (default 20MB,
configurable). Existing skip rules (concealed, transient, ignored apps)
apply to images identically.

### Storage

- Image bytes written to `Application Support/Clippy/media/<uuid>.<ext>`
- DB: new `contentKind` column (`text` | `image`), media file reference,
  pixel dimensions, byte size
- Thumbnail (~400px max edge) generated at capture time and stored alongside,
  so list scrolling never decodes full images
- File writes complete and are verified before the DB row commits: no
  dangling references
- Deleting a clip, cap eviction, and Clear Unpinned History all delete the
  associated media files

### Display

Image cards show a rounded thumbnail (about 72pt tall), an "Image" kind badge,
and a dimensions caption (for example "1280x720 PNG").

### Paste

PasteService writes the image data to the pasteboard and sends Cmd+V exactly
as for text. "Paste as plain text" is disabled (hidden) for image clips.

### Export

JSON export includes image clips as media file references, with a top-level
note field in the export explaining that image payloads are file paths.

## 5. Footer Legend

- Key cap glyphs: 9pt -> 12pt, roomier padding on the cap background
- Action labels: 9.5pt -> 12pt
- Contrast: from tertiary/secondary up to a level passing 4.5:1 on every
  panel material, including the glass materials
- Show fewer hints: paste, plain, pin, close. Edit and the rest live in the
  context menu.

## 6. Settings Additions

Capture tab only:
- "Capture images" toggle (default on)
- Max image size field (default 20MB)

No new Appearance settings. The side pane is always visible by design.
Existing accent, material, and card color options apply to the new layout
unchanged.

## 7. Error Handling, Data Safety, Testing

- Migration is additive (new tables, new columns with defaults) and upgrades
  existing databases in place
- Media writes verified before DB commit; orphan sweep on launch removes
  media files with no DB row
- Unit tests: category CRUD, tag junction behavior, legacy pinned migration,
  image store and evict, dedupe by hash
- UI smoke tests via the existing `--show-panel` launch flag
- Manual checks: both light and dark appearance, all five panel materials,
  reduced motion on, panel at minimum width (side pane min 150pt)

## Out of Scope

- Sync, encryption at rest, MCP server, REST API (tracked in Settings >
  Integrations as planned)
- Undo for delete (separate improvement, noted in earlier UX review)
- Custom hotkey recording
