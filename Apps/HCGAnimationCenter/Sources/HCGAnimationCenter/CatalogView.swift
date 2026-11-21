//
//  CatalogView.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//

import AppKit
import HCGAnimationPack
import SwiftUI

struct CatalogView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var catalog: CatalogModel

    init() { catalog = AppModel.shared.catalog }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(catalog.snapshot?.catalog.title ?? "HCG Animation Catalog").font(.system(size: 20, weight: .semibold)).foregroundStyle(HCG.text)
                    Text(catalog.isUsingLocalCatalog
                         ? "Local catalog: the supplied clip, until you choose where to host it."
                         : "Online catalog over HTTPS. Downloads are verified and kept for offline use.")
                        .font(.system(size: 12)).foregroundStyle(HCG.textSecondary)
                }
                Spacer()
                Button {
                    Task { await catalog.refresh() }
                } label: {
                    if catalog.refreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            HCGCard(title: "Catalog URL", systemImage: "link") {
                HStack {
                    TextField("https://…/catalog.json", text: $catalog.catalogURLString)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await catalog.refresh() } }
                    Button("Use bundled") { catalog.useBundledCatalog(); Task { await catalog.refresh() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Text("HTTPS only (or a local file before hosting). A failed refresh keeps showing the last catalog that loaded.")
                    .font(.system(size: 11)).foregroundStyle(HCG.textMuted)
            }

            if let error = catalog.refreshError {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(HCG.warning)
                    Text("Couldn't refresh: \(error).") + Text(catalog.snapshot.map { " Showing the catalog loaded \($0.loaded.formatted(date: .abbreviated, time: .shortened))." } ?? "")
                }
                .font(.system(size: 12)).foregroundStyle(HCG.text)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(HCG.warning.opacity(0.12)))
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16)], spacing: 16) {
                    ForEach(catalog.snapshot?.catalog.items ?? []) { item in
                        CatalogCard(item: item, catalog: catalog)
                    }
                }
                if catalog.snapshot == nil, !catalog.refreshing {
                    Text("No catalog loaded yet. Press Refresh.").foregroundStyle(HCG.textMuted).padding(.top, 40)
                }
            }
        }
        .padding(24)
        .task { if catalog.snapshot == nil { await catalog.refresh() } else { await catalog.loadPosters() } }
    }
}

struct CatalogCard: View {
    let item: CatalogItem
    @ObservedObject var catalog: CatalogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Rectangle().fill(HCG.input)
                if let poster = catalog.posters[item.id] {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(HCG.textMuted)
                }
            }
            .frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HCG.text)
            if let s = item.summary { Text(s).font(.system(size: 12)).foregroundStyle(HCG.textSecondary) }
            HStack(spacing: 12) {
                Label(formatBytes(item.totalBytes), systemImage: "arrow.down.circle")
                if let w = item.width, let h = item.height { Label("\(Int(w))×\(Int(h))", systemImage: "aspectratio") }
                if let d = item.duration { Label(formatSeconds(d), systemImage: "clock") }
            }
            .font(.system(size: 11)).foregroundStyle(HCG.textSecondary)

            if let p = catalog.progress[item.id] {
                ProgressView(value: p).tint(HCG.cyan)
            } else if catalog.isCached(item) {
                HStack {
                    Label("Downloaded · verified · available offline", systemImage: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(HCG.success)
                    Spacer()
                    Button("Add to Library") { catalog.addToLibrary(item, apply: false) }.buttonStyle(SecondaryButtonStyle())
                    Button("Apply to Desktop") { catalog.addToLibrary(item, apply: true) }.buttonStyle(PrimaryButtonStyle())
                }
            } else if !item.isHosted {
                Label("Not hosted yet — fill in this item's baseURL in the catalog.", systemImage: "icloud.slash")
                    .font(.system(size: 11)).foregroundStyle(HCG.warning)
            } else {
                Button {
                    Task { await catalog.download(item) }
                } label: { Label("Download \(formatBytes(item.totalBytes))", systemImage: "arrow.down") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            if let e = catalog.itemErrors[item.id] {
                Text(e).font(.system(size: 11)).foregroundStyle(HCG.error)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(HCG.surface.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HCG.divider))
    }
}

struct CompatibilityView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Where a pack can play").font(.system(size: 20, weight: .semibold)).foregroundStyle(HCG.text)
                Text("What each platform can actually render today. Only macOS is implemented in this milestone; the others are planned adapters.")
                    .font(.system(size: 12)).foregroundStyle(HCG.textSecondary)
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Platform").bold()
                        ForEach(PlatformSupport.columns, id: \.id) { Text($0.title).bold() }
                    }
                    .font(.system(size: 12)).foregroundStyle(HCG.textSecondary)
                    ForEach(PlatformSupport.matrix, id: \.platform) { p in
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.platform).font(.system(size: 12, weight: .semibold)).foregroundStyle(HCG.text)
                                Text(p.adapter).font(.system(size: 10)).foregroundStyle(HCG.textMuted)
                            }
                            .frame(width: 200, alignment: .leading)
                            ForEach(PlatformSupport.columns, id: \.id) { col in
                                let cell = p.cells[col.id]
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cell?.level.symbol ?? "—").font(.system(size: 14))
                                    Text(cell?.note ?? "").font(.system(size: 10)).foregroundStyle(HCG.textSecondary)
                                }
                                .frame(width: 150, alignment: .leading)
                            }
                        }
                        Divider().overlay(HCG.divider).gridCellColumns(PlatformSupport.columns.count + 1)
                    }
                }
                Text("✅ renders (verified here) · 🟡 renderer exists, pack adapter or device test pending · 🗺️ adapter planned · ⛔ not possible for third-party software · 🔬 research milestone")
                    .font(.system(size: 11)).foregroundStyle(HCG.textMuted)
            }
            .padding(24)
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text(model.desktop.status.label)
        if let name = model.desktop.appliedName { Text(name) }
        Divider()
        if model.desktop.status.isActive {
            if model.desktop.isPausedByUser {
                Button("Resume") { model.desktop.resume() }.keyboardShortcut("p")
            } else {
                Button("Pause") { model.desktop.pause() }.keyboardShortcut("p")
            }
            Button("Stop and Restore Desktop") { model.stopDesktop() }.keyboardShortcut("s")
        } else if let item = model.selected {
            Button("Apply “\(item.pack.name)” to Desktop") { model.applySelectedToDesktop() }
        }
        Divider()
        Toggle("Keep Playing When the Editor Closes", isOn: $model.keepPlaying)
        Toggle("Still Frame Only", isOn: $model.stillOnly)
        Toggle("Resume on Launch", isOn: $model.resumeOnLaunch)
        Divider()
        Button("Open Editor…") { AppDelegate.shared?.showEditor() }.keyboardShortcut("e")
        Button("Show Event Log") { NSWorkspace.shared.open(model.paths.eventLog) }
        Divider()
        Button("Quit HCG Animation Center") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
