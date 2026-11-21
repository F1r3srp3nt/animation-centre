import Foundation
import XCTest
@testable import HCGAnimationPack

/// Serves files from memory; counts requests; can be told to fail.
final class MockTransport: CatalogTransport, @unchecked Sendable {
    var files: [String: Data] = [:]
    var failAll = false
    var requests: [String] = []
    let lock = NSLock()

    func data(from url: URL) async throws -> Data { try serve(url) }

    private func serve(_ url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        requests.append(url.absoluteString)
        if failAll { throw PackError(.network, "offline") }
        guard let d = files[url.absoluteString] else { throw PackError(.network, "404 \(url.absoluteString)") }
        return d
    }

    func download(from url: URL) async throws -> URL {
        let d = try await data(from: url)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mock-\(UUID().uuidString)")
        try d.write(to: tmp)
        return tmp
    }
}

final class CatalogTests: XCTestCase {
    let catalogURL = URL(string: "https://cdn.example.com/hcg/catalog.json")!

    func hostedCatalog(baseURL: String) throws -> (Catalog, MockTransport, AnimationPack) {
        let (pack, folder) = try makePack(name: "HCG Orbital Command")
        let item = try Catalog.item(for: pack, packFolder: folder, baseURL: baseURL, summary: "Test")
        let catalog = Catalog(title: "HCG", updated: Date(timeIntervalSince1970: 1_800_000_000), items: [item])
        let t = MockTransport()
        t.files[catalogURL.absoluteString] = catalog.dictionary().canonicalData()
        for f in item.files {
            let url = try CatalogURLs.fileURL(item: item, file: f.file, catalogURL: catalogURL)
            t.files[url.absoluteString] = try Data(contentsOf: folder.appendingPathComponent(f.file))
        }
        return (catalog, t, pack)
    }

    func testParseAndRoundTrip() throws {
        let (catalog, _, pack) = try hostedCatalog(baseURL: "https://cdn.example.com/hcg/OrbitalCommand.hcgpack/")
        let read = try Catalog.read(jsonData: catalog.dictionary().canonicalData())
        XCTAssertEqual(read, catalog)
        let item = try XCTUnwrap(read.items.first)
        XCTAssertEqual(item.id, pack.id)
        XCTAssertEqual(item.poster, "poster.jpg")
        XCTAssertEqual(item.totalBytes, pack.totalBytes + item.file("pack.json")!.bytes)
        XCTAssertEqual(item.files.map(\.file), ["pack.json", "media.mp4", "poster.jpg"])
    }

    func testURLRules() throws {
        let (catalog, _, _) = try hostedCatalog(baseURL: "packs/Orbital Command.hcgpack/")
        let item = catalog.items[0]
        XCTAssertEqual(try CatalogURLs.fileURL(item: item, file: "media.mp4", catalogURL: catalogURL).absoluteString,
                       "https://cdn.example.com/hcg/packs/Orbital%20Command.hcgpack/media.mp4")
        var http = item; http.baseURL = "http://cdn.example.com/x/"
        XCTAssertThrowsError(try CatalogURLs.fileURL(item: http, file: "media.mp4", catalogURL: catalogURL)) {
            XCTAssertEqual(($0 as? PackError)?.code, .insecureURL)
        }
        var local = item; local.baseURL = "file:///tmp/x/"
        XCTAssertThrowsError(try CatalogURLs.fileURL(item: local, file: "media.mp4", catalogURL: catalogURL),
                             "an https catalog may not point at local files")
        XCTAssertNoThrow(try CatalogURLs.fileURL(item: item, file: "media.mp4", catalogURL: URL(fileURLWithPath: "/tmp/c/catalog.json")))
        var unhosted = item; unhosted.baseURL = ""
        XCTAssertThrowsError(try CatalogURLs.fileURL(item: unhosted, file: "media.mp4", catalogURL: catalogURL)) {
            XCTAssertTrue(($0 as? PackError)?.message.contains("not hosted yet") == true)
        }
        XCTAssertThrowsError(try CatalogURLs.checkCatalogURL(URL(string: "http://example.com/c.json")!))
        XCTAssertThrowsError(try CatalogURLs.checkCatalogURL(URL(string: "https://u:p@example.com/c.json")!))
    }

    func testSkipsBadItemsAndRefusesNewerFormats() throws {
        let doc: JSONValue = ["format": "com.hakmicapitalgroup.animation-catalog", "formatVersion": 1,
                              "items": [["id": "nope", "name": "Bad"], ["id": "6F0B2C1E-4A55-4C8B-9E1D-2B7F1A3C9D40", "name": "No files"]]]
        let c = try Catalog.read(jsonData: doc.canonicalData())
        XCTAssertEqual(c.items.count, 0)
        XCTAssertEqual(c.warnings.count, 2)
        let newer: JSONValue = ["format": "com.hakmicapitalgroup.animation-catalog", "formatVersion": 2, "items": []]
        XCTAssertThrowsError(try Catalog.read(jsonData: newer.canonicalData()))
    }

    func testVerifiedDownloadAndOfflineCache() async throws {
        let (catalog, transport, pack) = try hostedCatalog(baseURL: "OrbitalCommand.hcgpack/")
        let store = CatalogStore(root: temporaryFolder(), transport: transport)
        guard case .updated = await store.refresh(from: catalogURL) else { return XCTFail("refresh") }
        let item = catalog.items[0]
        XCTAssertNil(store.cachedPack(for: item))
        let folder = try await store.download(item, catalogURL: catalogURL)
        XCTAssertEqual(store.cachedPack(for: item), folder)
        let read = try AnimationPack.read(contentsOf: folder)
        XCTAssertEqual(read.id, pack.id)
        try read.verify(in: folder)
        // Offline: no more requests needed for the pack or the poster.
        transport.failAll = true
        let again = try await store.download(item, catalogURL: catalogURL)
        XCTAssertEqual(again, folder)
        let poster = try await store.posterData(for: item, catalogURL: catalogURL)
        XCTAssertEqual(poster.count, 512)
    }

    func testTamperedDownloadIsRejectedAndNothingIsCached() async throws {
        let (catalog, transport, _) = try hostedCatalog(baseURL: "OrbitalCommand.hcgpack/")
        let item = catalog.items[0]
        let mediaURL = try CatalogURLs.fileURL(item: item, file: "media.mp4", catalogURL: catalogURL).absoluteString
        var bad = transport.files[mediaURL]!
        bad[0] ^= 1
        transport.files[mediaURL] = bad
        let store = CatalogStore(root: temporaryFolder(), transport: transport)
        do {
            _ = try await store.download(item, catalogURL: catalogURL)
            XCTFail("expected a checksum error")
        } catch let e as PackError {
            XCTAssertEqual(e.code, .checksumMismatch)
        }
        XCTAssertNil(store.cachedPack(for: item))
        XCTAssertNil(store.anyCachedPack(id: item.id))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix("Staging") }
        XCTAssertEqual(leftovers, [])
    }

    func testFailedRefreshKeepsThePreviousCatalog() async throws {
        let (catalog, transport, _) = try hostedCatalog(baseURL: "OrbitalCommand.hcgpack/")
        let root = temporaryFolder()
        let store = CatalogStore(root: root, transport: transport)
        guard case .updated(let first) = await store.refresh(from: catalogURL) else { return XCTFail("refresh") }
        XCTAssertEqual(first.catalog, catalog)

        transport.failAll = true
        guard case .failed(let error, let kept) = await store.refresh(from: catalogURL) else { return XCTFail("expected failure") }
        XCTAssertEqual(error, "offline")
        XCTAssertEqual(kept?.catalog, catalog)
        XCTAssertEqual(store.snapshot?.catalog, catalog)

        transport.failAll = false
        transport.files[catalogURL.absoluteString] = Data("{ not json".utf8)
        guard case .failed(_, let kept2) = await store.refresh(from: catalogURL) else { return XCTFail("expected failure") }
        XCTAssertEqual(kept2?.catalog, catalog)

        // Survives a restart.
        let reopened = CatalogStore(root: root, transport: transport)
        XCTAssertEqual(reopened.snapshot?.catalog, catalog)
        XCTAssertEqual(reopened.snapshot?.sourceURL, catalogURL)
    }
}
