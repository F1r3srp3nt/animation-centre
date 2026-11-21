//
//  EditorView.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  The studio: library on the left, a large live preview of the chosen placement, the trim timeline underneath, the
//  inspector on the right, and a clear Apply to Desktop button.
//

import AppKit
import HCGAnimationPack
import HCGPackPlayer
import SwiftUI
import UniformTypeIdentifiers

enum EditorSection: Hashable {
    case item(String)
    case catalog
    case compatibility
}

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: EditorSection?

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(section: $section)
                .frame(width: 270)
            Divider().overlay(HCG.divider)
            Group {
                switch section {
                case .catalog: CatalogView()
                case .compatibility: CompatibilityView()
                default:
                    if model.selected != nil { PackEditor() } else { EmptyLibraryView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HCG.background)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) { BannerView() }
        .onAppear {
            if section == nil, let id = model.selectedID { section = .item(id) }
        }
        .onChange(of: section) { _, new in
            if case .item(let id) = new { model.selectedID = id }
        }
        .onChange(of: model.selectedID) { _, new in
            if let new, section != .catalog, section != .compatibility { section = .item(new) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedURLs(providers) { model.importFiles($0) }
            return true
        }
    }
}

func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
}

// MARK: - Sidebar

struct LibrarySidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var section: EditorSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [HCG.cyan, HCG.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("HCG").font(.system(size: 11, weight: .heavy)).foregroundStyle(HCG.onAccent)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Animation Center").font(.system(size: 14, weight: .semibold)).foregroundStyle(HCG.text)
                    Text("Hakmi Capital Group").font(.system(size: 10)).foregroundStyle(HCG.textMuted)
                }
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            HStack {
                Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(HCG.textMuted)
                Spacer()
                Button { model.chooseFilesToImport() } label: { Label("Import", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Import MP4, MOV or GIF (or drop files on the window)")
            }
            .padding(.horizontal, 16).padding(.bottom, 6)

            List(selection: $section) {
                ForEach(model.items) { item in
                    LibraryRow(item: item, onDesktop: model.desktop.appliedPackID == item.id)
                        .tag(EditorSection.item(item.id))
                        .contextMenu {
                            Button("Apply to Desktop") { model.selectedID = item.id; model.applySelectedToDesktop() }
                            Button("Export Pack…") { model.exportPack(item) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { model.delete(item) }
                        }
                }
                Section("Online") {
                    Label("Catalog", systemImage: "cloud").tag(EditorSection.catalog)
                    Label("Platform compatibility", systemImage: "square.grid.3x3").tag(EditorSection.compatibility)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            DesktopStatusFooter()
        }
        .background(HCG.backgroundSecondary)
    }
}

struct LibraryRow: View {
    let item: LibraryItem
    let onDesktop: Bool
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(HCG.input)
                if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(onDesktop ? HCG.cyan : HCG.divider, lineWidth: onDesktop ? 1.5 : 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.pack.name).font(.system(size: 12, weight: .medium)).foregroundStyle(HCG.text).lineLimit(1)
                Text("\(Int(item.pack.media.width))×\(Int(item.pack.media.height)) · \(formatSeconds(item.pack.media.duration)) · \(formatBytes(item.pack.totalBytes))")
                    .font(.system(size: 10)).foregroundStyle(HCG.textMuted).lineLimit(1)
                if onDesktop { Text("ON DESKTOP").font(.system(size: 9, weight: .bold)).foregroundStyle(HCG.cyan) }
            }
        }
        .padding(.vertical, 3)
        .task(id: item.posterURL) {
            if let url = item.posterURL { thumb = NSImage(contentsOf: url) }
        }
    }
}

struct DesktopStatusFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusPill(text: model.desktop.status.label, color: model.desktop.status.colour)
            if let name = model.desktop.appliedName {
                Text(name).font(.system(size: 11)).foregroundStyle(HCG.textSecondary).lineLimit(1)
            }
            if model.desktop.status.isActive {
                HStack {
                    if model.desktop.isPausedByUser {
                        Button("Resume") { model.desktop.resume() }.buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Pause") { model.desktop.pause() }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Stop") { model.stopDesktop() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            Toggle("Keep playing when the editor closes", isOn: $model.keepPlaying)
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(HCG.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HCG.background.opacity(0.6))
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(HCG.cyan)
            Text("Import a clip to begin").font(.title2.weight(.semibold)).foregroundStyle(HCG.text)
            Text("MP4, MOV or GIF. Drop files here or choose them.").foregroundStyle(HCG.textSecondary)
            Button("Import…") { model.chooseFilesToImport() }.buttonStyle(PrimaryButtonStyle())
        }
    }
}

struct BannerView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            if let busy = model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(HCG.surface))
            }
            if let b = model.banner {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(b.isError ? HCG.error : HCG.success)
                    Text(b.text).foregroundStyle(HCG.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(HCG.textMuted)
                }
                .padding(12).frame(maxWidth: 560)
                .background(RoundedRectangle(cornerRadius: 10).fill(HCG.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(b.isError ? HCG.error.opacity(0.5) : HCG.divider))
                .task(id: b) {
                    try? await Task.sleep(nanoseconds: b.isError ? 12_000_000_000 : 5_000_000_000)
                    if model.banner == b { model.banner = nil }
                }
            }
        }
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.2), value: model.banner)
    }
}

// MARK: - Pack editor

struct PackEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var previewPlaying = true
    @State private var showStillPreview = false
    @State private var seek: PackPreview.SeekRequest?
    @State private var seekSerial = 0
    @State private var playerState: PlayerState = .empty

    var body: some View {
        if let item = model.selected, let placement = model.selectedPlacement {
            HStack(spacing: 0) {
                VStack(spacing: 14) {
                    header(item)
                    preview(item, placement)
                    TrimTimeline(item: item, placement: placement, playhead: model.playhead,
                                 onScrub: { t in
                                     previewPlaying = false
                                     seekSerial += 1
                                     seek = .init(seconds: t, serial: seekSerial)
                                 },
                                 onTrim: { s, e in model.editPlacement { $0.preset.trimStart = s; $0.preset.trimEnd = e } })
                    transport(item, placement)
                }
                .padding(20)
                Divider().overlay(HCG.divider)
                ScrollView {
                    InspectorPanel(item: item, placement: placement)
                        .padding(16)
                }
                .frame(width: 320)
                .background(HCG.backgroundSecondary)
            }
        }
    }

    @ViewBuilder
    private func header(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Name", text: Binding(get: { item.pack.name }, set: { n in model.editPack { $0.name = String(n.prefix(120)) } }))
                .textFieldStyle(.plain).font(.system(size: 20, weight: .semibold)).foregroundStyle(HCG.text)
            Text("\(item.pack.media.file) · \(Int(item.pack.media.width))×\(Int(item.pack.media.height)) · \(item.pack.media.codec ?? "video") · \(formatSeconds(item.pack.media.duration)) · muted")
                .font(.system(size: 11)).foregroundStyle(HCG.textMuted).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Picker("Placement", selection: $model.placement) {
            ForEach(PlacementID.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { applyButtons }
            VStack(alignment: .leading, spacing: 8) { applyButtons }
        }
        if model.placement != .desktop {
            Text("Apply to Desktop always uses the Desktop placement.").font(.system(size: 11)).foregroundStyle(HCG.textMuted)
        }
    }

    @ViewBuilder
    private var applyButtons: some View {
        Button {
            model.applySelectedToDesktop()
        } label: {
            Label("Apply to Desktop", systemImage: "display").font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .buttonStyle(PrimaryButtonStyle())
        .keyboardShortcut(.return, modifiers: [.command])
        .help("Plays this pack's Desktop placement behind your desktop icons on every display (⌘↩)")
        if model.desktop.status.isActive {
            Button("Stop Desktop") { model.stopDesktop() }.buttonStyle(SecondaryButtonStyle()).fixedSize()
        }
        StatusPill(text: model.desktop.status.label, color: model.desktop.status.colour).fixedSize()
    }

    private func canvasAspect(_ placement: Placement) -> CGFloat {
        if placement.id == .desktop, let screen = NSScreen.main { return screen.frame.width / screen.frame.height }
        if let c = placement.canvas { return CGFloat(c.width / c.height) }
        return 16 / 9
    }

    @ViewBuilder
    private func preview(_ item: LibraryItem, _ placement: Placement) -> some View {
        let mode = RenderPolicy.mode(for: placement, conditions: model.monitor.conditions)
        let forcedStill: String? = showStillPreview ? "Still preview" : {
            if case .still(let r) = mode { return r }
            return nil
        }()
        GeometryReader { geo in
            let aspect = canvasAspect(placement)
            let size = fit(aspect: aspect, in: geo.size)
            ZStack {
                PackPreview(preset: placement.preset, folder: item.folder,
                            display: forcedStill != nil ? .still : (previewPlaying ? .playing : .paused),
                            stillReason: forcedStill ?? "",
                            onTime: { t in model.playhead.time = t },
                            onState: { s in playerState = s },
                            seekRequest: seek)
                PlacementChrome(placement: placement.id)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(HCG.cyan.opacity(0.35)))
            .shadow(color: HCG.cyan.opacity(0.12), radius: 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    StatusPill(text: "\(placement.id.title) preview · \(playerState.label)", color: playerState.showsVideo ? HCG.success : HCG.blue)
                    if case .none(let r) = mode { StatusPill(text: r, color: HCG.warning) }
                }
                .padding(8)
            }
        }
        .frame(minHeight: 300)
    }

    private func fit(aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let w = min(size.width, size.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }

    @ViewBuilder
    private func transport(_ item: LibraryItem, _ placement: Placement) -> some View {
        HStack(spacing: 10) {
            Button { previewPlaying.toggle() } label: {
                Image(systemName: previewPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.space, modifiers: [])
            PlayheadLabel(playhead: model.playhead)
            Toggle("Preview still frame", isOn: $showStillPreview).toggleStyle(.checkbox).font(.system(size: 11))
            Spacer()
            Button {
                model.setPoster(at: model.playhead.time)
            } label: { Label("Set Poster Frame Here", systemImage: "photo") }
                .buttonStyle(SecondaryButtonStyle())
                .help("Uses the frame at the playhead as the pack's poster and still fallback")
        }
    }
}

struct PlayheadLabel: View {
    @ObservedObject var playhead: Playhead
    var body: some View {
        Text(formatSeconds(playhead.time)).monospacedDigit().font(.system(size: 12)).foregroundStyle(HCG.textSecondary)
            .frame(width: 70, alignment: .leading)
    }
}

/// Light overlays that show how a placement is used (illustrative, drawn above the preview).
struct PlacementChrome: View {
    let placement: PlacementID
    var body: some View {
        switch placement {
        case .desktop:
            VStack {
                HStack { Spacer(); Text("Desktop").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).padding(6) }
                Spacer()
            }
        case .appBackground:
            VStack(spacing: 10) {
                Spacer()
                ForEach(["Dashboard", "Portfolio", "Settings"], id: \.self) { t in
                    Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(HCG.onAccent)
                        .frame(maxWidth: 180).padding(.vertical, 8)
                        .background(Capsule().fill(HCG.cyan.opacity(0.9)))
                }
                Spacer().frame(height: 30)
            }
        case .banner:
            HStack {
                VStack(alignment: .leading) {
                    Text("HCG").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                    Text("Banner").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                }
                .padding(12)
                Spacer()
            }
        case .loadingScreen:
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small).tint(.white)
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                Spacer().frame(height: 24)
            }
        }
    }
}

// MARK: - Trim timeline

struct TrimTimeline: View {
    let item: LibraryItem
    let placement: Placement
    @ObservedObject var playhead: Playhead
    let onScrub: (Double) -> Void
    let onTrim: (Double, Double) -> Void

    @State private var thumbs: [CGImage] = []
    @State private var dragStart: Double?
    @State private var dragEnd: Double?

    private var duration: Double { item.pack.media.duration }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let start = dragStart ?? placement.preset.trimStart
                let end = dragEnd ?? placement.preset.trimEnd
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(max(thumbs.count, 1)), height: 54).clipped()
                        }
                    }
                    .frame(width: w, height: 54).background(HCG.input)
                    // dim outside the trim
                    Rectangle().fill(.black.opacity(0.6)).frame(width: x(start, w), height: 54)
                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, w - x(end, w)), height: 54).offset(x: x(end, w))
                    // trim frame
                    RoundedRectangle(cornerRadius: 4).stroke(HCG.cyan, lineWidth: 2)
                        .frame(width: max(2, x(end, w) - x(start, w)), height: 54).offset(x: x(start, w))
                    handle.offset(x: x(start, w) - 6)
                        .gesture(DragGesture().onChanged { v in
                            dragStart = clamp(t(v.location.x, w), 0, end - Layout.minClipSeconds)
                        }.onEnded { _ in commit() })
                    handle.offset(x: x(end, w) - 6)
                        .gesture(DragGesture().onChanged { v in
                            dragEnd = clamp(t(v.location.x, w), start + Layout.minClipSeconds, duration)
                        }.onEnded { _ in commit() })
                    // poster marker
                    Image(systemName: "photo.fill").font(.system(size: 9)).foregroundStyle(HCG.warning)
                        .offset(x: x(placement.preset.stillTime, w) - 5, y: -34)
                    // playhead
                    Rectangle().fill(.white).frame(width: 2, height: 64).offset(x: x(playhead.time, w) - 1)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in onScrub(clamp(t(v.location.x, w), 0, duration)) })
            }
            .frame(height: 64)
            HStack {
                Text("Trim \(formatSeconds(dragStart ?? placement.preset.trimStart)) – \(formatSeconds(dragEnd ?? placement.preset.trimEnd))")
                Text("· clip \(formatSeconds(placement.preset.clipDuration)) · plays \(formatSeconds(placement.preset.playbackDuration)) at \(String(format: "%.2g", placement.preset.speed))×")
                Spacer()
                Text("Poster \(formatSeconds(placement.preset.stillTime))")
            }
            .font(.system(size: 11)).foregroundStyle(HCG.textSecondary)
        }
        .task(id: item.mediaURL) {
            thumbs = await PackPlayerFrames.thumbnails(of: item.mediaURL, duration: duration, count: 14, height: 54)
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(HCG.cyan).frame(width: 12, height: 62)
            .overlay(Rectangle().fill(HCG.onAccent).frame(width: 2, height: 18))
    }

    private func x(_ seconds: Double, _ w: CGFloat) -> CGFloat { duration > 0 ? CGFloat(seconds / duration) * w : 0 }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double { w > 0 ? Double(x / w) * duration : 0 }
    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    private func commit() {
        let s = dragStart ?? placement.preset.trimStart
        let e = dragEnd ?? placement.preset.trimEnd
        dragStart = nil
        dragEnd = nil
        onTrim(s, e)
    }
}

// MARK: - Inspector

struct InspectorPanel: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let placement: Placement

    private var preset: BackgroundPreset { placement.preset }
    private var canvas: CanvasSize {
        if placement.id == .desktop, let s = NSScreen.main { return CanvasSize(width: s.frame.width, height: s.frame.height) }
        return placement.canvas ?? CanvasSize(width: preset.mediaWidth, height: preset.mediaHeight)
    }

    var body: some View {
        VStack(spacing: 12) {
            HCGCard(title: "Playback", systemImage: "play.circle") {
                Toggle("Loop", isOn: bind(\.preset.loops)).toggleStyle(.switch)
                Text(preset.loops ? "Repeats the trimmed range." : "Plays once, then holds the last frame.")
                    .font(.system(size: 11)).foregroundStyle(HCG.textMuted)
                LabeledSlider(title: "Speed", value: bind(\.preset.speed), range: Layout.speedRange, step: 0.05,
                              format: { String(format: "%.2f×", $0) })
                HStack {
                    ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { s in
                        Button(String(format: "%g×", s)) { model.editPlacement { $0.preset.speed = s } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "speaker.slash.fill").foregroundStyle(HCG.textMuted)
                    Text("Muted — backgrounds never play sound (format v1).").font(.system(size: 11)).foregroundStyle(HCG.textMuted)
                }
                HStack {
                    numberField("Trim start", bind(\.preset.trimStart))
                    numberField("Trim end", bind(\.preset.trimEnd))
                }
            }

            HCGCard(title: "Framing", systemImage: "crop") {
                Picker("Scaling", selection: Binding(get: { preset.scaling }, set: { s in
                    model.editPlacement { p in
                        p.preset.scaling = s
                        if s == .crop, p.preset.crop == .whole {
                            p.preset.crop = Layout.crop(container: (canvas.width, canvas.height), media: (p.preset.mediaWidth, p.preset.mediaHeight), zoom: 1, centerX: 0.5, centerY: 0.5)
                        }
                    }
                })) {
                    Text("Fill").tag(Scaling.fill)
                    Text("Fit").tag(Scaling.fit)
                    Text("Crop").tag(Scaling.crop)
                }
                .pickerStyle(.segmented)
                if preset.scaling == .crop {
                    let zoom = Layout.zoom(container: (canvas.width, canvas.height), media: (preset.mediaWidth, preset.mediaHeight), crop: preset.crop)
                    LabeledSlider(title: "Zoom", value: Binding(get: { zoom }, set: { z in setCrop(zoom: z) }), range: 1...4, step: 0.01,
                                  format: { String(format: "%.2f×", $0) })
                    LabeledSlider(title: "Horizontal", value: Binding(get: { preset.crop.x + preset.crop.width / 2 }, set: { c in setCrop(centerX: c) }),
                                  range: 0...1, step: 0.005, format: { String(format: "%.0f%%", $0 * 100) })
                    LabeledSlider(title: "Vertical", value: Binding(get: { preset.crop.y + preset.crop.height / 2 }, set: { c in setCrop(centerY: c) }),
                                  range: 0...1, step: 0.005, format: { String(format: "%.0f%%", $0 * 100) })
                }
                if preset.scaling == .fit {
                    ColorPicker("Background colour", selection: Binding(get: { colour(preset.backgroundColor) }, set: { c in
                        model.editPlacement { $0.preset.backgroundColor = hex(c) }
                    }), supportsOpacity: false)
                }
                Text(framingHelp).font(.system(size: 11)).foregroundStyle(HCG.textMuted)
            }

            HCGCard(title: "Still frame fallback", systemImage: "photo") {
                Picker("Reduce Motion", selection: bind(\.reduceMotion)) {
                    Text("Show still frame").tag(MotionPolicy.still)
                    Text("Keep playing").tag(MotionPolicy.play)
                }
                Picker("Low Power Mode", selection: bind(\.lowPower)) {
                    Text("Show still frame").tag(PowerPolicy.still)
                    Text("Keep playing").tag(PowerPolicy.play)
                    Text(placement.id == .desktop ? "Normal desktop" : "Host's own background").tag(PowerPolicy.system)
                }
                Text("The still also shows whenever the video cannot play, while it loads, and when the Mac is hot.")
                    .font(.system(size: 11)).foregroundStyle(HCG.textMuted)
                Toggle("Still frame only (everywhere)", isOn: $model.stillOnly).toggleStyle(.checkbox).font(.system(size: 12))
            }

            HCGCard(title: "Placement", systemImage: "rectangle.3.group") {
                if let c = placement.canvas {
                    Text("Authoring canvas \(Int(c.width))×\(Int(c.height))").font(.system(size: 11)).foregroundStyle(HCG.textMuted)
                }
                Button("Copy these settings to all placements") { model.copyPlacementToAll() }.buttonStyle(SecondaryButtonStyle())
                Button("Export \(placement.id.title) for iOS (.hcgbackground)…") { model.exportForIOS(item, placement: placement.id) }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("An HCG background preset v1 folder that HCG Animation Center on iOS / HCGBackgroundKit reads as-is")
            }

            HCGCard(title: "Animation pack", systemImage: "shippingbox") {
                Text("\(item.pack.placements.count) placements · \(formatBytes(item.pack.totalBytes)) · format v\(AnimationPack.formatVersion)")
                    .font(.system(size: 11)).foregroundStyle(HCG.textSecondary)
                HStack {
                    Button("Export Pack…") { model.exportPack(item) }.buttonStyle(SecondaryButtonStyle())
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }.buttonStyle(SecondaryButtonStyle())
                }
                if !preset.warnings.isEmpty || !item.pack.warnings.isEmpty {
                    ForEach(preset.warnings + item.pack.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(HCG.warning)
                    }
                }
            }
        }
    }

    private var framingHelp: String {
        switch preset.scaling {
        case .fill: return "Covers the whole area, centred; edges may be cut."
        case .fit: return "Shows the whole frame; bars in the background colour."
        case .crop: return "Covers the area with the part of the frame you choose."
        }
    }

    private func bind<T>(_ path: WritableKeyPath<Placement, T>) -> Binding<T> {
        Binding(get: { placement[keyPath: path] }, set: { v in model.editPlacement { $0[keyPath: path] = v } })
    }

    private func setCrop(zoom: Double? = nil, centerX: Double? = nil, centerY: Double? = nil) {
        let media = (preset.mediaWidth, preset.mediaHeight)
        let container = (canvas.width, canvas.height)
        let z = zoom ?? Layout.zoom(container: container, media: media, crop: preset.crop)
        let cx = centerX ?? preset.crop.x + preset.crop.width / 2
        let cy = centerY ?? preset.crop.y + preset.crop.height / 2
        model.editPlacement { $0.preset.crop = Layout.crop(container: container, media: media, zoom: z, centerX: cx, centerY: cy) }
    }

    private func numberField(_ title: String, _ binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(HCG.textMuted)
            TextField(title, value: binding, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder).frame(width: 110)
        }
    }

    private func colour(_ hex: String) -> Color {
        guard let c = parseHexColour(hex) else { return .black }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    private func hex(_ c: Color) -> String {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(HCG.text)
                Spacer()
                Text(format(value)).font(.system(size: 11)).monospacedDigit().foregroundStyle(HCG.textSecondary)
            }
            Slider(value: $value, in: range, step: step).tint(HCG.cyan)
        }
    }
}
