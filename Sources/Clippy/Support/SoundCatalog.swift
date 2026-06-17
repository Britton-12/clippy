import AppKit

// Discovers every capture sound the machine can play and addresses each by a
// stable string id. Two id schemes:
//   "system:<Name>"  -> NSSound(named:)        classic alerts + ~/Library/Sounds
//   "file:<abspath>" -> NSSound(contentsOf:)   modern CoreAudio UI sounds
// The modern UI/notification sounds live under the CoreAudio component and are
// not name-resolvable, so they are addressed by absolute path.

struct SoundOption: Identifiable, Hashable {
    let id: String
    let label: String
    let group: String
}

enum SoundCatalog {
    static let defaultID = "system:Tink"

    /// Root of CoreAudio's bundled UI sounds. The whole tree is enumerated (see
    /// build()); the curated list below just hoists the best capture-confirmation
    /// candidates into a highlights group at the top of the picker.
    private static let coreAudioBase =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"

    /// Subfolder -> picker group label for the full CoreAudio enumeration.
    /// "system" maps to "System UI" so it does not collide with the
    /// /System/Library/Sounds "System" group.
    private static let coreAudioGroupLabels: [String: String] = [
        "accessibility": "Accessibility",
        "dock": "Dock",
        "facetime": "FaceTime",
        "finder": "Finder",
        "ink": "Ink",
        "siri": "Siri",
        "system": "System UI",
        "telephony": "Telephony",
    ]

    private static let curatedModern: [(label: String, relativePath: String)] = [
        ("Sent Message", "system/SentMessage.caf"),
        ("Acknowledgment", "system/acknowledgment_sent.caf"),
        ("Payment Success", "system/payment_success.aif"),
        ("Media Handoff", "system/media_handoff.caf"),
        ("Screen Share", "system/screen_sharing_started.caf"),
        ("Grab", "system/Grab.aif"),
        ("Screenshot", "system/Screen Capture.aif"),
        ("Shutter", "system/Shutter.aif"),
        ("Siri Begin", "siri/jbl_begin.caf"),
        ("Siri Confirm", "siri/jbl_confirm.caf"),
        ("Siri Cancel", "siri/jbl_cancel.caf"),
        ("Empty Trash", "finder/move to trash.aif"),
        ("FaceTime Join", "facetime/multiway_join.caf"),
    ]

    /// Built once, lazily: probing the filesystem is cheap but pointless to
    /// repeat on every settings render.
    static let options: [SoundOption] = build()

    /// All ids in declared order, for "next sound" cycling if ever needed.
    static var allIDs: [String] { options.map(\.id) }

    static func label(for id: String) -> String {
        options.first { $0.id == id }?.label ?? "Sound"
    }

    static func contains(_ id: String) -> Bool {
        options.contains { $0.id == id }
    }

    /// First valid id at or after the stored one, so a removed sound never
    /// leaves the picker on a dead selection.
    static func resolvedID(for stored: String) -> String {
        contains(stored) ? stored : defaultID
    }

    private static func build() -> [SoundOption] {
        var result: [SoundOption] = []

        // Classic alert sounds (the 14 in /System/Library/Sounds).
        for sound in CaptureSound.allCases {
            result.append(SoundOption(id: "system:\(sound.rawValue)", label: sound.label, group: "Classic"))
        }

        let fm = FileManager.default

        // Every remaining alert sound shipped in /System/Library/Sounds. These
        // are name-resolvable via NSSound(named:), so they share the "system:"
        // scheme. The curated Classic names above already cover the stock set;
        // de-duping by id keeps a name that lands in both groups out of System,
        // and any extra sounds a future OS adds show up here without a code change.
        let systemSoundsDir = "/System/Library/Sounds"
        let systemNames = (try? fm.contentsOfDirectory(atPath: systemSoundsDir)) ?? []
        for file in systemNames.sorted() where isSoundFile(file) {
            let base = (file as NSString).deletingPathExtension
            let id = "system:\(base)"
            guard !result.contains(where: { $0.id == id }) else { continue }
            result.append(SoundOption(id: id, label: base, group: "System"))
        }

        // Modern notification / UI sounds, included only if present on disk.
        for entry in curatedModern {
            let path = "\(coreAudioBase)/\(entry.relativePath)"
            if fm.fileExists(atPath: path) {
                result.append(SoundOption(id: "file:\(path)", label: entry.label, group: "Notification & UI"))
            }
        }

        // The full CoreAudio SystemSounds tree, one group per subfolder. Dedup by
        // id keeps the curated highlights above from reappearing in their category
        // group. The curated entries use the same file:<abspath> id scheme, so a
        // highlighted sound is matched and skipped here.
        for (subfolder, group) in coreAudioGroupLabels.sorted(by: { $0.key < $1.key }) {
            let dir = "\(coreAudioBase)/\(subfolder)"
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for file in names.sorted() where isSoundFile(file) {
                let id = "file:\(dir)/\(file)"
                guard !result.contains(where: { $0.id == id }) else { continue }
                let base = (file as NSString).deletingPathExtension
                result.append(SoundOption(id: id, label: readableLabel(from: base), group: group))
            }
        }

        // Anything the user dropped in their own Sounds folders.
        for dir in userSoundDirectories() {
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for file in names.sorted() where isSoundFile(file) {
                let base = (file as NSString).deletingPathExtension
                let id = "system:\(base)"
                guard !result.contains(where: { $0.id == id }) else { continue }
                result.append(SoundOption(id: id, label: base, group: "Custom"))
            }
        }

        return result
    }

    private static func userSoundDirectories() -> [String] {
        var dirs: [String] = []
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            dirs.append("\(home)/Library/Sounds")
        }
        dirs.append("/Library/Sounds")
        return dirs
    }

    private static func isSoundFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["aiff", "aif", "caf", "wav", "m4a", "mp3", "aifc"].contains(ext)
    }

    /// Turns a raw filename stem into a picker label: underscores and hyphens
    /// become spaces, runs of whitespace collapse, and each word is title-cased.
    /// Deterministic and lossless for already-readable names ("move to trash" ->
    /// "Move to Trash"); leaves acronym-ish stems alone beyond first-letter case
    /// ("jbl_begin" -> "Jbl Begin").
    private static func readableLabel(from stem: String) -> String {
        let spaced = stem.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let words = spaced.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - id-based playback

extension SoundPlayer {
    /// Resolve an NSSound from a catalog id. Results are cached because NSSound
    /// construction reads and decodes the file.
    static func resolve(id: String) -> NSSound? {
        if let cached = idCache[id] { return cached }
        let sound: NSSound?
        if id.hasPrefix("system:") {
            let name = String(id.dropFirst("system:".count))
            sound = NSSound(named: NSSound.Name(name))
        } else if id.hasPrefix("file:") {
            let path = String(id.dropFirst("file:".count))
            sound = NSSound(contentsOfFile: path, byReference: true)
        } else {
            sound = NSSound(named: NSSound.Name(id))
        }
        if let sound { idCache[id] = sound }
        return sound
    }

    /// Play a catalog sound by id at the given volume. Returns false when the id
    /// does not resolve (missing file / OS version), in which case the caller
    /// simply produces no sound rather than crashing.
    @discardableResult
    static func play(id: String, volume: Float) -> Bool {
        guard let sound = resolve(id: id) else { return false }
        sound.volume = clampVolume(volume)
        // Restart cleanly if a rapid second capture lands mid-playback.
        if sound.isPlaying { sound.stop() }
        sound.play()
        return true
    }
}
