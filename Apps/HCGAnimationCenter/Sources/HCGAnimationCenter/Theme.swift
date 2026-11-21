//
//  Theme.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  HCG brand tokens (same values as HCG Executable Maker's "HCG Future" theme).
//

import AppKit
import HCGAnimationPack
import HCGPackPlayer
import SwiftUI

enum HCG {
    static let background = Color(hex: 0x080C12)
    static let backgroundSecondary = Color(hex: 0x101722)
    static let surface = Color(hex: 0x182331)
    static let input = Color(hex: 0x0D141E)
    static let cyan = Color(hex: 0x00D9FF)
    static let blue = Color(hex: 0x178BFF)
    static let silver = Color(hex: 0xD9E2EB)
    static let text = Color(hex: 0xF3F7FB)
    static let textSecondary = Color(hex: 0x98A9BA)
    static let textMuted = Color(hex: 0x64778B)
    static let success = Color(hex: 0x27D6A0)
    static let warning = Color(hex: 0xF0B94D)
    static let error = Color(hex: 0xF16B75)
    static let onAccent = Color(hex: 0x04121A)
    static let divider = Color(hex: 0xD9E2EB).opacity(0.12)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

struct HCGCard<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(HCG.cyan) }
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(HCG.textSecondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(HCG.surface.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HCG.divider))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = HCG.cyan
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HCG.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(configuration.isPressed ? 0.75 : 1)))
            .shadow(color: tint.opacity(0.35), radius: configuration.isPressed ? 2 : 10)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(HCG.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(HCG.surface.opacity(configuration.isPressed ? 1 : 0.85)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(HCG.divider))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).shadow(color: color, radius: 3)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(HCG.text).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(HCG.backgroundSecondary))
        .overlay(Capsule().stroke(color.opacity(0.4)))
    }
}

extension DesktopPlayer.Status {
    var colour: Color {
        switch self {
        case .stopped: return HCG.textMuted
        case .playing: return HCG.success
        case .paused: return HCG.warning
        case .still, .showingNormalDesktop: return HCG.blue
        case .failed: return HCG.error
        }
    }
}

/// SwiftUI wrapper of the shared renderer (HCGPackPlayer.PackPlayerView).
struct PackPreview: NSViewRepresentable {
    var preset: BackgroundPreset
    var folder: URL
    var display: PlayerDisplay
    var stillReason: String
    var onTime: ((Double) -> Void)?
    var onState: ((PlayerState) -> Void)?
    var seekRequest: SeekRequest?

    struct SeekRequest: Equatable {
        var seconds: Double
        var serial: Int
    }

    final class Coordinator {
        var lastSeekSerial = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PackPlayerView {
        let v = PackPlayerView(frame: .zero)
        v.reportsTime = true
        return v
    }

    func updateNSView(_ v: PackPlayerView, context: Context) {
        v.onTime = onTime
        v.onStateChange = onState
        v.stillReason = stillReason
        if v.preset != preset || v.folder != folder { v.load(preset: preset, folder: folder) }
        if let seekRequest, seekRequest.serial != context.coordinator.lastSeekSerial {
            context.coordinator.lastSeekSerial = seekRequest.serial
            v.seek(to: seekRequest.seconds)
        } else {
            v.display = display
        }
    }

    static func dismantleNSView(_ v: PackPlayerView, coordinator: Coordinator) {
        v.onTime = nil
        v.onStateChange = nil
        v.unload()
    }
}
