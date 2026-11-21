import Foundation
import XCTest
@testable import HCGAnimationPack

final class JSONAndChecksumTests: XCTestCase {
    func testBooleansAndNumbersStayApart() throws {
        let v = try XCTUnwrap(JSONValue.parse(Data(#"{"a": true, "b": 1, "c": 0, "d": false, "e": 1.5}"#.utf8)))
        XCTAssertEqual(v["a"], .bool(true))
        XCTAssertEqual(v["b"], .number(1))
        XCTAssertEqual(v["c"], .number(0))
        XCTAssertEqual(v["d"], .bool(false))
        XCTAssertEqual(v["e"], .number(1.5))
    }

    func testCanonicalWriterIsDeterministic() throws {
        let v: JSONValue = ["z": 1, "a": ["y": 2.5, "b": "x\"q"], "m": [true, nil, 3840]]
        let text = String(decoding: v.canonicalData(), as: UTF8.self)
        XCTAssertEqual(text, """
        {
          "a": {
            "b": "x\\"q",
            "y": 2.5
          },
          "m": [
            true,
            null,
            3840
          ],
          "z": 1
        }

        """)
        XCTAssertEqual(JSONValue.parse(v.canonicalData()), v)
    }

    func testSHA256Vectors() {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(Checksum.portableSHA256(Data(input.utf8)), expected)
            XCTAssertEqual(Checksum.sha256(Data(input.utf8)), expected)
        }
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(Checksum.portableSHA256(million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        var random = Data(count: 200_003)
        for i in 0..<random.count { random[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 7) }
        XCTAssertEqual(Checksum.portableSHA256(random), Checksum.sha256(random))
    }
}

final class BackgroundPresetTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    func testReadsTheIOSProjectsAuroraExample() throws {
        let p = try BackgroundPreset.read(jsonData: fixture("Aurora-preset.json"))
        XCTAssertEqual(p.id, "6F0B2C1E-4A55-4C8B-9E1D-2B7F1A3C9D40")
        XCTAssertEqual(p.name, "Aurora")
        XCTAssertEqual(p.mediaFile, "media.mov")
        XCTAssertEqual(p.mediaWidth, 1080)
        XCTAssertEqual(p.mediaHeight, 1920)
        XCTAssertEqual(p.duration, 12)
        XCTAssertEqual(p.stillFile, "still.jpg")
        XCTAssertEqual(p.stillTime, 1.5)
        XCTAssertEqual(p.trimStart, 1.5)
        XCTAssertEqual(p.trimEnd, 9.5)
        XCTAssertTrue(p.loops)
        XCTAssertEqual(p.speed, 0.75)
        XCTAssertEqual(p.scaling, .crop)
        XCTAssertEqual(p.crop, NormalizedRect(x: 0.1, y: 0.05, width: 0.8, height: 0.8))
        XCTAssertEqual(p.backgroundColor, "#000000")
        XCTAssertEqual(p.warnings, [])
        XCTAssertEqual(p.clipDuration, 8, accuracy: 1e-9)
        XCTAssertEqual(p.generator?["kind"], "import")
    }

    func testRoundTripKeepsEveryValue() throws {
        let p = try BackgroundPreset.read(jsonData: fixture("Aurora-preset.json"))
        let again = try BackgroundPreset.read(jsonData: p.jsonData())
        XCTAssertEqual(p, again)
        XCTAssertEqual(p.jsonData(), again.jsonData())
        // The written document has exactly the keys HCGBackgroundKit writes.
        let d = try XCTUnwrap(JSONValue.parse(p.jsonData())?.objectValue)
        XCTAssertEqual(Set(d.keys), ["format", "formatVersion", "id", "name", "created", "media", "still", "playback", "layout", "generator"])
        XCTAssertEqual(d["playback"]?["muted"], .bool(true))
    }

    func base() -> [String: JSONValue] {
        ["format": "com.hakmicapitalgroup.background-preset", "formatVersion": 1,
         "media": ["file": "m.mp4", "width": 1920, "height": 1080, "duration": 10]]
    }

    func testRefusesWhatCannotBeUsed() {
        func code(_ d: [String: JSONValue]) -> PackError.Code? {
            do { _ = try BackgroundPreset.read(dictionary: d); return nil } catch let e as PackError { return e.code } catch { return nil }
        }
        var d = base(); d["format"] = "something.else"
        XCTAssertEqual(code(d), .notAPreset)
        d = base(); d["formatVersion"] = 2
        XCTAssertEqual(code(d), .unsupportedVersion)
        d = base(); d["formatVersion"] = 1.5
        XCTAssertEqual(code(d), .unsupportedVersion)
        for bad in ["../m.mp4", "a/b.mp4", ".hidden", "c:d", "a\\b", "x\u{1}y", ""] {
            d = base(); d["media"] = ["file": .string(bad), "width": 1920, "height": 1080, "duration": 10]
            XCTAssertEqual(code(d), bad.isEmpty ? .unsafeFileName : .unsafeFileName, bad)
        }
        d = base(); d["media"] = ["file": "m.mp4", "width": 1920, "height": 1080, "duration": 0]
        XCTAssertEqual(code(d), .invalidValue)
        d = base(); d["media"] = ["file": "m.mp4", "width": 9000, "height": 1080, "duration": 5]
        XCTAssertEqual(code(d), .invalidValue)
        d = base(); d["media"] = ["file": "m.mp4", "width": 1920, "height": 1080, "duration": 0.3]
        XCTAssertEqual(code(d), .invalidValue)
        d = base(); d["media"] = ["file": "m.mp4", "width": 1920, "height": 1080]
        XCTAssertEqual(code(d), .missingValue)
        d = base(); d["id"] = "not-a-uuid"
        XCTAssertEqual(code(d), .invalidValue)
        d = base(); d["media"] = ["kind": "image", "file": "m.png", "width": 1920, "height": 1080, "duration": 10]
        XCTAssertEqual(code(d), .invalidValue)
    }

    func testRepairsAndWarns() throws {
        var d = base()
        d["playback"] = ["trimStart": 9.9, "trimEnd": 50, "speed": 7, "loop": 1, "muted": false]
        d["still"] = ["file": "s.jpg", "time": 99]
        d["layout"] = ["scaling": "stretch", "crop": ["x": 0.95, "y": -1, "width": 0.01, "height": 2], "backgroundColor": "red"]
        let p = try BackgroundPreset.read(dictionary: d)
        XCTAssertEqual(p.trimStart, 9.5)
        XCTAssertEqual(p.trimEnd, 10)
        XCTAssertEqual(p.speed, 2)
        XCTAssertTrue(p.loops, "a number is not a boolean: the default (loop) applies")
        XCTAssertEqual(p.stillTime, 10)
        XCTAssertEqual(p.scaling, .fill)
        XCTAssertEqual(p.crop, NormalizedRect(x: 0.9, y: 0, width: 0.1, height: 1))
        XCTAssertEqual(p.backgroundColor, "#000000")
        XCTAssertTrue(p.warnings.contains("Sound is not supported: the background plays muted."))
        XCTAssertTrue(p.warnings.contains("Unknown scaling \"stretch\": using fill."))
        XCTAssertTrue(p.warnings.contains("The trim range was adjusted to fit the clip."))
        XCTAssertTrue(p.warnings.contains("The speed was limited to 0.25×–2×."))
        XCTAssertTrue(p.warnings.contains("The still was moved inside the trimmed clip."))
        XCTAssertTrue(p.warnings.contains("The crop was adjusted to fit the frame."))
        XCTAssertTrue(p.warnings.contains("backgroundColor must be #RRGGBB: using black."))
    }

    func testTrimEndZeroMeansToTheEnd() throws {
        var d = base()
        d["playback"] = ["trimStart": 2, "trimEnd": 0]
        let p = try BackgroundPreset.read(dictionary: d)
        XCTAssertEqual(p.trimEnd, 10)
        XCTAssertFalse(p.warnings.contains("The trim range was adjusted to fit the clip."))
    }

    func testIgnoresUnknownKeys() throws {
        var d = base()
        d["futureThing"] = ["x": 1]
        d["layout"] = ["scaling": "fit", "newKey": true]
        XCTAssertEqual(try BackgroundPreset.read(dictionary: d).scaling, .fit)
    }

    func testLayoutMatchesTheCCore() {
        let fill = Layout.frame(container: (100, 100), media: (200, 100), scaling: .fill, crop: .whole)
        XCTAssertEqual(fill, NormalizedRect(x: -50, y: 0, width: 200, height: 100))
        let fit = Layout.frame(container: (100, 100), media: (200, 100), scaling: .fit, crop: .whole)
        XCTAssertEqual(fit, NormalizedRect(x: 0, y: 25, width: 100, height: 50))
        // crop the left half: the left half fills the square
        let crop = Layout.frame(container: (100, 100), media: (200, 100), scaling: .crop,
                                crop: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(crop, NormalizedRect(x: 0, y: 0, width: 200, height: 100))
        let c = Layout.crop(container: (1179, 2556), media: (3840, 2160), zoom: 1, centerX: 0.5, centerY: 0.5)
        XCTAssertEqual(c.height, 1, accuracy: 1e-9)
        XCTAssertEqual(c.x + c.width / 2, 0.5, accuracy: 1e-9)
        XCTAssertEqual(Layout.zoom(container: (1179, 2556), media: (3840, 2160), crop: c), 1, accuracy: 1e-9)
    }
}

final class RenderPolicyTests: XCTestCase {
    func testDecisions() {
        func m(_ rm: MotionPolicy, _ lp: PowerPolicy, _ c: SystemConditions) -> RenderMode {
            RenderPolicy.mode(reduceMotionPolicy: rm, lowPowerPolicy: lp, conditions: c)
        }
        XCTAssertEqual(m(.still, .still, .init()), .play)
        XCTAssertEqual(m(.still, .still, .init(reduceMotion: true)), .still(reason: "Reduce Motion"))
        XCTAssertEqual(m(.play, .still, .init(reduceMotion: true)), .play)
        XCTAssertEqual(m(.play, .still, .init(lowPower: true)), .still(reason: "Low Power Mode"))
        XCTAssertEqual(m(.play, .play, .init(lowPower: true)), .play)
        XCTAssertEqual(m(.play, .system, .init(lowPower: true)), .none(reason: "Low Power Mode: showing the normal background"))
        XCTAssertEqual(m(.play, .play, .init(thermalPressure: true)), .still(reason: "The Mac is hot"))
        XCTAssertEqual(m(.play, .play, .init(forceStill: true)), .still(reason: "Still frame selected"))
    }
}
