//
//  AppModel.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  The library (one .hcgpack folder per item), the selection being edited, autosave, Apply to Desktop and exports.
//

import AppKit
import Combine
import Foundation
import HCGAnimationPack
import UniformTypeIdentifiers

struct LibraryItem: Identifiable, Equatable {
    var pack: AnimationPack
    var folder: URL
    var id: String { pack.id }
    var mediaURL: URL { folder.appendingPathComponent(pack.media.file) }
    var posterURL: URL? { pack.files.first { $0.role == "poster" }.map { folder.appendingPathComponent($0.file) } }
}

@MainActor
final class Playhead: ObservableObject {
    @Published var time: Double = 0
}

struct Banner: Equatable {
    var text: String
    var isError: Bool
}

@MainActor
final class AppModel: ObservableObject {
    let paths: AppPaths
    let monitor: SystemMonitor
    let desktop: DesktopPlayer
    let catalog: CatalogModel

    @Published private(set) var items: [LibraryItem] = []
    @Published var selectedID: String? { didSet { if selectedID != oldValue { playhead.time = 0 } } }
    @Published var placement: PlacementID = .desktop
    @Published var banner: Banner?
    @Published var busy: String?
    /// The editor preview's playhead (its own object: it changes 30 times a second).
    let playhead = Playhead()
    @Published var editorOpen = true

    @Published var keepPlaying: Bool { didSet { Settings.keepPlayingWhenEditorCloses = keepPlaying } }
    @Published var resumeOnLaunch: Bool { didSet { Settings.defaults.set(resumeOnLaunch, forKey: Settings.Key.resumeOnLaunch) } }
    @Published var stillOnly: Bool {
        didSet {
            Settings.defaults.set(stillOnly, forKey: Settings.Key.stillOnly)
            monitor.forceStill = stillOnly
        }
    }

    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(paths: AppPaths = .standard) {
        Settings.register()
        paths.prepare()
        self.paths = paths
        let monitor = SystemMonitor()
        self.monitor = monitor
        desktop = DesktopPlayer(monitor: monitor)
        catalog = CatalogModel(root: paths.catalog)
        keepPlaying = Settings.keepPlayingWhenEditorCloses
        resumeOnLaunch = Settings.defaults.bool(forKey: Settings.Key.resumeOnLaunch)
        stillOnly = Settings.defaults.bool(forKey: Settings.Key.stillOnly)
        monitor.forceStill = stillOnly
        // Re-publish nested objects so menu bar and editor views update.
        desktop.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        monitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        catalog.library = self
    }

    var selected: LibraryItem? { items.first { $0.id == selectedID } }
    var selectedPlacement: Placement? { selected?.pack.placement(placement) }

    // MARK: Library

    func loadLibrary() {
        seedSampleIfNeeded()
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: paths.library, includingPropertiesForKeys: nil)) ?? []
        var loaded: [LibraryItem] = []
        for f in folders where f.pathExtension == AnimationPack.folderExtension {
            do {
                loaded.append(LibraryItem(pack: try AnimationPack.read(contentsOf: f), folder: f))
            } catch {
                EventLog.shared.log("library: skipped \(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        items = loaded.sorted { ($0.pack.created ?? .distantPast) > ($1.pack.created ?? .distantPast) }
        if selectedID == nil || selected == nil { selectedID = items.first?.id }
    }

    /// First launch: copy the bundled HCG Orbital Command pack into the library.
    func seedSampleIfNeeded() {
        guard !Settings.defaults.bool(forKey: Settings.Key.seeded), let sample = BundledResources.samplePack,
              let pack = try? AnimationPack.read(contentsOf: sample) else { return }
        let dest = paths.library.appendingPathComponent("\(pack.id).hcgpack", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            do {
                try FileManager.default.copyItem(at: sample, to: dest)
                EventLog.shared.log("library: added the sample \(pack.name)")
            } catch {
                EventLog.shared.log("library: could not add the sample: \(error.localizedDescription)")
                return
            }
        }
        Settings.defaults.set(true, forKey: Settings.Key.seeded)
    }

    func addPackFolder(_ source: URL, select: Bool = true) throws {
        let pack = try AnimationPack.read(contentsOf: source)
        try pack.verify(in: source)
        let dest = paths.library.appendingPathComponent("\(pack.id).hcgpack", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        loadLibrary()
        if select { selectedID = pack.id }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = urls.count == 1 ? "Importing \(urls[0].lastPathComponent)…" : "Importing \(urls.count) files…"
        Task {
            var lastID: String?
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    if url.pathExtension == AnimationPack.folderExtension {
                        try addPackFolder(url, select: false)
                        lastID = try AnimationPack.read(contentsOf: url).id
                    } else {
                        let (pack, _) = try await MediaImporter.importFile(url, into: paths.library)
                        lastID = pack.id
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            busy = nil
            loadLibrary()
            if let lastID { selectedID = lastID }
            banner = failures.isEmpty
                ? Banner(text: "Imported. Edit each placement, then Apply to Desktop.", isError: false)
                : Banner(text: failures.joined(separator: "\n"), isError: true)
        }
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaImporter.acceptedTypes
        panel.message = "Choose MP4, MOV or GIF files to import"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func delete(_ item: LibraryItem) {
        if desktop.appliedPackID == item.id { stopDesktop() }
        try? FileManager.default.trashItem(at: item.folder, resultingItemURL: nil)
        EventLog.shared.log("library: moved \(item.pack.name) to the Trash")
        loadLibrary()
    }

    // MARK: Editing (autosaved)

    /// Changes the selected placement. Values are repaired by the shared rules; the pack is saved shortly after.
    func editPlacement(_ change: (inout Placement) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == selectedID }),
              var p = items[index].pack.placements[placement] else { return }
        change(&p)
        try? p.preset.sanitize()
        items[index].pack.placements[placement] = p
        changed(index)
    }

    func editPack(_ change: (inout AnimationPack) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&items[index].pack)
        changed(index)
    }

    /// Copies the current placement's framing and playback to the other placements.
    func copyPlacementToAll() {
        guard let source = selectedPlacement else { return }
        editPack { pack in
            for id in pack.placements.keys where id != source.id {
                var p = pack.placements[id]!
                let keep = (p.preset.id, p.preset.name)
                p.preset = source.preset
                (p.preset.id, p.preset.name) = keep
                pack.placements[id] = p
            }
        }
    }

    private func changed(_ index: Int) {
        let item = items[index]
        if desktop.appliedPackID == item.id { desktop.update(pack: item.pack, folder: item.folder) }
        saveTasks[item.id]?.cancel()
        saveTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save(item.id)
        }
    }

    func save(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            try item.pack.writeManifest(to: item.folder)
        } catch {
            banner = Banner(text: "Could not save \(item.pack.name): \(error.localizedDescription)", isError: true)
        }
    }

    /// Takes the poster frame at `seconds` for the whole pack (every placement that uses the pack poster).
    func setPoster(at seconds: Double) {
        guard let item = selected, let posterName = item.pack.files.first(where: { $0.role == "poster" })?.file else { return }
        busy = "Saving the poster frame…"
        Task {
            defer { busy = nil }
            do {
                let tmp = item.folder.appendingPathComponent(".poster-\(UUID().uuidString).jpg")
                try await MediaImporter.writeStill(of: item.mediaURL, at: seconds, to: tmp)
                _ = try FileManager.default.replaceItemAt(item.folder.appendingPathComponent(posterName), withItemAt: tmp)
                editPack { pack in
                    try? pack.registerFile(posterName, role: "poster", in: item.folder)
                    for id in pack.placements.keys where pack.placements[id]!.preset.stillFile == posterName {
                        pack.placements[id]!.preset.stillTime = seconds
                        try? pack.placements[id]!.preset.sanitize()
                    }
                }
                save(item.id)
                objectWillChange.send()
                banner = Banner(text: "Poster frame set to \(formatSeconds(seconds)).", isError: false)
            } catch {
                banner = Banner(text: error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Desktop

    func applySelectedToDesktop() {
        guard let item = selected else { return }
        save(item.id)
        do {
            try item.pack.verify(in: item.folder)
        } catch {
            banner = Banner(text: "\(item.pack.name) cannot be applied: \(error.localizedDescription)", isError: true)
            return
        }
        desktop.apply(pack: item.pack, folder: item.folder)
        Settings.defaults.set(item.id, forKey: Settings.Key.appliedPack)
        banner = Banner(text: "\(item.pack.name) is on your desktop. Control it from the menu bar.", isError: false)
    }

    func stopDesktop() {
        desktop.stop()
        Settings.defaults.removeObject(forKey: Settings.Key.appliedPack)
    }

    func resumeLastAppliedIfWanted() {
        guard resumeOnLaunch, let id = Settings.defaults.string(forKey: Settings.Key.appliedPack),
              let item = items.first(where: { $0.id == id }) else { return }
        guard (try? item.pack.verify(in: item.folder)) != nil else { return }
        desktop.apply(pack: item.pack, folder: item.folder)
        EventLog.shared.log("resumed on launch: \(item.pack.name)")
    }

    // MARK: Export

    func exportPack(_ item: LibraryItem) {
        save(item.id)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \(item.pack.name).hcgpack (media, poster, placements and pack.json)"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            try item.pack.verify(in: item.folder)
            let dest = dir.appendingPathComponent(sanitized(item.pack.name) + ".hcgpack", isDirectory: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for f in item.pack.allFiles {
                try FileManager.default.copyItem(at: item.folder.appendingPathComponent(f.file), to: dest.appendingPathComponent(f.file))
            }
            try item.pack.writeManifest(to: dest)
            try AnimationPack.read(contentsOf: dest).verify(in: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            banner = Banner(text: "Exported \(dest.lastPathComponent) (\(formatBytes(item.pack.totalBytes))).", isError: false)
        } catch {
            banner = Banner(text: "Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    func exportForIOS(_ item: LibraryItem, placement: PlacementID) {
        save(item.id)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Export the \(placement.title) placement as an HCG background preset (.hcgbackground) for HCG Animation Center on iOS"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let out = try item.pack.exportBackgroundPreset(placement, from: item.folder, to: dir)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            banner = Banner(text: "Exported \(out.lastPathComponent) for iOS.", isError: false)
        } catch {
            banner = Banner(text: "Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func sanitized(_ s: String) -> String {
        String(s.map { "/:\\".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Editor window lifecycle

    enum EditorCloseAction: String { case continueInMenuBar, stopAndQuit }

    /// What closing the editor does: keep the desktop animation running from the menu bar only when that is enabled
    /// and something is playing; otherwise stop (restoring the desktop) and quit.
    nonisolated static func editorCloseAction(keepPlaying: Bool, desktopActive: Bool) -> EditorCloseAction {
        keepPlaying && desktopActive ? .continueInMenuBar : .stopAndQuit
    }

    /// The editor window closed.
    func editorDidClose() {
        editorOpen = false
        for id in saveTasks.keys { save(id) }
        if AppModel.editorCloseAction(keepPlaying: keepPlaying, desktopActive: desktop.status.isActive) == .continueInMenuBar {
            NSApp.setActivationPolicy(.accessory)
            EventLog.shared.log("editor closed: playback continues (menu bar)")
        } else {
            EventLog.shared.log("editor closed: \(desktop.status.isActive ? "stopping playback and " : "")quitting")
            stopDesktopKeepingResume()
            NSApp.terminate(nil)
        }
    }

    func editorDidOpen() {
        editorOpen = true
        NSApp.setActivationPolicy(.regular)
    }

    /// Stops without forgetting what to resume next launch.
    func stopDesktopKeepingResume() { desktop.stop() }
}
