//
//  App.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  SwiftUI app with a menu bar control (pause / resume / stop) and a Settings window. The editor window is an AppKit
//  window hosting SwiftUI, so closing it can decide reliably whether the desktop animation keeps playing.
//
//  Command-line options:
//    --self-test [--report file.json] [--screenshots dir]   run the desktop-player checks and exit (CI, hardware check)
//    --open-sample                                          select the HCG Orbital Command sample on launch
//    --no-resume                                            do not resume the last applied animation
//

import AppKit
import HCGAnimationPack
import SwiftUI

extension AppModel {
    static let shared = AppModel()
}

@main
struct HCGAnimationCenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environmentObject(model)
        }
    }

    private var menuIcon: String {
        switch model.desktop.status {
        case .playing: return "play.rectangle.fill"
        case .paused: return "pause.rectangle"
        case .stopped: return "rectangle.on.rectangle"
        default: return "photo.on.rectangle"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    private var editorWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            NSApp.setActivationPolicy(.regular)
            Task { @MainActor in
                let code = await SelfTest.run(arguments: args)
                exit(code)
            }
            return
        }
        let model = AppModel.shared
        EventLog.shared.log("launch \(AppInfo.version) (\(AppInfo.build)) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        model.loadLibrary()
        if args.contains("--open-sample"), let sample = BundledResources.samplePack,
           let id = try? AnimationPack.read(contentsOf: sample).id, model.items.contains(where: { $0.id == id }) {
            model.selectedID = id
        }
        if !args.contains("--no-resume") { model.resumeLastAppliedIfWanted() }
        showEditor()
    }

    @MainActor
    func showEditor() {
        let model = AppModel.shared
        if let w = editorWindow {
            model.editorDidOpen()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: EditorView().environmentObject(model))
        let w = NSWindow(contentViewController: host)
        w.title = "HCG Animation Center"
        w.setContentSize(NSSize(width: 1380, height: 860))
        w.minSize = NSSize(width: 1120, height: 720)
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(red: 8 / 255, green: 12 / 255, blue: 18 / 255, alpha: 1)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("HCGAnimationCenterEditor")
        w.center()
        editorWindow = w
        model.editorDidOpen()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === editorWindow else { return }
        editorWindow = nil
        MainActor.assumeIsolated { AppModel.shared.editorDidClose() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { showEditor() }
        return true
    }

    /// Double-clicked .hcgpack folders (and files dropped on the Dock icon) are imported into the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !Settings.isSelfTest else { return }
        MainActor.assumeIsolated {
            AppModel.shared.loadLibrary()
            AppModel.shared.importFiles(urls)
            showEditor()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // Closing the desktop windows restores the normal desktop (the system wallpaper was never changed).
        MainActor.assumeIsolated {
            if AppModel.shared.desktop.status.isActive {
                AppModel.shared.desktop.stop()
            }
        }
        EventLog.shared.log("quit")
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Toggle("Keep playing on the desktop when the editor closes", isOn: $model.keepPlaying)
            Toggle("Resume the last desktop animation when the app opens", isOn: $model.resumeOnLaunch)
            Toggle("Still frame only (no video anywhere)", isOn: $model.stillOnly)
            LabeledContent("Library", value: model.paths.library.path)
            LabeledContent("Event log", value: model.paths.eventLog.path)
            LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
        }
        .padding(20)
        .frame(width: 560)
    }
}
