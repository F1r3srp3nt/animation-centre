//
//  HCGPackDemoApp.swift
//  HCG Pack Demo — Hakmi Capital Group
//
//  Shows the App Background placement of the bundled HCG animation pack behind ordinary controls.
//   - Offline: the pack is read from Contents/Resources; this app makes no network requests.
//   - If playback is unavailable (or the pack is missing/damaged), it shows the still, or its plain background.
//   - The background never takes clicks (PackPlayerView.hitTest returns nil), so every control stays usable.
//
//  Every launch writes a short report to $TMPDIR/hcg-pack-demo.txt. With --self-check it also clicks its own button
//  and toggle through the window's normal event path, then quits. --simulate-playback-failure forces the still.
//

import AppKit
import HCGPackPlayer
import SwiftUI

@main
struct HCGPackDemoApp: App {
    @StateObject private var model = DemoModel()

    var body: some Scene {
        WindowGroup("HCG Pack Demo") {
            DemoView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
                .task { await model.start() }
        }
        .defaultSize(width: 980, height: 640)
    }
}

@MainActor
final class DemoModel: ObservableObject {
    struct Loaded {
        var pack: AnimationPack
        var folder: URL
        var placement: PlacementID
    }

    @Published var loaded: Loaded?
    @Published var loadProblem: String?
    @Published var playerState: PlayerState = .empty
    @Published var animate = true
    @Published var launches = 0
    @Published var callSign = "ORBITAL-1"
    @Published var panelOpacity = 0.72

    let simulateFailure = CommandLine.arguments.contains("--simulate-playback-failure")
    let selfCheck = CommandLine.arguments.contains("--self-check")
    /// Test hook: play even if the system's Reduce Motion is on (CI runners have it on).
    let ignoreReduceMotion = CommandLine.arguments.contains("--ignore-reduce-motion")
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ignoreReduceMotion }
    weak var playerView: PackPlayerView?
    var buttonFrame: CGRect = .zero   // window coordinates (SwiftUI global space, top-left origin)
    var toggleFrame: CGRect = .zero
    private var report: [String] = []

    /// The project-level opt-in: Info.plist names the bundled pack and placement.
    func locatePack() -> (URL, PlacementID)? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "HCGAnimationPack") as? String,
              BackgroundPreset.isSafeFileName(name),
              let resources = Bundle.main.resourceURL else { return nil }
        let placement = (Bundle.main.object(forInfoDictionaryKey: "HCGAnimationPlacement") as? String).flatMap(PlacementID.init(rawValue:)) ?? .appBackground
        return (resources.appendingPathComponent(name, isDirectory: true), placement)
    }

    func start() async {
        note("app=HCG Pack Demo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        note("bundle=\(Bundle.main.bundlePath)")
        guard let located = locatePack() else {
            loadProblem = "No animation pack declared in Info.plist (HCGAnimationPack): showing the plain background."
            note("pack=not-declared")
            writeReport()
            return
        }
        let (folder, placement) = located
        note("pack.path=\(folder.path.replacingOccurrences(of: Bundle.main.bundlePath + "/", with: ""))")
        do {
            let pack = try AnimationPack.read(contentsOf: folder)
            try pack.verify(in: folder)
            note("pack=loaded id=\(pack.id) name=\(pack.name)")
            note("verify=ok media=\(pack.media.file) sha256=\(pack.media.sha256) bytes=\(pack.media.bytes)")
            note("placement=\(placement.rawValue) scaling=\(pack.placement(placement)?.preset.scaling.rawValue ?? "?")")
            loaded = Loaded(pack: pack, folder: folder, placement: placement)
        } catch {
            loadProblem = "The bundled animation could not be used (\(error.localizedDescription)): showing the plain background."
            note("pack=failed \(error.localizedDescription)")
        }
        note("network=not-used (reads Contents/Resources only)")
        note("simulateFailure=\(simulateFailure)")
        note("reduceMotion.system=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) ignoredForThisRun=\(ignoreReduceMotion)")
        await observePlayback()
    }

    private func observePlayback() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if playerState == .playing { break }
            if case .failed = playerState { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        note("state=\(playerState.label)")
        if playerState == .playing, let v = playerView {
            let t0 = v.currentTime ?? -1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let t1 = v.currentTime ?? -1
            note(String(format: "advanced=%@ t0=%.3f t1=%.3f", t1 > t0 + 0.3 ? "yes" : "no", t0, t1))
        }
        note("still=\(playerView?.hasStillImage == true ? "yes" : "no")")
        note("videoOnScreen=\(playerView?.isVideoOnScreen == true ? "yes" : "no")")
        if selfCheck { await clickControls() }
        note("done=1")
        writeReport()
        if selfCheck {
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }

    /// Clicks the button and the toggle through NSWindow.sendEvent — the same hit-testing path a real click takes —
    /// to prove the background never swallows input.
    private func clickControls() async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = window.contentView else {
            note("click=no-window")
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        func click(_ frame: CGRect, trailing: Bool = false) {
            // SwiftUI global frames are top-left based inside the window's content; AppKit window points are bottom-left.
            // A switch toggles only on the control itself, which sits at the trailing edge of its row.
            let p = NSPoint(x: trailing ? frame.maxX - 14 : frame.midX, y: content.bounds.height - frame.midY)
            let hit = content.hitTest(content.convert(p, from: nil))
            note("hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") isBackground=\(hit is PackPlayerView)")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
        }
        let before = launches
        click(buttonFrame)
        try? await Task.sleep(nanoseconds: 400_000_000)
        note("click=Launch Mission launches=\(before)->\(launches) works=\(launches == before + 1 ? "yes" : "no")")
        let animateBefore = animate
        click(toggleFrame, trailing: true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        note("toggle=Animate background \(animateBefore)->\(animate) works=\(animate != animateBefore ? "yes" : "no") state=\(playerState.label)")
    }

    func note(_ line: String) {
        report.append(line)
        print(line)
    }

    private func writeReport() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hcg-pack-demo.txt")
        try? (report.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

struct DemoView: View {
    @EnvironmentObject var model: DemoModel

    var body: some View {
        ZStack {
            Color(red: 8 / 255, green: 12 / 255, blue: 18 / 255)
            if let loaded = model.loaded, let preset = loaded.pack.exportedPreset(loaded.placement) {
                BackgroundPlayer(preset: preset, folder: loaded.folder, playing: model.animate, simulateFailure: model.simulateFailure)
            }
            controls
        }
        .coordinateSpace(name: "window")
        .ignoresSafeArea()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HCG ORBITAL COMMAND").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
            Text("Mission console — background: bundled HCG animation pack (\(model.loaded?.placement.rawValue ?? "none"))")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
            if let problem = model.loadProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack(spacing: 14) {
                Button("Launch Mission") { model.launches += 1 }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .background(GeometryReader { g in Color.clear.onAppear { model.buttonFrame = g.frame(in: .named("window")) }
                        .onChange(of: g.frame(in: .named("window"))) { _, f in model.buttonFrame = f } })
                Text("Missions launched: \(model.launches)").foregroundStyle(.white).monospacedDigit()
            }
            Toggle("Animate background", isOn: $model.animate)
                .toggleStyle(.switch).foregroundStyle(.white)
                .background(GeometryReader { g in Color.clear.onAppear { model.toggleFrame = g.frame(in: .named("window")) }
                    .onChange(of: g.frame(in: .named("window"))) { _, f in model.toggleFrame = f } })
            HStack {
                Text("Call sign").foregroundStyle(.white)
                TextField("Call sign", text: $model.callSign).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            HStack {
                Text("Panel").foregroundStyle(.white)
                Slider(value: $model.panelOpacity, in: 0.2...1).frame(width: 180)
            }
            Text("Background: \(model.playerState.label)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(model.panelOpacity * 0.6)))
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// The pack's renderer, behind everything; it never takes clicks.
struct BackgroundPlayer: NSViewRepresentable {
    @EnvironmentObject var model: DemoModel
    var preset: BackgroundPreset
    var folder: URL
    var playing: Bool
    var simulateFailure: Bool

    func makeNSView(context: Context) -> PackPlayerView {
        let v = PackPlayerView(frame: .zero)
        v.simulatePlaybackFailure = simulateFailure
        v.stillReason = "Animation off"
        v.onStateChange = { [weak model] s in DispatchQueue.main.async { model?.playerState = s } }
        model.playerView = v
        return v
    }

    func updateNSView(_ v: PackPlayerView, context: Context) {
        if v.preset != preset || v.folder != folder { v.load(preset: preset, folder: folder) }
        v.stillReason = model.reduceMotion ? "Reduce Motion" : "Animation off"
        v.display = playing && !model.reduceMotion ? .playing : .still
    }
}
