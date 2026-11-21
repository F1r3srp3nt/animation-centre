//
//  SelfTest.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  `HCGAnimationCenter --self-test [--report r.json] [--screenshots dir] [--cycles 20]`
//
//  Runs the real desktop player, importer, renderer and catalog in this GUI session and writes a JSON report. It uses
//  its own data folder and settings, never the user's library. Checks that can only be imitated here (display
//  hot-plug, sleep/wake, Reduce Motion / Low Power switches) are marked "simulated": they drive the same code paths
//  through the notifications and overrides the app listens to. Real hardware checks are in
//  docs/MAC-HARDWARE-CHECKLIST.md.
//

import AppKit
import AVFoundation
import Foundation
import HCGAnimationPack
import HCGPackPlayer
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum SelfTest {
    struct Check {
        var name: String
        var status: String // pass | fail | skip
        var detail: String
        var simulated: Bool
    }

    static var checks: [Check] = []
    static var screenshotDir: URL?

    static func record(_ name: String, _ ok: Bool, _ detail: String, simulated: Bool = false) {
        checks.append(Check(name: name, status: ok ? "pass" : "fail", detail: detail, simulated: simulated))
        print("\(ok ? "PASS" : "FAIL")\(simulated ? " (simulated)" : "")  \(name) — \(detail)")
    }

    static func skip(_ name: String, _ detail: String) {
        checks.append(Check(name: name, status: "skip", detail: detail, simulated: false))
        print("SKIP  \(name) — \(detail)")
    }

    static func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    static func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    static func argument(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: Run

    static func run(arguments args: [String]) async -> Int32 {
        let report = argument("--report", in: args).map { URL(fileURLWithPath: $0) }
        screenshotDir = argument("--screenshots", in: args).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let d = screenshotDir { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let cycles = Int(argument("--cycles", in: args) ?? "") ?? 20
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-selftest-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        AppSettings.defaults.removePersistentDomain(forName: AppSettings.suiteName)
        let model = AppModel(paths: paths)
        let env = environment()
        print("HCG Animation Center self-test \(AppInfo.version) — \(env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")

        await libraryAndImport(model, paths: paths)
        await placements(model)
        await desktop(model, cycles: cycles)
        editorLifecycle()
        await catalog(paths: paths)

        let failed = checks.filter { $0.status == "fail" }.count
        let json: JSONValue = [
            "app": .string(AppInfo.version),
            "environment": .object(env.mapValues { .string($0) }),
            "summary": ["passed": .number(Double(checks.filter { $0.status == "pass" }.count)),
                        "failed": .number(Double(failed)),
                        "skipped": .number(Double(checks.filter { $0.status == "skip" }.count))],
            "checks": .array(checks.map { ["name": .string($0.name), "status": .string($0.status), "detail": .string($0.detail),
                                           "simulated": .bool($0.simulated)] }),
        ]
        if let report { try? json.canonicalData().write(to: report) }
        print("SELF-TEST \(failed == 0 ? "PASSED" : "FAILED"): \(checks.count - failed)/\(checks.count) (\(checks.filter { $0.status == "skip" }.count) skipped)")
        try? FileManager.default.removeItem(at: root)
        return failed == 0 ? 0 : 1
    }

    static func environment() -> [String: String] {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            guard size > 0 else { return "?" }
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(cString: buf)
        }
        var vmm: Int32 = 0
        var vsize = MemoryLayout<Int32>.size
        sysctlbyname("kern.hv_vmm_present", &vmm, &vsize, nil, 0)
        return [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": sysctl("hw.model"),
            "cpu": sysctl("machdep.cpu.brand_string"),
            "virtualMachine": vmm == 1 ? "yes" : "no",
            "architecture": {
                #if arch(arm64)
                return "arm64"
                #else
                return "x86_64"
                #endif
            }(),
            "displays": NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x" }.joined(separator: ","),
            "reduceMotion": "\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)",
            "lowPowerMode": "\(ProcessInfo.processInfo.isLowPowerModeEnabled)",
        ]
    }

    // MARK: Library and import

    static func libraryAndImport(_ model: AppModel, paths: AppPaths) async {
        model.loadLibrary()
        guard let sample = model.items.first else {
            record("Sample pack seeded into the library", false, "no sample found (Resources/Samples missing?)")
            return
        }
        record("Sample pack seeded into the library", sample.pack.name == "HCG Orbital Command",
               "\(sample.pack.name), \(sample.pack.placements.count) placements, \(formatBytes(sample.pack.totalBytes))")
        do {
            try sample.pack.verify(in: sample.folder)
            record("Sample pack checksums", true, "media \(sample.pack.media.sha256.prefix(12))…")
        } catch { record("Sample pack checksums", false, error.localizedDescription) }

        do {
            let info = try await MediaImporter.probe(sample.mediaURL)
            record("4K clip probed with AVFoundation", info.width == 3840 && info.height == 2160 && abs(info.duration - 12) < 0.1,
                   "\(Int(info.width))x\(Int(info.height)) \(String(format: "%.2f", info.duration)) s \(info.codec ?? "?")")
        } catch { record("4K clip probed with AVFoundation", false, error.localizedDescription) }

        let work = paths.root.appendingPathComponent("inputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // MP4
        let mp4 = work.appendingPathComponent("Orbital MP4.mp4")
        try? FileManager.default.copyItem(at: sample.mediaURL, to: mp4)
        await importCheck("Import MP4", mp4, model: model, expectOrigin: "video", expectWidth: 3840)
        // MOV (re-wrapped with AVFoundation, passthrough)
        let mov = work.appendingPathComponent("Orbital MOV.mov")
        if await exportMOV(from: sample.mediaURL, to: mov) {
            await importCheck("Import MOV", mov, model: model, expectOrigin: "video", expectWidth: 3840)
        } else {
            record("Import MOV", false, "could not create a MOV test file")
        }
        // GIF (12 frames, 0.1 s each → 1.2 s)
        let gif = work.appendingPathComponent("Pulse.gif")
        if makeGIF(gif) {
            await importCheck("Import GIF (converted to H.264)", gif, model: model, expectOrigin: "gif", expectWidth: 320, expectDuration: 1.2)
        } else {
            record("Import GIF (converted to H.264)", false, "could not create a GIF test file")
        }
        // Refusals
        let bad = work.appendingPathComponent("broken.mp4")
        try? Data("not a video".utf8).write(to: bad)
        do {
            _ = try await MediaImporter.importFile(bad, into: paths.library)
            record("Damaged file refused", false, "was imported")
        } catch { record("Damaged file refused", true, error.localizedDescription) }
        model.loadLibrary()
        if let s = model.items.first(where: { $0.pack.name == "HCG Orbital Command" }) { model.selectedID = s.id }
    }

    static func importCheck(_ name: String, _ url: URL, model: AppModel, expectOrigin: String, expectWidth: Double,
                            expectDuration: Double? = nil) async {
        do {
            let (pack, folder) = try await MediaImporter.importFile(url, into: model.paths.library)
            try pack.verify(in: folder)
            let poster = pack.files.first { $0.role == "poster" }
            var ok = pack.media.origin == expectOrigin && pack.media.width == expectWidth && pack.placements.count == 4 && poster != nil
            if let d = expectDuration { ok = ok && abs(pack.media.duration - d) < 0.05 }
            ok = ok && pack.placements.values.allSatisfy { $0.preset.muted }
            record(name, ok, "\(pack.media.file) \(Int(pack.media.width))x\(Int(pack.media.height)) \(String(format: "%.2f", pack.media.duration)) s origin \(pack.media.origin), poster \(poster?.bytes ?? 0) bytes, 4 placements, muted")
        } catch {
            record(name, false, error.localizedDescription)
        }
    }

    static func exportMOV(from source: URL, to output: URL) async -> Bool {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else { return false }
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()
        return session.status == .completed
    }

    static func makeGIF(_ url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 12, nil) else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<12 {
            let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.07, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            ctx.setFillColor(CGColor(red: 0, green: 0.85, blue: 1, alpha: 1))
            let r = CGFloat(20 + i * 5)
            ctx.fillEllipse(in: CGRect(x: 160 - r, y: 90 - r, width: 2 * r, height: 2 * r))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Placements (the same renderer used by Mac apps)

    static func placements(_ model: AppModel) async {
        guard let item = model.selected else { return }
        for placement in item.pack.orderedPlacements {
            let canvas = placement.canvas ?? CanvasSize(width: 1600, height: 900)
            let scale = 480 / max(canvas.width, canvas.height)
            let frame = NSRect(x: 60, y: 60, width: canvas.width * scale, height: canvas.height * scale)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = PackPlayerView(frame: NSRect(origin: .zero, size: frame.size))
            window.contentView = view
            window.orderFrontRegardless()
            view.load(pack: item.pack, folder: item.folder, placement: placement.id)
            view.display = .playing
            let playing = await wait(8) { view.state == .playing }
            let t0 = view.currentTime ?? -1
            await sleep(1.0)
            let t1 = view.currentTime ?? -1
            let expected = Layout.frame(container: (Double(view.bounds.width), Double(view.bounds.height)),
                                        media: (placement.preset.mediaWidth, placement.preset.mediaHeight),
                                        scaling: placement.preset.scaling, crop: placement.preset.crop)
            let mf = view.mediaFrame()
            let layoutOK = abs(mf.width - expected.width) < 0.5 && abs(mf.height - expected.height) < 0.5
            let advanced = t1 > t0 + 0.3 * placement.preset.speed
            record("Placement \(placement.id.title) renders", playing && advanced && layoutOK && view.hasStillImage,
                   "\(placement.preset.scaling.rawValue) at \(placement.preset.speed)×: \(view.state.label), time \(String(format: "%.2f→%.2f", t0, t1)), layout \(Int(mf.width))x\(Int(mf.height)) (C core \(Int(expected.width))x\(Int(expected.height)))")
            view.unload()
            window.close()
        }
        // Play once holds the last frame.
        var once = item.pack.placements[.desktop]!.preset
        once.loops = false
        once.trimStart = 0
        once.trimEnd = 1.0
        once.speed = 2
        let w2 = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        w2.isReleasedWhenClosed = false
        let v2 = PackPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        w2.contentView = v2
        w2.orderFrontRegardless()
        v2.load(preset: once, folder: item.folder)
        let finished = await wait(6) { v2.state == .finished }
        record("Play once holds the last frame", finished, "trim 0–1 s at 2×: \(v2.state.label)")
        // Unplayable → still.
        v2.unload()
        v2.simulatePlaybackFailure = true
        v2.load(preset: item.pack.placements[.desktop]!.preset, folder: item.folder)
        let failed = await wait(3) { if case .failed = v2.state { return true } else { return false } }
        let stillShown = await wait(3) { v2.hasStillImage }
        record("Unplayable video shows the still", failed && stillShown, v2.state.label, simulated: true)
        v2.unload()
        w2.close()
    }

    // MARK: Desktop

    static func ourDesktopWindows() -> [[String: Any]] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let pid = ProcessInfo.processInfo.processIdentifier
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == DesktopWindow.desktopLevel.rawValue }
    }

    static func desktopImages() -> [String] {
        NSScreen.screens.map { NSWorkspace.shared.desktopImageURL(for: $0)?.path ?? "none" }
    }

    static func playingTimes(_ d: DesktopPlayer) -> [Double] { d.windows.values.compactMap { $0.playerView.currentTime } }

    static func advancing(_ d: DesktopPlayer, over seconds: Double = 0.8) async -> Bool {
        let a = playingTimes(d)
        await sleep(seconds)
        let b = playingTimes(d)
        return !a.isEmpty && a.count == b.count && zip(a, b).allSatisfy { $1 > $0 + 0.2 || $1 < $0 - 1 } // a loop may wrap
    }

    static func desktop(_ model: AppModel, cycles: Int) async {
        guard model.selected != nil else { return }
        let d = model.desktop
        let imagesBefore = desktopImages()
        let shotBefore = screenshot("desktop-before")

        model.applySelectedToDesktop()
        let screens = NSScreen.screens
        let playing = await wait(10) { d.status == .playing && d.windows.values.allSatisfy { $0.playerView.state == .playing } }
        record("Apply to Desktop plays on every display", playing && d.windows.count == screens.count,
               "\(d.windows.count) window(s) for \(screens.count) display(s): \(d.windowSummaries.joined(separator: "; "))")
        let framesOK = screens.allSatisfy { s in d.windows[s.displayID]?.frame == s.frame }
        let levelOK = d.windows.values.allSatisfy { $0.level == DesktopWindow.desktopLevel && $0.ignoresMouseEvents && $0.collectionBehavior.contains(.canJoinAllSpaces) }
        record("Desktop windows cover each display at desktop level, ignore the mouse, join all Spaces", framesOK && levelOK,
               "level \(DesktopWindow.desktopLevel.rawValue)")
        let onScreen = ourDesktopWindows()
        record("Window server shows the desktop windows on screen", onScreen.count == screens.count, "\(onScreen.count) on-screen window(s) at the desktop level")
        record("Desktop video advances", await advancing(d), "times \(playingTimes(d).map { String(format: "%.2f", $0) })")
        let shotA = screenshot("desktop-playing-1")
        await sleep(1.0)
        let shotB = screenshot("desktop-playing-2")
        if let before = shotBefore, let a = shotA, let b = shotB {
            let visible = difference(before, a)
            let moving = difference(a, b)
            record("Animation visible on the desktop (screenshots)", visible > 0.05 && moving > 0.002,
                   String(format: "%.1f%% of pixels differ from the normal desktop; %.2f%% change between frames 1 s apart", visible * 100, moving * 100))
        } else {
            skip("Animation visible on the desktop (screenshots)", "screencapture unavailable (Screen Recording permission?)")
        }

        // Menu bar commands.
        d.pause()
        await sleep(0.3)
        let stillAdvancing = await advancing(d)
        let pausedOK = !stillAdvancing && d.status == .paused(reason: "paused from the menu bar")
        d.resume()
        let resumed = await wait(4) { d.status == .playing }
        let advancingAgain = await advancing(d)
        record("Pause and resume (menu bar commands)", pausedOK && resumed && advancingAgain,
               "paused \(pausedOK), resumed \(resumed && advancingAgain)")

        // Display changes (simulated: synthetic second display, removal, resize).
        let main = DisplayTarget.current().first!
        d.displayProvider = { [main, DisplayTarget(id: 0xDEAD, frame: CGRect(x: main.frame.maxX, y: 0, width: 1920, height: 1080), name: "Simulated display")] }
        d.monitor.screensChanged()
        let added = d.windows.count == 2 && d.windows[0xDEAD]?.frame.width == 1920
        let addedPlays = await wait(8) { d.windows[0xDEAD]?.playerView.state == .playing }
        d.displayProvider = { [DisplayTarget(id: main.id, frame: CGRect(x: main.frame.minX, y: main.frame.minY, width: main.frame.width - 200, height: main.frame.height - 100), name: main.name)] }
        d.monitor.screensChanged()
        let removedAndResized = d.windows.count == 1 && d.windows[main.id]?.frame.width == main.frame.width - 200
        d.displayProvider = DisplayTarget.current
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        await sleep(0.3)
        let restored = d.windows.count == NSScreen.screens.count && NSScreen.screens.allSatisfy { d.windows[$0.displayID]?.frame == $0.frame }
        record("Display added, removed and resized", added && addedPlays && removedAndResized && restored,
               "added → \(added && addedPlays), removed+resized → \(removedAndResized), back to real displays → \(restored)", simulated: true)

        // Sleep / wake (simulated with the workspace notifications the app listens to).
        let ws = NSWorkspace.shared.notificationCenter
        ws.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        let paused = await wait(2) { if case .paused = d.status { return true } else { return false } }
        await sleep(9) // decoders are released after 8 s suspended
        let released = d.windows.values.allSatisfy { $0.playerView.currentTime == nil && $0.playerView.hasStillImage }
        ws.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        let woke = await wait(10) { d.status == .playing && d.windows.values.allSatisfy { $0.playerView.state == .playing } }
        let wokeAdvancing = await advancing(d)
        record("Sleep pauses, frees decoders after 8 s; wake resumes", paused && released && woke && wokeAdvancing,
               "paused \(paused), released \(released), resumed \(woke), advancing \(wokeAdvancing)", simulated: true)
        ws.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        let dPaused = await wait(2) { if case .paused = d.status { return true } else { return false } }
        ws.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared)
        let dWoke = await wait(8) { d.status == .playing }
        d.monitor.suspend(.screenLocked)
        let lPaused = await wait(2) { if case .paused = d.status { return true } else { return false } }
        d.monitor.resume(.screenLocked)
        let lWoke = await wait(8) { d.status == .playing }
        record("Displays asleep and screen lock pause and resume", dPaused && dWoke && lPaused && lWoke, d.status.label, simulated: true)

        // Reduce Motion / Low Power / thermal.
        d.monitor.overrideReduceMotion = true
        let rm = await wait(3) { d.status == .still(reason: "Reduce Motion") && d.windows.values.allSatisfy { !$0.playerView.isVideoOnScreen && $0.playerView.hasStillImage } }
        d.monitor.overrideReduceMotion = nil
        d.monitor.overrideLowPower = true
        let lp = await wait(3) { d.status == .still(reason: "Low Power Mode") }
        let savedPlacement = model.placement
        model.placement = .desktop
        model.editPlacement { $0.lowPower = .system }
        let normal = await wait(3) { if case .showingNormalDesktop = d.status { return d.windows.values.allSatisfy { !$0.isVisible } } else { return false } }
        model.editPlacement { $0.lowPower = .still }
        model.placement = savedPlacement
        d.monitor.overrideLowPower = nil
        d.monitor.overrideThermal = true
        let hot = await wait(3) { d.status == .still(reason: "The Mac is hot") }
        d.monitor.overrideThermal = nil
        let back = await wait(8) { d.status == .playing && d.windows.values.allSatisfy { $0.isVisible && $0.playerView.state == .playing } }
        record("Still-frame fallback: Reduce Motion, Low Power (still / normal desktop), heat", rm && lp && normal && hot && back,
               "reduceMotion \(rm), lowPower \(lp), lowPower→normal desktop \(normal), thermal \(hot), back to playing \(back)", simulated: true)

        // Stop restores the normal desktop.
        model.stopDesktop()
        await sleep(0.5)
        let gone = ourDesktopWindows().isEmpty && d.windows.isEmpty && d.status == .stopped
        let imagesAfter = desktopImages()
        record("Stop closes every desktop window", gone, "\(ourDesktopWindows().count) on-screen desktop windows left")
        record("System wallpaper never modified", imagesBefore == imagesAfter, imagesAfter.joined(separator: ", "))
        if let before = shotBefore, let after = screenshot("desktop-after-stop") {
            let diff = difference(before, after)
            record("Normal desktop restored (screenshot matches the one before Apply)", diff < 0.02, String(format: "%.2f%% of pixels differ", diff * 100))
        } else {
            skip("Normal desktop restored (screenshot matches the one before Apply)", "screencapture unavailable")
        }

        // Repeated apply / stop.
        let footprintBefore = footprintMB()
        var weakWindows: [WeakBox] = []
        var allPlayed = true
        var allStopped = true
        for i in 0..<cycles {
            model.applySelectedToDesktop()
            let ok = await wait(10) { d.status == .playing && d.windows.values.allSatisfy { $0.playerView.state == .playing } }
            allPlayed = allPlayed && ok
            weakWindows += d.windows.values.map { WeakBox($0) }
            if i % 2 == 0 { await sleep(0.2) }
            model.stopDesktop()
            allStopped = allStopped && d.windows.isEmpty && d.status == .stopped
        }
        await sleep(1.5)
        let leftOnScreen = ourDesktopWindows().count
        let leaked = weakWindows.filter { $0.object != nil }.count
        let footprintAfter = footprintMB()
        record("Repeated apply/stop ×\(cycles)", allPlayed && allStopped && leftOnScreen == 0 && leaked == 0 && footprintAfter - footprintBefore < 200,
               String(format: "played every time %@, stopped every time %@, windows left %d, window objects alive %d/%d, memory %.0f → %.0f MB",
                      "\(allPlayed)", "\(allStopped)", leftOnScreen, leaked, weakWindows.count, footprintBefore, footprintAfter))
        record("System wallpaper still unchanged after repeated apply/stop", desktopImages() == imagesBefore, "")
    }

    final class WeakBox {
        weak var object: AnyObject?
        init(_ o: AnyObject) { object = o }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    // MARK: Editor lifecycle

    static func editorLifecycle() {
        let a = AppModel.editorCloseAction(keepPlaying: true, desktopActive: true)
        let b = AppModel.editorCloseAction(keepPlaying: false, desktopActive: true)
        let c = AppModel.editorCloseAction(keepPlaying: true, desktopActive: false)
        record("Editor close: keeps playing only when enabled", a == .continueInMenuBar && b == .stopAndQuit && c == .stopAndQuit,
               "enabled+playing → \(a), disabled+playing → \(b), nothing playing → \(c)")
    }

    // MARK: Catalog

    static func catalog(paths: AppPaths) async {
        guard let local = BundledResources.localCatalog else {
            record("Catalog (bundled local catalog)", false, "Samples/catalog.local.json missing")
            return
        }
        let store = CatalogStore(root: paths.root.appendingPathComponent("CatalogTest", isDirectory: true))
        guard case .updated(let snap) = await store.refresh(from: local), let item = snap.catalog.items.first else {
            record("Catalog loads", false, "the local catalog did not load")
            return
        }
        record("Catalog loads (poster, size)", item.name == "HCG Orbital Command" && item.poster != nil,
               "\(item.name), \(formatBytes(item.totalBytes)), poster \(item.poster ?? "-")")
        do {
            let folder = try await store.download(item, catalogURL: local)
            let pack = try AnimationPack.read(contentsOf: folder)
            try pack.verify(in: folder)
            record("Catalog download verified and cached for offline use", store.cachedPack(for: item) == folder, folder.lastPathComponent)
        } catch { record("Catalog download verified and cached for offline use", false, error.localizedDescription) }
        let poster = try? await store.posterData(for: item, catalogURL: local)
        record("Catalog poster loads", poster.flatMap { NSImage(data: $0) } != nil, "\(poster?.count ?? 0) bytes")
        let failed = await store.refresh(from: URL(string: "https://catalog.invalid/hcg/catalog.json")!)
        if case .failed(let error, let kept) = failed {
            record("Failed refresh keeps the previous catalog", kept?.catalog.items.first?.id == item.id, "error: \(error)")
        } else {
            record("Failed refresh keeps the previous catalog", false, "the refresh did not fail")
        }
        let insecure = await store.refresh(from: URL(string: "http://example.com/catalog.json")!)
        if case .failed(let error, _) = insecure { record("Plain HTTP catalog refused", true, error) } else { record("Plain HTTP catalog refused", false, "accepted") }
    }

    // MARK: Screenshots

    static func screenshot(_ name: String) -> CGImage? {
        let dir = screenshotDir ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("\(name).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-m", url.path]
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Fraction of pixels that differ noticeably (images reduced to 320×200; the menu bar strip is ignored).
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: 320 * 200 * 4)
            let ctx = CGContext(data: &buf, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 320 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 320, height: 200))
            return buf
        }
        let pa = pixels(a), pb = pixels(b)
        var differing = 0, total = 0
        for y in 8..<200 { // bitmap row 0 is the top: skip the menu bar strip (clock)
            for x in 0..<320 {
                let i = (y * 320 + x) * 4
                total += 1
                if abs(Int(pa[i]) - Int(pb[i])) > 24 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 24 || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 24 {
                    differing += 1
                }
            }
        }
        return total > 0 ? Double(differing) / Double(total) : 0
    }
}
