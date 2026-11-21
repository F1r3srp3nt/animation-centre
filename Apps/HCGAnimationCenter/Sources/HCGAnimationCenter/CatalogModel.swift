//
//  CatalogModel.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  The online catalog screen's state. Until you choose a host, the catalog URL points at the local catalog shipped in
//  the app (Samples/catalog.local.json beside the supplied pack). Set it to your https URL in the catalog screen.
//

import AppKit
import Foundation
import HCGAnimationPack

@MainActor
final class CatalogModel: ObservableObject {
    let store: CatalogStore
    weak var library: AppModel?

    @Published var catalogURLString: String {
        didSet { Settings.defaults.set(catalogURLString, forKey: Settings.Key.catalogURL) }
    }
    @Published private(set) var snapshot: CatalogStore.Snapshot?
    @Published private(set) var refreshError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var posters: [String: NSImage] = [:]
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var itemErrors: [String: String] = [:]
    @Published private(set) var cachedIDs: Set<String> = []

    init(root: URL, transport: CatalogTransport = URLSessionTransport()) {
        store = CatalogStore(root: root, transport: transport)
        catalogURLString = Settings.defaults.string(forKey: Settings.Key.catalogURL)
            ?? BundledResources.localCatalog?.absoluteString ?? ""
        snapshot = store.snapshot
        updateCached()
    }

    var catalogURL: URL? {
        let s = catalogURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        return URL(string: s)
    }

    var isUsingLocalCatalog: Bool { catalogURL?.isFileURL == true }

    func useBundledCatalog() {
        catalogURLString = BundledResources.localCatalog?.absoluteString ?? ""
    }

    func refresh() async {
        guard let url = catalogURL else { refreshError = "Enter the catalog's HTTPS URL."; return }
        refreshing = true
        defer { refreshing = false }
        switch await store.refresh(from: url) {
        case .updated(let snap):
            snapshot = snap
            refreshError = nil
            EventLog.shared.log("catalog: loaded \(snap.catalog.items.count) item(s) from \(url.absoluteString)")
        case .failed(let error, let kept):
            snapshot = kept
            refreshError = error
            EventLog.shared.log("catalog: refresh failed (\(error)); keeping \(kept == nil ? "nothing" : "the previous catalog")")
        }
        updateCached()
        await loadPosters()
    }

    private func updateCached() {
        cachedIDs = Set((snapshot?.catalog.items ?? []).filter { store.cachedPack(for: $0) != nil }.map(\.id))
    }

    func loadPosters() async {
        guard let snap = snapshot else { return }
        for item in snap.catalog.items where posters[item.id] == nil {
            if let data = try? await store.posterData(for: item, catalogURL: snap.sourceURL), let image = NSImage(data: data) {
                posters[item.id] = image
            }
        }
    }

    func isCached(_ item: CatalogItem) -> Bool { cachedIDs.contains(item.id) }

    func download(_ item: CatalogItem) async {
        guard let snap = snapshot else { return }
        itemErrors[item.id] = nil
        progress[item.id] = 0
        defer { progress[item.id] = nil }
        do {
            let id = item.id
            let folder = try await store.download(item, catalogURL: snap.sourceURL) { done, total in
                Task { @MainActor [weak self] in self?.progress[id] = total > 0 ? Double(done) / Double(total) : 1 }
            }
            EventLog.shared.log("catalog: downloaded and verified \(item.name) → \(folder.lastPathComponent)")
            updateCached()
        } catch {
            itemErrors[item.id] = error.localizedDescription
            EventLog.shared.log("catalog: download of \(item.name) failed: \(error.localizedDescription)")
        }
    }

    /// Adds the verified offline copy to the library (and optionally applies it).
    func addToLibrary(_ item: CatalogItem, apply: Bool) {
        guard let folder = store.cachedPack(for: item) ?? store.anyCachedPack(id: item.id), let library else { return }
        do {
            try library.addPackFolder(folder)
            if apply { library.applySelectedToDesktop() }
        } catch {
            itemErrors[item.id] = error.localizedDescription
        }
    }
}
