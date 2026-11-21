import Foundation
import XCTest
@testable import HCGAnimationPack

func temporaryFolder(_ name: String = UUID().uuidString) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-tests-\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A pack folder with stand-in bytes for the media and poster (the format does not decode media).
func makePack(name: String = "Orbital Test") throws -> (AnimationPack, URL) {
    let folder = temporaryFolder().appendingPathComponent("Test.hcgpack", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 4096).write(to: folder.appendingPathComponent("media.mp4"))
    try Data(repeating: 9, count: 512).write(to: folder.appendingPathComponent("poster.jpg"))
    let pack = try AnimationPack.assemble(in: folder, name: name, mediaFile: "media.mp4", width: 3840, height: 2160,
                                          duration: 12, codec: "avc1", posterFile: "poster.jpg", posterTime: 2,
                                          generator: ["app": "tests"])
    try pack.writeManifest(to: folder)
    return (pack, folder)
}

final class AnimationPackTests: XCTestCase {
    func testAssembleWriteReadVerify() throws {
        let (pack, folder) = try makePack()
        XCTAssertEqual(Set(pack.placements.keys), Set(PlacementID.allCases))
        XCTAssertEqual(pack.media.bytes, 4096)
        XCTAssertEqual(pack.totalBytes, 4096 + 512)
        let read = try AnimationPack.read(contentsOf: folder)
        XCTAssertEqual(read, pack)
        XCTAssertEqual(read.warnings, [])
        try read.verify(in: folder)
        // One source clip; independent layout per placement.
        XCTAssertEqual(read.placement(.desktop)?.preset.scaling, .fill)
        XCTAssertEqual(read.placement(.appBackground)?.preset.scaling, .crop)
        XCTAssertEqual(read.placement(.banner)?.preset.scaling, .crop)
        XCTAssertEqual(read.placement(.loadingScreen)?.preset.scaling, .fit)
        XCTAssertNotEqual(read.placement(.appBackground)?.preset.crop, read.placement(.banner)?.preset.crop)
        for p in read.orderedPlacements {
            XCTAssertEqual(p.preset.mediaFile, "media.mp4")
            XCTAssertTrue(p.preset.muted)
            XCTAssertEqual(p.preset.stillFile, "poster.jpg")
            XCTAssertEqual(p.preset.stillTime, 2)
        }
    }

    func testPackFolderIsAlsoABackgroundPresetFolderForIOS() throws {
        let (pack, folder) = try makePack()
        // HCGBackgroundKit reads <folder>/preset.json: the default placement, with the media checksum.
        let preset = try BackgroundPreset.read(contentsOf: folder)
        XCTAssertEqual(preset.mediaSHA256, pack.media.sha256)
        XCTAssertEqual(preset.scaling, pack.placement(.desktop)?.preset.scaling)
        XCTAssertEqual(preset.id, pack.placement(.desktop)?.preset.id)
    }

    func testIndependentSettingsSurviveARoundTrip() throws {
        var (pack, folder) = try makePack()
        pack.placements[.banner]!.preset.trimStart = 3
        pack.placements[.banner]!.preset.trimEnd = 6
        pack.placements[.banner]!.preset.speed = 0.5
        pack.placements[.banner]!.reduceMotion = .play
        pack.placements[.loadingScreen]!.preset.loops = false
        pack.placements[.desktop]!.lowPower = .system
        pack.defaultPlacement = .appBackground
        try pack.writeManifest(to: folder)
        let read = try AnimationPack.read(contentsOf: folder)
        XCTAssertEqual(read.placement(.banner)?.preset.trimStart, 3)
        XCTAssertEqual(read.placement(.banner)?.preset.speed, 0.5)
        XCTAssertEqual(read.placement(.banner)?.reduceMotion, .play)
        XCTAssertEqual(read.placement(.loadingScreen)?.preset.loops, false)
        XCTAssertEqual(read.placement(.desktop)?.lowPower, .system)
        XCTAssertEqual(read.placement(.desktop)?.preset.trimStart, 0)
        XCTAssertEqual(read.defaultPlacement, .appBackground)
        XCTAssertEqual(try BackgroundPreset.read(contentsOf: folder).id, read.placement(.appBackground)?.preset.id)
    }

    func testVerifyDetectsDamage() throws {
        let (pack, folder) = try makePack()
        var bytes = try Data(contentsOf: folder.appendingPathComponent("media.mp4"))
        bytes[100] ^= 0xFF
        try bytes.write(to: folder.appendingPathComponent("media.mp4"))
        XCTAssertThrowsError(try pack.verify(in: folder)) { XCTAssertEqual(($0 as? PackError)?.code, .checksumMismatch) }
        try Data(repeating: 1, count: 3).write(to: folder.appendingPathComponent("poster.jpg"))
        try Data(repeating: 7, count: 4096).write(to: folder.appendingPathComponent("media.mp4"))
        XCTAssertThrowsError(try pack.verify(in: folder)) { XCTAssertEqual(($0 as? PackError)?.code, .sizeMismatch) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("poster.jpg"))
        XCTAssertThrowsError(try pack.verify(in: folder)) { XCTAssertEqual(($0 as? PackError)?.code, .missingValue) }
    }

    func manifest(_ edit: (inout [String: JSONValue]) -> Void) throws -> PackError.Code? {
        let (pack, _) = try makePack()
        var d = pack.dictionary().objectValue!
        edit(&d)
        do { _ = try AnimationPack.read(dictionary: d); return nil } catch let e as PackError { return e.code }
    }

    func testRefusals() throws {
        XCTAssertEqual(try manifest { $0["formatVersion"] = 2 }, .unsupportedVersion)
        XCTAssertEqual(try manifest { $0["format"] = "com.hakmicapitalgroup.background-preset" }, .notAPreset)
        XCTAssertEqual(try manifest { $0["placements"] = [:] }, .missingValue)
        XCTAssertEqual(try manifest {
            var m = $0["media"]!.objectValue!; m["file"] = "../escape.mp4"; $0["media"] = .object(m)
        }, .unsafeFileName)
        XCTAssertEqual(try manifest {
            var m = $0["media"]!.objectValue!; m["file"] = "pack.json"; $0["media"] = .object(m)
        }, .unsafeFileName)
        XCTAssertEqual(try manifest {
            var m = $0["media"]!.objectValue!; m["sha256"] = "abc"; $0["media"] = .object(m)
        }, .missingValue)
        // A placement may not point at a second clip.
        XCTAssertEqual(try manifest {
            var pl = $0["placements"]!.objectValue!
            var banner = pl["banner"]!.objectValue!
            var preset = banner["preset"]!.objectValue!
            var media = preset["media"]!.objectValue!
            media["file"] = "other.mp4"; media.removeValue(forKey: "sha256")
            preset["media"] = .object(media); banner["preset"] = .object(preset); pl["banner"] = .object(banner)
            $0["placements"] = .object(pl)
        }, .invalidValue)
        // A still must be one of the listed files.
        XCTAssertEqual(try manifest { $0["files"] = [] }, .missingValue)
    }

    func testForwardCompatibility() throws {
        let (pack, _) = try makePack()
        var d = pack.dictionary().objectValue!
        var pl = d["placements"]!.objectValue!
        pl["watch-face"] = pl["banner"]
        d["placements"] = .object(pl)
        d["somethingNew"] = ["x": 1]
        d["defaultPlacement"] = "watch-face"
        let read = try AnimationPack.read(dictionary: d)
        XCTAssertEqual(read.placements.count, 4)
        XCTAssertTrue(read.warnings.contains { $0.contains("watch-face") && $0.contains("ignored") })
        XCTAssertEqual(read.defaultPlacement, .desktop, "falls back to the first placement in canonical order")
    }

    func testExportBackgroundPresetForIOS() throws {
        let (pack, folder) = try makePack()
        let out = try pack.exportBackgroundPreset(.appBackground, from: folder, to: temporaryFolder())
        XCTAssertEqual(out.pathExtension, "hcgbackground")
        let preset = try BackgroundPreset.read(contentsOf: out)
        XCTAssertEqual(preset.scaling, .crop)
        XCTAssertEqual(preset.mediaSHA256, pack.media.sha256)
        XCTAssertEqual(try Checksum.sha256(of: out.appendingPathComponent("media.mp4")).hex, pack.media.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("poster.jpg").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["media.mp4", "poster.jpg", "preset.json"])
    }

    func testOwnStillPerPlacementAndPrune() throws {
        var (pack, folder) = try makePack()
        try Data(repeating: 3, count: 64).write(to: folder.appendingPathComponent("still-banner.jpg"))
        try pack.registerFile("still-banner.jpg", role: "still", in: folder)
        pack.placements[.banner]!.preset.stillFile = "still-banner.jpg"
        try pack.writeManifest(to: folder)
        let read = try AnimationPack.read(contentsOf: folder)
        try read.verify(in: folder)
        XCTAssertEqual(read.placement(.banner)?.preset.stillFile, "still-banner.jpg")
        var p2 = read
        p2.placements[.banner]!.preset.stillFile = "poster.jpg"
        XCTAssertEqual(p2.pruneUnusedFiles(), ["still-banner.jpg"])
        XCTAssertEqual(p2.files.map(\.file), ["poster.jpg"])
    }
}
