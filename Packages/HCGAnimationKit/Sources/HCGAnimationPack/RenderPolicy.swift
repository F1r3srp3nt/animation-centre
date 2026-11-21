//
//  RenderPolicy.swift
//  HCGAnimationPack — Hakmi Capital Group
//
//  What a renderer shows for a placement under the current system conditions. Pure logic shared by the Mac desktop
//  player, the editor preview and the bundled-app player, so every surface decides the same way (and the rules are
//  tested on Linux). Same choices as the iOS tweak: still image, keep playing, or nothing (the system wallpaper).
//

import Foundation

public struct SystemConditions: Equatable, Sendable {
    public var reduceMotion: Bool
    public var lowPower: Bool
    /// ProcessInfo thermal state is .serious or .critical.
    public var thermalPressure: Bool
    /// The user (or the host app) asked for the still only.
    public var forceStill: Bool

    public init(reduceMotion: Bool = false, lowPower: Bool = false, thermalPressure: Bool = false, forceStill: Bool = false) {
        self.reduceMotion = reduceMotion; self.lowPower = lowPower; self.thermalPressure = thermalPressure
        self.forceStill = forceStill
    }
}

public enum RenderMode: Equatable, Sendable {
    case play
    case still(reason: String)
    /// Draw nothing: the normal desktop / the host's own background shows.
    case none(reason: String)

    public var isPlaying: Bool { if case .play = self { return true } else { return false } }
}

public enum RenderPolicy {
    public static func mode(reduceMotionPolicy: MotionPolicy, lowPowerPolicy: PowerPolicy,
                            conditions c: SystemConditions) -> RenderMode {
        if c.forceStill { return .still(reason: "Still frame selected") }
        if c.lowPower {
            switch lowPowerPolicy {
            case .system: return .none(reason: "Low Power Mode: showing the normal background")
            case .still: return .still(reason: "Low Power Mode")
            case .play: break
            }
        }
        if c.reduceMotion, reduceMotionPolicy == .still { return .still(reason: "Reduce Motion") }
        if c.thermalPressure { return .still(reason: "The Mac is hot") }
        return .play
    }

    public static func mode(for placement: Placement, conditions: SystemConditions) -> RenderMode {
        mode(reduceMotionPolicy: placement.reduceMotion, lowPowerPolicy: placement.lowPower, conditions: conditions)
    }
}
