# Clipboard Manager - Stack and Architecture Decision

Target platform: macOS 14 (Sonoma) minimum, built and tested on macOS 26 (Tahoe).
Decision date: 2026-06-10.

## Recommendation in one line

Build it native in Swift (SwiftUI for views, AppKit/NSPanel for the window, Accessibility API for cursor attachment), store data in an encrypted SQLite database via GRDB, and expose an in-process MCP server plus a loopback REST endpoint for AI and script access.

## Recommended stack

| Layer | Choice | Why |
|-------|--------|-----|
| Language | Swift 6 (Xcode 16+) | Required by GRDB 7 and the MCP Swift SDK. Single language for app and API. |
| Window/UI | SwiftUI views hosted in an `NSPanel` (nonactivating) | The popup that opens at the cursor and does not steal focus. Same pattern Maccy 2.0 uses. |
| Clipboard capture | `NSPasteboard` change-count polling | The supported way to detect copies. No public push notification exists. |
| Cursor attachment | Accessibility API (`AXUIElementCreateSystemWide` -> focused element -> selected range -> bounds-for-range) | Gets the text caret screen rect. Fall back to mouse location when the host app does not expose it. |
| Storage | SQLite through GRDB 7.x, FTS5 for search | Inspectable file, fast full-text search, change observation for live UI. |
| Encryption at rest | SQLCipher (via SPM: mezhevikin/GRDB.SQLCipher.swift or skiptools/swift-sqlcipher) | User-controlled key in the Keychain. |
| AI / agent API | Official MCP Swift SDK (in-process server) | Claude Code and Claude Desktop connect directly. |
| Script / automation API | Loopback HTTP (127.0.0.1) with a bearer token | Shortcuts, shell, and non-MCP tools. |
| Sync / backup | User choice: encrypted DB in a synced folder, CloudKit private DB, or encrypted export | No server you operate. The user owns the data path. |
| Distribution | Signed and notarized .dmg, optional Homebrew cask | Standard for this app class. |

## Why native Swift and not Electron or Tauri

The features you asked for are native-integration features, not UI features. Pasteboard monitoring, opening at the caret, simulating a paste keystroke, honoring password-manager concealed flags, and low idle memory all run through AppKit, Core Graphics, and the Accessibility API. A web runtime sits between your code and those APIs and buys you nothing here, because the UI surface (a list, a search box, a text editor, a pinboard grid) is small.

Specific evidence:

- Maccy is the existence proof. It is written in Swift on native AppKit, MIT licensed, stores everything locally, and drops copied passwords when a password manager sets the concealed flag. Its 2.0 rewrite uses SwiftUI plus NSPanel. You can read or fork the source.
- The caret-position trick you like in Maccy does not work in Electron host apps. They return a zero or garbage selection rectangle because the relevant Accessibility attribute is treated as private. If the host is Electron you fall back to the mouse position. This is a capture-side limitation, but it is also a reason not to build the manager itself on web tech: you would inherit the same accessibility gaps for your own editor and panel.
- Electron memory and launch cost work against the "fast, lives in the menu bar" goal. Tauri is much lighter than Electron, but you would still write the pasteboard, accessibility, and paste-simulation layers in Rust plus Objective-C bindings, so you pay a two-language tax for a web UI you do not need.

Tradeoff you accept by going native: macOS only. Given the requirement set (caret attachment, pasteboard fidelity, password-manager respect), that is the right scope.

## Component decisions

### 1. The popup window (fixes the Paste "huge bottom bar" complaint)

Use a single `NSPanel` configured as nonactivating and floating, with SwiftUI content inside. It opens at the caret, sized and positioned by user settings, and closes on escape or paste. Pinboards live inside this panel as a sidebar or tab strip, not as a permanent dock attached to the screen edge. Nothing stays on screen when the panel is closed.

Settings that directly answer your complaints:
- Window width and height, with a "remember last size" option.
- Position mode: at caret, at mouse, at last position, or fixed point.
- Whether pinboards show as sidebar, top tabs, or a separate hotkey.

### 2. Clipboard capture

Poll `NSPasteboard.general.changeCount` on a timer (a short interval, tuned for responsiveness vs idle cost). On change, read the types present and store them.

Password and sensitive-content safety (matters for a regulated environment):
- Skip any item carrying the concealed pasteboard type `org.nspasteboard.ConcealedType`. This is the convention 1Password, Bitwarden, and others set, and it is what Maccy honors.
- Skip the transient type `org.nspasteboard.TransientType`.
- Maintain a user-editable ignore list by source app bundle id and by pasteboard type, so the user can exclude specific apps entirely.

### 3. Cursor attachment (the Maccy behavior you want)

Flow, all through the Accessibility API:
1. `AXIsProcessTrustedWithOptions` to confirm or prompt for Accessibility permission.
2. `AXUIElementCreateSystemWide`, then read `kAXFocusedUIElementAttribute`.
3. Read `kAXSelectedTextRangeAttribute` (a CFRange) on the focused element.
4. Read `kAXBoundsForRangeParameterizedAttribute` for that range to get a screen-coordinate CGRect.
5. Place the panel relative to that rect.

Fallback order when step 3 or 4 fails (Electron hosts, web views, sandboxed apps that block it): use `NSEvent.mouseLocation`, then the last-used position. The SPM package Aeastr/CursorBounds wraps steps 1 through 4 and is a reasonable starting point or reference.

### 4. Plain-text editor (fixes the Unicode-mangling complaint)

The reason Paste turns your straight quotes into curly quotes and hyphens into em dashes is rich-text round-tripping with macOS smart substitutions left on. Avoid both.

For the editor view, use `NSTextView` and disable every automatic substitution:

```swift
textView.isAutomaticQuoteSubstitutionEnabled = false
textView.isAutomaticDashSubstitutionEnabled = false
textView.isAutomaticTextReplacementEnabled = false
textView.isAutomaticSpellingCorrectionEnabled = false
textView.smartInsertDeleteEnabled = false
textView.isRichText = false        // plain text only for text clips
```

Store text clips as raw `String` from `NSPasteboardType.string`. Do not convert plain text to RTF or attributed strings on save or restore. When the clip is genuinely rich (came in as RTF or HTML), keep the original data blob and also keep a plain-text rendering, and let the user pick which to paste. Round-trip a plain-text clip and it comes back byte for byte.

### 5. Pinboards and snippets

Model:
- `clips` table: every captured item, with type, content (or a blob reference), source app, timestamp, and a pinned flag.
- `pinboards` table: named collections.
- `pinboard_items` join table: ordered membership, so a clip can live on more than one board.
- Optional `snippets`: user-authored static entries, same storage, flagged as snippet.

The "do not re-sort after paste" behavior you want from Maccy becomes a setting: "move pasted item to top" defaults to off, so order stays stable. History order, pinboard order, and snippet order are independent.

### 6. AI and agent API

Two interfaces over one shared service layer.

MCP server (primary, for Claude Code and Claude Desktop):
- Use the official MCP Swift SDK. It implements server and client for the 2025-11-25 spec and needs Swift 6.
- Run it in-process over stdio for a locally launched agent, or over the SDK's HTTP transport for a long-running connection.
- Tools to expose: `search_clips`, `get_clip`, `set_clipboard`, `list_pinboards`, `get_pinboard`, `pin_clip`, `create_snippet`, `delete_clip`.
- Resources to expose: recent history and each pinboard, so an agent can read context without a tool call.

REST endpoint (secondary, for Shortcuts and shell):
- Bind to 127.0.0.1 only. Require a bearer token stored in the Keychain and shown once in settings.
- Mirror the MCP tool set as JSON routes.
- Pick the Swift HTTP server at build time (Vapor or Hummingbird are the two to evaluate). Confirm the current version and API with Context7 before writing routes rather than from memory.

### 7. Sync and backup, user controlled

No server you run. Offer three modes, user picks:

1. File sync: keep the encrypted SQLite database (or a periodic encrypted export) in a folder the user chooses, for example an iCloud Drive, Dropbox, or Synology Drive folder. The sync engine is theirs; you only write the file. Handle the multi-writer case by treating one machine as primary or by merging on an append-only change log.
2. CloudKit private database: Apple-native sync inside the user's own iCloud, end-to-end within their account. Use this only if the user wants zero-config Apple sync and accepts CloudKit's model.
3. Manual encrypted export/import: a single encrypted archive the user moves however they want, including air-gapped.

Encryption: SQLCipher for the database, key in the Keychain. For exports, encrypt with a user passphrase. Never write history to a location you do not control by default; local-only is the out-of-box state and sync is opt-in.

## Security posture (regulated-environment fit)

- Local-only by default. Sync and any network listener are opt-in and clearly labeled.
- Concealed and transient pasteboard types are never stored.
- Database encrypted at rest with a Keychain-held key.
- REST API on loopback only, token required, off by default.
- App sandbox where feasible; Accessibility permission requested with a clear prompt and a settings link.
- Signed and notarized build so Gatekeeper and your own endpoint policy accept it.

## Customization surface (the knobs that answer every complaint you listed)

- Panel size and a remember-last-size toggle (Paste was too big, Maccy too small).
- Position mode: at caret, at mouse, last position, fixed.
- Move-pasted-item-to-top toggle, default off (Maccy re-sorts).
- Plain-text editor with all smart substitutions off (Paste mangled characters).
- Pinboard layout: sidebar, tabs, or separate hotkey.
- Per-app and per-type ignore list.
- Paste mode: with formatting or plain text, with a default and a modifier override.
- History retention: count cap, age cap, or unlimited.
- Hotkeys for open, paste, paste-plain, pin, and clear.

## Build and distribution notes

- Swift Package Manager for all dependencies. GRDB, the MCP SDK, and the SQLCipher package are all SPM-installable.
- Deployment target macOS 14. Build on Xcode 16+ with the macOS 26 SDK.
- Sign and notarize. Offer a Homebrew cask if you distribute beyond your own machines.

## Verified this session vs verify at build time

Verified now (from current sources):
- Maccy is Swift on AppKit, MIT, local-only, honors the concealed flag; 2.0 uses SwiftUI plus NSPanel and SwiftData.
- MCP Swift SDK is official, implements server and client for the 2025-11-25 spec, around version 0.11.0, needs Swift 6 / Xcode 16+.
- GRDB latest is 7.8.0, MIT, Swift 6+, supports FTS and SQLCipher; SQLCipher via SPM exists (mezhevikin/GRDB.SQLCipher.swift, skiptools/swift-sqlcipher embeds SQLite 3.50.4 and SQLCipher 4.10.0).
- Caret bounds via Accessibility API is documented; Aeastr/CursorBounds wraps it; Electron hosts do not expose it.
- Current macOS is Tahoe 26.5.1 (2026-06-01); macOS 27 previewed at WWDC 2026.

Verify at build time with Context7 or the project docs, do not code from memory:
- Vapor vs Hummingbird current version and route API for the REST layer.
- MCP Swift SDK exact server-setup API for the SDK version you pin.
- CloudKit private-database sync constraints if you choose mode 2.
- GRDB 7 plus SQLCipher SPM integration steps for your Xcode version.

## Suggested first milestone

1. Menu-bar app with an `NSPanel` that opens on a hotkey at the caret, mouse-location fallback.
2. `NSPasteboard` polling that writes text clips to an unencrypted GRDB database, concealed and transient types skipped.
3. Search box backed by FTS5, paste on enter.
4. Plain-text editor with substitutions disabled, verified by copying text with straight quotes and a hyphen and confirming it pastes unchanged.

Ship that, then add pinboards, encryption, the MCP server, and sync in that order.
