//
//  SystemMonitor.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  Watches what decides how the desktop animation behaves: Reduce Motion, Low Power Mode, thermal state, sleep and
//  wake, displays asleep, screen lock / fast user switching, screen saver, and display configuration changes.
//  Self-tests can override the conditions (they cannot toggle the real system settings).
//

import AppKit
import Combine
import Foundation
import HCGAnimationPack

@MainActor
final class SystemMonitor: ObservableObject {
    /// Why playback is suspended right now (empty = not suspended).
    enum Suspension: String, CaseIterable {
        case systemSleep = "the Mac is asleep"
        case displaysAsleep = "the displays are asleep"
        case sessionInactive = "another user session is active"
        case screenLocked = "the screen is locked"
        case screenSaver = "the screen saver is running"
    }

    @Published private(set) var conditions = SystemConditions()
    @Published private(set) var suspensions: Set<Suspension> = []
    /// Increments on every display configuration change.
    @Published private(set) var screenConfigurationGeneration = 0

    /// Test overrides (nil = read the system).
    var overrideReduceMotion: Bool? { didSet { refresh() } }
    var overrideLowPower: Bool? { didSet { refresh() } }
    var overrideThermal: Bool? { didSet { refresh() } }
    @Published var forceStill = false { didSet { refresh() } }

    var onWake: (() -> Void)?
    var onScreensChanged: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { body(note) }
            }
        }

        tokens.append(on(nc, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.screensChanged() })
        tokens.append(on(nc, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] _ in self?.refresh(log: true) })
        tokens.append(on(nc, ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in self?.refresh(log: true) })

        workspaceTokens.append(on(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in self?.refresh(log: true) })
        workspaceTokens.append(on(ws, NSWorkspace.willSleepNotification) { [weak self] _ in self?.suspend(.systemSleep) })
        workspaceTokens.append(on(ws, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.resume(.systemSleep)
            self?.onWake?()
        })
        workspaceTokens.append(on(ws, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.suspend(.displaysAsleep) })
        workspaceTokens.append(on(ws, NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            self?.resume(.displaysAsleep)
            self?.onWake?()
        })
        workspaceTokens.append(on(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.suspend(.sessionInactive) })
        workspaceTokens.append(on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.resume(.sessionInactive) })

        distributedTokens.append(on(dnc, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.suspend(.screenLocked) })
        distributedTokens.append(on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.resume(.screenLocked) })
        distributedTokens.append(on(dnc, Notification.Name("com.apple.screensaver.didstart")) { [weak self] _ in self?.suspend(.screenSaver) })
        distributedTokens.append(on(dnc, Notification.Name("com.apple.screensaver.didstop")) { [weak self] _ in self?.resume(.screenSaver) })
        refresh()
    }

    deinit {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        tokens.forEach { nc.removeObserver($0) }
        workspaceTokens.forEach { ws.removeObserver($0) }
        distributedTokens.forEach { dnc.removeObserver($0) }
    }

    func refresh(log: Bool = false) {
        let info = ProcessInfo.processInfo
        let thermal = info.thermalState == .serious || info.thermalState == .critical
        let next = SystemConditions(
            reduceMotion: overrideReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: overrideLowPower ?? info.isLowPowerModeEnabled,
            thermalPressure: overrideThermal ?? thermal,
            forceStill: forceStill)
        if next != conditions {
            if log {
                EventLog.shared.log("conditions: reduceMotion=\(next.reduceMotion) lowPower=\(next.lowPower) thermal=\(next.thermalPressure) stillOnly=\(next.forceStill)")
            }
            conditions = next
        }
    }

    func suspend(_ s: Suspension) {
        guard !suspensions.contains(s) else { return }
        suspensions.insert(s)
        EventLog.shared.log("suspend: \(s.rawValue)")
    }

    func resume(_ s: Suspension) {
        guard suspensions.contains(s) else { return }
        suspensions.remove(s)
        EventLog.shared.log("resume: \(s.rawValue) cleared")
    }

    func screensChanged() {
        screenConfigurationGeneration += 1
        let desc = NSScreen.screens.map { "\($0.displayID):\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)x" }
        EventLog.shared.log("displays changed: \(desc.joined(separator: ", "))")
        onScreensChanged?()
    }
}
