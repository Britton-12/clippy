# iCloud sync setup

Clippy's iCloud sync mirrors clips and categories to your private CloudKit
database (`CloudSyncEngine` + `CloudRecordMapper`). The record-mapping logic is
unit-tested (`CloudRecordMapperTests`), but live device-to-device sync only works
in a **signed build with the iCloud entitlement**. SwiftPM `swift run` and the
test bundle cannot exercise CloudKit, so the toggle is a safe no-op there.

## What a signed build needs

1. An Apple Developer account with iCloud + CloudKit enabled.
2. The CloudKit container `iCloud.com.henssler.clippy` (this string is
   `CloudSchema.containerIdentifier` in `CloudRecordMapper.swift` — change both if
   you use a different container).
3. An entitlements file applied at codesign time. A template is committed at
   `Clippy.entitlements`:

   ```xml
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array><string>iCloud.com.henssler.clippy</string></array>
   <key>com.apple.developer.icloud-services</key>
   <array><string>CloudKit</string></array>
   <key>com.apple.developer.ubiquity-kvstore-identifier</key>
   <string>$(TeamIdentifierPrefix)com.henssler.clippy</string>
   ```

4. Sign the packaged `.app` with these entitlements (the release pipeline's
   `codesign` step gains `--entitlements Clippy.entitlements`), using a
   provisioning profile that includes the container.

## CloudKit schema

The engine creates a custom zone `ClippyZone` and two record types. In the
CloudKit dashboard (or via first-run in the Development environment, which
auto-creates types), ensure these exist and are queryable:

- `Clip`: `contentText` (String), `typeIdentifier` (String), `contentKind`
  (String), `createdAt` (Date/Time), `userTitle`, `sourceAppName`,
  `sourceAppBundleID`, `mediaFilename`, `thumbFilename`, `pixelWidth` (Int),
  `pixelHeight` (Int), `byteSize` (Int).
- `Category`: `name`, `colorHex`, `iconKind`, `iconValue`, `sortOrder` (Int),
  `isStarter` (Int), `createdAt` (Date/Time).

The pull step queries with a `TRUEPREDICATE`, which requires the record types'
`recordName` to be queryable — the default in the Development environment.

## Limitations (this version)

- Image clip **bytes** are not yet uploaded as `CKAsset`s; image clips sync their
  metadata but are skipped on pull (text clips and categories sync fully).
- Pull is a full-zone fetch, not an incremental `CKServerChangeToken` delta. Fine
  for the typical history size; a future version should move to
  `CKFetchRecordZoneChangesOperation` with a persisted change token and a
  `CKDatabaseSubscription` for push-driven refresh.
- Merge is non-destructive (upsert by content key); it never deletes local data.
