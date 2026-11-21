//
//  AnimationPack.swift
//  HCGAnimationPack — Hakmi Capital Group
//
//  The HCG animation pack, format "com.hakmicapitalgroup.animation-pack", version 1 (docs/PACK-FORMAT.md,
//  schema/hcg-animation-pack-v1.schema.json).
//
//  A pack is a folder `<Name>.hcgpack` holding ONE source clip, its poster and stills, and one placement per surface
//  (Desktop, App Background, Banner, Loading Screen). Every placement embeds a complete HCG background preset v1 —
//  the format the iOS project already reads — so a placement travels to iOS as-is, and the pack's default placement
//  is also written as `preset.json`, which makes the pack folder itself readable by HCGBackgroundKit.
//
//  Data only. File names are plain names inside the pack's own folder; every file carries its size and SHA-256.
//

import Foundation

// MARK: - Placements

public enum PlacementID: String, CaseIterable, Sendable, Identifiable, Comparable {
    case desktop
    case appBackground = "app-background"
    case banner
    case loadingScreen = "loading-screen"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .appBackground: return "App Background"
        case .banner: return "Banner"
        case .loadingScreen: return "Loading Screen"
        }
    }

    public static func < (a: PlacementID, b: PlacementID) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// What to show while Reduce Motion is on. Same strings as the iOS tweak's HACKeyReduceMotion.
public enum MotionPolicy: String, CaseIterable, Sendable { case still, play }
/// What to show in Low Power Mode. Same strings as the iOS tweak's HACKeyLowPower ("system" = the normal
/// wallpaper / no background at all).
public enum PowerPolicy: String, CaseIterable, Sendable { case still, play, system }

public struct CanvasSize: Equatable, Sendable {
    public var width: Double, height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct Placement: Equatable, Sendable {
    public var id: PlacementID
    /// The aspect the author previewed this placement at (informational; renderers lay out for the real container).
    public var canvas: CanvasSize?
    public var reduceMotion: MotionPolicy = .still
    public var lowPower: PowerPolicy = .still
    public var preset: BackgroundPreset

    public init(id: PlacementID, canvas: CanvasSize?, reduceMotion: MotionPolicy = .still,
                lowPower: PowerPolicy = .still, preset: BackgroundPreset) {
        self.id = id; self.canvas = canvas; self.reduceMotion = reduceMotion; self.lowPower = lowPower
        self.preset = preset
    }
}

// MARK: - Files

public struct PackFile: Equatable, Sendable {
    public var file: String
    public var bytes: Int64
    public var sha256: String
    /// "media", "poster", "still" (informational)
    public var role: String

    public init(file: String, bytes: Int64, sha256: String, role: String) {
        self.file = file; self.bytes = bytes; self.sha256 = sha256; self.role = role
    }
}

public struct PackMedia: Equatable, Sendable {
    public var file: String
    public var bytes: Int64
    public var sha256: String
    public var width: Double
    public var height: Double
    public var duration: Double
    /// "video" | "gif" | "ai" (informational, as in preset v1)
    public var origin: String
    /// e.g. "avc1", "hvc1" (informational; helps adapters pick a decoder)
    public var codec: String?

    public init(file: String, bytes: Int64, sha256: String, width: Double, height: Double, duration: Double,
                origin: String = "video", codec: String? = nil) {
        self.file = file; self.bytes = bytes; self.sha256 = sha256; self.width = width; self.height = height
        self.duration = duration; self.origin = origin; self.codec = codec
    }

    public var asFile: PackFile { PackFile(file: file, bytes: bytes, sha256: sha256, role: "media") }
}

// MARK: - Pack

public struct AnimationPack: Equatable, Sendable {
    public static let format = "com.hakmicapitalgroup.animation-pack"
    public static let formatVersion = 1
    public static let manifestName = "pack.json"
    public static let folderExtension = "hcgpack"
    public static let maxManifestBytes = 256 * 1024
    static let reservedNames: Set<String> = [manifestName, BackgroundPreset.fileName]

    public var id: String
    public var name: String
    public var created: Date?
    public var generator: JSONValue?
    public var media: PackMedia
    /// Every other file in the pack (poster, stills), with size and checksum.
    public var files: [PackFile]
    public var defaultPlacement: PlacementID
    public var placements: [PlacementID: Placement]
    public private(set) var warnings: [String] = []

    public init(id: String = UUID().uuidString, name: String, created: Date? = Date(), generator: JSONValue? = nil,
                media: PackMedia, files: [PackFile], defaultPlacement: PlacementID,
                placements: [PlacementID: Placement]) {
        self.id = id; self.name = name; self.created = created; self.generator = generator; self.media = media
        self.files = files; self.defaultPlacement = defaultPlacement; self.placements = placements
    }

    public static func == (a: AnimationPack, b: AnimationPack) -> Bool { a.dictionary() == b.dictionary() }

    public var orderedPlacements: [Placement] { placements.values.sorted { $0.id < $1.id } }
    public var totalBytes: Int64 { media.bytes + files.reduce(0) { $0 + $1.bytes } }
    public var allFiles: [PackFile] { [media.asFile] + files }

    public func placement(_ id: PlacementID) -> Placement? { placements[id] }

    // MARK: Reading

    /// Reads `pack.json` from a pack folder (or the file itself). Does not verify media checksums: call `verify(in:)`.
    public static func read(contentsOf url: URL) throws -> AnimationPack {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PackError(.unreadable, "No animation pack at \(url.lastPathComponent).")
        }
        let file = isDirectory.boolValue ? url.appendingPathComponent(manifestName) : url
        return try read(jsonData: readSmallFile(file, limit: maxManifestBytes))
    }

    public static func read(jsonData data: Data) throws -> AnimationPack {
        guard data.count <= maxManifestBytes else { throw PackError(.unreadable, "pack.json is larger than 256 KB.") }
        guard let value = JSONValue.parse(data), case .object(let d) = value else {
            throw PackError(.unreadable, "pack.json is not a JSON object.")
        }
        return try read(dictionary: d)
    }

    public static func read(dictionary d: [String: JSONValue]) throws -> AnimationPack {
        guard d["format"]?.stringValue == format else {
            throw PackError(.notAPreset, "Not an HCG animation pack (format must be \(format)).")
        }
        guard let version = d["formatVersion"]?.numberValue, version == version.rounded(), version >= 1 else {
            throw PackError(.unsupportedVersion, "formatVersion must be a whole number.")
        }
        if Int(version) > formatVersion {
            throw PackError(.unsupportedVersion,
                            "This pack uses format version \(Int(version)); this app reads version \(formatVersion). Update to use it.")
        }
        var warnings: [String] = []

        var identifier = UUID().uuidString
        if let s = d["id"]?.stringValue, !s.isEmpty {
            guard UUID(uuidString: s) != nil else { throw PackError(.invalidValue, "id must be a UUID.") }
            identifier = s.uppercased()
        }
        let name = truncateUTF16(d["name"]?.stringValue ?? "Animation", to: 120)
        let created = d["created"]?.stringValue.flatMap(ISO8601.date(from:))

        guard let m = d["media"]?.objectValue else { throw PackError(.missingValue, "media is missing.") }
        let mediaFile = try readFile(m, where: "media", role: "media")
        guard let w = m["width"]?.numberValue, let h = m["height"]?.numberValue, let dur = m["duration"]?.numberValue else {
            throw PackError(.missingValue, "media needs width, height and duration.")
        }
        let media = PackMedia(file: mediaFile.file, bytes: mediaFile.bytes, sha256: mediaFile.sha256, width: w, height: h,
                              duration: dur, origin: m["origin"]?.stringValue ?? "video", codec: m["codec"]?.stringValue)

        var files: [PackFile] = []
        var seen: Set<String> = [media.file]
        for (i, item) in (d["files"]?.arrayValue ?? []).enumerated() {
            guard let o = item.objectValue else { throw PackError(.invalidValue, "files[\(i)] must be an object.") }
            let f = try readFile(o, where: "files[\(i)]", role: o["role"]?.stringValue ?? "still")
            guard seen.insert(f.file).inserted else { throw PackError(.invalidValue, "\(f.file) is listed twice.") }
            files.append(f)
        }

        guard let placementsObject = d["placements"]?.objectValue else {
            throw PackError(.missingValue, "placements is missing.")
        }
        var placements: [PlacementID: Placement] = [:]
        for key in placementsObject.keys.sorted() {
            guard let id = PlacementID(rawValue: key) else {
                warnings.append("Placement \"\(key)\" is not known to this version and was ignored.")
                continue
            }
            guard let o = placementsObject[key]?.objectValue else {
                throw PackError(.invalidValue, "placements.\(key) must be an object.")
            }
            guard let presetObject = o["preset"]?.objectValue else {
                throw PackError(.missingValue, "placements.\(key).preset is missing.")
            }
            let preset: BackgroundPreset
            do { preset = try BackgroundPreset.read(dictionary: presetObject) } catch let e as PackError {
                throw PackError(e.code, "\(id.title): \(e.message)")
            }
            guard preset.mediaFile == media.file else {
                throw PackError(.invalidValue, "\(id.title) uses \(preset.mediaFile); a pack has one source clip (\(media.file)).")
            }
            guard abs(preset.mediaWidth - media.width) < 0.5, abs(preset.mediaHeight - media.height) < 0.5,
                  abs(preset.duration - media.duration) < 0.001 else {
                throw PackError(.invalidValue, "\(id.title) describes a different clip size or duration than media.")
            }
            if let sha = preset.mediaSHA256, sha != media.sha256 {
                throw PackError(.checksumMismatch, "\(id.title) names a different media checksum than the pack.")
            }
            if let still = preset.stillFile, !files.contains(where: { $0.file == still }) {
                throw PackError(.missingValue, "\(id.title) uses the still \(still), which is not listed in files.")
            }
            for w in preset.warnings { warnings.append("\(id.title): \(w)") }
            var placement = Placement(id: id, canvas: nil, preset: preset)
            if let c = o["canvas"]?.objectValue, let cw = c["width"]?.numberValue, let ch = c["height"]?.numberValue,
               cw > 0, ch > 0, cw.isFinite, ch.isFinite {
                placement.canvas = CanvasSize(width: cw, height: ch)
            }
            if let s = o["reduceMotion"]?.stringValue {
                if let p = MotionPolicy(rawValue: s) { placement.reduceMotion = p } else {
                    warnings.append("\(id.title): unknown reduceMotion \"\(s)\": using still.")
                }
            }
            if let s = o["lowPower"]?.stringValue {
                if let p = PowerPolicy(rawValue: s) { placement.lowPower = p } else {
                    warnings.append("\(id.title): unknown lowPower \"\(s)\": using still.")
                }
            }
            placements[id] = placement
        }
        guard let first = placements.keys.sorted().first else {
            throw PackError(.missingValue, "The pack has no placement this version can show.")
        }
        var defaultPlacement = first
        if let s = d["defaultPlacement"]?.stringValue {
            if let id = PlacementID(rawValue: s), placements[id] != nil { defaultPlacement = id } else {
                warnings.append("defaultPlacement \"\(s)\" is not in this pack: using \(first.title).")
            }
        }
        var pack = AnimationPack(id: identifier, name: name, created: created,
                                 generator: d["generator"]?.objectValue != nil ? d["generator"] : nil,
                                 media: media, files: files, defaultPlacement: defaultPlacement, placements: placements)
        pack.warnings = warnings
        return pack
    }

    private static func readFile(_ o: [String: JSONValue], where w: String, role: String) throws -> PackFile {
        guard let file = o["file"]?.stringValue else { throw PackError(.missingValue, "\(w).file is missing.") }
        guard BackgroundPreset.isSafeFileName(file), !reservedNames.contains(file) else {
            throw PackError(.unsafeFileName, "\(w).file must be a plain file name.")
        }
        guard let bytes = o["bytes"]?.numberValue, bytes >= 0, bytes == bytes.rounded() else {
            throw PackError(.missingValue, "\(w).bytes must be a whole number.")
        }
        guard let sha = o["sha256"]?.stringValue, sha.utf16.count == 64,
              sha.lowercased().allSatisfy({ $0.isHexDigit }) else {
            throw PackError(.missingValue, "\(w).sha256 must be 64 hex digits.")
        }
        return PackFile(file: file, bytes: Int64(bytes), sha256: sha.lowercased(), role: role)
    }

    // MARK: Verification

    /// Checks that every file is present, is a regular file (not a link), and matches its size and SHA-256.
    public func verify(in folder: URL) throws {
        for f in allFiles {
            let url = folder.appendingPathComponent(f.file, isDirectory: false)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard let values, values.isSymbolicLink != true, values.isRegularFile == true else {
                throw PackError(.missingValue, "\(f.file) is missing from the pack.")
            }
            if let size = values.fileSize, Int64(size) != f.bytes {
                throw PackError(.sizeMismatch, "\(f.file) is \(size) bytes; the pack says \(f.bytes).")
            }
            let actual = try Checksum.sha256(of: url)
            guard actual.hex == f.sha256 else {
                throw PackError(.checksumMismatch, "\(f.file) does not match its checksum (damaged or replaced).")
            }
        }
    }

    // MARK: Writing

    public func dictionary() -> JSONValue {
        var m: [String: JSONValue] = [
            "file": .string(media.file), "bytes": .number(Double(media.bytes)), "sha256": .string(media.sha256),
            "width": .number(media.width.rounded()), "height": .number(media.height.rounded()),
            "duration": .number(round6(media.duration)), "origin": .string(media.origin),
        ]
        if let c = media.codec { m["codec"] = .string(c) }
        var placementsObject: [String: JSONValue] = [:]
        for p in orderedPlacements {
            var preset = p.preset
            preset.mediaSHA256 = media.sha256
            var o: [String: JSONValue] = [
                "reduceMotion": .string(p.reduceMotion.rawValue),
                "lowPower": .string(p.lowPower.rawValue),
                "preset": preset.dictionary(),
            ]
            if let c = p.canvas { o["canvas"] = ["width": .number(c.width), "height": .number(c.height)] }
            placementsObject[p.id.rawValue] = .object(o)
        }
        var d: [String: JSONValue] = [
            "format": .string(AnimationPack.format),
            "formatVersion": .number(Double(AnimationPack.formatVersion)),
            "id": .string(id),
            "name": .string(name),
            "media": .object(m),
            "files": .array(files.map {
                ["file": .string($0.file), "bytes": .number(Double($0.bytes)), "sha256": .string($0.sha256),
                 "role": .string($0.role)]
            }),
            "defaultPlacement": .string(defaultPlacement.rawValue),
            "placements": .object(placementsObject),
            "presetFormat": ["format": .string(BackgroundPreset.format),
                             "formatVersion": .number(Double(BackgroundPreset.formatVersion))],
        ]
        if let c = created { d["created"] = .string(ISO8601.string(from: c)) }
        if let g = generator { d["generator"] = g }
        return .object(d)
    }

    /// The preset of a placement exactly as it is written inside the pack (media checksum included).
    public func exportedPreset(_ id: PlacementID) -> BackgroundPreset? {
        guard var p = placements[id]?.preset else { return nil }
        p.mediaSHA256 = media.sha256
        return p
    }

    /// Writes pack.json and preset.json (the default placement) into an existing pack folder.
    public func writeManifest(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try dictionary().canonicalData().write(to: folder.appendingPathComponent(AnimationPack.manifestName), options: .atomic)
        if let preset = exportedPreset(defaultPlacement) {
            try preset.jsonData().write(to: folder.appendingPathComponent(BackgroundPreset.fileName), options: .atomic)
        }
    }

    /// Exports one placement as a standalone `<name>.hcgbackground` folder for HCG Animation Center on iOS
    /// (HCGBackgroundKit): preset.json + the media + the still. Returns the folder.
    @discardableResult
    public func exportBackgroundPreset(_ id: PlacementID, from packFolder: URL, to directory: URL,
                                       folderName: String? = nil) throws -> URL {
        guard let preset = exportedPreset(id) else { throw PackError(.missingValue, "The pack has no \(id.title) placement.") }
        let base = sanitizedFolderName(folderName ?? "\(name) \(id.title)")
        let out = directory.appendingPathComponent(base + ".hcgbackground", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        var names = [media.file]
        if let s = preset.stillFile { names.append(s) }
        for n in names {
            try fm.copyItem(at: packFolder.appendingPathComponent(n), to: out.appendingPathComponent(n))
        }
        try preset.jsonData().write(to: out.appendingPathComponent(BackgroundPreset.fileName), options: .atomic)
        return out
    }
}

// MARK: - Building a pack

public struct PlacementTemplate: Sendable {
    public var id: PlacementID
    public var canvas: CanvasSize
    public var scaling: Scaling
    public var backgroundColor: String
    public var reduceMotion: MotionPolicy
    public var lowPower: PowerPolicy

    /// The four placement presets. Every placement starts from the whole clip, looping at 1×, muted.
    public static let defaults: [PlacementTemplate] = [
        PlacementTemplate(id: .desktop, canvas: CanvasSize(width: 3456, height: 2234), scaling: .fill,
                          backgroundColor: "#000000", reduceMotion: .still, lowPower: .still),
        PlacementTemplate(id: .appBackground, canvas: CanvasSize(width: 1179, height: 2556), scaling: .crop,
                          backgroundColor: "#000000", reduceMotion: .still, lowPower: .still),
        PlacementTemplate(id: .banner, canvas: CanvasSize(width: 1500, height: 500), scaling: .crop,
                          backgroundColor: "#000000", reduceMotion: .still, lowPower: .still),
        PlacementTemplate(id: .loadingScreen, canvas: CanvasSize(width: 1179, height: 2556), scaling: .fit,
                          backgroundColor: "#080C12", reduceMotion: .still, lowPower: .play),
    ]

    public static func template(_ id: PlacementID) -> PlacementTemplate { defaults.first { $0.id == id }! }
}

extension AnimationPack {
    /// Builds a pack for files already inside `folder` (the media and an optional poster), with checksums and the
    /// four default placements.
    public static func assemble(in folder: URL, name: String, mediaFile: String, width: Double, height: Double,
                                duration: Double, origin: String = "video", codec: String? = nil,
                                posterFile: String?, posterTime: Double,
                                generator: JSONValue? = nil, id: String = UUID().uuidString,
                                created: Date? = Date()) throws -> AnimationPack {
        guard BackgroundPreset.isSafeFileName(mediaFile), !reservedNames.contains(mediaFile) else {
            throw PackError(.unsafeFileName, "media file must be a plain file name.")
        }
        let mediaSum = try Checksum.sha256(of: folder.appendingPathComponent(mediaFile))
        let media = PackMedia(file: mediaFile, bytes: mediaSum.bytes, sha256: mediaSum.hex, width: width, height: height,
                              duration: duration, origin: origin, codec: codec)
        var files: [PackFile] = []
        if let posterFile {
            guard BackgroundPreset.isSafeFileName(posterFile), !reservedNames.contains(posterFile) else {
                throw PackError(.unsafeFileName, "poster file must be a plain file name.")
            }
            let s = try Checksum.sha256(of: folder.appendingPathComponent(posterFile))
            files.append(PackFile(file: posterFile, bytes: s.bytes, sha256: s.hex, role: "poster"))
        }
        var placements: [PlacementID: Placement] = [:]
        for t in PlacementTemplate.defaults {
            var p = try BackgroundPreset(mediaFile: mediaFile, width: width, height: height, duration: duration, origin: origin)
            p.id = derivedUUID(id.uppercased() + "/" + t.id.rawValue)
            p.name = truncateUTF16("\(name) — \(t.id.title)", to: 120)
            p.created = created
            p.stillFile = posterFile
            p.stillTime = posterTime
            p.scaling = t.scaling
            p.backgroundColor = t.backgroundColor
            if t.scaling == .crop {
                p.crop = Layout.crop(container: (t.canvas.width, t.canvas.height), media: (width, height),
                                     zoom: 1, centerX: 0.5, centerY: 0.5)
            }
            p.generator = ["kind": "import", "source": .string(origin)]
            try p.sanitize()
            placements[t.id] = Placement(id: t.id, canvas: t.canvas, reduceMotion: t.reduceMotion,
                                         lowPower: t.lowPower, preset: p)
        }
        return AnimationPack(id: id, name: truncateUTF16(name, to: 120), created: created, generator: generator,
                             media: media, files: files, defaultPlacement: .desktop, placements: placements)
    }

    /// Adds or replaces a still file (poster or a placement's own still) after it was written into the folder.
    public mutating func registerFile(_ file: String, role: String, in folder: URL) throws {
        guard BackgroundPreset.isSafeFileName(file), !AnimationPack.reservedNames.contains(file), file != media.file else {
            throw PackError(.unsafeFileName, "\(file) cannot be used as a pack file name.")
        }
        let s = try Checksum.sha256(of: folder.appendingPathComponent(file))
        files.removeAll { $0.file == file }
        files.append(PackFile(file: file, bytes: s.bytes, sha256: s.hex, role: role))
        files.sort { $0.file < $1.file }
    }

    /// Removes still files no placement uses any more (returns their names so the caller can delete them).
    public mutating func pruneUnusedFiles() -> [String] {
        let used = Set(placements.values.compactMap { $0.preset.stillFile })
        let unused = files.filter { !used.contains($0.file) && $0.role != "poster" }.map(\.file)
        files.removeAll { unused.contains($0.file) }
        return unused
    }
}

/// A stable UUID (version 5 layout) derived from text: a placement's preset id follows from the pack id, so a pack
/// rebuilt from the same inputs is byte-identical.
func derivedUUID(_ text: String) -> String {
    var b = Array(Checksum.sha256(Data(text.utf8)).prefix(32))
    func hex(_ r: Range<Int>) -> String { String(b[r]) }
    b[12] = "5"
    let variant = ["8", "9", "a", "b"][Int(String(b[16]), radix: 16)! % 4]
    b[16] = Character(variant)
    return [hex(0..<8), hex(8..<12), hex(12..<16), hex(16..<20), hex(20..<32)].joined(separator: "-").uppercased()
}

func sanitizedFolderName(_ s: String) -> String {
    var out = ""
    for ch in s {
        if ch == "/" || ch == "\\" || ch == ":" || ch.unicodeScalars.contains(where: { $0.value < 0x20 }) { out.append("-") } else { out.append(ch) }
    }
    while out.hasPrefix(".") { out.removeFirst() }
    let trimmed = out.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "Animation" : String(trimmed.prefix(100))
}
