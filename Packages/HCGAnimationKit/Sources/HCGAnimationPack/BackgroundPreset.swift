//
//  BackgroundPreset.swift
//  HCGAnimationPack — Hakmi Capital Group
//
//  The HCG background preset, format "com.hakmicapitalgroup.background-preset", version 1 — the format the iOS
//  project (HCG Animation Center / HCGBackgroundKit) already reads and writes. This is a Swift port of
//  HCGBackgroundPreset.m with the same rules: strict about identity and safety (format, major version, file names,
//  required numbers), tolerant about the rest (unknown keys ignored, out-of-range numbers repaired and reported in
//  `warnings`). The numeric repairs are done by the shared C core (HCGBackgroundCore), not re-implemented.
//

import Foundation
import HCGBackgroundCore

public enum Scaling: String, CaseIterable, Sendable {
    case fill, fit, crop

    var core: HCGBGScaling {
        switch self {
        case .fill: return HCGBGScalingFill
        case .fit: return HCGBGScalingFit
        case .crop: return HCGBGScalingCrop
        }
    }
}

/// A rectangle normalised to the media's display frame, origin top-left.
public struct NormalizedRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let whole = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    var core: HCGBGRect { HCGBGRect(x: x, y: y, width: width, height: height) }
    init(_ r: HCGBGRect) { self.init(x: r.x, y: r.y, width: r.width, height: r.height) }
}

public struct BackgroundPreset: Equatable, Sendable {
    public static let format = "com.hakmicapitalgroup.background-preset"
    public static let formatVersion = 1
    public static let fileName = "preset.json"
    /// Largest preset document accepted from disk (HCGBackgroundKit uses the same limit).
    public static let maxDocumentBytes = 64 * 1024

    // Identity
    public var id: String = UUID().uuidString
    public var name: String = "Background"
    public var created: Date?
    // Media (one video file)
    public var mediaFile: String = ""
    public var mediaWidth: Double = 0
    public var mediaHeight: Double = 0
    public var duration: Double = 0
    public var origin: String = "video"
    public var mediaSHA256: String?
    // Still fallback
    public var stillFile: String?
    public var stillTime: Double = 0
    // Playback
    public var trimStart: Double = 0
    public var trimEnd: Double = 0
    public var loops: Bool = true
    public var speed: Double = HCGBG_SPEED_DEFAULT
    /// Always true in format version 1: backgrounds never play sound.
    public var muted: Bool { true }
    // Layout
    public var scaling: Scaling = .fill
    public var crop: NormalizedRect = .whole
    public var backgroundColor: String = "#000000"
    /// Informational: how the media was made. Never trusted for decisions.
    public var generator: JSONValue?

    public private(set) var warnings: [String] = []

    public init() {}

    /// A new preset with sensible defaults (fill, loop, 1×, whole clip, still at the start).
    public init(mediaFile: String, width: Double, height: Double, duration: Double, origin: String = "video") throws {
        self.mediaFile = mediaFile
        self.mediaWidth = width
        self.mediaHeight = height
        self.duration = duration
        self.origin = origin.isEmpty ? "video" : origin
        self.trimEnd = duration
        self.created = Date()
        let stem = (mediaFile as NSString).deletingPathExtension
        self.name = stem.isEmpty ? "Background" : stem
        try sanitize()
    }

    public static func == (a: BackgroundPreset, b: BackgroundPreset) -> Bool {
        a.dictionary(sanitizing: false) == b.dictionary(sanitizing: false)
    }

    // MARK: File names

    /// Whether a file name is safe to resolve inside a preset's (or pack's) own folder.
    public static func isSafeFileName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty, name.utf16.count <= 255 else { return false }
        if name.hasPrefix(".") || name.contains("/") || name.contains("\\") || name.contains(":") { return false }
        for u in name.unicodeScalars where u.value < 0x20 || u.value == 0x7F { return false }
        return true
    }

    // MARK: Reading

    public static func read(contentsOf url: URL) throws -> BackgroundPreset {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PackError(.unreadable, "No preset file at \(url.lastPathComponent).")
        }
        let file = isDirectory.boolValue ? url.appendingPathComponent(fileName) : url
        let data = try readSmallFile(file, limit: maxDocumentBytes)
        return try read(jsonData: data)
    }

    public static func read(jsonData data: Data) throws -> BackgroundPreset {
        guard data.count <= maxDocumentBytes else { throw PackError(.unreadable, "The preset is larger than 64 KB.") }
        guard let value = JSONValue.parse(data), case .object(let d) = value else {
            throw PackError(.unreadable, "The preset is not a JSON object.")
        }
        return try read(dictionary: d)
    }

    public static func read(dictionary d: [String: JSONValue]) throws -> BackgroundPreset {
        guard d["format"]?.stringValue == format else {
            throw PackError(.notAPreset, "Not an HCG background preset (format must be \(format)).")
        }
        guard let version = d["formatVersion"]?.numberValue, version == version.rounded(), version >= 1 else {
            throw PackError(.unsupportedVersion, "formatVersion must be a whole number.")
        }
        if Int(version) > formatVersion {
            throw PackError(.unsupportedVersion,
                            "This preset uses format version \(Int(version)); this version of HCGBackgroundKit reads version \(formatVersion). Update to use it.")
        }

        var p = BackgroundPreset()
        if let identifier = d["id"]?.stringValue, !identifier.isEmpty {
            guard UUID(uuidString: identifier) != nil else { throw PackError(.invalidValue, "id must be a UUID.") }
            p.id = identifier.uppercased()
        }
        if let name = d["name"]?.stringValue, !name.isEmpty { p.name = truncateUTF16(name, to: 120) }
        if let created = d["created"]?.stringValue { p.created = ISO8601.date(from: created) }

        guard let media = d["media"]?.objectValue else { throw PackError(.missingValue, "media is missing.") }
        let kind = media["kind"]?.stringValue ?? "video"
        guard kind == "video" else {
            throw PackError(.invalidValue, "media.kind \"\(kind)\" is not supported (version 1 plays video only).")
        }
        guard let file = media["file"]?.stringValue else { throw PackError(.missingValue, "media.file is missing.") }
        guard isSafeFileName(file) else { throw PackError(.unsafeFileName, "media.file must be a plain file name.") }
        p.mediaFile = file
        guard let w = media["width"]?.numberValue, let h = media["height"]?.numberValue,
              let duration = media["duration"]?.numberValue else {
            throw PackError(.missingValue, "media needs width, height and duration.")
        }
        p.mediaWidth = w
        p.mediaHeight = h
        p.duration = duration
        if let origin = media["origin"]?.stringValue, !origin.isEmpty { p.origin = origin }
        if let sha = media["sha256"]?.stringValue, sha.utf16.count == 64 { p.mediaSHA256 = sha.lowercased() }

        let still = d["still"]?.objectValue ?? [:]
        if let stillFile = still["file"]?.stringValue {
            guard isSafeFileName(stillFile) else { throw PackError(.unsafeFileName, "still.file must be a plain file name.") }
            p.stillFile = stillFile
        }
        p.stillTime = still["time"]?.numberValue ?? 0

        let playback = d["playback"]?.objectValue ?? [:]
        p.trimStart = playback["trimStart"]?.numberValue ?? 0
        p.trimEnd = playback["trimEnd"]?.numberValue ?? 0
        p.loops = playback["loop"]?.boolValue ?? true
        p.speed = playback["speed"]?.numberValue ?? HCGBG_SPEED_DEFAULT
        if playback["muted"]?.boolValue == false {
            p.warnings.append("Sound is not supported: the background plays muted.")
        }

        let layout = d["layout"]?.objectValue ?? [:]
        if let scaling = layout["scaling"]?.stringValue {
            if let s = Scaling(rawValue: scaling) { p.scaling = s } else {
                p.warnings.append("Unknown scaling \"\(scaling)\": using fill.")
            }
        }
        if let crop = layout["crop"]?.objectValue {
            p.crop = NormalizedRect(x: crop["x"]?.numberValue ?? 0, y: crop["y"]?.numberValue ?? 0,
                                    width: crop["width"]?.numberValue ?? 1, height: crop["height"]?.numberValue ?? 1)
        }
        if let colour = layout["backgroundColor"]?.stringValue {
            if parseHexColour(colour) != nil { p.backgroundColor = colour.uppercased() } else {
                p.warnings.append("backgroundColor must be #RRGGBB: using black.")
            }
        }
        if case .object(_)? = d["generator"] { p.generator = d["generator"] }

        try p.sanitize()
        return p
    }

    // MARK: Sanitising (C core rules)

    var corePlayback: HCGBGPlayback {
        HCGBGPlayback(duration: duration, trimStart: trimStart, trimEnd: trimEnd, speed: speed, posterTime: stillTime,
                      width: mediaWidth, height: mediaHeight, crop: crop.core)
    }

    /// Clamps every number into range and records warnings. Throws if the preset cannot be used at all.
    public mutating func sanitize() throws {
        guard BackgroundPreset.isSafeFileName(mediaFile) else {
            throw PackError(.unsafeFileName, "media.file must be a plain file name.")
        }
        if let stillFile, !BackgroundPreset.isSafeFileName(stillFile) {
            throw PackError(.unsafeFileName, "still.file must be a plain file name.")
        }
        if parseHexColour(backgroundColor) == nil { backgroundColor = "#000000" }

        var c = corePlayback
        let issues = hcgbg_playback_sanitize(&c)
        if issues & HCGBGIssueDurationInvalid.rawValue != 0 {
            throw PackError(.invalidValue, "media.duration must be between 0 and \(Int(HCGBG_MAX_SOURCE_SECONDS)) seconds.")
        }
        if issues & HCGBGIssueDimensionsInvalid.rawValue != 0 {
            throw PackError(.invalidValue, "media width and height must be \(HCGBG_MIN_DIMENSION)–\(HCGBG_MAX_DIMENSION) pixels.")
        }
        if issues & HCGBGIssueClipTooShort.rawValue != 0 {
            throw PackError(.invalidValue, "The media is shorter than \(HCGBG_MIN_CLIP_SECONDS) s.")
        }
        func note(_ flag: HCGBGIssue, _ text: String) {
            if issues & flag.rawValue != 0, !warnings.contains(text) { warnings.append(text) }
        }
        note(HCGBGIssueTrimClamped, "The trim range was adjusted to fit the clip.")
        note(HCGBGIssueSpeedClamped, "The speed was limited to 0.25×–2×.")
        note(HCGBGIssuePosterClamped, "The still was moved inside the trimmed clip.")
        note(HCGBGIssueCropClamped, "The crop was adjusted to fit the frame.")
        trimStart = round6(c.trimStart)
        trimEnd = round6(c.trimEnd)
        speed = round6(c.speed)
        stillTime = round6(c.posterTime)
        crop = NormalizedRect(x: round6(c.crop.x), y: round6(c.crop.y),
                              width: round6(c.crop.width), height: round6(c.crop.height))
    }

    /// Trimmed clip length at 1×.
    public var clipDuration: Double {
        var c = corePlayback
        _ = hcgbg_playback_sanitize(&c)
        return hcgbg_clip_seconds(&c)
    }

    /// Wall-clock length of one pass at the preset's speed.
    public var playbackDuration: Double { speed > 0 ? clipDuration / speed : clipDuration }

    // MARK: Writing

    /// The canonical document (identical keys and values to HCGBackgroundKit's -dictionaryRepresentation).
    public func dictionary(sanitizing: Bool = true) -> JSONValue {
        var p = self
        if sanitizing { try? p.sanitize() }
        var media: [String: JSONValue] = [
            "kind": "video",
            "file": .string(p.mediaFile),
            "width": .number(p.mediaWidth.rounded()),
            "height": .number(p.mediaHeight.rounded()),
            "duration": .number(round6(p.duration)),
            "origin": .string(p.origin),
        ]
        if let sha = p.mediaSHA256 { media["sha256"] = .string(sha) }
        var still: [String: JSONValue] = ["time": .number(p.stillTime)]
        if let f = p.stillFile { still["file"] = .string(f) }
        var d: [String: JSONValue] = [
            "format": .string(BackgroundPreset.format),
            "formatVersion": .number(Double(BackgroundPreset.formatVersion)),
            "id": .string(p.id),
            "name": .string(p.name),
            "media": .object(media),
            "still": .object(still),
            "playback": [
                "trimStart": .number(p.trimStart),
                "trimEnd": .number(p.trimEnd),
                "loop": .bool(p.loops),
                "speed": .number(p.speed),
                "muted": true,
            ],
            "layout": [
                "scaling": .string(p.scaling.rawValue),
                "crop": [
                    "x": .number(p.crop.x), "y": .number(p.crop.y),
                    "width": .number(p.crop.width), "height": .number(p.crop.height),
                ],
                "backgroundColor": .string(p.backgroundColor),
            ],
        ]
        if let created = p.created { d["created"] = .string(ISO8601.string(from: created)) }
        if let g = p.generator { d["generator"] = g }
        return .object(d)
    }

    public func jsonData() -> Data { dictionary().canonicalData() }

    public func mediaURL(in folder: URL) -> URL? {
        BackgroundPreset.isSafeFileName(mediaFile) ? folder.appendingPathComponent(mediaFile, isDirectory: false) : nil
    }

    public func stillURL(in folder: URL) -> URL? {
        BackgroundPreset.isSafeFileName(stillFile) ? folder.appendingPathComponent(stillFile!, isDirectory: false) : nil
    }
}

// MARK: - Geometry (shared with every renderer)

public enum Layout {
    /// The rectangle the WHOLE media frame is drawn in, in container coordinates (top-left origin).
    public static func frame(container: (width: Double, height: Double), media: (width: Double, height: Double),
                             scaling: Scaling, crop: NormalizedRect) -> NormalizedRect {
        NormalizedRect(hcgbg_layout(HCGBGSize(width: container.width, height: container.height),
                                    HCGBGSize(width: media.width, height: media.height), scaling.core, crop.core))
    }

    public static func crop(container: (width: Double, height: Double), media: (width: Double, height: Double),
                            zoom: Double, centerX: Double, centerY: Double) -> NormalizedRect {
        NormalizedRect(hcgbg_crop_from_zoom(HCGBGSize(width: container.width, height: container.height),
                                            HCGBGSize(width: media.width, height: media.height), zoom, centerX, centerY))
    }

    public static func zoom(container: (width: Double, height: Double), media: (width: Double, height: Double),
                            crop: NormalizedRect) -> Double {
        hcgbg_zoom_for_crop(HCGBGSize(width: container.width, height: container.height),
                            HCGBGSize(width: media.width, height: media.height), crop.core)
    }

    public static let maxZoom = HCGBG_ZOOM_MAX
    public static let speedRange = HCGBG_SPEED_MIN...HCGBG_SPEED_MAX
    public static let minClipSeconds = HCGBG_MIN_CLIP_SECONDS
    public static let maxSourceSeconds = HCGBG_MAX_SOURCE_SECONDS
    public static let dimensionRange = Double(HCGBG_MIN_DIMENSION)...Double(HCGBG_MAX_DIMENSION)

    /// GIF import timing and output sizing (same rules as the iOS importer).
    public static func gifFrameDelay(_ declared: Double) -> Double { hcgbg_gif_frame_delay(declared) }
    public static func evenFit(width: Double, height: Double, maxLongSide: Double) -> (width: Double, height: Double) {
        let s = hcgbg_even_fit(HCGBGSize(width: width, height: height), maxLongSide)
        return (s.width, s.height)
    }
}

// MARK: - Helpers

/// Components in 0…1 for "#RRGGBB", or nil.
public func parseHexColour(_ text: String) -> (r: Double, g: Double, b: Double)? {
    var r = 0.0, g = 0.0, b = 0.0
    let ok = text.withCString { hcgbg_parse_hex_colour($0, &r, &g, &b) }
    return ok ? (r, g, b) : nil
}

func round6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

func truncateUTF16(_ s: String, to limit: Int) -> String {
    guard s.utf16.count > limit else { return s }
    var out = ""
    var count = 0
    for ch in s {
        let n = String(ch).utf16.count
        if count + n > limit { break }
        out.append(ch)
        count += n
    }
    return out
}

enum ISO8601 {
    static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func date(from text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}

func readSmallFile(_ url: URL, limit: Int) throws -> Data {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true else { throw PackError(.unreadable, "No file at \(url.lastPathComponent).") }
    if let size = values?.fileSize, size > limit {
        throw PackError(.unreadable, "\(url.lastPathComponent) is larger than \(limit / 1024) KB.")
    }
    guard let data = try? Data(contentsOf: url) else {
        throw PackError(.unreadable, "\(url.lastPathComponent) could not be read.")
    }
    return data
}
