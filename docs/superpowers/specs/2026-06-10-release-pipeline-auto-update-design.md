# Release Pipeline and In-App Auto-Update

Date: 2026-06-10
Status: Approved

## Problem

Clippy has no release process and no way for installed copies to learn about
new versions. Releases are built locally with `scripts/make-app.sh`, the
version is hardcoded at 0.1.0, and distribution is manual. Users who install
the app today never see updates.

## Goals

- Pushing a git tag `vX.Y.Z` produces a published GitHub Release with a
  ready-to-install `Clippy.app` zip.
- The running app checks for new releases on its own, offers the update in a
  standard UI, downloads, verifies, installs, and relaunches.
- Updates are cryptographically verified even though the app is only ad-hoc
  signed (no paid Apple Developer account).

## Non-Goals

- Developer ID signing and notarization. First-time installers right-click >
  Open once to pass Gatekeeper; the pipeline leaves an obvious place to add
  notarization later.
- Delta updates, release channels (beta/stable), or multi-version appcast
  history. The appcast carries only the latest release; Sparkle only needs an
  entry newer than the installed version.

## Decisions

| Decision | Choice |
| --- | --- |
| Update framework | Sparkle 2 (SwiftPM dependency) |
| Release trigger | Push of a `v*` tag |
| Update security | Sparkle EdDSA signatures; private key in GitHub secret `SPARKLE_ED_PRIVATE_KEY`, public key committed in the repo |
| Appcast hosting | `appcast.xml` committed to `main`, served via `https://raw.githubusercontent.com/w159/clippy/main/appcast.xml` |
| Version source of truth | The git tag. Local builds default to `0.0.0-dev`. |

## Components

### 1. Packaging script (`scripts/make-app.sh`)

- Accepts the version as `$1` or `$VERSION`, defaulting to `0.0.0-dev`.
- Writes `CFBundleShortVersionString` and `CFBundleVersion` from that value.
- Adds Sparkle keys to Info.plist: `SUFeedURL`, `SUPublicEDKeyString` (read
  from `scripts/sparkle-public-key.txt`), `SUEnableAutomaticChecks`.
- Copies `Sparkle.framework` from the SwiftPM artifacts directory into
  `Clippy.app/Contents/Frameworks` and adds an
  `@executable_path/../Frameworks` rpath to the binary with
  `install_name_tool`.
- Ad-hoc signs the bundle as before. The embedded Sparkle framework keeps the
  Sparkle project's own valid signature.
- If the public key file is missing or a placeholder, local builds skip the
  Sparkle plist keys with a warning; CI builds fail fast.

### 2. App integration

- `Package.swift` gains `https://github.com/sparkle-project/Sparkle` (major
  version 2) as a dependency of the executable target.
- `AppDelegate` owns a `SPUStandardUpdaterController` (started at launch,
  standard Sparkle UI).
- The status item menu gains "Check for Updates..." wired to
  `SPUStandardUpdaterController.checkForUpdates(_:)`.
- Automatic background checks use Sparkle defaults (daily). Sparkle prompts
  the user on second launch for permission to check automatically.
- When the app runs unbundled (swift run, tests), Sparkle has no feed URL and
  the updater stays inert; the menu item remains but Sparkle disables it via
  its own validation.

### 3. Appcast generator (`scripts/make-appcast.sh`)

- Inputs: version, zip path, EdDSA signature, zip byte length.
- Emits a single-item `appcast.xml` pointing at the GitHub Release download
  URL `https://github.com/w159/clippy/releases/download/vX.Y.Z/Clippy-X.Y.Z.zip`
  with `sparkle:version`, `sparkle:shortVersionString`,
  `sparkle:edSignature`, `length`, and `sparkle:minimumSystemVersion` 14.0.

### 4. Release workflow (`.github/workflows/release.yml`)

Trigger: push of tag `v*`. Permissions: `contents: write`. Runner: `macos-15`.

1. Checkout the tag; derive `VERSION` from the tag name.
2. `swift test` - failing tests abort the release.
3. `scripts/make-app.sh "$VERSION"` and zip the app with
   `ditto -c -k --keepParent`.
4. Sign the zip with Sparkle's `sign_update` using the
   `SPARKLE_ED_PRIVATE_KEY` secret (tool taken from the pinned Sparkle
   distribution archive).
5. `scripts/make-appcast.sh` writes `appcast.xml`; the workflow commits it to
   `main`.
6. Publish the GitHub Release with the zip attached and auto-generated notes.

### 5. One-time owner setup (manual, documented in README)

1. Run Sparkle's `generate_keys`; it stores the private key in the local
   Keychain and prints the public key.
2. Put the public key in `scripts/sparkle-public-key.txt` and commit.
3. Export the private key (`generate_keys -x`) and add it as the GitHub
   Actions secret `SPARKLE_ED_PRIVATE_KEY`. The private key never enters the
   repo or the agent conversation.

## Error Handling

- Release workflow fails (and publishes nothing) when tests fail, the public
  key file is missing, the secret is absent, or signing fails.
- Sparkle rejects any update whose EdDSA signature does not verify against
  the embedded public key, so a compromised download host cannot push
  tampered binaries.
- If the appcast commit to `main` races a concurrent push, the workflow
  rebases and retries once; a second failure fails the job loudly.

## Testing

- `swift test` keeps passing with the Sparkle dependency added.
- `scripts/make-app.sh 1.2.3` locally produces a bundle whose Info.plist
  carries version 1.2.3, the Sparkle keys, and an embedded
  `Sparkle.framework`; the app launches.
- `scripts/make-appcast.sh` output validates as XML and carries the expected
  enclosure attributes (unit-style check run locally and in CI).
- Full end-to-end check (tag push -> release -> in-app update prompt) happens
  on the first real tag, since it requires the repo secret.

## Release Ritual

```
git tag v0.2.0
git push origin v0.2.0
```
