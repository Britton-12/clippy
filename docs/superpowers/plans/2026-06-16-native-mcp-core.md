# Native MCP Core Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bundled Node.js HTTP MCP server with an in-process native Swift MCP server reached over a Unix domain socket via a tiny bundled `clippy-mcp` stdio helper, with full feature parity (clips, categories, paste-to-frontmost, Scripts, AI Actions) and a settings panel that shows status, reveals the socket/helper in Finder, and can force-reset.

**Architecture:** The running clippy app listens on a Unix domain socket. AI clients spawn the bundled `clippy-mcp` helper binary, which splices `stdin <-> socket <-> stdout` (a dumb byte pipe, zero deps). Each accepted socket connection gets its own `MCP.Server` + `StdioTransport(input: fd, output: fd)`. All tool handlers call a single shared `ClippyMCPService` that wraps the app's existing GRDB store, `ScriptRunner`, `AIService`, and `PasteService` — no duplicated logic. No TCP port anywhere; "port in use" stops existing.

**Tech Stack:** Swift 6 / SwiftPM, GRDB, the official `modelcontextprotocol/swift-sdk` (`import MCP`), POSIX `AF_UNIX` sockets, SwiftUI (settings), `scripts/make-app.sh` for bundling/signing.

**Spec:** `docs/superpowers/specs/2026-06-16-native-mcp-integration-design.md`

**Scope of Plan 1 (this doc):** Milestones 0-7 below. Plan 2 (App Intents, multi-client one-click install, live connected-clients list) is a separate plan written after Plan 1 is verified.

---

## File Structure

Created:
- `Sources/Clippy/Integrations/MCP/ClippyMCPDTOs.swift` — Codable DTOs returned by the service.
- `Sources/Clippy/Integrations/MCP/ClippyMCPService.swift` — shared tool layer; the DRY core both MCP and (later) App Intents call.
- `Sources/Clippy/Integrations/MCP/UnixSocketListener.swift` — `AF_UNIX` bind/listen/accept loop.
- `Sources/Clippy/Integrations/MCP/ClippyMCPServer.swift` — owns the listener; per-connection `Server` + tool registration.
- `Sources/Clippy/Integrations/MCP/ClippyMCPController.swift` — `ObservableObject` wrapper the UI binds to (replaces `McpServerController`).
- `Sources/Clippy/Integrations/MCP/MCPPaths.swift` — single source of truth for the socket path + helper path.
- `Sources/Clippy/Integrations/MCP/ClaudeDesktopInstaller.swift` — writes Claude Desktop config (needed for E2E verification).
- `Sources/clippy-mcp/main.swift` — the helper binary (stdio<->UDS pipe + auto-launch).
- `Tests/ClippyTests/ClippyMCPServiceTests.swift` — service-layer unit tests.
- `Tests/ClippyTests/MCPRoundTripTests.swift` — spawn the helper, run `initialize`+`tools/list`+a call, assert < 2s.

Modified:
- `Package.swift` — add MCP SDK dependency; add `clippy-mcp` executable target; add MCP product to `Clippy` target.
- `Sources/Clippy/Storage/ClipDatabase.swift` — add `clip(id:)`; factor out `ensureStarterCategoryID()`; add `setPinned(clipID:pinned:)`.
- `Sources/Clippy/AppDelegate.swift` — construct `ClippyMCPService` + `ClippyMCPController`; start/stop; drop `McpServerController`.
- `Sources/Clippy/UI/SettingsView.swift:903-987` — new integration panel.
- `scripts/make-app.sh` — copy + codesign `clippy-mcp`; delete Node bundling (lines 47-69).
- `.github/workflows/release.yml` — delete Node MCP CI steps (lines 124-129) and `REQUIRE_MCP`.

Deleted:
- `Sources/Clippy/Integrations/McpServerController.swift`
- `integrations/clippy-mcp/` (entire Node tree)

---

## Milestone 0: Dependency + scaffolding

### Task 0.1: Confirm toolchain supports the SDK

The MCP SDK's own manifest is `swift-tools-version: 6.1`. SwiftPM needs a Swift 6.1+ toolchain to resolve it.

- [ ] **Step 1: Check the toolchain**

Run: `swift --version`
Expected: version line shows Swift `6.1` or newer. If it shows < 6.1, STOP: install/select Xcode 16.3+ (`xcode-select -p` to check, `sudo xcode-select -s /Applications/Xcode.app` to switch) before continuing. Record the version in the commit message of Task 0.2.

### Task 0.2: Add the MCP SDK and the helper target to Package.swift

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Read the current manifest**

Run: `cat Package.swift`
Note the exact `dependencies:` array and the `Clippy` `.executableTarget` `dependencies:` list so the edits below splice in cleanly.

- [ ] **Step 2: Add the package dependency**

In the top-level `dependencies:` array, add:

```swift
.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
```

- [ ] **Step 3: Add the MCP product to the Clippy target**

In the `Clippy` `.executableTarget`'s `dependencies:` array, add:

```swift
.product(name: "MCP", package: "swift-sdk"),
```

- [ ] **Step 4: Add the helper executable target**

Add a new target to the `targets:` array (alongside the `Clippy` target). The target name becomes the produced binary name `clippy-mcp`:

```swift
.executableTarget(
    name: "clippy-mcp",
    path: "Sources/clippy-mcp"
),
```

- [ ] **Step 5: Create a placeholder helper main so the target compiles**

Create `Sources/clippy-mcp/main.swift`:

```swift
import Foundation

// Replaced in Milestone 3. Present now so the target resolves and builds.
FileHandle.standardError.write(Data("clippy-mcp: not yet implemented\n".utf8))
exit(1)
```

- [ ] **Step 6: Resolve and build**

Run: `swift build 2>&1 | tail -20`
Expected: dependency `swift-sdk` resolves and both `Clippy` and `clippy-mcp` build with no errors. If resolution fails on the tools version, revisit Task 0.1.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources/clippy-mcp/main.swift
git commit -m "build: add MCP Swift SDK dep and clippy-mcp helper target"
```

---

## Milestone 1: Shared tool layer (the DRY core)

### Task 1.1: Add the three missing ClipDatabase primitives

The service needs fetch-by-id and explicit pin set/unset. `toggleStarterMembership` already contains the "ensure the Pinned starter category exists" logic — factor that out so both it and the new setter reuse it (DRY).

**Files:**
- Modify: `Sources/Clippy/Storage/ClipDatabase.swift`
- Modify: `Sources/Clippy/Storage/ClipDatabase+Categories.swift`
- Test: `Tests/ClippyTests/ClipDatabaseMCPTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/ClippyTests/ClipDatabaseMCPTests.swift`:

```swift
import XCTest
import GRDB
@testable import Clippy

final class ClipDatabaseMCPTests: XCTestCase {
    private func makeDB() throws -> ClipDatabase {
        // Mirror how existing ClippyTests construct an in-memory/temp ClipDatabase.
        // If existing tests use ClipDatabase.shared with a temp file, copy that setup here.
        try ClipDatabase(inMemory: true)
    }

    func testClipByIdRoundTrips() throws {
        let db = try makeDB()
        let id = try db.insertTextClip("hello world")
        let fetched = try db.clip(id: id)
        XCTAssertEqual(fetched?.contentText, "hello world")
        XCTAssertNil(try db.clip(id: id + 9999))
    }

    func testSetPinnedAddsAndRemovesStarterMembership() throws {
        let db = try makeDB()
        let id = try db.insertTextClip("pin me")
        try db.setPinned(clipID: id, pinned: true)
        let starter = try XCTUnwrap(try db.starterCategoryID())
        XCTAssertTrue(try db.membershipMap()[id]?.contains(starter) ?? false)
        try db.setPinned(clipID: id, pinned: false)
        XCTAssertFalse(try db.membershipMap()[id]?.contains(starter) ?? false)
    }
}
```

Note: if `ClipDatabase` has no `init(inMemory:)`, use the same construction the existing `ClippyTests` use for a throwaway DB (open `Tests/ClippyTests` first and copy that helper). Replace `makeDB()` accordingly. Do not invent an initializer that does not exist.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClipDatabaseMCPTests 2>&1 | tail -20`
Expected: FAIL — `clip(id:)` and `setPinned` are not defined.

- [ ] **Step 3: Add `clip(id:)`**

In `Sources/Clippy/Storage/ClipDatabase.swift`, directly after `searchClips(matching:limit:)`, add (use the same DB-accessor the surrounding methods use — match the `dbQueue.read { db in ... }` form already in this file):

```swift
/// Fetch a single clip by primary key, or nil if it does not exist.
func clip(id: Int64) throws -> Clip? {
    try dbQueue.read { db in try Clip.fetchOne(db, key: id) }
}
```

- [ ] **Step 4: Factor out starter-id creation and add `setPinned`**

In `Sources/Clippy/Storage/ClipDatabase+Categories.swift`, locate `toggleStarterMembership(clipID:)`. Extract the part that finds-or-creates the starter category into:

```swift
/// Returns the id of the immutable "Pinned" starter category, creating it if absent.
func ensureStarterCategoryID() throws -> Int64 {
    if let id = try starterCategoryID() { return id }
    // Reuse the exact creation the old inline code in toggleStarterMembership used
    // (same name/color/icon/isStarter=true). Move that block here verbatim and
    // return the new category's id.
    let created = try createCategory(named: "Pinned", colorHex: "#FF9500",
                                     iconKind: .symbol, iconValue: "pin.fill")
    // Mark as starter using the same mechanism the original code used.
    var starter = created
    starter.isStarter = true
    try updateCategory(starter)
    return starter.id!
}
```

Then rewrite `toggleStarterMembership` to call `ensureStarterCategoryID()` for its id, and add the explicit setter:

```swift
/// Add or remove a clip's membership in the "Pinned" starter category (idempotent).
func setPinned(clipID: Int64, pinned: Bool) throws {
    let starterID = try ensureStarterCategoryID()
    try setClip(clipID, inCategory: starterID, pinned)
}
```

Caution: read the real `toggleStarterMembership` body first and move its existing find-or-create lines into `ensureStarterCategoryID` rather than guessing the starter's seed values — match whatever the app already uses so a second "Pinned" category is never created.

- [ ] **Step 5: Run tests**

Run: `swift test --filter ClipDatabaseMCPTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Clippy/Storage/ClipDatabase.swift Sources/Clippy/Storage/ClipDatabase+Categories.swift Tests/ClippyTests/ClipDatabaseMCPTests.swift
git commit -m "feat(storage): add clip(id:), ensureStarterCategoryID, setPinned"
```

### Task 1.2: Define the DTOs

**Files:**
- Create: `Sources/Clippy/Integrations/MCP/ClippyMCPDTOs.swift`

- [ ] **Step 1: Write the DTOs**

Create `Sources/Clippy/Integrations/MCP/ClippyMCPDTOs.swift`:

```swift
import Foundation

/// Plain, Codable transfer types returned by ClippyMCPService.
/// Kept separate from the GRDB models so the wire shape is stable and JSON-friendly.

struct ClipDTO: Codable, Equatable {
    let id: Int64
    let title: String
    let preview: String
    let kind: String          // "text" | "image"
    let createdAt: String     // ISO-8601
    var contentText: String?  // full text, populated by `get`
    var categoryIDs: [Int64]?
}

struct CategoryDTO: Codable, Equatable {
    let id: Int64
    let name: String
    let colorHex: String
    let iconKind: String
    let iconValue: String
    let sortOrder: Int
    let isStarter: Bool
}

struct ScriptDTO: Codable, Equatable {
    let id: String            // UUID string
    let name: String
    let interpreter: String
}

struct ScriptRunDTO: Codable, Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
    let durationMs: Int
}

struct AIActionDTO: Codable, Equatable {
    let id: String            // UUID string
    let name: String
}

struct AIRunDTO: Codable, Equatable {
    let label: String
    let proposed: String
    let kind: String
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/Clippy/Integrations/MCP/ClippyMCPDTOs.swift
git commit -m "feat(mcp): add Codable DTOs for the MCP tool layer"
```

### Task 1.3: Implement ClippyMCPService

**Files:**
- Create: `Sources/Clippy/Integrations/MCP/ClippyMCPService.swift`
- Test: `Tests/ClippyTests/ClippyMCPServiceTests.swift`

- [ ] **Step 1: Write failing tests for the clip + category surface**

Create `Tests/ClippyTests/ClippyMCPServiceTests.swift`:

```swift
import XCTest
@testable import Clippy

final class ClippyMCPServiceTests: XCTestCase {
    private func makeService() throws -> (ClippyMCPService, ClipDatabase) {
        let db = try ClipDatabase(inMemory: true)   // match Task 1.1's construction
        let svc = ClippyMCPService(
            database: db,
            scriptStore: ScriptStore.shared,
            aiActionStore: AIActionStore.shared,
            aiService: nil,        // AI paths tested separately / wired in AppDelegate
            pasteService: nil,
            monitor: nil
        )
        return (svc, db)
    }

    func testAddThenSearchThenGet() async throws {
        let (svc, _) = try makeService()
        let added = try await svc.add(text: "the quick brown fox", title: "Fox")
        XCTAssertEqual(added.title, "Fox")

        let hits = try await svc.search(query: "brown", limit: 10)
        XCTAssertTrue(hits.contains { $0.id == added.id })

        let full = try await svc.get(id: added.id)
        XCTAssertEqual(full?.contentText, "the quick brown fox")
    }

    func testEditAndDelete() async throws {
        let (svc, _) = try makeService()
        let c = try await svc.add(text: "before", title: nil)
        let edited = try await svc.edit(id: c.id, text: "after")
        XCTAssertEqual(edited.contentText, "after")
        try await svc.delete(id: c.id)
        XCTAssertNil(try await svc.get(id: c.id))
    }

    func testCreateRenameDeleteCategoryAndMembership() async throws {
        let (svc, _) = try makeService()
        let cat = try await svc.createCategory(name: "Work", colorHex: nil, iconKind: nil, iconValue: nil)
        let renamed = try await svc.renameCategory(id: cat.id, name: "Job")
        XCTAssertEqual(renamed.name, "Job")

        let clip = try await svc.add(text: "task", title: nil)
        try await svc.setCategory(clipID: clip.id, categoryID: cat.id, member: true)
        let got = try await svc.get(id: clip.id)
        XCTAssertTrue(got?.categoryIDs?.contains(cat.id) ?? false)

        try await svc.deleteCategory(id: cat.id)
        XCTAssertFalse(try await svc.listCategories().contains { $0.id == cat.id })
    }

    func testPin() async throws {
        let (svc, db) = try makeService()
        let clip = try await svc.add(text: "pin", title: nil)
        try await svc.setPinned(id: clip.id, pinned: true)
        let starter = try XCTUnwrap(try db.starterCategoryID())
        XCTAssertTrue(try db.membershipMap()[clip.id]?.contains(starter) ?? false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClippyMCPServiceTests 2>&1 | tail -20`
Expected: FAIL — `ClippyMCPService` undefined.

- [ ] **Step 3: Implement the service**

Create `Sources/Clippy/Integrations/MCP/ClippyMCPService.swift`. All methods are `async` and run off the main actor; GRDB calls are already thread-safe. Paste hops to `@MainActor`.

```swift
import Foundation

/// The single tool layer. Every MCP tool (and, in Plan 2, every App Intent) calls
/// through here, so business logic lives in exactly one place. Reuses the app's
/// existing store/services rather than duplicating any clipboard logic.
final class ClippyMCPService: @unchecked Sendable {
    private let database: ClipDatabase
    private let scriptStore: ScriptStore
    private let aiActionStore: AIActionStore
    private let aiService: AIService?
    private let pasteService: PasteService?
    private let monitor: ClipboardMonitor?

    private let iso = ISO8601DateFormatter()

    init(database: ClipDatabase,
         scriptStore: ScriptStore,
         aiActionStore: AIActionStore,
         aiService: AIService?,
         pasteService: PasteService?,
         monitor: ClipboardMonitor?) {
        self.database = database
        self.scriptStore = scriptStore
        self.aiActionStore = aiActionStore
        self.aiService = aiService
        self.pasteService = pasteService
        self.monitor = monitor
    }

    // MARK: Mapping

    private func dto(_ clip: Clip, full: Bool) throws -> ClipDTO {
        let id = clip.id ?? -1
        var d = ClipDTO(
            id: id,
            title: clip.displayTitle,
            preview: clip.previewText,
            kind: clip.contentKind == .image ? "image" : "text",
            createdAt: iso.string(from: clip.createdAt),
            contentText: full ? clip.contentText : nil,
            categoryIDs: nil
        )
        if full, id >= 0 {
            d.categoryIDs = Array(try database.membershipMap()[id] ?? [])
        }
        return d
    }

    private func dto(_ c: Category) -> CategoryDTO {
        CategoryDTO(id: c.id ?? -1, name: c.name, colorHex: c.colorHex,
                    iconKind: String(describing: c.iconKind), iconValue: c.iconValue,
                    sortOrder: c.sortOrder, isStarter: c.isStarter)
    }

    // MARK: Clips

    func search(query: String, limit: Int) async throws -> [ClipDTO] {
        try database.searchClips(matching: query, limit: limit).map { try dto($0, full: false) }
    }

    func listRecent(limit: Int) async throws -> [ClipDTO] {
        try Array(database.allClips().prefix(limit)).map { try dto($0, full: false) }
    }

    func get(id: Int64) async throws -> ClipDTO? {
        guard let clip = try database.clip(id: id) else { return nil }
        return try dto(clip, full: true)
    }

    func add(text: String, title: String?) async throws -> ClipDTO {
        let id = try database.insertTextClip(text)
        if let title { try database.updateClipTitle(id: id, userTitle: title) }
        guard let clip = try database.clip(id: id) else { throw MCPServiceError.notFound("clip") }
        return try dto(clip, full: true)
    }

    func edit(id: Int64, text: String) async throws -> ClipDTO {
        try database.updateClipText(id: id, newText: text)
        guard let clip = try database.clip(id: id) else { throw MCPServiceError.notFound("clip") }
        return try dto(clip, full: true)
    }

    func delete(id: Int64) async throws {
        try database.deleteClip(id: id)
    }

    func setPinned(id: Int64, pinned: Bool) async throws {
        try database.setPinned(clipID: id, pinned: pinned)
    }

    // MARK: Categories

    func listCategories() async throws -> [CategoryDTO] {
        try database.categories().map(dto)
    }

    func createCategory(name: String, colorHex: String?, iconKind: String?, iconValue: String?) async throws -> CategoryDTO {
        let kind: CategoryIconKind = (iconKind == "emoji") ? .emoji : (iconKind == "appLogo" ? .appLogo : .symbol)
        let created = try database.createCategory(
            named: name,
            colorHex: colorHex ?? "#FF9500",
            iconKind: kind,
            iconValue: iconValue ?? "tag.fill"
        )
        return dto(created)
    }

    func renameCategory(id: Int64, name: String) async throws -> CategoryDTO {
        guard var cat = try database.categories().first(where: { $0.id == id }) else {
            throw MCPServiceError.notFound("category")
        }
        cat.name = name
        try database.updateCategory(cat)
        return dto(cat)
    }

    func deleteCategory(id: Int64) async throws {
        try database.deleteCategory(id: id)
    }

    func setCategory(clipID: Int64, categoryID: Int64, member: Bool) async throws {
        try database.setClip(clipID, inCategory: categoryID, member)
    }

    // MARK: Live actions

    @MainActor
    func pasteToFrontmost(id: Int64) async throws {
        guard let paste = pasteService else { throw MCPServiceError.unavailable("paste") }
        guard let clip = try database.clip(id: id) else { throw MCPServiceError.notFound("clip") }
        paste.paste(clip, asPlainText: false)
    }

    func listScripts() async throws -> [ScriptDTO] {
        scriptStore.scripts.map { ScriptDTO(id: $0.id.uuidString, name: $0.name,
                                            interpreter: String(describing: $0.interpreter)) }
    }

    func runScript(id: String, input: String?) async throws -> ScriptRunDTO {
        guard let uuid = UUID(uuidString: id), let script = scriptStore.script(id: uuid) else {
            throw MCPServiceError.notFound("script")
        }
        let r = await ScriptRunner.run(script, input: input)
        return ScriptRunDTO(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode,
                            timedOut: r.timedOut, durationMs: r.durationMs)
    }

    func listAIActions() async throws -> [AIActionDTO] {
        aiActionStore.actions.map { AIActionDTO(id: $0.id.uuidString, name: $0.name) }
    }

    func runAIAction(id: String, text: String, instruction: String?) async throws -> AIRunDTO {
        guard let service = aiService else { throw MCPServiceError.unavailable("ai") }
        guard let uuid = UUID(uuidString: id), let action = aiActionStore.action(id: uuid) else {
            throw MCPServiceError.notFound("aiAction")
        }
        let proposal = try await service.run(action: action, on: text, instruction: instruction ?? "")
        return AIRunDTO(label: proposal.label, proposed: proposal.proposed,
                        kind: String(describing: proposal.kind))
    }
}

enum MCPServiceError: LocalizedError {
    case notFound(String)
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let what): return "\(what) not found"
        case .unavailable(let what): return "\(what) is unavailable (app feature not initialized)"
        }
    }
}
```

Wiring caution: confirm the real property/case names while implementing — `Clip.contentKind` (`.text`/`.image`), `Category.iconKind` (`CategoryIconKind.symbol/.emoji/.appLogo`), `Script.interpreter`, `AIProposal.label/.proposed/.kind`, `ScriptResult.durationMs`. The map in the spec research lists all of these; if any differs, match the real declaration, do not rename the model.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ClippyMCPServiceTests 2>&1 | tail -20`
Expected: PASS (AI/paste paths are nil-guarded and not exercised here).

- [ ] **Step 5: Commit**

```bash
git add Sources/Clippy/Integrations/MCP/ClippyMCPService.swift Tests/ClippyTests/ClippyMCPServiceTests.swift
git commit -m "feat(mcp): shared ClippyMCPService tool layer over existing store/services"
```

---

## Milestone 2: MCP server + Unix-socket transport

### Task 2.1: MCPPaths — one source of truth for socket + helper paths

**Files:**
- Create: `Sources/Clippy/Integrations/MCP/MCPPaths.swift`

- [ ] **Step 1: Write it**

```swift
import Foundation

/// Canonical filesystem locations shared by the app and the helper binary.
/// Both processes run as the same user, so these resolve identically.
enum MCPPaths {
    /// ~/Library/Application Support/Clippy  (same dir ScriptStore/AIActionStore use).
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clippy", isDirectory: true)
    }

    /// The Unix domain socket. sun_path is capped at 104 bytes on macOS; this stays well under.
    static var socketURL: URL { supportDir.appendingPathComponent("clippy-mcp.sock") }
    static var socketPath: String { socketURL.path }

    /// The bundled helper binary inside the running app: Contents/MacOS/clippy-mcp.
    static var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/clippy-mcp")
            .path
    }

    static let bundleID = "com.jerry.clippy"

    static func ensureSupportDir() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 2: Build + commit**

Run: `swift build 2>&1 | tail -5` (expect clean)

```bash
git add Sources/Clippy/Integrations/MCP/MCPPaths.swift
git commit -m "feat(mcp): MCPPaths single source of truth for socket/helper paths"
```

### Task 2.2: UnixSocketListener

**Files:**
- Create: `Sources/Clippy/Integrations/MCP/UnixSocketListener.swift`
- Test: `Tests/ClippyTests/UnixSocketListenerTests.swift`

- [ ] **Step 1: Write a failing test**

Create `Tests/ClippyTests/UnixSocketListenerTests.swift`:

```swift
import XCTest
import Darwin
@testable import Clippy

final class UnixSocketListenerTests: XCTestCase {
    func testAcceptsAConnectionAndDeliversFD() throws {
        let path = NSTemporaryDirectory() + "clippy-test-\(getpid()).sock"
        unlink(path)
        let exp = expectation(description: "accepted")
        let listener = try UnixSocketListener(path: path)
        listener.onAccept = { fd in
            XCTAssertGreaterThanOrEqual(fd, 0)
            close(fd)
            exp.fulfill()
        }
        try listener.start()

        // Client connects.
        let cfd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&addr.sun_path.0, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(cfd, $0, len) }
        }
        XCTAssertEqual(rc, 0)
        wait(for: [exp], timeout: 2)
        close(cfd)
        listener.stop()
        unlink(path)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter UnixSocketListenerTests 2>&1 | tail -20`
Expected: FAIL — `UnixSocketListener` undefined.

- [ ] **Step 3: Implement the listener**

Create `Sources/Clippy/Integrations/MCP/UnixSocketListener.swift`:

```swift
import Foundation
import Darwin

/// Minimal AF_UNIX stream listener. Binds a socket file, accepts connections on a
/// background thread, and hands each accepted raw FD to `onAccept`. No TCP, no port.
final class UnixSocketListener {
    let path: String
    var onAccept: ((Int32) -> Void)?

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "clippy.mcp.accept")
    private var running = false

    init(path: String) throws {
        self.path = path
    }

    var isListening: Bool { listenFD >= 0 && running }

    func start() throws {
        unlink(path) // clear any stale socket file
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= cap else {
            close(fd); throw MCPListenerError.pathTooLong(path)
        }
        _ = path.withCString { strncpy(&addr.sun_path.0, $0, cap) }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE) }
        guard listen(fd, 8) == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        listenFD = fd
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            onAccept?(client)
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }
}

enum MCPListenerError: LocalizedError {
    case pathTooLong(String)
    var errorDescription: String? {
        switch self { case .pathTooLong(let p): return "Socket path too long: \(p)" }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter UnixSocketListenerTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clippy/Integrations/MCP/UnixSocketListener.swift Tests/ClippyTests/UnixSocketListenerTests.swift
git commit -m "feat(mcp): AF_UNIX socket listener with accept loop"
```

### Task 2.3: ClippyMCPServer — per-connection MCP.Server + tool registration

**Files:**
- Create: `Sources/Clippy/Integrations/MCP/ClippyMCPServer.swift`

This is the core wiring. One `MCP.Server` + `StdioTransport` per accepted socket FD, all handlers dispatching to `ClippyMCPService`.

- [ ] **Step 1: Implement the server**

Create `Sources/Clippy/Integrations/MCP/ClippyMCPServer.swift`:

```swift
import Foundation
import Darwin
import MCP
import System

/// Owns the UNIX socket listener and, per accepted connection, runs an MCP.Server
/// whose tools call ClippyMCPService. Lives off the main actor.
final class ClippyMCPServer: @unchecked Sendable {
    private let service: ClippyMCPService
    private let socketPath: String
    private var listener: UnixSocketListener?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()

    init(service: ClippyMCPService, socketPath: String = MCPPaths.socketPath) {
        self.service = service
        self.socketPath = socketPath
    }

    var isListening: Bool { listener?.isListening ?? false }

    func start() throws {
        try MCPPaths.ensureSupportDir()
        let l = try UnixSocketListener(path: socketPath)
        l.onAccept = { [weak self] fd in self?.handle(fd: fd) }
        try l.start()
        listener = l
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    func restart() throws {
        stop()
        try start()
    }

    func clearStaleSocket() {
        if !isListening { unlink(socketPath) }
    }

    // MARK: One connection -> one MCP.Server

    private func handle(fd: Int32) {
        Task.detached { [service, encoder] in
            let server = Server(
                name: "Clippy",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                capabilities: .init(tools: .init(listChanged: false))
            )

            await server.withMethodHandler(ListTools.self) { _ in
                .init(tools: ClippyTools.all)
            }

            await server.withMethodHandler(CallTool.self) { params in
                do {
                    let text = try await ClippyToolDispatcher.call(
                        name: params.name,
                        args: params.arguments ?? [:],
                        service: service,
                        encoder: encoder
                    )
                    return .init(content: [.text(text)], isError: false)
                } catch {
                    return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
                }
            }

            let sock = FileDescriptor(rawValue: fd)
            let transport = StdioTransport(input: sock, output: sock)
            do {
                try await server.start(transport: transport)
                await server.waitUntilCompleted()
            } catch {
                // connection ended or transport failed; nothing else to do
            }
            try? sock.close()
        }
    }
}
```

Note on `StdioTransport(input:output:)`: confirmed available in the SDK and FD-parameterized. If the pinned SDK tag exposes a different label (e.g. `fileDescriptor:`), adjust to the real initializer — verify against the resolved `swift-sdk` source in `.build/checkouts/swift-sdk/Sources/MCP/Base/Transports/StdioTransport.swift` while implementing.

- [ ] **Step 2: Build (expects ClippyTools/ClippyToolDispatcher missing)**

Run: `swift build 2>&1 | tail -10`
Expected: FAIL — `ClippyTools` and `ClippyToolDispatcher` undefined. They are Task 2.4.

### Task 2.4: Tool definitions + dispatcher

**Files:**
- Create: `Sources/Clippy/Integrations/MCP/ClippyTools.swift`
- Test: `Tests/ClippyTests/ClippyToolDispatcherTests.swift`

- [ ] **Step 1: Write a failing dispatcher test (in-memory, no socket)**

Create `Tests/ClippyTests/ClippyToolDispatcherTests.swift`:

```swift
import XCTest
import MCP
@testable import Clippy

final class ClippyToolDispatcherTests: XCTestCase {
    private func makeService() throws -> ClippyMCPService {
        ClippyMCPService(database: try ClipDatabase(inMemory: true),
                         scriptStore: ScriptStore.shared, aiActionStore: AIActionStore.shared,
                         aiService: nil, pasteService: nil, monitor: nil)
    }

    func testListToolsCoversTheSurface() {
        let names = Set(ClippyTools.all.map { $0.name })
        XCTAssertTrue(names.isSuperset(of: [
            "clippy_search", "clippy_list_recent", "clippy_get", "clippy_add",
            "clippy_edit", "clippy_delete", "clippy_pin",
            "clippy_list_categories", "clippy_create_category", "clippy_rename_category",
            "clippy_delete_category", "clippy_set_category",
            "clippy_paste_to_frontmost", "clippy_list_scripts", "clippy_run_script",
            "clippy_list_ai_actions", "clippy_run_ai_action"
        ]))
    }

    func testAddThenSearchThroughDispatcher() async throws {
        let svc = try makeService()
        let enc = JSONEncoder()
        _ = try await ClippyToolDispatcher.call(name: "clippy_add",
            args: ["text": .string("dispatcher fox"), "title": .string("T")],
            service: svc, encoder: enc)
        let out = try await ClippyToolDispatcher.call(name: "clippy_search",
            args: ["query": .string("fox"), "limit": .int(5)],
            service: svc, encoder: enc)
        XCTAssertTrue(out.contains("dispatcher fox"))
    }

    func testUnknownToolThrows() async {
        let svc = try! makeService()
        await XCTAssertThrowsErrorAsync(
            try await ClippyToolDispatcher.call(name: "nope", args: [:], service: svc, encoder: JSONEncoder())
        )
    }
}

// Small async-throws assertion helper if the codebase lacks one.
func XCTAssertThrowsErrorAsync(_ expr: @autoclosure () async throws -> Void,
                              file: StaticString = #file, line: UInt = #line) async {
    do { try await expr(); XCTFail("expected throw", file: file, line: line) }
    catch { /* ok */ }
}
```

If `XCTAssertThrowsErrorAsync` already exists in the test target, delete the local copy to avoid a redeclaration.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClippyToolDispatcherTests 2>&1 | tail -20`
Expected: FAIL — `ClippyTools` / `ClippyToolDispatcher` undefined.

- [ ] **Step 3: Implement tools + dispatcher**

Create `Sources/Clippy/Integrations/MCP/ClippyTools.swift`:

```swift
import Foundation
import MCP

/// Tool catalog (the `tools/list` payload) plus the call dispatcher.
enum ClippyTools {
    private static func obj(_ props: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) })
        ])
    }
    private static func str(_ desc: String) -> Value { .object(["type": .string("string"), "description": .string(desc)]) }
    private static func int(_ desc: String) -> Value { .object(["type": .string("integer"), "description": .string(desc)]) }
    private static func bool(_ desc: String) -> Value { .object(["type": .string("boolean"), "description": .string(desc)]) }

    static let all: [Tool] = [
        Tool(name: "clippy_search", description: "Full-text search the clipboard history.",
             inputSchema: obj(["query": str("Search text"), "limit": int("Max results (default 25)")], required: ["query"])),
        Tool(name: "clippy_list_recent", description: "List the most recent clips, newest first.",
             inputSchema: obj(["limit": int("Max results (default 25)")])),
        Tool(name: "clippy_get", description: "Get one clip in full by id.",
             inputSchema: obj(["id": int("Clip id")], required: ["id"])),
        Tool(name: "clippy_add", description: "Add a new text clip.",
             inputSchema: obj(["text": str("Clip text"), "title": str("Optional title")], required: ["text"])),
        Tool(name: "clippy_edit", description: "Replace the text of an existing clip.",
             inputSchema: obj(["id": int("Clip id"), "text": str("New text")], required: ["id", "text"])),
        Tool(name: "clippy_delete", description: "Delete a clip by id.",
             inputSchema: obj(["id": int("Clip id")], required: ["id"])),
        Tool(name: "clippy_pin", description: "Pin or unpin a clip (Pinned category membership).",
             inputSchema: obj(["id": int("Clip id"), "pinned": bool("true to pin, false to unpin")], required: ["id", "pinned"])),
        Tool(name: "clippy_list_categories", description: "List all categories/pinboards.",
             inputSchema: obj([:])),
        Tool(name: "clippy_create_category", description: "Create a category.",
             inputSchema: obj(["name": str("Category name"), "colorHex": str("Hex color, default #FF9500"),
                               "iconKind": str("symbol|emoji|appLogo, default symbol"), "iconValue": str("SF Symbol/emoji/bundle id")],
                              required: ["name"])),
        Tool(name: "clippy_rename_category", description: "Rename a category.",
             inputSchema: obj(["id": int("Category id"), "name": str("New name")], required: ["id", "name"])),
        Tool(name: "clippy_delete_category", description: "Delete a category.",
             inputSchema: obj(["id": int("Category id")], required: ["id"])),
        Tool(name: "clippy_set_category", description: "Add or remove a clip's membership in a category.",
             inputSchema: obj(["clipId": int("Clip id"), "categoryId": int("Category id"), "member": bool("true to add, false to remove")],
                              required: ["clipId", "categoryId", "member"])),
        Tool(name: "clippy_paste_to_frontmost", description: "Paste a clip into the frontmost app (requires Accessibility).",
             inputSchema: obj(["id": int("Clip id")], required: ["id"])),
        Tool(name: "clippy_list_scripts", description: "List the user's saved Scripts.",
             inputSchema: obj([:])),
        Tool(name: "clippy_run_script", description: "Run a saved Script, optionally feeding it input text.",
             inputSchema: obj(["id": str("Script UUID"), "input": str("Optional stdin text")], required: ["id"])),
        Tool(name: "clippy_list_ai_actions", description: "List the user's AI Actions.",
             inputSchema: obj([:])),
        Tool(name: "clippy_run_ai_action", description: "Run an AI Action against text and return the result.",
             inputSchema: obj(["id": str("AI Action UUID"), "text": str("Input text"), "instruction": str("Optional extra instruction")],
                              required: ["id", "text"])),
    ]
}

enum ClippyToolDispatcher {
    /// Decode args, call the service, JSON-encode the result to a text payload.
    static func call(name: String, args: [String: Value],
                     service: ClippyMCPService, encoder: JSONEncoder) async throws -> String {
        func s(_ k: String) throws -> String {
            guard let v = args[k]?.stringValue else { throw MCPServiceError.notFound("argument \(k)") }
            return v
        }
        func i(_ k: String) throws -> Int64 {
            if let n = args[k]?.intValue { return Int64(n) }
            if let n = args[k]?.stringValue, let parsed = Int64(n) { return parsed }
            throw MCPServiceError.notFound("argument \(k)")
        }
        func b(_ k: String) throws -> Bool {
            guard let v = args[k]?.boolValue else { throw MCPServiceError.notFound("argument \(k)") }
            return v
        }
        func optS(_ k: String) -> String? { args[k]?.stringValue }
        func optLimit() -> Int { args["limit"]?.intValue ?? 25 }

        func json<T: Encodable>(_ v: T) throws -> String {
            String(decoding: try encoder.encode(v), as: UTF8.self)
        }

        switch name {
        case "clippy_search":          return try await json(service.search(query: try s("query"), limit: optLimit()))
        case "clippy_list_recent":     return try await json(service.listRecent(limit: optLimit()))
        case "clippy_get":
            if let dto = try await service.get(id: try i("id")) { return try json(dto) }
            return "null"
        case "clippy_add":             return try await json(service.add(text: try s("text"), title: optS("title")))
        case "clippy_edit":            return try await json(service.edit(id: try i("id"), text: try s("text")))
        case "clippy_delete":          try await service.delete(id: try i("id")); return "{\"ok\":true}"
        case "clippy_pin":             try await service.setPinned(id: try i("id"), pinned: try b("pinned")); return "{\"ok\":true}"
        case "clippy_list_categories": return try await json(service.listCategories())
        case "clippy_create_category": return try await json(service.createCategory(name: try s("name"),
                                            colorHex: optS("colorHex"), iconKind: optS("iconKind"), iconValue: optS("iconValue")))
        case "clippy_rename_category": return try await json(service.renameCategory(id: try i("id"), name: try s("name")))
        case "clippy_delete_category": try await service.deleteCategory(id: try i("id")); return "{\"ok\":true}"
        case "clippy_set_category":    try await service.setCategory(clipID: try i("clipId"), categoryID: try i("categoryId"), member: try b("member")); return "{\"ok\":true}"
        case "clippy_paste_to_frontmost": try await service.pasteToFrontmost(id: try i("id")); return "{\"ok\":true}"
        case "clippy_list_scripts":    return try await json(service.listScripts())
        case "clippy_run_script":      return try await json(service.runScript(id: try s("id"), input: optS("input")))
        case "clippy_list_ai_actions": return try await json(service.listAIActions())
        case "clippy_run_ai_action":   return try await json(service.runAIAction(id: try s("id"), text: try s("text"), instruction: optS("instruction")))
        default: throw MCPServiceError.notFound("tool \(name)")
        }
    }
}
```

Caution: `Value`'s accessor names (`stringValue`, `intValue`, `boolValue`) are from the SDK research. Confirm against `.build/checkouts/swift-sdk/Sources/MCP/Base/Value.swift`; if an accessor differs, adjust the three helper funcs only.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ClippyToolDispatcherTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Full build**

Run: `swift build 2>&1 | tail -5`
Expected: `ClippyMCPServer` now builds (its references resolve).

- [ ] **Step 6: Commit**

```bash
git add Sources/Clippy/Integrations/MCP/ClippyTools.swift Sources/Clippy/Integrations/MCP/ClippyMCPServer.swift Tests/ClippyTests/ClippyToolDispatcherTests.swift
git commit -m "feat(mcp): tool catalog, dispatcher, and per-connection MCP server"
```

---

## Milestone 3: The helper binary

### Task 3.1: Implement `clippy-mcp` (stdio <-> UDS pipe + auto-launch)

**Files:**
- Modify: `Sources/clippy-mcp/main.swift`

- [ ] **Step 1: Replace the placeholder**

Overwrite `Sources/clippy-mcp/main.swift`:

```swift
import Foundation
import Darwin

// clippy-mcp: the binary MCP clients spawn. It connects to the running Clippy app's
// Unix domain socket and splices stdin <-> socket <-> stdout. Zero protocol logic; a
// dumb, dependency-free byte pipe, so it spawns instantly and cannot hang the client.

let supportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Clippy", isDirectory: true)
let socketPath = supportDir.appendingPathComponent("clippy-mcp.sock").path
let bundleID = "com.jerry.clippy"

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func connectOnce() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path) - 1
    if socketPath.utf8.count > cap { close(fd); return nil }
    _ = socketPath.withCString { strncpy(&addr.sun_path.0, $0, cap) }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    if rc == 0 { return fd }
    close(fd)
    return nil
}

func launchApp() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", bundleID]   // -g: don't steal focus
    try? p.run()
}

// Try to connect; if the app isn't up, launch it and poll for up to ~10s.
var sockFD = connectOnce()
if sockFD == nil {
    launchApp()
    for _ in 0..<100 {
        usleep(100_000) // 100ms
        if let fd = connectOnce() { sockFD = fd; break }
    }
}
guard let fd = sockFD else {
    err("clippy-mcp: could not reach Clippy. Is the app installed and allowed to run?")
    exit(1)
}

// Bidirectional splice: one thread stdin->socket, main loop socket->stdout. EOF ends both.
let bufSize = 65536
let group = DispatchGroup()
group.enter()
Thread.detached {
    var buf = [UInt8](repeating: 0, count: bufSize)
    while true {
        let n = read(0, &buf, bufSize)
        if n <= 0 { break }
        var off = 0
        while off < n {
            let w = write(fd, &buf[off], n - off)
            if w <= 0 { break }
            off += w
        }
    }
    shutdown(fd, SHUT_WR)
    group.leave()
}

var buf = [UInt8](repeating: 0, count: bufSize)
while true {
    let n = read(fd, &buf, bufSize)
    if n <= 0 { break }
    var off = 0
    while off < n {
        let w = write(1, &buf[off], n - off)
        if w <= 0 { break }
        off += w
    }
}
group.wait()
close(fd)
exit(0)
```

Note: `Thread.detached(_:)` is used to avoid pulling in any concurrency runtime; if the project prefers, a `DispatchQueue.global().async` block is equivalent. Keep the helper free of the MCP/GRDB dependencies — it must stay tiny.

- [ ] **Step 2: Build the helper**

Run: `swift build --product clippy-mcp 2>&1 | tail -5`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/clippy-mcp/main.swift
git commit -m "feat(mcp): clippy-mcp helper — stdio<->unix-socket pipe with auto-launch"
```

### Task 3.2: Round-trip regression test (the < 2s guard)

This is the direct guard against the old 4-minute timeout. It stands up a `ClippyMCPServer` on a temp socket in-process, then drives a real MCP `initialize` + `tools/list` + `clippy_add` over that socket and asserts a fast response. (It exercises the server+transport over a real socket without needing the bundled app, so it runs in CI.)

**Files:**
- Create: `Tests/ClippyTests/MCPRoundTripTests.swift`

- [ ] **Step 1: Write the test**

Create `Tests/ClippyTests/MCPRoundTripTests.swift`:

```swift
import XCTest
import Darwin
@testable import Clippy

final class MCPRoundTripTests: XCTestCase {
    func testInitializeListAndCallUnderTwoSeconds() async throws {
        let path = NSTemporaryDirectory() + "clippy-rt-\(getpid()).sock"
        unlink(path)
        let svc = ClippyMCPService(database: try ClipDatabase(inMemory: true),
                                   scriptStore: ScriptStore.shared, aiActionStore: AIActionStore.shared,
                                   aiService: nil, pasteService: nil, monitor: nil)
        let server = ClippyMCPServer(service: svc, socketPath: path)
        try server.start()
        defer { server.stop(); unlink(path) }

        // Raw client: connect, send newline-delimited JSON-RPC, read responses.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&addr.sun_path.0, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        XCTAssertEqual(rc, 0)
        defer { close(fd) }

        func send(_ s: String) { _ = (s + "\n").withCString { write(fd, $0, strlen($0)) } }
        func readSome(timeout: TimeInterval) -> String {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buf, buf.count)
            return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
        }

        let start = Date()
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        let initResp = readSome(timeout: 2)
        XCTAssertTrue(initResp.contains("\"id\":1"), "no initialize response: \(initResp)")

        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let listResp = readSome(timeout: 2)
        XCTAssertTrue(listResp.contains("clippy_search"), "tools/list missing tools: \(listResp)")

        send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"clippy_add","arguments":{"text":"round trip"}}}"#)
        let callResp = readSome(timeout: 2)
        XCTAssertTrue(callResp.contains("round trip"), "tools/call result wrong: \(callResp)")

        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "round trip exceeded 2s budget")
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter MCPRoundTripTests 2>&1 | tail -30`
Expected: PASS, well under 2s. If `initialize` gets no response, verify the `StdioTransport(input:output:)` FD wiring in Task 2.3 against the resolved SDK source; if framing looks off, confirm the transport is newline-delimited.

- [ ] **Step 3: Commit**

```bash
git add Tests/ClippyTests/MCPRoundTripTests.swift
git commit -m "test(mcp): sub-2s initialize+list+call round trip over the socket"
```

---

## Milestone 4: AppDelegate wiring + controller

### Task 4.1: ClippyMCPController (replaces McpServerController)

**Files:**
- Create: `Sources/Clippy/Integrations/MCP/ClippyMCPController.swift`

- [ ] **Step 1: Implement the controller**

```swift
import Foundation
import Combine

/// UI-facing wrapper around ClippyMCPServer. Owns enable state and exposes status,
/// paths, and the force-reset actions the settings panel binds to.
@MainActor
final class ClippyMCPController: ObservableObject {
    enum Status: Equatable { case stopped, listening, failed(String) }

    @Published private(set) var status: Status = .stopped
    @Published var isEnabled: Bool {
        didSet {
            AppSettings.shared.mcpEnabled = isEnabled   // see Step 2 for the setting
            isEnabled ? start() : stop()
        }
    }

    let socketPath = MCPPaths.socketPath
    var helperPath: String { MCPPaths.helperPath }

    private let server: ClippyMCPServer

    init(service: ClippyMCPService) {
        self.server = ClippyMCPServer(service: service)
        self.isEnabled = AppSettings.shared.mcpEnabled
        if isEnabled { start() }
    }

    func start() {
        do { try server.start(); status = .listening }
        catch { status = .failed(error.localizedDescription) }
    }

    func stop() {
        server.stop()
        status = .stopped
    }

    func restart() {
        do { try server.restart(); status = .listening }
        catch { status = .failed(error.localizedDescription) }
    }

    func clearStaleSocket() { server.clearStaleSocket() }
}
```

- [ ] **Step 2: Add the `mcpEnabled` setting**

In the app's settings store (the type referenced as `AppSettings.shared` — open it first to match its pattern, likely `@AppStorage`/`UserDefaults`-backed), add a `Bool` `mcpEnabled` (default `true`). If a port-based MCP setting exists from the old controller, migrate: treat any previously-stored "mcp enabled/port present" as `mcpEnabled = true`, then remove the port key. Match the existing property style in that file; do not introduce a new settings mechanism.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -10`
Expected: clean (old `McpServerController` still present; removed in Task 4.3).

- [ ] **Step 4: Commit**

```bash
git add Sources/Clippy/Integrations/MCP/ClippyMCPController.swift Sources/Clippy/Support/AppSettings.swift
git commit -m "feat(mcp): ClippyMCPController + mcpEnabled setting"
```

(Adjust the `AppSettings.swift` path to the real settings file.)

### Task 4.2: Construct the service + controller in AppDelegate

**Files:**
- Modify: `Sources/Clippy/AppDelegate.swift`

- [ ] **Step 1: Find the live service instances**

Open `Sources/Clippy/AppDelegate.swift`. Locate the already-constructed `pasteService` (`PasteService(monitor:)`), the `monitor` (`ClipboardMonitor`), and how the app obtains an `AIService` (search for `AIService(` in the project; reuse the same construction the editor/AI UI uses). Note them.

- [ ] **Step 2: Wire it in `applicationDidFinishLaunching`**

Replace the line `McpServerController.shared.syncWithSettings()` (around `AppDelegate.swift:91`) with:

```swift
// Native MCP integration (replaces the old Node subprocess controller).
let mcpService = ClippyMCPService(
    database: ClipDatabase.shared,
    scriptStore: ScriptStore.shared,
    aiActionStore: AIActionStore.shared,
    aiService: self.aiService,        // the same instance the UI uses; construct one if none exists
    pasteService: self.pasteService,
    monitor: self.monitor
)
self.mcpController = ClippyMCPController(service: mcpService)
```

Add a stored property near the other service properties:

```swift
private(set) var mcpController: ClippyMCPController!
```

If there is no existing shared `aiService` property, add one constructed the same way the AI editor builds it, e.g. `let aiService = AIService(...)` using the real initializer found in Step 1.

- [ ] **Step 3: Stop on terminate**

In `applicationWillTerminate` (around `AppDelegate.swift:445`), replace the old `McpServerController.shared.stop()` with:

```swift
mcpController?.stop()
```

- [ ] **Step 4: Build + run the app**

Run: `swift build 2>&1 | tail -10` (expect clean)
Run: `scripts/make-app.sh && open build/Clippy.app` (or the script's documented output path), then confirm via `lsof -U | grep clippy-mcp.sock` that the socket is listening once the app is up.
Expected: the socket file exists and the app is listening.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clippy/AppDelegate.swift
git commit -m "feat(mcp): start native MCP controller from AppDelegate"
```

### Task 4.3: Delete the old McpServerController

**Files:**
- Delete: `Sources/Clippy/Integrations/McpServerController.swift`

- [ ] **Step 1: Find remaining references**

Run: `grep -rn "McpServerController" Sources/ Tests/`
Expected: only `SettingsView.swift` still references it (handled in Milestone 6). If `AppDelegate` still references it, fix per Task 4.2 first.

- [ ] **Step 2: Remove the file**

Run: `git rm Sources/Clippy/Integrations/McpServerController.swift`

- [ ] **Step 3: Build (SettingsView will break — expected)**

Run: `swift build 2>&1 | tail -20`
Expected: FAIL only in `SettingsView.swift` (old MCP tab). Fixed in Milestone 6. Do not commit a broken build; proceed straight to Milestone 6 next, then commit the deletion together with the new settings UI.

---

## Milestone 5: Remove Node + update build/CI

### Task 5.1: Delete the Node MCP tree and its build/CI steps

**Files:**
- Delete: `integrations/clippy-mcp/`
- Modify: `scripts/make-app.sh`
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Delete the Node tree**

Run: `git rm -r integrations/clippy-mcp`

- [ ] **Step 2: Remove Node bundling from make-app.sh**

Open `scripts/make-app.sh`. Delete the MCP bundling block (lines ~47-69: the section that copies `clippy-mcp/index.mjs` into `Contents/Resources` and the `REQUIRE_MCP` handling). Verify nothing else references `REQUIRE_MCP` or `index.mjs`:

Run: `grep -n "REQUIRE_MCP\|index.mjs\|clippy-mcp" scripts/make-app.sh`
Expected after edit: the only `clippy-mcp` hits are the new helper-copy/codesign lines added in Task 5.2 (none yet at this step).

- [ ] **Step 3: Remove Node CI steps**

Open `.github/workflows/release.yml`. Delete the MCP npm steps (lines ~124-129: `npm ci` / `npm run typecheck` / `npm test` for `integrations/clippy-mcp`) and remove `REQUIRE_MCP=1` from the two `make-app.sh` invocations.

Run: `grep -n "clippy-mcp\|REQUIRE_MCP" .github/workflows/release.yml`
Expected: no remaining Node references.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(mcp): remove bundled Node.js MCP server and its build/CI steps"
```

### Task 5.2: Bundle + codesign the helper binary

**Files:**
- Modify: `scripts/make-app.sh`

- [ ] **Step 1: Copy the helper into the bundle**

In `scripts/make-app.sh`, right after the line that copies the main binary (`cp .build/release/Clippy "$APP/Contents/MacOS/Clippy"`, ~line 41), add:

```bash
cp .build/release/clippy-mcp "$APP/Contents/MacOS/clippy-mcp"
```

- [ ] **Step 2: Codesign the helper before the outer app**

In the codesigning section, insert a codesign for the helper immediately before the `Clippy.app` outer-envelope signing (after the Sparkle framework is signed, before line ~177). Only runs when an identity is set:

```bash
if [ -n "$CODESIGN_IDENTITY" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
    "$APP/Contents/MacOS/clippy-mcp"
fi
```

For local ad-hoc builds (`codesign --sign -`), add the helper to that path too so the ad-hoc signature covers it, matching how the main binary is ad-hoc signed.

- [ ] **Step 3: Build the bundle and verify both binaries are signed**

Run: `scripts/make-app.sh 1.6.0`
Run: `codesign -dv "build/Clippy.app/Contents/MacOS/clippy-mcp" 2>&1 | tail -3`
Expected: the helper is present and signed; `codesign --verify --deep build/Clippy.app` passes.

- [ ] **Step 4: Commit**

```bash
git add scripts/make-app.sh
git commit -m "build(mcp): bundle and codesign the clippy-mcp helper in the app"
```

---

## Milestone 6: Settings panel

### Task 6.1: Replace the MCP settings tab

**Files:**
- Modify: `Sources/Clippy/UI/SettingsView.swift:903-987`

This fixes the build break from Task 4.3 and delivers the panel from the spec: status, socket + helper rows with reveal-in-Finder buttons, Restart, Clear stale socket, and a Connect Claude Desktop button (needed for E2E).

- [ ] **Step 1: Read the current tab + how the view gets the controller**

Open `SettingsView.swift` around 903-987 and find how it currently reaches `McpServerController` (an `@ObservedObject`, an environment object, or a singleton). The new `ClippyMCPController` is owned by `AppDelegate` (Task 4.2). Inject it the same way the app injects other AppDelegate-owned controllers into Settings (search for how `editorController`/`store` reach `SettingsView`). Match that pattern.

- [ ] **Step 2: Write the new panel**

Replace the MCP section body with (bind `@ObservedObject var mcp: ClippyMCPController`):

```swift
Section("Integration (MCP + Shortcuts)") {
    Toggle("Enable clippy integration", isOn: $mcp.isEnabled)

    HStack {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
        Text(statusText)
            .foregroundStyle(.secondary)
        Spacer()
        Text((mcp.socketPath as NSString).lastPathComponent)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
        Button { revealInFinder(mcp.socketPath) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Reveal the socket file in Finder")
            .disabled(!FileManager.default.fileExists(atPath: mcp.socketPath))
    }

    HStack {
        Text("Helper").foregroundStyle(.secondary)
        Text("clippy-mcp").font(.caption.monospaced())
        Spacer()
        Button { revealInFinder(mcp.helperPath) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Reveal the clippy-mcp helper in Finder")
            .disabled(!FileManager.default.fileExists(atPath: mcp.helperPath))
    }

    HStack {
        Button("Connect Claude Desktop") { connectClaudeDesktop() }
        Spacer()
        Button("Restart listener") { mcp.restart() }
        Button("Clear stale socket") { mcp.clearStaleSocket() }
            .disabled(mcp.status == .listening)
    }
    .disabled(!mcp.isEnabled)

    if let msg = connectMessage {
        Text(msg).font(.caption).foregroundStyle(.secondary)
    }
}
```

Add the supporting computed props + helpers in the same view:

```swift
private var statusColor: Color {
    switch mcp.status { case .listening: return .green; case .stopped: return .secondary; case .failed: return .orange }
}
private var statusText: String {
    switch mcp.status {
    case .listening: return "Listening"
    case .stopped: return "Stopped"
    case .failed(let m): return "Error: \(m)"
    }
}
@State private var connectMessage: String?

private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
private func connectClaudeDesktop() {
    do { try ClaudeDesktopInstaller.install(helperPath: mcp.helperPath)
         connectMessage = "Added to Claude Desktop. Restart Claude Desktop to load it." }
    catch { connectMessage = "Could not write Claude config: \(error.localizedDescription)" }
}
```

Remove every remaining reference to the old `McpServerController`, the port field, `isPortFree`, and `testConnection` in this file.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -10`
Expected: clean — the Task 4.3 break is now resolved.

- [ ] **Step 4: Commit the deletion + new UI together**

```bash
git add Sources/Clippy/UI/SettingsView.swift Sources/Clippy/Integrations/McpServerController.swift
git commit -m "feat(mcp): new integration settings panel; remove old port-based MCP tab"
```

### Task 6.2: ClaudeDesktopInstaller

**Files:**
- Create: `Sources/Clippy/Integrations/MCP/ClaudeDesktopInstaller.swift`
- Test: `Tests/ClippyTests/ClaudeDesktopInstallerTests.swift`

- [ ] **Step 1: Write a failing test (pure JSON merge, no real config path)**

Create `Tests/ClippyTests/ClaudeDesktopInstallerTests.swift`:

```swift
import XCTest
@testable import Clippy

final class ClaudeDesktopInstallerTests: XCTestCase {
    func testMergeAddsClippyEntryPreservingOthers() throws {
        let existing = #"{"mcpServers":{"other":{"command":"x"}}}"#.data(using: .utf8)!
        let merged = try ClaudeDesktopInstaller.merge(existing: existing, helperPath: "/Apps/Clippy.app/Contents/MacOS/clippy-mcp")
        let obj = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        let servers = obj["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["other"])
        let clippy = servers["clippy"] as! [String: Any]
        XCTAssertEqual(clippy["command"] as? String, "/Apps/Clippy.app/Contents/MacOS/clippy-mcp")
    }

    func testMergeFromEmpty() throws {
        let merged = try ClaudeDesktopInstaller.merge(existing: nil, helperPath: "/h/clippy-mcp")
        let obj = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        let servers = obj["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["clippy"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClaudeDesktopInstallerTests 2>&1 | tail -20`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Writes a `clippy` entry into Claude Desktop's config, pointing `command` at the
/// bundled helper. No npx, no port — exactly what makes install robust.
enum ClaudeDesktopInstaller {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Pure, testable merge: insert/replace mcpServers.clippy in `existing` JSON.
    static func merge(existing: Data?, helperPath: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty,
           let obj = try JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = obj
        }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers["clippy"] = ["command": helperPath]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func install(helperPath: String) throws {
        let url = configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let existing = try? Data(contentsOf: url)
        let merged = try merge(existing: existing, helperPath: helperPath)
        try merged.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ClaudeDesktopInstallerTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clippy/Integrations/MCP/ClaudeDesktopInstaller.swift Tests/ClippyTests/ClaudeDesktopInstallerTests.swift
git commit -m "feat(mcp): Claude Desktop one-click install writing the helper command"
```

---

## Milestone 7: Full-suite green + real end-to-end verification

### Task 7.1: Whole test suite

- [ ] **Step 1: Run everything**

Run: `swift test 2>&1 | tail -30`
Expected: all tests pass, including `MCPRoundTripTests` under 2s. Fix any regressions before continuing.

- [ ] **Step 2: Commit any fixes**

```bash
git add -A && git commit -m "test(mcp): green full suite for native MCP integration"
```

### Task 7.2: End-to-end with Claude Desktop (manual, evidence required)

- [ ] **Step 1: Build, sign, install**

Run: `scripts/make-app.sh 1.6.0`
Then copy `build/Clippy.app` to `/Applications` and launch it. Confirm the menu-bar item appears and `lsof -U | grep clippy-mcp.sock` shows the app listening.

- [ ] **Step 2: Connect Claude Desktop**

In clippy Settings -> Integration, click "Connect Claude Desktop". Then fully quit and reopen Claude Desktop.
Run (to confirm the config): `cat "$HOME/Library/Application Support/Claude/claude_desktop_config.json"`
Expected: an `mcpServers.clippy.command` pointing at `/Applications/Clippy.app/Contents/MacOS/clippy-mcp`.

- [ ] **Step 3: Exercise the tools from Claude Desktop**

In Claude Desktop, confirm the `clippy` MCP server shows as connected, then run `clippy_list_categories` and `clippy_add` (then check the new clip appears in clippy). Capture: a screenshot or the tool-call transcript showing a response in seconds, not minutes.
Expected: tool calls return promptly. This is the acceptance criterion that the original timeout is gone.

- [ ] **Step 4: Negative path — app not running**

Quit clippy. In Claude Desktop trigger a clippy tool. The helper should auto-launch clippy and then succeed (or, if launch is blocked, return the clear "could not reach Clippy" error rather than hanging).
Expected: either auto-recovery or a fast, clear error — never a multi-minute hang.

- [ ] **Step 5: Record the result**

Note in the final commit message what was verified (which tools, observed latency). Do not claim success without the captured evidence from Step 3.

---

## Done criteria (Plan 1)

- `swift test` green, including the sub-2s round-trip guard.
- No Node, no `mcp-remote`, no `isPortFree`, no port field anywhere (`grep -rn "isPortFree\|mcp-remote\|index.mjs" .` returns nothing in tracked source).
- Claude Desktop reaches clippy through the bundled helper and runs tools in seconds, with captured evidence.
- Settings shows status, reveals the socket and helper in Finder, and can Restart / Clear stale socket.
- Both `Clippy` and `clippy-mcp` are codesigned in the bundle.

Plan 2 (separate doc) then adds: App Intents (Shortcuts/Siri/Spotlight), one-click connect for Claude Code / Cursor / VS Code, and the live connected-clients list.
