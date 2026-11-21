//
//  hcgpack — HCG animation pack tool (Hakmi Capital Group)
//
//  Foundation only; runs on macOS and Linux. Uses the same HCGAnimationPack code as the Mac studio, so packs made
//  here are identical to packs exported from the app. It does not decode video: pass the clip's numbers (the Mac app
//  and scripts/make-sample-pack.sh read them with AVFoundation / ffprobe).
//
//    hcgpack create --media clip.mp4 --name "HCG Orbital Command" --width 3840 --height 2160 --duration 12
//                   [--codec avc1] [--origin video] [--poster poster.jpg --poster-time 2] [--id UUID]
//                   [--created 2026-11-21T00:00:00Z] --out OrbitalCommand.hcgpack
//    hcgpack set <pack> --placement banner [--scaling fill|fit|crop] [--zoom 1.5] [--center-x 0.5] [--center-y 0.5]
//                   [--trim-start s] [--trim-end s] [--speed x] [--loop true|false] [--still-time s]
//                   [--reduce-motion still|play] [--low-power still|play|system] [--background-color #RRGGBB]
//                   [--make-default]
//    hcgpack validate <pack>
//    hcgpack info <pack>
//    hcgpack export-preset <pack> <placement> <output-directory>
//    hcgpack catalog --pack <pack> --base-url "<url or empty>" [--title T] [--summary S] [--updated ISO] --out catalog.json
//    hcgpack validate-catalog <catalog.json>
//    hcgpack compatibility            (the platform × placement table, Markdown)
//

import Foundation
import HCGAnimationPack

struct Failure: Error { let message: String }

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("hcgpack: \(m)\n".utf8))
    exit(1)
}

/// `fail` usable where a value is expected (`x ?? die("…")`).
func die<T>(_ m: String) -> T { fail(m) }

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: ArraySlice<String>) {
        var i = argv.startIndex
        while i < argv.endIndex {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.endIndex, !argv[i + 1].hasPrefix("--") || argv[i + 1] == "--" {
                    options[key] = argv[i + 1]
                    i += 2
                    continue
                }
                flags.insert(key)
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func string(_ k: String) -> String? { options[k] }
    func require(_ k: String) -> String { options[k] ?? die("--\(k) is required") }
    func double(_ k: String) -> Double? {
        guard let s = options[k] else { return nil }
        return Double(s) ?? die("--\(k) must be a number")
    }
    func requireDouble(_ k: String) -> Double { double(k) ?? die("--\(k) is required") }
}

func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

func summary(_ pack: AnimationPack) -> String {
    var lines = [
        "\(pack.name)  [\(pack.id)]",
        "  media    \(pack.media.file)  \(Int(pack.media.width))x\(Int(pack.media.height))  \(pack.media.duration) s  \(pack.media.codec ?? "?")  \(pack.media.bytes) bytes",
        "  sha256   \(pack.media.sha256)",
        "  files    " + pack.files.map { "\($0.file) (\($0.role), \($0.bytes) bytes)" }.joined(separator: ", "),
        "  default  \(pack.defaultPlacement.rawValue)",
    ]
    for p in pack.orderedPlacements {
        let pr = p.preset
        let c = pr.crop
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        let id = p.id.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)
        lines.append("  \(id) \(pr.scaling.rawValue) trim \(f(pr.trimStart))–\(f(pr.trimEnd))  \(pr.loops ? "loop" : "once")  "
            + "\(String(format: "%.2f", pr.speed))x  still \(pr.stillFile ?? "-")@\(f(pr.stillTime))  "
            + "crop \(f(c.x)),\(f(c.y)) \(f(c.width))x\(f(c.height))  RM:\(p.reduceMotion.rawValue) LP:\(p.lowPower.rawValue)")
    }
    for w in pack.warnings { lines.append("  warning  \(w)") }
    return lines.joined(separator: "\n")
}

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    print("usage: hcgpack create|set|validate|info|export-preset|catalog|validate-catalog …  (see the header of main.swift)")
    exit(2)
}
let command = argv[1]
let args = Args(argv.dropFirst(2))
let fm = FileManager.default

do {
    switch command {
    case "create":
        let media = url(args.require("media"))
        let out = url(args.require("out"))
        let ext = media.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { fail("--media must be an .mp4, .mov or .m4v file (convert GIFs first)") }
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let mediaName = "media.\(ext)"
        try fm.copyItem(at: media, to: out.appendingPathComponent(mediaName))
        var posterName: String?
        if let poster = args.string("poster") {
            let p = url(poster)
            posterName = "poster.\(p.pathExtension.lowercased().isEmpty ? "jpg" : p.pathExtension.lowercased())"
            try fm.copyItem(at: p, to: out.appendingPathComponent(posterName!))
        }
        var created = Date()
        if let c = args.string("created") {
            let f = ISO8601DateFormatter()
            guard let d = f.date(from: c) else { fail("--created must be an ISO 8601 date-time") }
            created = d
        }
        let pack = try AnimationPack.assemble(
            in: out, name: args.require("name"), mediaFile: mediaName, width: args.requireDouble("width"),
            height: args.requireDouble("height"), duration: args.requireDouble("duration"),
            origin: args.string("origin") ?? "video", codec: args.string("codec"), posterFile: posterName,
            posterTime: args.double("poster-time") ?? 0,
            generator: ["app": "hcgpack", "version": .string(HCGAnimationPackVersion.string)],
            id: args.string("id")?.uppercased() ?? UUID().uuidString, created: created)
        try pack.writeManifest(to: out)
        print(summary(try AnimationPack.read(contentsOf: out)))

    case "set":
        guard let path = args.positional.first else { fail("set needs a pack folder") }
        let folder = url(path)
        var pack = try AnimationPack.read(contentsOf: folder)
        guard let id = PlacementID(rawValue: args.require("placement")) else {
            fail("--placement must be one of " + PlacementID.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard var placement = pack.placements[id] else { fail("the pack has no \(id.rawValue) placement") }
        var p = placement.preset
        if let s = args.string("scaling") { p.scaling = Scaling(rawValue: s) ?? die("--scaling must be fill, fit or crop") }
        if args.double("zoom") != nil || args.double("center-x") != nil || args.double("center-y") != nil {
            let canvas = placement.canvas ?? CanvasSize(width: p.mediaWidth, height: p.mediaHeight)
            p.crop = Layout.crop(container: (canvas.width, canvas.height), media: (p.mediaWidth, p.mediaHeight),
                                 zoom: args.double("zoom") ?? 1, centerX: args.double("center-x") ?? 0.5,
                                 centerY: args.double("center-y") ?? 0.5)
            if args.string("scaling") == nil { p.scaling = .crop }
        }
        if let v = args.double("trim-start") { p.trimStart = v }
        if let v = args.double("trim-end") { p.trimEnd = v }
        if let v = args.double("speed") { p.speed = v }
        if let v = args.string("loop") { p.loops = v == "true" || v == "yes" || v == "1" }
        if let v = args.double("still-time") { p.stillTime = v }
        if let v = args.string("background-color") { p.backgroundColor = v.uppercased() }
        if let v = args.string("reduce-motion") { placement.reduceMotion = MotionPolicy(rawValue: v) ?? die("--reduce-motion: still|play") }
        if let v = args.string("low-power") { placement.lowPower = PowerPolicy(rawValue: v) ?? die("--low-power: still|play|system") }
        try p.sanitize()
        for w in p.warnings { print("warning: \(w)") }
        placement.preset = p
        pack.placements[id] = placement
        if args.flags.contains("make-default") { pack.defaultPlacement = id }
        try pack.writeManifest(to: folder)
        print(summary(try AnimationPack.read(contentsOf: folder)))

    case "validate", "info":
        guard let path = args.positional.first else { fail("\(command) needs a pack folder") }
        let folder = url(path)
        let pack = try AnimationPack.read(contentsOf: folder)
        if command == "validate" {
            try pack.verify(in: folder)
            let preset = try BackgroundPreset.read(contentsOf: folder)
            guard preset == pack.exportedPreset(pack.defaultPlacement)! else {
                fail("preset.json does not match the default placement (re-save the pack)")
            }
            let listed = Set(pack.allFiles.map(\.file) + [AnimationPack.manifestName, BackgroundPreset.fileName])
            let present = Set(try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") })
            if !present.subtracting(listed).isEmpty {
                print("warning: files not listed in pack.json (ignored by readers): " + present.subtracting(listed).sorted().joined(separator: ", "))
            }
        }
        print(summary(pack))
        if command == "validate" { print("OK: pack.json, preset.json and every checksum verified") }

    case "export-preset":
        guard args.positional.count == 3, let id = PlacementID(rawValue: args.positional[1]) else {
            fail("export-preset <pack> <placement> <output-directory>")
        }
        let folder = url(args.positional[0])
        let pack = try AnimationPack.read(contentsOf: folder)
        try pack.verify(in: folder)
        let out = url(args.positional[2])
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try pack.exportBackgroundPreset(id, from: folder, to: out)
        print(result.path)

    case "catalog":
        let folder = url(args.require("pack"))
        let pack = try AnimationPack.read(contentsOf: folder)
        try pack.verify(in: folder)
        let item = try Catalog.item(for: pack, packFolder: folder, baseURL: args.string("base-url") ?? "",
                                    summary: args.string("summary"))
        var updated = Date()
        if let u = args.string("updated") { updated = ISO8601DateFormatter().date(from: u) ?? die("--updated must be ISO 8601") }
        let catalog = Catalog(title: args.string("title") ?? "HCG Animation Catalog", updated: updated, items: [item])
        try catalog.dictionary().canonicalData().write(to: url(args.require("out")), options: .atomic)
        print("catalog: 1 item, \(item.totalBytes) bytes, baseURL \"\(item.baseURL)\"")

    case "validate-catalog":
        guard let path = args.positional.first else { fail("validate-catalog <catalog.json>") }
        let c = try Catalog.read(jsonData: Data(contentsOf: url(path)))
        for w in c.warnings { print("warning: \(w)") }
        for i in c.items {
            print("\(i.name)  [\(i.id)]  \(i.totalBytes) bytes  poster \(i.poster ?? "-")  baseURL \"\(i.baseURL)\"\(i.isHosted ? "" : "  (NOT HOSTED YET)")")
        }
        print("OK: \(c.items.count) item(s)")

    case "compatibility":
        print(PlatformSupport.markdownTable())

    default:
        fail("unknown command \(command)")
    }
} catch let e as PackError {
    fail(e.message)
} catch {
    fail("\(error)")
}
