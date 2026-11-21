//
//  Catalog.swift
//  HCGAnimationPack — Hakmi Capital Group
//
//  The online catalog, format "com.hakmicapitalgroup.animation-catalog", version 1 (docs/CATALOG.md,
//  schema/hcg-animation-catalog-v1.schema.json). A JSON document served over HTTPS listing animation packs; each item
//  names the folder its files are hosted in (`baseURL`) and every file's size and SHA-256. Downloads are verified file
//  by file and as a pack before they replace anything, and are kept for offline use. A failed refresh never discards
//  the last catalog that loaded.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CatalogItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String?
    /// As written in the document: "" (not hosted yet), a relative path (resolved against the catalog URL) or an
    /// absolute https URL of the folder holding the files. Must end with "/".
    public var baseURL: String
    public var poster: String?
    public var files: [PackFile]
    public var width: Double?
    public var height: Double?
    public var duration: Double?
    public var packFormatVersion: Int

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var isHosted: Bool { !baseURL.trimmingCharacters(in: .whitespaces).isEmpty }
    public func file(_ name: String) -> PackFile? { files.first { $0.file == name } }
}

public struct Catalog: Equatable, Sendable {
    public static let format = "com.hakmicapitalgroup.animation-catalog"
    public static let formatVersion = 1
    public static let maxDocumentBytes = 1024 * 1024
    /// Largest pack the catalog will download (sum of its files).
    public static let maxItemBytes: Int64 = 4 * 1024 * 1024 * 1024

    public var title: String
    public var updated: Date?
    public var items: [CatalogItem]
    public private(set) var warnings: [String] = []

    public init(title: String, updated: Date?, items: [CatalogItem]) {
        self.title = title; self.updated = updated; self.items = items
    }

    public static func == (a: Catalog, b: Catalog) -> Bool { a.title == b.title && a.updated == b.updated && a.items == b.items }

    public static func read(jsonData data: Data) throws -> Catalog {
        guard data.count <= maxDocumentBytes else { throw PackError(.unreadable, "The catalog is larger than 1 MB.") }
        guard let value = JSONValue.parse(data), case .object(let d) = value else {
            throw PackError(.unreadable, "The catalog is not a JSON object.")
        }
        guard d["format"]?.stringValue == format else {
            throw PackError(.notAPreset, "Not an HCG animation catalog (format must be \(format)).")
        }
        guard let v = d["formatVersion"]?.numberValue, v == v.rounded(), v >= 1 else {
            throw PackError(.unsupportedVersion, "formatVersion must be a whole number.")
        }
        if Int(v) > formatVersion {
            throw PackError(.unsupportedVersion, "This catalog uses format version \(Int(v)); update the app to read it.")
        }
        var warnings: [String] = []
        var items: [CatalogItem] = []
        for (i, raw) in (d["items"]?.arrayValue ?? []).enumerated() {
            do {
                guard let o = raw.objectValue else { throw PackError(.invalidValue, "items[\(i)] must be an object.") }
                items.append(try readItem(o, index: i))
            } catch let e as PackError {
                warnings.append("Item \(i + 1) was skipped: \(e.message)")
            }
        }
        var c = Catalog(title: d["title"]?.stringValue ?? "HCG Animation Catalog",
                        updated: d["updated"]?.stringValue.flatMap(ISO8601.date(from:)), items: items)
        c.warnings = warnings
        return c
    }

    static func readItem(_ o: [String: JSONValue], index i: Int) throws -> CatalogItem {
        guard let id = o["id"]?.stringValue, UUID(uuidString: id) != nil else {
            throw PackError(.invalidValue, "id must be a UUID.")
        }
        guard let name = o["name"]?.stringValue, !name.isEmpty else { throw PackError(.missingValue, "name is missing.") }
        let packVersion = Int(o["packFormatVersion"]?.numberValue ?? 1)
        if packVersion > AnimationPack.formatVersion {
            throw PackError(.unsupportedVersion, "\(name) needs a newer version of the app (pack format \(packVersion)).")
        }
        let baseURL = o["baseURL"]?.stringValue ?? ""
        if !baseURL.isEmpty, !baseURL.hasSuffix("/") {
            throw PackError(.invalidValue, "\(name): baseURL must end with \"/\".")
        }
        var files: [PackFile] = []
        for (j, f) in (o["files"]?.arrayValue ?? []).enumerated() {
            guard let fo = f.objectValue, let file = fo["file"]?.stringValue,
                  BackgroundPreset.isSafeFileName(file) else {
                throw PackError(.unsafeFileName, "\(name): files[\(j)].file must be a plain file name.")
            }
            guard let bytes = fo["bytes"]?.numberValue, bytes >= 0, bytes == bytes.rounded(),
                  let sha = fo["sha256"]?.stringValue, sha.utf16.count == 64, sha.allSatisfy(\.isHexDigit) else {
                throw PackError(.missingValue, "\(name): \(file) needs bytes and a 64-digit sha256.")
            }
            guard !files.contains(where: { $0.file == file }) else {
                throw PackError(.invalidValue, "\(name): \(file) is listed twice.")
            }
            files.append(PackFile(file: file, bytes: Int64(bytes), sha256: sha.lowercased(), role: fo["role"]?.stringValue ?? ""))
        }
        guard files.contains(where: { $0.file == AnimationPack.manifestName }) else {
            throw PackError(.missingValue, "\(name): files must include pack.json.")
        }
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        guard total <= maxItemBytes else { throw PackError(.invalidValue, "\(name) is larger than 4 GB.") }
        let poster = o["poster"]?.stringValue
        if let poster, !files.contains(where: { $0.file == poster }) {
            throw PackError(.missingValue, "\(name): poster \(poster) is not one of its files.")
        }
        let media = o["media"]?.objectValue
        return CatalogItem(id: id.uppercased(), name: truncateUTF16(name, to: 120), summary: o["summary"]?.stringValue,
                           baseURL: baseURL, poster: poster, files: files, width: media?["width"]?.numberValue,
                           height: media?["height"]?.numberValue, duration: media?["duration"]?.numberValue,
                           packFormatVersion: packVersion)
    }

    public func dictionary() -> JSONValue {
        var d: [String: JSONValue] = [
            "format": .string(Catalog.format), "formatVersion": .number(Double(Catalog.formatVersion)),
            "title": .string(title),
            "items": .array(items.map { item in
                var o: [String: JSONValue] = [
                    "id": .string(item.id), "name": .string(item.name), "baseURL": .string(item.baseURL),
                    "packFormatVersion": .number(Double(item.packFormatVersion)),
                    "files": .array(item.files.map {
                        var f: [String: JSONValue] = ["file": .string($0.file), "bytes": .number(Double($0.bytes)),
                                                      "sha256": .string($0.sha256)]
                        if !$0.role.isEmpty { f["role"] = .string($0.role) }
                        return .object(f)
                    }),
                ]
                if let s = item.summary { o["summary"] = .string(s) }
                if let p = item.poster { o["poster"] = .string(p) }
                var m: [String: JSONValue] = [:]
                if let w = item.width { m["width"] = .number(w) }
                if let h = item.height { m["height"] = .number(h) }
                if let du = item.duration { m["duration"] = .number(du) }
                if !m.isEmpty { o["media"] = .object(m) }
                return .object(o)
            }),
        ]
        if let u = updated { d["updated"] = .string(ISO8601.string(from: u)) }
        return .object(d)
    }

    /// Builds the catalog entry for a pack folder (pack.json, media and stills, with checksums).
    public static func item(for pack: AnimationPack, packFolder: URL, baseURL: String, summary: String? = nil) throws -> CatalogItem {
        let manifest = try Checksum.sha256(of: packFolder.appendingPathComponent(AnimationPack.manifestName))
        var files = [PackFile(file: AnimationPack.manifestName, bytes: manifest.bytes, sha256: manifest.hex, role: "manifest")]
        files += pack.allFiles
        let poster = pack.files.first { $0.role == "poster" }?.file
        return CatalogItem(id: pack.id, name: pack.name, summary: summary, baseURL: baseURL, poster: poster, files: files,
                           width: pack.media.width, height: pack.media.height, duration: pack.media.duration,
                           packFormatVersion: AnimationPack.formatVersion)
    }
}

// MARK: - URL rules

public enum CatalogURLs {
    /// A catalog may be read from https (published) or file (local, before hosting). Never plain http.
    public static func checkCatalogURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "file" else {
            throw PackError(.insecureURL, "The catalog must be served over HTTPS (got \(url.scheme ?? "no scheme")).")
        }
        if url.user != nil || url.password != nil {
            throw PackError(.insecureURL, "The catalog URL must not contain a user name or password.")
        }
    }

    /// Where an item's file is fetched from. A relative baseURL resolves against the catalog URL. The result must be
    /// https — or file, but only when the catalog itself is a local file.
    public static func fileURL(item: CatalogItem, file: String, catalogURL: URL) throws -> URL {
        guard item.isHosted else {
            throw PackError(.missingValue, "\(item.name) is not hosted yet: fill in its baseURL in the catalog.")
        }
        guard BackgroundPreset.isSafeFileName(file),
              let base = URL(string: item.baseURL, relativeTo: catalogURL)?.absoluteURL,
              let url = URL(string: file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file,
                            relativeTo: base)?.absoluteURL else {
            throw PackError(.invalidValue, "\(item.name): \(item.baseURL) is not a valid URL.")
        }
        let scheme = url.scheme?.lowercased()
        let catalogIsFile = catalogURL.isFileURL
        guard scheme == "https" || (scheme == "file" && catalogIsFile) else {
            throw PackError(.insecureURL, "\(item.name): files must be served over HTTPS (\(url.absoluteString)).")
        }
        if url.user != nil || url.password != nil {
            throw PackError(.insecureURL, "\(item.name): file URLs must not contain a user name or password.")
        }
        return url
    }
}

// MARK: - Transport

public protocol CatalogTransport: Sendable {
    /// The body of a small document (catalog, poster).
    func data(from url: URL) async throws -> Data
    /// Downloads a file to a temporary location and returns it (the caller moves it).
    func download(from url: URL) async throws -> URL
}

public struct URLSessionTransport: CatalogTransport {
    public init() {}

    public func data(from url: URL) async throws -> Data {
        if url.isFileURL {
            guard let d = try? Data(contentsOf: url) else { throw PackError(.network, "\(url.lastPathComponent) could not be read.") }
            return d
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("HCGAnimationCenter/1", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: PackError(.network, error.localizedDescription)); return }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    cont.resume(throwing: PackError(.network, "The server answered \(http.statusCode) for \(url.lastPathComponent)."))
                    return
                }
                cont.resume(returning: data ?? Data())
            }.resume()
        }
    }

    public func download(from url: URL) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-dl-\(UUID().uuidString)")
        if url.isFileURL {
            do { try FileManager.default.copyItem(at: url, to: tmp) } catch {
                throw PackError(.network, "\(url.lastPathComponent) could not be read.")
            }
            return tmp
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("HCGAnimationCenter/1", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { cont in
            URLSession.shared.downloadTask(with: request) { location, response, error in
                if let error { cont.resume(throwing: PackError(.network, error.localizedDescription)); return }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    cont.resume(throwing: PackError(.network, "The server answered \(http.statusCode) for \(url.lastPathComponent)."))
                    return
                }
                guard let location else { cont.resume(throwing: PackError(.network, "No data for \(url.lastPathComponent).")); return }
                do {
                    try FileManager.default.moveItem(at: location, to: tmp)
                    cont.resume(returning: tmp)
                } catch {
                    cont.resume(throwing: PackError(.network, "The download could not be saved."))
                }
            }.resume()
        }
    }
}

// MARK: - Store (last good catalog + verified offline cache)

public final class CatalogStore: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var catalog: Catalog
        public var sourceURL: URL
        public var loaded: Date
    }

    public enum RefreshOutcome: Equatable, Sendable {
        case updated(Snapshot)
        /// The refresh failed; `kept` is the previous catalog, still shown (nil if there never was one).
        case failed(error: String, kept: Snapshot?)
    }

    public let root: URL
    public let transport: CatalogTransport
    private let lock = NSLock()
    private var _snapshot: Snapshot?

    public init(root: URL, transport: CatalogTransport = URLSessionTransport()) {
        self.root = root
        self.transport = transport
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _snapshot = loadLastGood()
    }

    public var snapshot: Snapshot? { lock.lock(); defer { lock.unlock() }; return _snapshot }

    private func setSnapshot(_ s: Snapshot) { lock.lock(); _snapshot = s; lock.unlock() }

    var lastGoodURL: URL { root.appendingPathComponent("catalog-last-good.json") }
    var packsDirectory: URL { root.appendingPathComponent("Packs", isDirectory: true) }
    var postersDirectory: URL { root.appendingPathComponent("Posters", isDirectory: true) }

    private func loadLastGood() -> Snapshot? {
        guard let data = try? Data(contentsOf: lastGoodURL), let v = JSONValue.parse(data),
              let source = v["source"]?.stringValue.flatMap(URL.init(string:)),
              let loaded = v["loaded"]?.stringValue.flatMap(ISO8601.date(from:)),
              let doc = v["catalog"], let catalog = try? Catalog.read(jsonData: doc.canonicalData()) else { return nil }
        return Snapshot(catalog: catalog, sourceURL: source, loaded: loaded)
    }

    /// Fetches and parses the catalog. On any failure the previous catalog stays in place.
    @discardableResult
    public func refresh(from url: URL) async -> RefreshOutcome {
        do {
            try CatalogURLs.checkCatalogURL(url)
            let data = try await transport.data(from: url)
            let catalog = try Catalog.read(jsonData: data)
            let snap = Snapshot(catalog: catalog, sourceURL: url, loaded: Date())
            let record: JSONValue = ["source": .string(url.absoluteString), "loaded": .string(ISO8601.string(from: snap.loaded)),
                                     "catalog": catalog.dictionary()]
            try? record.canonicalData().write(to: lastGoodURL, options: .atomic)
            setSnapshot(snap)
            return .updated(snap)
        } catch {
            let message = (error as? PackError)?.message ?? error.localizedDescription
            return .failed(error: message, kept: snapshot)
        }
    }

    // MARK: Offline cache

    func packFolder(for item: CatalogItem) -> URL {
        let manifest = item.file(AnimationPack.manifestName)?.sha256.prefix(16) ?? "unknown"
        return packsDirectory.appendingPathComponent("\(item.id)-\(manifest).\(AnimationPack.folderExtension)", isDirectory: true)
    }

    /// The verified offline copy of this exact item version, if it was downloaded.
    public func cachedPack(for item: CatalogItem) -> URL? {
        let folder = packFolder(for: item)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".verified").path),
              (try? AnimationPack.read(contentsOf: folder)) != nil else { return nil }
        return folder
    }

    /// Any verified offline copy of this item (an older version if the catalog moved on).
    public func anyCachedPack(id: String) -> URL? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: packsDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(id + "-") }.sorted().map { packsDirectory.appendingPathComponent($0) }
            .first { fm.fileExists(atPath: $0.appendingPathComponent(".verified").path) }
    }

    /// Downloads every file, checks each size and SHA-256, reads and verifies the pack, then moves it into the cache
    /// in one step. Nothing partial is ever left where `cachedPack` looks.
    public func download(_ item: CatalogItem, catalogURL: URL,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        if let done = cachedPack(for: item) { return done }
        let fm = FileManager.default
        let staging = root.appendingPathComponent("Staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var received: Int64 = 0
        let total = item.totalBytes
        for f in item.files {
            let url = try CatalogURLs.fileURL(item: item, file: f.file, catalogURL: catalogURL)
            let tmp = try await transport.download(from: url)
            defer { try? fm.removeItem(at: tmp) }
            let sum = try Checksum.sha256(of: tmp)
            guard sum.bytes == f.bytes else {
                throw PackError(.sizeMismatch, "\(f.file) is \(sum.bytes) bytes; the catalog says \(f.bytes).")
            }
            guard sum.hex == f.sha256 else {
                throw PackError(.checksumMismatch, "\(f.file) does not match the catalog's checksum.")
            }
            try fm.moveItem(at: tmp, to: staging.appendingPathComponent(f.file))
            received += f.bytes
            progress?(received, total)
        }
        let pack = try AnimationPack.read(contentsOf: staging)
        guard pack.id == item.id else { throw PackError(.invalidValue, "The downloaded pack is not \(item.name).") }
        try pack.verify(in: staging)
        try Data("verified \(ISO8601.string(from: Date()))\n".utf8).write(to: staging.appendingPathComponent(".verified"))
        try fm.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        let destination = packFolder(for: item)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    /// The poster image bytes for an item: from the offline pack if present, else fetched (and checked) once.
    public func posterData(for item: CatalogItem, catalogURL: URL) async throws -> Data {
        guard let poster = item.poster, let f = item.file(poster) else {
            throw PackError(.missingValue, "\(item.name) has no poster.")
        }
        if let pack = cachedPack(for: item) ?? anyCachedPack(id: item.id),
           let d = try? Data(contentsOf: pack.appendingPathComponent(poster)), Checksum.sha256(d) == f.sha256 {
            return d
        }
        let cached = postersDirectory.appendingPathComponent(f.sha256 + "-" + poster)
        if let d = try? Data(contentsOf: cached), Checksum.sha256(d) == f.sha256 { return d }
        let url = try CatalogURLs.fileURL(item: item, file: poster, catalogURL: catalogURL)
        let d = try await transport.data(from: url)
        guard Checksum.sha256(d) == f.sha256 else { throw PackError(.checksumMismatch, "The poster does not match its checksum.") }
        try? FileManager.default.createDirectory(at: postersDirectory, withIntermediateDirectories: true)
        try? d.write(to: cached, options: .atomic)
        return d
    }
}
