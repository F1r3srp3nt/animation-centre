//
//  Support.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  Paths, settings, the event log and small helpers.
//

import AppKit
import Foundation
import HCGAnimationPack

enum AppInfo {
    static let name = "HCG Animation Center"
    static let bundleID = "com.hakmicapitalgroup.animationcenter.mac"
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0-dev"
    }
    static var build: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev" }
}

/// Where the app keeps its data. `HCG_ANIMATION_CENTER_HOME` overrides the root (self-tests, CI).
struct AppPaths {
    let root: URL

    static let standard: AppPaths = {
        if let override = ProcessInfo.processInfo.environment["HCG_ANIMATION_CENTER_HOME"], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        if Settings.isSelfTest {
            // The self-test never touches the user's library or log.
            return AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("hcg-selftest-home", isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appendingPathComponent("HCG Animation Center", isDirectory: true))
    }()

    var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    var catalog: URL { root.appendingPathComponent("Catalog", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    var eventLog: URL { logs.appendingPathComponent("events.log") }

    func prepare() {
        for d in [root, library, catalog, logs] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

/// The resources shipped inside the app (sample pack and the local catalog), or the repository copy when run with
/// `swift run` during development.
enum BundledResources {
    static var samplesFolder: URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Samples", isDirectory: true),
           fm.fileExists(atPath: r.appendingPathComponent("catalog.local.json").path) {
            return r
        }
        // Development: walk up from the executable to the repository's Samples folder.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Samples", isDirectory: true)
            if fm.fileExists(atPath: candidate.appendingPathComponent("catalog.local.json").path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static var samplePack: URL? { samplesFolder?.appendingPathComponent("OrbitalCommand.hcgpack", isDirectory: true) }
    static var localCatalog: URL? { samplesFolder?.appendingPathComponent("catalog.local.json") }
}

/// User settings (UserDefaults).
enum Settings {
    static let isSelfTest = CommandLine.arguments.contains("--self-test")
    static let suiteName = "com.hakmicapitalgroup.animationcenter.mac.selftest"
    /// The self-test uses its own settings domain.
    static let defaults: UserDefaults = isSelfTest ? (UserDefaults(suiteName: suiteName) ?? .standard) : .standard

    enum Key {
        static let keepPlaying = "keepPlayingWhenEditorCloses"
        static let resumeOnLaunch = "resumeOnLaunch"
        static let appliedPack = "appliedPackID"
        static let catalogURL = "catalogURL"
        static let stillOnly = "stillOnly"
        static let seeded = "seededSample"
    }

    static func register() {
        defaults.register(defaults: [Key.keepPlaying: true, Key.resumeOnLaunch: true, Key.stillOnly: false])
    }

    static var keepPlayingWhenEditorCloses: Bool {
        get { defaults.bool(forKey: Key.keepPlaying) }
        set { defaults.set(newValue, forKey: Key.keepPlaying) }
    }
}

/// A plain-text event log (~/Library/Application Support/HCG Animation Center/Logs/events.log): apply, stop, display
/// changes, sleep/wake, policy changes. The hardware checklist reads it.
final class EventLog: @unchecked Sendable {
    static let shared = EventLog(url: AppPaths.standard.eventLog)

    let url: URL
    private let queue = DispatchQueue(label: "hcg.eventlog")
    private(set) var recent: [String] = []
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)"
        lock.lock()
        recent.append(line)
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        lock.unlock()
        queue.async { [url] in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data((line + "\n").utf8))
                try? h.close()
            } else {
                try? Data((line + "\n").utf8).write(to: url)
            }
        }
        #if DEBUG
        print(line)
        #endif
    }

    func lines() -> [String] { lock.lock(); defer { lock.unlock() }; return recent }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatSeconds(_ s: Double) -> String {
    guard s.isFinite else { return "–" }
    let m = Int(s) / 60
    let rest = s - Double(m * 60)
    return m > 0 ? String(format: "%d:%05.2f", m, rest) : String(format: "%.2f s", rest)
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
