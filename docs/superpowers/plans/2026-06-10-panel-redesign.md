# Clippy Panel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the pinned-at-top single column with a category side pane (tag model), add full image clipboard support, and fix card/legend legibility, per `docs/superpowers/specs/2026-06-10-panel-redesign-design.md`.

**Architecture:** Evolve the existing floating panel in place. Two new GRDB tables (`category`, `clip_category`) replace the `isPinned` flag; a `MediaStore` owns image files on disk while the DB stores filenames; the panel becomes a 75/25 split with a state-driven slide between History and a selected category.

**Tech Stack:** Swift 5 mode under swift-tools 6.0, SwiftPM, GRDB 7, SwiftUI + AppKit, XCTest. macOS 14 target.

**Build/test commands:** `swift build` and `swift test` from the repo root. UI smoke: `swift run Clippy --show-panel`.

**Conventions for this codebase:** Comments explain why, not what. No force-unwraps outside tests. Match existing file style (4-space indent, `// MARK: -` sections).

---

### Task 1: Initialize git and commit the baseline

The folder is not a git repository, and this plan relies on per-task commits.

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Init repo**

```bash
cd /Users/jerry/Downloads/clippy
git init -b main
```

- [ ] **Step 2: Create `.gitignore`** (deny-by-default allowlist)

```gitignore
# Deny everything first
*
/**
/.*
/.*/
.DS_Store

# Global sensitive-file protection
.env
.env.*
!.env.example
*.key
*.pem
*.p12
*.sqlite
*.dump
*.bak

# Allowlisted project content
!.gitignore
!README.md
!Package.swift
!Package.resolved
!clipboard-manager-stack-decision.md
!Sources/
!Sources/**
!Tests/
!Tests/**
!docs/
!docs/**
!scripts/
!scripts/**

# Re-exclude generated artifacts (must come after allowlist)
.build/
build/
**/.DS_Store

# Pre-commit verification:
#   1. git status            # nothing unexpected staged?
#   2. git ls-files | grep -E '\.(env|key|pem|sqlite)$'   # must be empty
```

- [ ] **Step 3: Baseline commit**

```bash
git add -A
git commit -m "chore: baseline before panel redesign"
```

Expected: commit created; `git status` clean except `.build/`.

---

### Task 2: Add a test target

**Files:**
- Modify: `Package.swift`
- Create: `Tests/ClippyTests/SmokeTests.swift`

- [ ] **Step 1: Add the test target to `Package.swift`**

Replace the `targets:` array with:

```swift
    targets: [
        .executableTarget(
            name: "Clippy",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            // AppKit delegates and Carbon callbacks are simpler under the v5
            // concurrency model; revisit when the whole app moves to Swift 6 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClippyTests",
            dependencies: [
                "Clippy",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
```

- [ ] **Step 2: Write a smoke test**

`Tests/ClippyTests/SmokeTests.swift`:

```swift
import XCTest
@testable import Clippy

final class SmokeTests: XCTestCase {
    func testClipKindDetection() {
        XCTAssertEqual(ClipKind.detect("https://example.com"), .link)
        XCTAssertEqual(ClipKind.detect("plain words"), .text)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test`
Expected: PASS (2 assertions). SwiftPM supports testing executable targets; if the build complains about top-level code in `main.swift`, stop and report rather than restructuring.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/
git commit -m "test: add ClippyTests target with smoke test"
```

---

### Task 3: Make ClipDatabase testable (injectable URL, internal migrator)

**Files:**
- Modify: `Sources/Clippy/Storage/ClipDatabase.swift`
- Create: `Tests/ClippyTests/TestSupport.swift`

- [ ] **Step 1: Write the failing test**

`Tests/ClippyTests/TestSupport.swift`:

```swift
import Foundation
import XCTest
@testable import Clippy

/// Creates an isolated ClipDatabase in a fresh temp directory.
func makeTestDatabase(_ testCase: XCTestCase) throws -> ClipDatabase {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clippy-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: dir)
    }
    return try ClipDatabase(databaseURL: dir.appendingPathComponent("test.sqlite"))
}

func makeTextClip(_ text: String, createdAt: Date = Date()) -> Clip {
    Clip(
        id: nil,
        contentText: text,
        contentRTF: nil,
        contentHTML: nil,
        typeIdentifier: "public.utf8-plain-text",
        sourceAppBundleID: "com.example.test",
        sourceAppName: "TestApp",
        createdAt: createdAt
    )
}
```

Note: `makeTextClip` already omits `isPinned`; it will not compile until Task 5 removes the field. For THIS task only, include `isPinned: false` as the last argument and delete it in Task 5.

Add to `Tests/ClippyTests/ClipDatabaseTests.swift` (create the file):

```swift
import XCTest
import GRDB
@testable import Clippy

final class ClipDatabaseTests: XCTestCase {
    func testOpensAtInjectedURL() throws {
        let db = try makeTestDatabase(self)
        XCTAssertTrue(db.databaseURL.path.contains("clippy-tests-"))
        var clip = makeTextClip("hello")
        try db.saveCapturedClip(&clip)
        XCTAssertEqual(try db.allClips().count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipDatabaseTests`
Expected: FAIL to compile ("extra argument 'databaseURL' in call").

- [ ] **Step 3: Implement**

In `ClipDatabase.swift`, replace `init() throws` with:

```swift
    init(databaseURL: URL? = nil) throws {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.databaseURL = databaseURL ?? supportDir.appendingPathComponent("clippy.sqlite")
        dbQueue = try DatabaseQueue(path: self.databaseURL.path)
        try Self.makeMigrator().migrate(dbQueue)
    }
```

and change `private var migrator: DatabaseMigrator { ... }` to an internal static so tests can migrate step-by-step:

```swift
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // ... body unchanged ...
        }
        return migrator
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clippy/Storage/ClipDatabase.swift Tests/
git commit -m "refactor: injectable database URL and static migrator for tests"
```

---

### Task 4: Category and ClipCategory records, migration v2, category APIs

**Files:**
- Create: `Sources/Clippy/Storage/Category.swift`
- Modify: `Sources/Clippy/Storage/ClipDatabase.swift`
- Create: `Tests/ClippyTests/CategoryTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ClippyTests/CategoryTests.swift`:

```swift
import XCTest
import GRDB
@testable import Clippy

final class CategoryTests: XCTestCase {
    func testMigrationCreatesStarterCategory() throws {
        let db = try makeTestDatabase(self)
        let starter = try db.starterCategory()
        XCTAssertEqual(starter?.name, "Pinned")
        XCTAssertTrue(starter?.isStarter == true)
    }

    func testLegacyPinnedClipsMigrateToStarterCategory() throws {
        // Build a v1 database by hand, mark a clip pinned, then run the
        // full migrator over it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try ClipDatabase.makeMigrator().migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt, isPinned)
                    VALUES ('keep me', 'public.utf8-plain-text', ?, 1),
                           ('plain', 'public.utf8-plain-text', ?, 0)
                    """,
                arguments: [Date(), Date()]
            )
        }

        let migrated = try ClipDatabase(databaseURL: url)
        let starter = try migrated.starterCategory()
        let map = try migrated.membershipMap()
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.values.first, [starter?.id])
    }

    func testCategoryCRUDAndMembership() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("snippet")
        try db.saveCapturedClip(&clip)
        let clipID = try XCTUnwrap(db.allClips().first?.id)

        let work = try db.createCategory(
            named: "Work", colorHex: "#007AFF", iconKind: .symbol, iconValue: "briefcase.fill"
        )
        let workID = try XCTUnwrap(work.id)

        try db.setClip(clipID, inCategory: workID, true)
        XCTAssertEqual(try db.membershipMap()[clipID], [workID])

        var renamed = work
        renamed.name = "Job"
        try db.updateCategory(renamed)
        XCTAssertEqual(try db.categories().first(where: { $0.id == workID })?.name, "Job")

        // Deleting a category never deletes clips; junction rows cascade away.
        try db.deleteCategory(id: workID)
        XCTAssertNil(try db.membershipMap()[clipID])
        XCTAssertEqual(try db.allClips().count, 1)
    }

    func testToggleStarterMembership() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("pin me")
        try db.saveCapturedClip(&clip)
        let clipID = try XCTUnwrap(db.allClips().first?.id)
        let starterID = try XCTUnwrap(db.starterCategory()?.id)

        try db.toggleStarterMembership(clipID: clipID)
        XCTAssertEqual(try db.membershipMap()[clipID], [starterID])
        try db.toggleStarterMembership(clipID: clipID)
        XCTAssertNil(try db.membershipMap()[clipID])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CategoryTests`
Expected: FAIL to compile ("cannot find 'Category' / no member 'starterCategory'").

- [ ] **Step 3: Create the records**

`Sources/Clippy/Storage/Category.swift`:

```swift
import Foundation
import GRDB

enum CategoryIconKind: String, Codable {
    case symbol
    case emoji
    case appLogo
}

/// A user-defined pinboard. A clip is "pinned" when it belongs to at least
/// one category (tag model: a clip can be in several at once).
struct Category: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var colorHex: String
    var iconKind: CategoryIconKind
    var iconValue: String
    var sortOrder: Int
    var isStarter: Bool
    var createdAt: Date

    static let databaseTableName = "category"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Junction row: one clip's membership in one category.
struct ClipCategory: Codable, FetchableRecord, PersistableRecord {
    var clipID: Int64
    var categoryID: Int64
    var addedAt: Date

    static let databaseTableName = "clip_category"
}
```

- [ ] **Step 4: Register migration v2 and the category APIs**

In `ClipDatabase.makeMigrator()`, after the `"v1"` registration, add:

```swift
        migrator.registerMigration("v2-categories") { db in
            try db.create(table: "category") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("iconKind", .text).notNull()
                t.column("iconValue", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isStarter", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "clip_category") { t in
                t.column("clipID", .integer).notNull()
                    .references("clips", onDelete: .cascade)
                t.column("categoryID", .integer).notNull()
                    .references("category", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["clipID", "categoryID"])
            }
            // Starter category receives every legacy pinned clip so nothing
            // is lost; users can rename or restyle it later.
            try db.execute(
                sql: """
                    INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
                    VALUES ('Pinned', '#FF9500', 'symbol', 'pin.fill', 0, 1, ?)
                    """,
                arguments: [Date()]
            )
            let starterID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO clip_category (clipID, categoryID, addedAt)
                    SELECT id, ?, ? FROM clips WHERE isPinned = 1
                    """,
                arguments: [starterID, Date()]
            )
            try db.alter(table: "clips") { t in
                t.drop(column: "isPinned")
            }
        }
```

Then add a new section to `ClipDatabase` (after the Reads section):

```swift
    // MARK: - Categories

    func categories() throws -> [Category] {
        try dbQueue.read { db in
            try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
        }
    }

    func starterCategory() throws -> Category? {
        try dbQueue.read { db in
            try Category.filter(Column("isStarter") == true).fetchOne(db)
        }
    }

    @discardableResult
    func createCategory(
        named name: String,
        colorHex: String,
        iconKind: CategoryIconKind,
        iconValue: String
    ) throws -> Category {
        try dbQueue.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(sortOrder), -1) FROM category") ?? -1
            var category = Category(
                id: nil,
                name: name,
                colorHex: colorHex,
                iconKind: iconKind,
                iconValue: iconValue,
                sortOrder: maxOrder + 1,
                isStarter: false,
                createdAt: Date()
            )
            try category.insert(db)
            return category
        }
    }

    func updateCategory(_ category: Category) throws {
        try dbQueue.write { db in
            try category.update(db)
        }
    }

    func deleteCategory(id: Int64) throws {
        _ = try dbQueue.write { db in
            try Category.deleteOne(db, key: id)
        }
    }

    func setClip(_ clipID: Int64, inCategory categoryID: Int64, _ isMember: Bool) throws {
        try dbQueue.write { db in
            if isMember {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt) VALUES (?, ?, ?)",
                    arguments: [clipID, categoryID, Date()]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM clip_category WHERE clipID = ? AND categoryID = ?",
                    arguments: [clipID, categoryID]
                )
            }
        }
    }

    /// Cmd+P fast path: one keystroke toggles membership in the starter category.
    func toggleStarterMembership(clipID: Int64) throws {
        guard let starterID = try starterCategory()?.id else { return }
        let isMember = try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM clip_category WHERE clipID = ? AND categoryID = ?)",
                arguments: [clipID, starterID]
            ) ?? false
        }
        try setClip(clipID, inCategory: starterID, !isMember)
    }

    /// clipID -> set of category IDs, for fast pinned/membership lookups in views.
    func membershipMap() throws -> [Int64: Set<Int64>] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT clipID, categoryID FROM clip_category")
            var map: [Int64: Set<Int64>] = [:]
            for row in rows {
                map[row["clipID"], default: []].insert(row["categoryID"])
            }
            return map
        }
    }
```

Dropping `isPinned` breaks the build (Clip struct, eviction SQL, UI). That fallout is Task 5; for THIS task run only the new tests, not `swift build`.

- [ ] **Step 5: Remove `isPinned` from the `Clip` struct**

In `Sources/Clippy/Storage/Clip.swift` delete the line `var isPinned: Bool`. Remove `isPinned: false` from `makeTextClip` in `TestSupport.swift` (added temporarily in Task 3).

- [ ] **Step 6: Run the category tests**

Run: `swift test --filter CategoryTests`
Expected: compile errors remain in OTHER files (monitor, store, views) that still reference `isPinned`. If so, proceed to Task 5 and run the tests at its end — Tasks 4 and 5 land as one commit pair. Do NOT commit yet.

---

### Task 5: Remove every isPinned dependency (DB methods, store, views)

**Files:**
- Modify: `Sources/Clippy/Storage/ClipDatabase.swift` (eviction, delete, search)
- Modify: `Sources/Clippy/Capture/ClipboardMonitor.swift`
- Modify: `Sources/Clippy/UI/ClipStore.swift` (full rewrite below)
- Modify: `Sources/Clippy/UI/ClipListView.swift` (minimal compile fixes)
- Modify: `Sources/Clippy/UI/ClipCardView.swift` (isPinned becomes a parameter)
- Modify: `Sources/Clippy/AppDelegate.swift`
- Modify: `Sources/Clippy/UI/SettingsView.swift` (copy)
- Create: `Tests/ClippyTests/EvictionTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ClippyTests/EvictionTests.swift`:

```swift
import XCTest
@testable import Clippy

final class EvictionTests: XCTestCase {
    /// Categorized clips are exempt from the history cap.
    func testCapEvictionSkipsCategorizedClips() throws {
        let db = try makeTestDatabase(self)
        let savedCap = AppSettings.shared.maxHistoryItems
        AppSettings.shared.maxHistoryItems = 2
        addTeardownBlock { AppSettings.shared.maxHistoryItems = savedCap }

        var old = makeTextClip("oldest", createdAt: Date(timeIntervalSinceNow: -300))
        try db.saveCapturedClip(&old)
        let oldID = try XCTUnwrap(db.allClips().first?.id)
        try db.toggleStarterMembership(clipID: oldID)

        for i in 0..<3 {
            var clip = makeTextClip("clip-\(i)", createdAt: Date(timeIntervalSinceNow: Double(i - 3)))
            try db.saveCapturedClip(&clip)
        }

        let texts = try db.allClips().map(\.contentText)
        XCTAssertTrue(texts.contains("oldest"), "categorized clip must survive the cap")
        XCTAssertEqual(texts.count, 3) // 2 uncategorized + 1 categorized
    }

    func testDeleteUnclassifiedKeepsCategorized() throws {
        let db = try makeTestDatabase(self)
        var keep = makeTextClip("keep")
        try db.saveCapturedClip(&keep)
        var drop = makeTextClip("drop")
        try db.saveCapturedClip(&drop)
        let keepID = try XCTUnwrap(db.allClips().first(where: { $0.contentText == "keep" })?.id)
        try db.toggleStarterMembership(clipID: keepID)

        try db.deleteUnclassifiedClips()
        XCTAssertEqual(try db.allClips().map(\.contentText), ["keep"])
    }
}
```

- [ ] **Step 2: Rewrite the pin-dependent DB methods**

In `ClipDatabase.swift`:

Replace the eviction SQL inside `saveCapturedClip` (the `if cap > 0 { ... }` block) with a call to a shared helper:

```swift
            var inserting = newClip
            try inserting.insert(db)
            try Self.evictOverCap(db, cap: cap)
```

Add the helper to ClipDatabase:

```swift
    /// Deletes uncategorized clips beyond the cap, oldest first. Clips in any
    /// category never count against the cap.
    @discardableResult
    static func evictOverCap(_ db: Database, cap: Int) throws -> [String] {
        guard cap > 0 else { return [] }
        try db.execute(
            sql: """
                DELETE FROM clips
                WHERE id NOT IN (SELECT clipID FROM clip_category)
                AND id NOT IN (
                    SELECT id FROM clips
                    WHERE id NOT IN (SELECT clipID FROM clip_category)
                    ORDER BY createdAt DESC, id DESC
                    LIMIT ?
                )
                """,
            arguments: [cap]
        )
        return []
    }
```

(The `[String]` return is empty for now; Task 7 makes it return evicted media filenames.)

Delete `togglePin(id:)`. Rename `deleteUnpinnedClips()` to:

```swift
    func deleteUnclassifiedClips() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE id NOT IN (SELECT clipID FROM clip_category)")
        }
    }
```

In `searchClips`, change `ORDER BY clips.isPinned DESC, rank` to `ORDER BY rank`.

- [ ] **Step 3: Fix ClipboardMonitor**

In `captureCurrentPasteboard`, delete the line `isPinned: false` from the `Clip(...)` initializer.

- [ ] **Step 4: Rewrite ClipStore**

Replace `Sources/Clippy/UI/ClipStore.swift` entirely with:

```swift
import Foundation
import Combine
import GRDB

/// View model for the panel: live observation of clips, categories, and
/// membership; FTS5 search when a query is typed. "Pinned" is derived:
/// a clip is pinned when it belongs to at least one category.
final class ClipStore: ObservableObject {
    @Published var query: String = "" {
        didSet { refilter() }
    }
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var categories: [Category] = []
    @Published private(set) var membership: [Int64: Set<Int64>] = [:]

    private var recents: [Clip] = [] {
        didSet { refilter() }
    }
    private var clipsCancellable: AnyDatabaseCancellable?
    private var categoriesCancellable: AnyDatabaseCancellable?
    private let database: ClipDatabase
    private let displayLimit = 300

    init(database: ClipDatabase) {
        self.database = database
        let limit = displayLimit
        // Recents window plus every categorized clip: categorized clips must
        // stay visible in their panes even when older than the window.
        let clipObservation = ValueObservation.tracking { db in
            try Clip.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE id IN (SELECT clipID FROM clip_category)
                    OR id IN (SELECT id FROM clips ORDER BY createdAt DESC, id DESC LIMIT ?)
                    ORDER BY createdAt DESC, id DESC
                    """,
                arguments: [limit]
            )
        }
        clipsCancellable = clipObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                NSLog("Clippy: clip observation failed: \(error)")
            },
            onChange: { [weak self] clips in
                self?.recents = clips
            }
        )

        let categoryObservation = ValueObservation.tracking { db -> ([Category], [Int64: Set<Int64>]) in
            let categories = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
            let rows = try Row.fetchAll(db, sql: "SELECT clipID, categoryID FROM clip_category")
            var map: [Int64: Set<Int64>] = [:]
            for row in rows {
                map[row["clipID"], default: []].insert(row["categoryID"])
            }
            return (categories, map)
        }
        categoriesCancellable = categoryObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                NSLog("Clippy: category observation failed: \(error)")
            },
            onChange: { [weak self] categories, map in
                self?.categories = categories
                self?.membership = map
            }
        )
    }

    // MARK: - Membership queries

    func isPinned(_ clip: Clip) -> Bool {
        guard let id = clip.id else { return false }
        return !(membership[id] ?? []).isEmpty
    }

    func categoryIDs(for clip: Clip) -> Set<Int64> {
        guard let id = clip.id else { return [] }
        return membership[id] ?? []
    }

    func clipCount(inCategory categoryID: Int64) -> Int {
        membership.values.reduce(0) { $0 + ($1.contains(categoryID) ? 1 : 0) }
    }

    // MARK: - Actions

    /// Toggles membership in the starter category (the Cmd+P fast path).
    func togglePin(_ clip: Clip) {
        guard let id = clip.id else { return }
        try? database.toggleStarterMembership(clipID: id)
    }

    func setClip(_ clip: Clip, inCategory categoryID: Int64, _ isMember: Bool) {
        guard let id = clip.id else { return }
        try? database.setClip(id, inCategory: categoryID, isMember)
    }

    func addClip(id clipID: Int64, toCategory categoryID: Int64) {
        try? database.setClip(clipID, inCategory: categoryID, true)
    }

    func createCategory(named name: String, colorHex: String, iconKind: CategoryIconKind, iconValue: String) {
        try? database.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
    }

    func updateCategory(_ category: Category) {
        try? database.updateCategory(category)
    }

    func deleteCategory(_ category: Category) {
        guard let id = category.id else { return }
        try? database.deleteCategory(id: id)
    }

    func delete(_ clip: Clip) {
        guard let id = clip.id else { return }
        try? database.deleteClip(id: id)
    }

    func updateText(of clip: Clip, to newText: String) {
        guard let id = clip.id else { return }
        try? database.updateClipText(id: id, newText: newText)
    }

    private func refilter() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clips = recents
        } else {
            clips = (try? database.searchClips(matching: trimmed, limit: displayLimit)) ?? []
        }
    }
}
```

- [ ] **Step 5: Minimal view fixes (full layout rework comes later)**

`ClipCardView.swift`: add a stored parameter and stop reading the deleted field.

```swift
struct ClipCardView: View {
    let clip: Clip
    let isSelected: Bool
    let isPinned: Bool
    // ... existing callbacks unchanged ...
```

In `trailingMetadata`, change `if clip.isPinned {` to `if isPinned {`.
In `hoverActions`, change both `clip.isPinned` occurrences to `isPinned`.

`ClipListView.swift`:
- `visibleClips` pinned case: `return store.clips.filter { store.isPinned($0) }`
- In `sectionTitle(for:)`, DELETE the line `if tab == .history, clip.isPinned { return "Pinned" }` (pinned clips stay chronological in History per the spec).
- In `card(for:at:)`, pass the new parameter:

```swift
        ClipCardView(
            clip: clip,
            isSelected: index == selectedIndex,
            isPinned: store.isPinned(clip),
            onPaste: { onPaste(clip, settings.pastePlainTextByDefault) },
            onPastePlain: { onPaste(clip, true) },
            onEdit: { onEdit(clip) },
            onTogglePin: { store.togglePin(clip) },
            onDelete: { store.delete(clip) }
        )
```

- In the context menu, change `Button(clip.isPinned ? "Unpin" : "Pin")` to `Button(store.isPinned(clip) ? "Unpin" : "Pin")`.

`AppDelegate.swift`: in `clearHistory()`, replace the `deleteUnpinnedClips` call with `deleteUnclassifiedClips` (keep surrounding error handling as is).

`SettingsView.swift` copy fixes (General tab):
- "Pinned clips never count against the cap and survive Clear History." becomes "Clips in categories never count against the cap and survive Clear Unpinned History."

- [ ] **Step 6: Run everything**

Run: `swift test`
Expected: ALL tests pass, including Task 4's CategoryTests.
Run: `swift build`
Expected: Build complete.

- [ ] **Step 7: Commit (Tasks 4+5 together)**

```bash
git add -A
git commit -m "feat: category tag model replaces isPinned flag, with migration"
```

---

### Task 6: MediaStore for image files

**Files:**
- Create: `Sources/Clippy/Storage/MediaStore.swift`
- Modify: `Sources/Clippy/Storage/ClipDatabase.swift` (own a MediaStore)
- Create: `Tests/ClippyTests/MediaStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ClippyTests/MediaStoreTests.swift`:

```swift
import AppKit
import XCTest
@testable import Clippy

final class MediaStoreTests: XCTestCase {
    private func makeStore() throws -> MediaStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-media-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try MediaStore(directory: dir)
    }

    func makePNGData(width: Int = 600, height: Int = 400) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func testStoreWritesImageAndThumbnail() throws {
        let store = try makeStore()
        let stored = try store.store(pngData: makePNGData())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stored.mediaFilename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stored.thumbFilename).path))
        XCTAssertEqual(stored.pixelWidth, 600)
        XCTAssertEqual(stored.pixelHeight, 400)
    }

    func testStoreIsIdempotentForSameBytes() throws {
        let store = try makeStore()
        let data = makePNGData()
        let first = try store.store(pngData: data)
        let second = try store.store(pngData: data)
        XCTAssertEqual(first, second)
    }

    func testSweepOrphansRemovesOnlyUnreferencedFiles() throws {
        let store = try makeStore()
        let stored = try store.store(pngData: makePNGData())
        let orphanURL = store.url(for: "orphan.png")
        try Data([0x1]).write(to: orphanURL)

        store.sweepOrphans(referencedFilenames: [stored.mediaFilename, stored.thumbFilename])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stored.mediaFilename).path))
    }

    func testDeleteRemovesFiles() throws {
        let store = try makeStore()
        let stored = try store.store(pngData: makePNGData())
        store.delete(filenames: [stored.mediaFilename, stored.thumbFilename])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: stored.mediaFilename).path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MediaStoreTests`
Expected: FAIL to compile ("cannot find 'MediaStore'").

- [ ] **Step 3: Implement MediaStore**

`Sources/Clippy/Storage/MediaStore.swift`:

```swift
import AppKit
import CryptoKit
import Foundation

enum MediaStoreError: Error {
    case undecodableImage
    case thumbnailFailed
}

/// Owns the on-disk directory for image clip payloads and thumbnails.
/// The database stores filenames only; the filename is the SHA-256 of the
/// PNG bytes, which makes storing the same image twice naturally idempotent.
final class MediaStore {
    struct StoredImage: Equatable {
        let mediaFilename: String
        let thumbFilename: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteSize: Int
    }

    let directory: URL
    private static let thumbnailMaxEdge: CGFloat = 400

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Writes the image and a small thumbnail; both must exist before the
    /// caller commits a database row, so a row never references missing bytes.
    func store(pngData: Data) throws -> StoredImage {
        guard let rep = NSBitmapImageRep(data: pngData) else {
            throw MediaStoreError.undecodableImage
        }
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        let mediaFilename = "\(hash).png"
        let thumbFilename = "\(hash)-thumb.jpg"
        let mediaURL = url(for: mediaFilename)
        if !FileManager.default.fileExists(atPath: mediaURL.path) {
            try pngData.write(to: mediaURL, options: .atomic)
            try Self.thumbnailJPEG(from: rep).write(to: url(for: thumbFilename), options: .atomic)
        }
        return StoredImage(
            mediaFilename: mediaFilename,
            thumbFilename: thumbFilename,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            byteSize: pngData.count
        )
    }

    func delete(filenames: [String]) {
        for filename in filenames where !filename.isEmpty {
            try? FileManager.default.removeItem(at: url(for: filename))
        }
    }

    /// Removes files no clip references (leftovers from a crash between file
    /// write and row insert).
    func sweepOrphans(referencedFilenames: Set<String>) {
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for filename in onDisk where !referencedFilenames.contains(filename) {
            try? FileManager.default.removeItem(at: url(for: filename))
        }
    }

    private static func thumbnailJPEG(from rep: NSBitmapImageRep) throws -> Data {
        let width = CGFloat(rep.pixelsWide)
        let height = CGFloat(rep.pixelsHigh)
        let scale = min(1, thumbnailMaxEdge / max(width, height))
        let targetSize = NSSize(width: max(1, width * scale), height: max(1, height * scale))
        let image = NSImage(size: targetSize)
        image.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: targetSize))
        image.unlockFocus()
        guard
            let tiff = image.tiffRepresentation,
            let thumbRep = NSBitmapImageRep(data: tiff),
            let jpeg = thumbRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw MediaStoreError.thumbnailFailed }
        return jpeg
    }
}
```

- [ ] **Step 4: Give ClipDatabase a MediaStore**

In `ClipDatabase.swift`, add the property and init parameter:

```swift
    let dbQueue: DatabaseQueue
    let databaseURL: URL
    let media: MediaStore

    init(databaseURL: URL? = nil, mediaDirectory: URL? = nil) throws {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.databaseURL = databaseURL ?? supportDir.appendingPathComponent("clippy.sqlite")
        self.media = try MediaStore(
            directory: mediaDirectory ?? supportDir.appendingPathComponent("media", isDirectory: true)
        )
        dbQueue = try DatabaseQueue(path: self.databaseURL.path)
        try Self.makeMigrator().migrate(dbQueue)
    }
```

In `TestSupport.swift`, pass an isolated media directory too:

```swift
    return try ClipDatabase(
        databaseURL: dir.appendingPathComponent("test.sqlite"),
        mediaDirectory: dir.appendingPathComponent("media", isDirectory: true)
    )
```

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: MediaStore owns image files with hash filenames and thumbnails"
```

---

### Task 7: Image clip columns, capture persistence, media cleanup

**Files:**
- Modify: `Sources/Clippy/Storage/Clip.swift`
- Modify: `Sources/Clippy/Storage/ClipDatabase.swift`
- Modify: `Sources/Clippy/Capture/ClipboardMonitor.swift` (constructor fix only)
- Modify: `Tests/ClippyTests/TestSupport.swift`
- Modify: `Sources/Clippy/AppDelegate.swift` (orphan sweep)
- Create: `Tests/ClippyTests/ImageClipTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ClippyTests/ImageClipTests.swift`:

```swift
import XCTest
@testable import Clippy

final class ImageClipTests: XCTestCase {
    private func storeImage(_ db: ClipDatabase, data: Data) throws -> Clip {
        let stored = try db.media.store(pngData: data)
        var clip = makeImageClip(stored)
        try db.saveCapturedImageClip(&clip)
        return clip
    }

    func testImageClipRoundTrip() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)

        let fetched = try XCTUnwrap(db.allClips().first)
        XCTAssertEqual(fetched.contentKind, .image)
        XCTAssertEqual(fetched.pixelWidth, 600)
        XCTAssertNotNil(fetched.mediaFilename)
    }

    func testImageDedupeBumpsTimestampInsteadOfDuplicating() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        _ = try storeImage(db, data: png)
        XCTAssertEqual(try db.allClips().count, 1)
    }

    func testDeleteClipRemovesMediaFiles() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        let clip = try XCTUnwrap(db.allClips().first)
        let mediaURL = db.media.url(for: try XCTUnwrap(clip.mediaFilename))

        try db.deleteClip(id: try XCTUnwrap(clip.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    func testCapEvictionRemovesMediaFiles() throws {
        let db = try makeTestDatabase(self)
        let savedCap = AppSettings.shared.maxHistoryItems
        AppSettings.shared.maxHistoryItems = 1
        addTeardownBlock { AppSettings.shared.maxHistoryItems = savedCap }

        let png = MediaStoreTests().makePNGData()
        let stored = try db.media.store(pngData: png)
        var imageClip = makeImageClip(stored, createdAt: Date(timeIntervalSinceNow: -60))
        try db.saveCapturedImageClip(&imageClip)

        var newer = makeTextClip("newer")
        try db.saveCapturedClip(&newer)

        XCTAssertEqual(try db.allClips().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.media.url(for: stored.mediaFilename).path))
    }
}
```

Add to `TestSupport.swift`:

```swift
func makeImageClip(_ stored: MediaStore.StoredImage, createdAt: Date = Date()) -> Clip {
    Clip(
        id: nil,
        contentText: "",
        contentRTF: nil,
        contentHTML: nil,
        typeIdentifier: "public.png",
        sourceAppBundleID: "com.example.test",
        sourceAppName: "TestApp",
        createdAt: createdAt,
        contentKind: .image,
        mediaFilename: stored.mediaFilename,
        thumbFilename: stored.thumbFilename,
        pixelWidth: stored.pixelWidth,
        pixelHeight: stored.pixelHeight,
        byteSize: stored.byteSize
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ImageClipTests`
Expected: FAIL to compile ("no member 'contentKind'").

- [ ] **Step 3: Extend the Clip record**

`Sources/Clippy/Storage/Clip.swift` becomes:

```swift
import Foundation
import GRDB

enum ClipContentKind: String, Codable {
    case text
    case image
}

struct Clip: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var contentText: String
    var contentRTF: Data?
    var contentHTML: Data?
    var typeIdentifier: String
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var contentKind: ClipContentKind = .text
    var mediaFilename: String?
    var thumbFilename: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteSize: Int?

    static let databaseTableName = "clips"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Single-line-ish preview for list rows.
    var previewText: String {
        let trimmed = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(300))
    }

    var isRich: Bool {
        contentRTF != nil || contentHTML != nil
    }

    /// Media filenames this clip owns on disk (empty for text clips).
    var mediaFilenames: [String] {
        [mediaFilename, thumbFilename].compactMap { $0 }
    }
}
```

- [ ] **Step 4: Migration v3 and persistence APIs**

In `ClipDatabase.makeMigrator()`, after `"v2-categories"`:

```swift
        migrator.registerMigration("v3-image-clips") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "contentKind", .text).notNull().defaults(to: "text")
                t.add(column: "mediaFilename", .text)
                t.add(column: "thumbFilename", .text)
                t.add(column: "pixelWidth", .integer)
                t.add(column: "pixelHeight", .integer)
                t.add(column: "byteSize", .integer)
            }
        }
```

Replace the eviction helper from Task 5 with the media-aware version, and route its result through `media.delete` in `saveCapturedClip`:

```swift
    /// Deletes uncategorized clips beyond the cap, oldest first, and returns
    /// the media filenames of evicted image clips so callers can remove files.
    @discardableResult
    static func evictOverCap(_ db: Database, cap: Int) throws -> [String] {
        guard cap > 0 else { return [] }
        let doomedSQL = """
            SELECT id FROM clips
            WHERE id NOT IN (SELECT clipID FROM clip_category)
            AND id NOT IN (
                SELECT id FROM clips
                WHERE id NOT IN (SELECT clipID FROM clip_category)
                ORDER BY createdAt DESC, id DESC
                LIMIT \(cap)
            )
            """
        let filenames = try String.fetchAll(
            db,
            sql: """
                SELECT mediaFilename FROM clips
                WHERE mediaFilename IS NOT NULL AND id IN (\(doomedSQL))
                UNION ALL
                SELECT thumbFilename FROM clips
                WHERE thumbFilename IS NOT NULL AND id IN (\(doomedSQL))
                """
        )
        try db.execute(sql: "DELETE FROM clips WHERE id IN (\(doomedSQL))")
        return filenames
    }
```

In `saveCapturedClip`, capture and clean up:

```swift
    func saveCapturedClip(_ clip: inout Clip) throws {
        let cap = AppSettings.shared.maxHistoryItems
        let newClip = clip
        var evicted: [String] = []
        try dbQueue.write { db in
            if var existing = try Clip
                .filter(Column("contentText") == newClip.contentText)
                .filter(Column("contentKind") == ClipContentKind.text.rawValue)
                .fetchOne(db)
            {
                existing.createdAt = newClip.createdAt
                existing.sourceAppBundleID = newClip.sourceAppBundleID
                existing.sourceAppName = newClip.sourceAppName
                try existing.update(db)
                return
            }
            var inserting = newClip
            try inserting.insert(db)
            evicted = try Self.evictOverCap(db, cap: cap)
        }
        media.delete(filenames: evicted)
    }
```

Add the image insert (next to `saveCapturedClip`):

```swift
    /// Insert a captured image clip. Media files are written by MediaStore
    /// BEFORE this runs. Dedupe key is the content-hash filename; a re-copy
    /// bumps the timestamp.
    func saveCapturedImageClip(_ clip: inout Clip) throws {
        let cap = AppSettings.shared.maxHistoryItems
        let newClip = clip
        var evicted: [String] = []
        try dbQueue.write { db in
            if var existing = try Clip
                .filter(Column("mediaFilename") == newClip.mediaFilename)
                .fetchOne(db)
            {
                existing.createdAt = newClip.createdAt
                existing.sourceAppBundleID = newClip.sourceAppBundleID
                existing.sourceAppName = newClip.sourceAppName
                try existing.update(db)
                return
            }
            var inserting = newClip
            try inserting.insert(db)
            evicted = try Self.evictOverCap(db, cap: cap)
        }
        media.delete(filenames: evicted)
    }
```

Make `deleteClip` and `deleteUnclassifiedClips` media-aware:

```swift
    func deleteClip(id: Int64) throws {
        let filenames: [String] = try dbQueue.write { db in
            let clip = try Clip.fetchOne(db, key: id)
            try Clip.deleteOne(db, key: id)
            return clip?.mediaFilenames ?? []
        }
        media.delete(filenames: filenames)
    }

    func deleteUnclassifiedClips() throws {
        let filenames: [String] = try dbQueue.write { db in
            let doomed = try Clip
                .filter(sql: "id NOT IN (SELECT clipID FROM clip_category)")
                .fetchAll(db)
            try db.execute(sql: "DELETE FROM clips WHERE id NOT IN (SELECT clipID FROM clip_category)")
            return doomed.flatMap(\.mediaFilenames)
        }
        media.delete(filenames: filenames)
    }

    /// Every media filename any clip references, for the launch orphan sweep.
    func referencedMediaFilenames() throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT mediaFilename, thumbFilename FROM clips WHERE mediaFilename IS NOT NULL"
            )
            var names = Set<String>()
            for row in rows {
                if let m: String = row["mediaFilename"] { names.insert(m) }
                if let t: String = row["thumbFilename"] { names.insert(t) }
            }
            return names
        }
    }
```

- [ ] **Step 5: Fix the remaining Clip constructor and add the launch sweep**

`ClipboardMonitor.captureCurrentPasteboard`: the `Clip(...)` call gets no new arguments (the new fields default), but verify it still compiles; if the compiler demands them, append `contentKind: .text`.

`AppDelegate.applicationDidFinishLaunching`: add (anywhere after ClipDatabase is first touched):

```swift
        // Crash between media write and row insert leaves orphan files;
        // sweep them off the main thread at launch.
        DispatchQueue.global(qos: .utility).async {
            let referenced = (try? ClipDatabase.shared.referencedMediaFilenames()) ?? []
            ClipDatabase.shared.media.sweepOrphans(referencedFilenames: referenced)
        }
```

- [ ] **Step 6: Run tests**

Run: `swift test`
Expected: PASS (all suites).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: image clip persistence with media cleanup on delete and evict"
```

---

### Task 8: Capture images from the pasteboard; paste them back; settings

**Files:**
- Modify: `Sources/Clippy/Support/AppSettings.swift`
- Modify: `Sources/Clippy/Capture/ClipboardMonitor.swift`
- Modify: `Sources/Clippy/Paste/PasteService.swift`
- Modify: `Sources/Clippy/UI/SettingsView.swift` (Capture tab)

- [ ] **Step 1: AppSettings keys**

Add to the `Keys` enum:

```swift
        static let captureImages = "captureImages"
        static let maxImageSizeMB = "maxImageSizeMB"
```

Add published properties (after `showSectionHeaders`):

```swift
    @Published var captureImages: Bool {
        didSet { defaults.set(captureImages, forKey: Keys.captureImages) }
    }
    @Published var maxImageSizeMB: Int {
        didSet { defaults.set(maxImageSizeMB, forKey: Keys.maxImageSizeMB) }
    }
```

Register defaults (also bump the default panel width for the new split layout):

```swift
            Keys.panelWidth: 640.0,   // was 420.0
            Keys.captureImages: true,
            Keys.maxImageSizeMB: 20,
```

Initialize in `init` (after `showSectionHeaders`):

```swift
        captureImages = defaults.bool(forKey: Keys.captureImages)
        maxImageSizeMB = defaults.integer(forKey: Keys.maxImageSizeMB)
```

- [ ] **Step 2: Monitor image branch**

In `ClipboardMonitor.captureCurrentPasteboard`, replace the text-extraction guard and everything after it with:

```swift
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureText(text, from: frontApp)
            return
        }
        captureImageIfPresent(from: frontApp)
```

Then split the existing body into two private methods and add the image path:

```swift
    private func captureText(_ text: String, from frontApp: NSRunningApplication?) {
        let rtf = pasteboard.data(forType: .rtf)
        let html = pasteboard.data(forType: .html)
        let typeIdentifier: String
        if rtf != nil {
            typeIdentifier = "public.rtf"
        } else if html != nil {
            typeIdentifier = "public.html"
        } else {
            typeIdentifier = "public.utf8-plain-text"
        }

        var clip = Clip(
            id: nil,
            contentText: text,
            contentRTF: rtf,
            contentHTML: html,
            typeIdentifier: typeIdentifier,
            sourceAppBundleID: frontApp?.bundleIdentifier,
            sourceAppName: frontApp?.localizedName,
            createdAt: Date()
        )
        do {
            try database.saveCapturedClip(&clip)
        } catch {
            NSLog("Clippy: failed to save clip: \(error)")
        }
    }

    /// Images are captured only when the pasteboard carries no text: a copied
    /// picture, a screenshot, not a rich-text snippet that happens to embed one.
    private func captureImageIfPresent(from frontApp: NSRunningApplication?) {
        guard AppSettings.shared.captureImages,
              let pngData = Self.pngData(from: pasteboard)
        else { return }
        guard pngData.count <= AppSettings.shared.maxImageSizeMB * 1_048_576 else { return }

        do {
            let stored = try database.media.store(pngData: pngData)
            var clip = Clip(
                id: nil,
                contentText: "",
                contentRTF: nil,
                contentHTML: nil,
                typeIdentifier: "public.png",
                sourceAppBundleID: frontApp?.bundleIdentifier,
                sourceAppName: frontApp?.localizedName,
                createdAt: Date(),
                contentKind: .image,
                mediaFilename: stored.mediaFilename,
                thumbFilename: stored.thumbFilename,
                pixelWidth: stored.pixelWidth,
                pixelHeight: stored.pixelHeight,
                byteSize: stored.byteSize
            )
            try database.saveCapturedImageClip(&clip)
        } catch {
            NSLog("Clippy: failed to save image clip: \(error)")
        }
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
```

- [ ] **Step 3: PasteService image branch**

Replace the pasteboard-writing section of `paste(_:asPlainText:)`:

```swift
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch clip.contentKind {
        case .image:
            if let filename = clip.mediaFilename,
               let data = try? Data(contentsOf: ClipDatabase.shared.media.url(for: filename)) {
                pasteboard.setData(data, forType: .png)
                // TIFF alongside PNG: some AppKit apps only read TIFF.
                if let rep = NSBitmapImageRep(data: data),
                   let tiff = rep.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            }
        case .text:
            if !asPlainText {
                if let rtf = clip.contentRTF {
                    pasteboard.setData(rtf, forType: .rtf)
                }
                if let html = clip.contentHTML {
                    pasteboard.setData(html, forType: .html)
                }
            }
            // Plain text is set from the stored raw String, never round-tripped
            // through attributed strings, so it comes back byte for byte.
            pasteboard.setString(clip.contentText, forType: .string)
        }
```

- [ ] **Step 4: Capture settings UI**

In `CaptureSettingsTab`, add a new section between "Monitoring" and "Ignored apps":

```swift
            Section("Images") {
                Toggle("Capture copied images", isOn: $settings.captureImages)
                Stepper(
                    "Largest image to keep: \(settings.maxImageSizeMB) MB",
                    value: $settings.maxImageSizeMB,
                    in: 1...100
                )
                Text("Bigger copies are ignored to keep the history database lean.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 5: Build and test**

Run: `swift build && swift test`
Expected: Build complete, all tests pass.

Manual check: `swift run Clippy --show-panel`, take a screenshot to the clipboard (Cmd+Ctrl+Shift+4), confirm an empty-preview card appears (thumbnail rendering arrives in Task 9), select it, press Return in a text editor that accepts images (e.g. TextEdit rich mode) and confirm the image pastes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: capture and paste image clips with size cap setting"
```

---

### Task 9: ClipKind.image and the upgraded ClipCardView

**Files:**
- Modify: `Sources/Clippy/Storage/ClipKind.swift`
- Modify: `Sources/Clippy/UI/ClipCardView.swift` (full replacement below)
- Modify: `Sources/Clippy/UI/ClipListView.swift` (pass categoryColors, guard edit on images)

- [ ] **Step 1: Add the image kind**

In `ClipKind.swift`:
- Add `case image` to the enum (after `case filePath`).
- In `iconName`: `case .image: return "photo"`.
- In `label`: `case .image: return "Image"`.
- In `tint`: `case .image: return Color(nsColor: .systemPurple)`.
- Change `private static func parseHexColor` to `static func parseHexColor` (category colors reuse it in Task 10).
- Replace the `extension Clip` at the bottom:

```swift
extension Clip {
    var kind: ClipKind {
        contentKind == .image ? .image : ClipKind.detect(contentText)
    }
}
```

- [ ] **Step 2: Replace ClipCardView.swift entirely**

```swift
import SwiftUI

/// One clipboard item rendered as a card: colored edge stripe (per-app or
/// per-kind tint), source app icon, content-type badge, preview text or image
/// thumbnail, and hover-revealed quick actions. Selection draws an accent ring.
struct ClipCardView: View {
    let clip: Clip
    let isSelected: Bool
    let isPinned: Bool
    /// Colors of the categories this clip belongs to (first three shown as dots).
    let categoryColors: [Color]

    let onPaste: () -> Void
    let onPastePlain: () -> Void
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var kind: ClipKind { clip.kind }
    private var isImage: Bool { clip.contentKind == .image }

    private var cardColor: Color {
        switch settings.cardColorMode {
        case .byApp:
            return AppIconProvider.shared.dominantColor(forBundleID: clip.sourceAppBundleID) ?? kind.tint
        case .byKind:
            return kind.tint
        case .accent:
            return settings.accentColor
        case .neutral:
            return Color(nsColor: .systemGray)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Color identity stripe.
            Rectangle()
                .fill(cardColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                headerRow
                if isImage {
                    imagePreview
                } else {
                    Text(clip.previewText)
                        .font(.system(size: 12.5))
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case .colorValue(let swatch) = kind {
                    swatchRow(swatch)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? settings.accentColor : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(kind.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilitySummary: String {
        let source = clip.sourceAppName ?? "Unknown app"
        let content = isImage ? "Image" : clip.previewText
        return "\(source), \(kind.label), \(content)\(isPinned ? ", pinned" : "")"
    }

    // MARK: - Pieces

    private var headerRow: some View {
        HStack(spacing: 6) {
            if settings.showAppIcons, let icon = AppIconProvider.shared.icon(forBundleID: clip.sourceAppBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            Text(clip.sourceAppName ?? "Unknown app")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isHovering {
                hoverActions
            } else {
                trailingMetadata
            }
        }
        .frame(height: 20)
    }

    private var trailingMetadata: some View {
        HStack(spacing: 6) {
            ForEach(Array(categoryColors.prefix(3).enumerated()), id: \.offset) { _, color in
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Image(systemName: kind.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.tint)
            if clip.isRich {
                Image(systemName: "textformat")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("Has rich formatting")
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(settings.accentColor)
            }
            Text(clip.createdAt, format: Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if !isImage {
                cardActionButton("doc.on.clipboard", help: "Paste as plain text", action: onPastePlain)
                cardActionButton("pencil", help: "Edit", action: onEdit)
            }
            cardActionButton(
                isPinned ? "pin.slash" : "pin",
                help: isPinned ? "Unpin" : "Pin",
                action: onTogglePin
            )
            cardActionButton("trash", help: "Delete", action: onDelete)
        }
    }

    private func cardActionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private var imagePreview: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if let filename = clip.thumbFilename,
                   let nsImage = NSImage(contentsOf: ClipDatabase.shared.media.url(for: filename)) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 72, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(width: 72, height: 48)
                }
            }
            if let width = clip.pixelWidth, let height = clip.pixelHeight {
                Text("\(width)x\(height) PNG")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func swatchRow(_ swatch: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(swatch)
                .frame(width: 38, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            Text("Color value")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var cardBackground: some View {
        ZStack {
            // Mostly opaque backing keeps text contrast safe on glass materials.
            Color(nsColor: .controlBackgroundColor).opacity(0.78)
            // Whisper of the identity color so cards differ beyond the stripe.
            LinearGradient(
                colors: [cardColor.opacity(isHovering ? 0.16 : 0.08), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            if isHovering {
                Color.primary.opacity(0.04)
            }
        }
    }
}
```

- [ ] **Step 3: Fix the ClipCardView call site**

In `ClipListView.card(for:at:)`, add the new argument (full call shown; `categoryColor(for:)` helper arrives properly in Task 10 — for now inline the mapping):

```swift
        ClipCardView(
            clip: clip,
            isSelected: index == selectedIndex,
            isPinned: store.isPinned(clip),
            categoryColors: store.categories
                .filter { category in
                    guard let id = category.id else { return false }
                    return store.categoryIDs(for: clip).contains(id)
                }
                .map { ClipKind.parseHexColor($0.colorHex) ?? Color(nsColor: .systemGray) },
            onPaste: { onPaste(clip, settings.pastePlainTextByDefault) },
            onPastePlain: { onPaste(clip, true) },
            onEdit: { onEdit(clip) },
            onTogglePin: { store.togglePin(clip) },
            onDelete: { store.delete(clip) }
        )
```

Also in `ClipListView`:
- The Cmd+E key handler: change the guard to `guard press.modifiers.contains(.command), let clip = selectedClip, clip.contentKind == .text else { return .ignored }` (no text editor for images).
- Context menu: wrap "Paste as Plain Text" and "Edit..." in `if clip.contentKind == .text { ... }`.

- [ ] **Step 4: Build, run, verify**

Run: `swift build && swift test`
Expected: Build complete, tests pass.
Manual: `swift run Clippy --show-panel` with an image in history; thumbnail renders, hover shows pin/trash only, VoiceOver (Cmd+F5) reads one sensible summary per card.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: image thumbnails on cards, larger badges, accessibility labels"
```

---

### Task 10: PanelSelection, CategorySidePane, CategoryEditorView

**Files:**
- Create: `Sources/Clippy/UI/PanelSelection.swift`
- Create: `Sources/Clippy/UI/CategorySidePane.swift`
- Create: `Sources/Clippy/UI/CategoryEditorView.swift`
- Modify: `Sources/Clippy/Support/Theme.swift` (palette + Color(hexString:))

- [ ] **Step 1: PanelSelection and Theme helpers**

`Sources/Clippy/UI/PanelSelection.swift`:

```swift
import Foundation

/// What the main pane is showing: the chronological history or one category.
enum PanelSelection: Equatable {
    case history
    case category(Int64)
}
```

Append to `Sources/Clippy/Support/Theme.swift`:

```swift
/// Fixed hexes for category colors. Stored in the DB as text, so they must
/// be stable values rather than dynamic system colors.
enum CategoryPalette {
    static let hexes: [String] = [
        "#007AFF", "#AF52DE", "#FF2D55", "#FF3B30", "#FF9500",
        "#FFCC00", "#34C759", "#30B0C7", "#5E5CE6", "#8E8E93",
    ]
}

extension Color {
    /// #RGB, #RRGGBB, or #RRGGBBAA; falls back to system gray.
    init(hexString: String) {
        self = ClipKind.parseHexColor(hexString) ?? Color(nsColor: .systemGray)
    }
}
```

(Then simplify the Task 9 call site: `.map { Color(hexString: $0.colorHex) }`.)

- [ ] **Step 2: CategoryEditorView**

`Sources/Clippy/UI/CategoryEditorView.swift`:

```swift
import SwiftUI

/// Popover for creating or editing a category: name, color, and an icon
/// chosen from curated SF Symbols, an emoji grid, or app logos already seen
/// in the user's history.
struct CategoryEditorView: View {
    /// nil means "create new".
    let category: Category?
    /// Bundle IDs with icons available, for the App logos tab.
    let knownBundleIDs: [String]
    let onSave: (_ name: String, _ colorHex: String, _ iconKind: CategoryIconKind, _ iconValue: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var iconKind: CategoryIconKind
    @State private var iconValue: String
    @State private var iconTab: CategoryIconKind

    private static let symbols: [String] = [
        "pin.fill", "star.fill", "heart.fill", "bolt.fill", "flame.fill", "tag.fill",
        "folder.fill", "tray.full.fill", "doc.text.fill", "terminal.fill", "curlybraces",
        "chevron.left.forwardslash.chevron.right", "link", "envelope.fill", "key.fill",
        "lock.fill", "creditcard.fill", "cart.fill", "gift.fill", "book.fill",
        "graduationcap.fill", "briefcase.fill", "house.fill", "airplane", "car.fill",
        "gamecontroller.fill", "music.note", "photo.fill", "paintpalette.fill", "lightbulb.fill",
    ]

    private static let emojis: [String] = [
        "\u{1F4CC}", "\u{2B50}", "\u{2764}\u{FE0F}", "\u{1F525}", "\u{26A1}", "\u{1F3F7}",
        "\u{1F4C1}", "\u{1F5C2}", "\u{1F4C4}", "\u{1F4BB}", "\u{1F9E0}", "\u{1F517}",
        "\u{2709}\u{FE0F}", "\u{1F511}", "\u{1F512}", "\u{1F4B3}", "\u{1F6D2}", "\u{1F381}",
        "\u{1F4DA}", "\u{1F393}", "\u{1F4BC}", "\u{1F3E0}", "\u{2708}\u{FE0F}", "\u{1F697}",
        "\u{1F3AE}", "\u{1F3B5}", "\u{1F5BC}", "\u{1F3A8}", "\u{1F4A1}", "\u{2705}",
        "\u{1F4DD}", "\u{1F916}",
    ]

    init(
        category: Category?,
        knownBundleIDs: [String],
        onSave: @escaping (String, String, CategoryIconKind, String) -> Void
    ) {
        self.category = category
        self.knownBundleIDs = knownBundleIDs
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
        _colorHex = State(initialValue: category?.colorHex ?? CategoryPalette.hexes[0])
        _iconKind = State(initialValue: category?.iconKind ?? .symbol)
        _iconValue = State(initialValue: category?.iconValue ?? "pin.fill")
        _iconTab = State(initialValue: category?.iconKind ?? .symbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Category name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(CategoryPalette.hexes, id: \.self) { hex in
                        colorSwatch(hex)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Icon", selection: $iconTab) {
                    Text("Symbols").tag(CategoryIconKind.symbol)
                    Text("Emoji").tag(CategoryIconKind.emoji)
                    Text("Apps").tag(CategoryIconKind.appLogo)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                iconGrid
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(category == nil ? "Create" : "Save") {
                    onSave(
                        name.trimmingCharacters(in: .whitespaces),
                        colorHex,
                        iconKind,
                        iconValue
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func colorSwatch(_ hex: String) -> some View {
        let isSelected = colorHex == hex
        return Button {
            colorHex = hex
        } label: {
            Circle()
                .fill(Color(hexString: hex))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.primary.opacity(isSelected ? 0.7 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(hex)")
    }

    @ViewBuilder
    private var iconGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 30), spacing: 4)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                switch iconTab {
                case .symbol:
                    ForEach(Self.symbols, id: \.self) { symbol in
                        iconCell(isSelected: iconKind == .symbol && iconValue == symbol) {
                            iconKind = .symbol
                            iconValue = symbol
                        } content: {
                            Image(systemName: symbol).font(.system(size: 14))
                        }
                        .accessibilityLabel(symbol)
                    }
                case .emoji:
                    ForEach(Self.emojis, id: \.self) { emoji in
                        iconCell(isSelected: iconKind == .emoji && iconValue == emoji) {
                            iconKind = .emoji
                            iconValue = emoji
                        } content: {
                            Text(emoji).font(.system(size: 15))
                        }
                        .accessibilityLabel(emoji)
                    }
                case .appLogo:
                    ForEach(knownBundleIDs, id: \.self) { bundleID in
                        iconCell(isSelected: iconKind == .appLogo && iconValue == bundleID) {
                            iconKind = .appLogo
                            iconValue = bundleID
                        } content: {
                            if let icon = AppIconProvider.shared.icon(forBundleID: bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "app.dashed").font(.system(size: 14))
                            }
                        }
                        .accessibilityLabel(bundleID)
                    }
                }
            }
        }
        .frame(height: 110)
    }

    private func iconCell<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 30, height: 28)
                .background(
                    isSelected ? AnyShapeStyle(Color(hexString: colorHex).opacity(0.25)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: CategorySidePane**

`Sources/Clippy/UI/CategorySidePane.swift`:

```swift
import SwiftUI

/// Right-hand quarter of the panel: a History home row, one row per category,
/// and a New Category row. Category rows accept drops of clip IDs and own the
/// category context menu and editor popover.
struct CategorySidePane: View {
    @ObservedObject var store: ClipStore
    @Binding var selection: PanelSelection

    @ObservedObject private var settings = AppSettings.shared
    @State private var editingCategory: Category?
    @State private var isCreating = false

    /// Distinct source apps seen in history, for the editor's App logos tab.
    private var knownBundleIDs: [String] {
        var seen = Set<String>()
        return store.clips.compactMap(\.sourceAppBundleID).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            historyRow
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1)
                .padding(.vertical, 4)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.categories) { category in
                        categoryRow(category)
                    }
                }
            }
            Spacer(minLength: 0)
            newCategoryRow
        }
        .padding(6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.03))
        .accessibilityLabel("Categories")
    }

    // MARK: - Rows

    private var historyRow: some View {
        sidePaneRow(
            isSelected: selection == .history,
            tint: settings.accentColor,
            icon: { Image(systemName: "clock").font(.system(size: 12, weight: .semibold)) },
            title: "History",
            count: nil,
            help: "All history (\u{2318}1)"
        ) {
            selection = .history
        }
        .accessibilityLabel("History")
    }

    private func categoryRow(_ category: Category) -> some View {
        let categoryID = category.id ?? -1
        let isSelected = selection == .category(categoryID)
        let tint = Color(hexString: category.colorHex)
        return sidePaneRow(
            isSelected: isSelected,
            tint: tint,
            icon: { categoryIcon(category) },
            title: category.name,
            count: store.clipCount(inCategory: categoryID),
            help: category.name
        ) {
            selection = isSelected ? .history : .category(categoryID)
        }
        .contextMenu {
            Button("Edit...") { editingCategory = category }
            if !category.isStarter {
                Divider()
                Button("Delete", role: .destructive) {
                    if selection == .category(categoryID) { selection = .history }
                    store.deleteCategory(category)
                }
            }
        }
        .popover(
            isPresented: Binding(
                get: { editingCategory?.id == category.id },
                set: { if !$0 { editingCategory = nil } }
            )
        ) {
            CategoryEditorView(category: category, knownBundleIDs: knownBundleIDs) { name, colorHex, iconKind, iconValue in
                var updated = category
                updated.name = name
                updated.colorHex = colorHex
                updated.iconKind = iconKind
                updated.iconValue = iconValue
                store.updateCategory(updated)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let clipID = items.first.flatMap(Int64.init) else { return false }
            store.addClip(id: clipID, toCategory: categoryID)
            return true
        }
        .accessibilityLabel("\(category.name), \(store.clipCount(inCategory: categoryID)) clips")
    }

    private var newCategoryRow: some View {
        sidePaneRow(
            isSelected: false,
            tint: .secondary,
            icon: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) },
            title: "New Category",
            count: nil,
            help: "Create a category"
        ) {
            isCreating = true
        }
        .popover(isPresented: $isCreating) {
            CategoryEditorView(category: nil, knownBundleIDs: knownBundleIDs) { name, colorHex, iconKind, iconValue in
                store.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
            }
        }
        .accessibilityLabel("New Category")
    }

    // MARK: - Pieces

    @ViewBuilder
    private func categoryIcon(_ category: Category) -> some View {
        switch category.iconKind {
        case .symbol:
            Image(systemName: category.iconValue)
                .font(.system(size: 12, weight: .semibold))
        case .emoji:
            Text(category.iconValue)
                .font(.system(size: 13))
        case .appLogo:
            if let icon = AppIconProvider.shared.icon(forBundleID: category.iconValue) {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12))
            }
        }
    }

    private func sidePaneRow<Icon: View>(
        isSelected: Bool,
        tint: Color,
        @ViewBuilder icon: () -> Icon,
        title: String,
        count: Int?,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon()
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let count {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Build complete (the pane is not mounted yet; that is Task 11).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: category side pane and category editor with color and icon picker"
```

---

### Task 11: ClipListView split layout, slide transition, keyboard, footer

**Files:**
- Modify: `Sources/Clippy/UI/ClipListView.swift` (full replacement below)

- [ ] **Step 1: Replace ClipListView.swift entirely**

```swift
import SwiftUI

/// Content of the popup panel: search bar, a 75/25 split between the main
/// content pane and the category side pane, and a shortcut footer. The main
/// pane slides between History and a selected category. Keyboard driven end
/// to end.
struct ClipListView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onPaste: (Clip, Bool) -> Void
    let onEdit: (Clip) -> Void
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @State private var selection: PanelSelection = .history
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    /// Clips shown for the current selection, in keyboard-navigation order.
    private var visibleClips: [Clip] {
        switch selection {
        case .history:
            return store.clips
        case .category(let categoryID):
            return store.clips.filter { store.categoryIDs(for: $0).contains(categoryID) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    mainPane
                        .frame(width: max(0, geo.size.width - sidePaneWidth(geo)))
                    Divider()
                    CategorySidePane(store: store, selection: $selection)
                        .frame(width: sidePaneWidth(geo) - 1)
                }
            }
            Divider()
            footer
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .tint(settings.accentColor)
        .onChange(of: store.clips) { _, _ in selectedIndex = 0 }
        .onChange(of: selection) { _, _ in selectedIndex = 0 }
    }

    /// Side pane takes a quarter of the panel but never less than 150pt.
    private func sidePaneWidth(_ geo: GeometryProxy) -> CGFloat {
        max(150, geo.size.width * 0.25)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if let material = settings.panelMaterial.material {
            Rectangle().fill(material)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: - Main pane

    private var mainPane: some View {
        ZStack {
            if selection == .history {
                paneContent
                    .transition(paneTransition(edge: .leading))
            } else {
                paneContent
                    .id(selection)
                    .transition(paneTransition(edge: .trailing))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selection)
        .clipped()
    }

    private func paneTransition(edge: Edge) -> AnyTransition {
        .move(edge: edge).combined(with: .opacity)
    }

    @ViewBuilder
    private var paneContent: some View {
        if visibleClips.isEmpty {
            emptyState
        } else {
            sectionedList
        }
    }

    // MARK: - Header

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search clipboard history", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    pasteSelected(shiftHeld: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onKeyPress(keys: ["e"]) { press in
                    guard press.modifiers.contains(.command),
                          let clip = selectedClip,
                          clip.contentKind == .text
                    else { return .ignored }
                    onEdit(clip)
                    return .handled
                }
                .onKeyPress(keys: ["p"]) { press in
                    guard press.modifiers.contains(.command), let clip = selectedClip else { return .ignored }
                    store.togglePin(clip)
                    return .handled
                }
                .onKeyPress(keys: [.delete]) { press in
                    guard press.modifiers.contains(.command), let clip = selectedClip else { return .ignored }
                    store.delete(clip)
                    return .handled
                }
                .onKeyPress(keys: ["1", "2", "3", "4", "5", "6", "7", "8", "9"]) { press in
                    guard press.modifiers.contains(.command),
                          let digit = press.characters.first?.wholeNumberValue
                    else { return .ignored }
                    if digit == 1 {
                        selection = .history
                        return .handled
                    }
                    let index = digit - 2
                    guard store.categories.indices.contains(index),
                          let categoryID = store.categories[index].id
                    else { return .ignored }
                    selection = .category(categoryID)
                    return .handled
                }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Clippy settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { searchFocused = true }
    }

    // MARK: - Sectioned list

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [(index: Int, clip: Clip)]
    }

    private var sections: [Section] {
        let rows = Array(visibleClips.enumerated()).map { (index: $0.offset, clip: $0.element) }
        // Date headers only make sense for the chronological history.
        guard settings.showSectionHeaders, selection == .history else {
            return [Section(id: "all", title: "", rows: rows)]
        }

        var grouped: [(title: String, rows: [(index: Int, clip: Clip)])] = []
        for row in rows {
            let title = sectionTitle(for: row.clip)
            if let last = grouped.indices.last, grouped[last].title == title {
                grouped[last].rows.append(row)
            } else {
                grouped.append((title: title, rows: [row]))
            }
        }
        return grouped.map { Section(id: $0.title, title: $0.title, rows: $0.rows) }
    }

    private func sectionTitle(for clip: Clip) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(clip.createdAt) { return "Today" }
        if calendar.isDateInYesterday(clip.createdAt) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()), clip.createdAt > weekAgo {
            return "This Week"
        }
        if let monthAgo = calendar.date(byAdding: .month, value: -1, to: Date()), clip.createdAt > monthAgo {
            return "This Month"
        }
        return "Earlier"
    }

    private var sectionedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6, pinnedViews: []) {
                    ForEach(sections) { section in
                        if !section.title.isEmpty {
                            sectionHeader(section.title)
                        }
                        ForEach(section.rows, id: \.clip.id) { row in
                            card(for: row.clip, at: row.index)
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard visibleClips.indices.contains(newIndex) else { return }
                proxy.scrollTo(visibleClips[newIndex].id, anchor: nil)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1)
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }

    private func card(for clip: Clip, at index: Int) -> some View {
        ClipCardView(
            clip: clip,
            isSelected: index == selectedIndex,
            isPinned: store.isPinned(clip),
            categoryColors: store.categories
                .filter { category in
                    guard let id = category.id else { return false }
                    return store.categoryIDs(for: clip).contains(id)
                }
                .map { Color(hexString: $0.colorHex) },
            onPaste: { onPaste(clip, settings.pastePlainTextByDefault) },
            onPastePlain: { onPaste(clip, true) },
            onEdit: { onEdit(clip) },
            onTogglePin: { store.togglePin(clip) },
            onDelete: { store.delete(clip) }
        )
        .id(clip.id)
        .onTapGesture { onPaste(clip, settings.pastePlainTextByDefault) }
        .draggable(String(clip.id ?? -1))
        .contextMenu {
            Button("Paste") { onPaste(clip, false) }
            if clip.contentKind == .text {
                Button("Paste as Plain Text") { onPaste(clip, true) }
                Divider()
                Button("Edit...") { onEdit(clip) }
            }
            Button(store.isPinned(clip) ? "Unpin" : "Pin") { store.togglePin(clip) }
            categoriesMenu(for: clip)
            Divider()
            Button("Delete", role: .destructive) { store.delete(clip) }
        }
    }

    private func categoriesMenu(for clip: Clip) -> some View {
        Menu("Categories") {
            ForEach(store.categories) { category in
                let categoryID = category.id ?? -1
                let isMember = store.categoryIDs(for: clip).contains(categoryID)
                Button {
                    store.setClip(clip, inCategory: categoryID, !isMember)
                } label: {
                    if isMember {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
        }
    }

    // MARK: - Empty and footer

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyIcon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyIcon: String {
        switch selection {
        case .history: return "clipboard"
        case .category: return "tray"
        }
    }

    private var emptyMessage: String {
        if !store.query.isEmpty {
            return "No clips match \"\(store.query)\"."
        }
        switch selection {
        case .history:
            return "Nothing here yet. Copy something and it will show up."
        case .category:
            return "No clips in this category yet. Right-click a clip and choose Categories, or drag a card onto the category."
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            keyHint("\u{21A9}", settings.pastePlainTextByDefault ? "paste plain" : "paste")
            keyHint("\u{21E7}\u{21A9}", settings.pastePlainTextByDefault ? "formatted" : "plain")
            keyHint("\u{2318}P", "pin")
            keyHint("\u{238B}", "close")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(action)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.75))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(action)")
    }

    // MARK: - Selection and actions

    private var selectedClip: Clip? {
        visibleClips.indices.contains(selectedIndex) ? visibleClips[selectedIndex] : nil
    }

    private func moveSelection(by delta: Int) {
        guard !visibleClips.isEmpty else { return }
        selectedIndex = max(0, min(visibleClips.count - 1, selectedIndex + delta))
    }

    private func pasteSelected(shiftHeld: Bool) {
        guard let clip = selectedClip else { return }
        // Shift inverts whichever paste mode is the configured default.
        let asPlainText = settings.pastePlainTextByDefault != shiftHeld
        onPaste(clip, asPlainText)
    }
}
```

Note: `PanelTab` is deleted with this replacement. Run `grep -rn "PanelTab" Sources/` and remove any remaining references.

- [ ] **Step 2: Build and run**

Run: `swift build && swift test`
Expected: Build complete, tests pass.

- [ ] **Step 3: Manual verification**

Run: `swift run Clippy --show-panel` and check:
- Side pane shows History, the Pinned starter category, New Category
- Clicking a category slides content in from the right; History slides back
- Cmd+1 / Cmd+2 switch panes from the search field
- Pinned clips appear chronologically in History (no top hoisting)
- Drag a card onto a category row adds it (dot appears on the card)
- Footer hints readable at arm's length
- Reduced motion (System Settings > Accessibility > Display) kills the slide

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: split panel layout with category side pane and slide navigation"
```

---

### Task 12: Export update and remaining copy

**Files:**
- Modify: `Sources/Clippy/UI/SettingsView.swift` (IntegrationsSettingsTab.exportJSON)

- [ ] **Step 1: Replace exportJSON with category- and image-aware export**

```swift
    private func exportJSON() {
        struct ExportClip: Encodable {
            let text: String
            let kind: String
            let mediaFile: String?
            let sourceApp: String?
            let sourceBundleID: String?
            let createdAt: Date
            let categories: [String]
        }
        struct ExportDocument: Encodable {
            let note: String
            let clips: [ExportClip]
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "clippy-export.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let database = ClipDatabase.shared
            let categories = try database.categories()
            let membership = try database.membershipMap()
            let nameByID = Dictionary(
                uniqueKeysWithValues: categories.compactMap { category in
                    category.id.map { ($0, category.name) }
                }
            )
            let clips = try database.allClips().map { clip in
                ExportClip(
                    text: clip.contentText,
                    kind: clip.contentKind.rawValue,
                    mediaFile: clip.mediaFilename.map { database.media.url(for: $0).path },
                    sourceApp: clip.sourceAppName,
                    sourceBundleID: clip.sourceAppBundleID,
                    createdAt: clip.createdAt,
                    categories: (clip.id.flatMap { membership[$0] } ?? [])
                        .compactMap { nameByID[$0] }
                        .sorted()
                )
            }
            let document = ExportDocument(
                note: "Image clips reference PNG files under the Clippy media folder; copy them separately if you need a portable backup.",
                clips: clips
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url)
            exportResult = "Exported \(clips.count) clips to \(url.lastPathComponent)."
        } catch {
            exportResult = "Export failed: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 2: Build, export manually once, inspect the JSON**

Run: `swift build`, launch, Settings > Integrations > Export as JSON. Open the file; confirm `kind`, `categories`, and `note` fields are present.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: export includes content kind, media paths, and category names"
```

---

### Task 13: Final verification

- [ ] **Step 1: Full automated pass**

Run: `swift test && swift build`
Expected: every suite green, clean build.

- [ ] **Step 2: Manual smoke checklist** (`swift run Clippy --show-panel`)

- Copy text in two different apps; both captured with correct app icons
- Copy an image (screenshot to clipboard); thumbnail card appears with dimensions
- Pin via Cmd+P; clip gains pin badge and appears in the Pinned category pane
- Create a category with an emoji icon and a custom color; add a clip via the context menu Categories submenu and via drag
- Category clip counts update live in the side pane
- Delete the category; clips survive, membership dots disappear
- Paste text (Return), paste plain (Shift+Return), paste an image into TextEdit
- Light and dark appearance; Glass (ultra thin) material: card text remains readable
- Reduced motion on: pane switch does not animate
- Panel at 300pt width: side pane clamps to 150pt, cards stay usable
- Settings > Capture: toggle image capture off, copy an image, confirm it is NOT captured

- [ ] **Step 3: Boy-scout pass**

Run: `grep -rn "isPinned\|PanelTab\|deleteUnpinnedClips" Sources/ Tests/`
Expected: only `isPinned(_:)`/`isPinned:` store/view-parameter hits remain; no Clip field, no PanelTab, no deleteUnpinnedClips.

- [ ] **Step 4: Final commit if the sweep changed anything**

```bash
git add -A
git commit -m "chore: post-redesign cleanup"
```

---

## Plan Self-Review Notes

- Spec coverage: layout/navigation (Task 11), tag-model categories + migration (Tasks 4-5), customization editor with symbols/emoji/app logos (Task 10), full image pipeline (Tasks 6-8), card legibility + a11y labels (Task 9), footer legend (Task 11), settings additions (Task 8), export (Task 12), data safety + orphan sweep (Task 7), testing (throughout + Task 13).
- Known judgment calls an implementer may hit: `swift test` against an executable target requires SwiftPM 5.5+ behavior (present here); `onKeyPress(keys:)` with character sets and `press.characters` requires macOS 14 SDK (the package already targets macOS 14). If `press.characters` is unavailable, use `press.key.character` equivalents and report the deviation.
- Tasks 4 and 5 intentionally share one commit because dropping `isPinned` cannot compile in isolation.
