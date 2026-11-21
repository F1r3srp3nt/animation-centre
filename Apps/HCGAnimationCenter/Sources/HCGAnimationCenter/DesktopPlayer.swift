//
//  DesktopPlayer.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  Plays a pack's Desktop placement behind the desktop icons on every display.
//
//  How it restores the normal desktop: it never changes the system wallpaper. It draws in its own borderless windows
//  at the desktop window level (below the icons, above the wallpaper), one per display, that ignore the mouse and join
//  every Space. Stop closes those windows, so the unchanged wallpaper shows again — also if the app quits or crashes.
//

import AppKit
import Combine
import HCGAnimationPack
import HCGPackPlayer

/// A display to cover. Real screens in normal use; self-tests can pass synthetic ones.
struct DisplayTarget: Equatable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var name: String

    static func current() -> [DisplayTarget] {
        NSScreen.screens.map { DisplayTarget(id: $0.displayID, frame: $0.frame, name: $0.localizedName) }
    }
}

final class DesktopWindow: NSWindow {
    let playerView = PackPlayerView(frame: .zero)
    let displayID: CGDirectDisplayID
    private var occlusionToken: NSObjectProtocol?
    var onOcclusionChange: ((Bool) -> Void)?

    static var desktopLevel: NSWindow.Level { NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))) }

    init(target: DisplayTarget) {
        displayID = target.id
        super.init(contentRect: target.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = DesktopWindow.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        title = "HCG Animation Center Desktop"
        contentView = playerView
        setFrame(target.frame, display: false)
        occlusionToken = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onOcclusionChange?(self.occlusionState.contains(.visible))
            }
        }
    }

    deinit {
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isOnScreenVisible: Bool { isVisible && occlusionState.contains(.visible) }
}

@MainActor
final class DesktopPlayer: ObservableObject {
    enum Status: Equatable {
        case stopped
        case playing
        case paused(reason: String)
        case still(reason: String)
        /// Low Power policy "system": windows hidden, the normal desktop shows, ready to come back.
        case showingNormalDesktop(reason: String)
        case failed(reason: String)

        var label: String {
            switch self {
            case .stopped: return "Stopped — normal desktop"
            case .playing: return "Playing on the desktop"
            case .paused(let r): return "Paused — \(r)"
            case .still(let r): return "Still frame — \(r)"
            case .showingNormalDesktop(let r): return r
            case .failed(let r): return "Still frame — \(r)"
            }
        }

        var isActive: Bool { self != .stopped }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var appliedPackID: String?
    @Published private(set) var appliedName: String?
    @Published private(set) var displayCount = 0

    let monitor: SystemMonitor
    private(set) var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var current: (pack: AnimationPack, folder: URL)?
    private var userPaused = false
    private var hiddenDisplays: Set<CGDirectDisplayID> = []
    private var cancellables: Set<AnyCancellable> = []
    /// Self-tests replace the real display list.
    var displayProvider: () -> [DisplayTarget] = DisplayTarget.current
    private var releaseTimer: Timer?

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        monitor.$conditions.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluate() } }
        }.store(in: &cancellables)
        monitor.$suspensions.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluate() } }
        }.store(in: &cancellables)
        monitor.onScreensChanged = { [weak self] in self?.syncDisplays(reason: "display configuration changed") }
        monitor.onWake = { [weak self] in self?.syncDisplays(reason: "wake") }
    }

    var desktopPlacement: Placement? { current?.pack.placement(.desktop) ?? current.map { $0.pack.placement($0.pack.defaultPlacement)! } }

    // MARK: Commands

    func apply(pack: AnimationPack, folder: URL) {
        let replacing = current != nil
        current = (pack, folder)
        appliedPackID = pack.id
        appliedName = pack.name
        userPaused = false
        EventLog.shared.log("apply: \(pack.name) [\(pack.id)]\(replacing ? " (replacing)" : "")")
        syncDisplays(reason: "apply")
        for w in windows.values { load(w) }
        evaluate()
    }

    /// Live update after editing the applied pack (no flicker if the clip and trim did not change).
    func update(pack: AnimationPack, folder: URL) {
        guard let current, current.pack.id == pack.id else { return }
        self.current = (pack, folder)
        appliedName = pack.name
        for w in windows.values { load(w) }
        evaluate()
    }

    func pause() {
        guard current != nil else { return }
        userPaused = true
        EventLog.shared.log("pause (user)")
        evaluate()
    }

    func resume() {
        guard current != nil else { return }
        userPaused = false
        EventLog.shared.log("resume (user)")
        evaluate()
    }

    /// Closes every desktop window: the unchanged system wallpaper shows again.
    func stop() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        let count = windows.count
        for w in windows.values { close(w) }
        windows = [:]
        hiddenDisplays = []
        current = nil
        appliedPackID = nil
        appliedName = nil
        userPaused = false
        displayCount = 0
        if status != .stopped { EventLog.shared.log("stop: closed \(count) desktop window(s); normal desktop restored") }
        status = .stopped
    }

    var isPausedByUser: Bool { userPaused }

    // MARK: Displays

    func syncDisplays(reason: String) {
        guard current != nil else { return }
        let targets = displayProvider()
        let ids = Set(targets.map(\.id))
        for (id, w) in windows where !ids.contains(id) {
            close(w)
            windows[id] = nil
            EventLog.shared.log("display \(id) removed (\(reason))")
        }
        for t in targets {
            if let w = windows[t.id] {
                if w.frame != t.frame {
                    w.setFrame(t.frame, display: true)
                    EventLog.shared.log("display \(t.id) resized to \(Int(t.frame.width))x\(Int(t.frame.height)) (\(reason))")
                }
            } else {
                let w = DesktopWindow(target: t)
                w.onOcclusionChange = { [weak self, weak w] visible in
                    guard let self, let w else { return }
                    if visible { self.hiddenDisplays.remove(w.displayID) } else { self.hiddenDisplays.insert(w.displayID) }
                    self.evaluate()
                }
                w.playerView.onStateChange = { [weak self] _ in self?.playerStateChanged() }
                load(w)
                windows[t.id] = w
                EventLog.shared.log("display \(t.id) \(t.name) added \(Int(t.frame.width))x\(Int(t.frame.height)) (\(reason))")
            }
        }
        displayCount = windows.count
        evaluate()
    }

    private func load(_ w: DesktopWindow) {
        guard let current else { return }
        w.playerView.load(pack: current.pack, folder: current.folder, placement: .desktop)
    }

    private func close(_ w: DesktopWindow) {
        w.playerView.onStateChange = nil
        w.playerView.unload()
        w.onOcclusionChange = nil
        w.orderOut(nil)
        w.close()
    }

    // MARK: Policy

    func evaluate() {
        guard let placement = desktopPlacement else { status = .stopped; return }
        let mode = RenderPolicy.mode(for: placement, conditions: monitor.conditions)
        if let s = monitor.suspensions.first {
            // Suspended (sleep, locked, …): pause now, free the decoders if it lasts.
            for w in windows.values { w.playerView.display = .paused }
            status = .paused(reason: s.rawValue)
            scheduleRelease()
            return
        }
        releaseTimer?.invalidate()
        releaseTimer = nil
        switch mode {
        case .none(let reason):
            for w in windows.values { w.playerView.display = .none; w.orderOut(nil) }
            status = .showingNormalDesktop(reason: reason)
            return
        case .still(let reason):
            for w in windows.values {
                w.playerView.stillReason = reason
                w.playerView.display = .still
                w.orderFrontRegardless()
            }
            status = .still(reason: reason)
        case .play:
            for w in windows.values {
                w.orderFrontRegardless()
                if userPaused {
                    w.playerView.display = .paused
                } else {
                    w.playerView.display = hiddenDisplays.contains(w.displayID) ? .paused : .playing
                }
            }
            if userPaused { status = .paused(reason: "paused from the menu bar") } else { status = .playing }
        }
        if let failure = windows.values.compactMap({ w -> String? in
            if case .failed(let r) = w.playerView.state { return r } else { return nil }
        }).first {
            status = .failed(reason: "playback unavailable: \(failure)")
        }
    }

    private var lastFailure: String?

    private func playerStateChanged() {
        let failure = windows.values.compactMap { w -> String? in
            if case .failed(let r) = w.playerView.state { return r } else { return nil }
        }.first
        if let failure {
            if lastFailure != failure { EventLog.shared.log("playback unavailable, showing the still: \(failure)") }
            lastFailure = failure
            status = .failed(reason: "playback unavailable: \(failure)")
        } else if lastFailure != nil {
            lastFailure = nil
            evaluate()
        }
    }

    private func scheduleRelease() {
        guard releaseTimer == nil else { return }
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.monitor.suspensions.isEmpty else { return }
                for w in self.windows.values { w.playerView.releasePlayer(keepState: true) }
                EventLog.shared.log("suspended for 8 s: decoders released")
            }
        }
    }

    // MARK: Inspection (self-test, diagnostics)

    var windowSummaries: [String] {
        windows.values.sorted { $0.displayID < $1.displayID }.map {
            "display \($0.displayID): \(Int($0.frame.width))x\(Int($0.frame.height)) level \($0.level.rawValue) visible \($0.isVisible) player \($0.playerView.state.label)"
        }
    }
}
