//
//  PackPlayerView.swift
//  HCGPackPlayer — Hakmi Capital Group
//
//  The macOS renderer for an HCG background preset / animation-pack placement. One AVPlayerLayer plus a still layer,
//  laid out with the shared C geometry (fill / fit / crop) so a placement frames the same on macOS and iOS.
//
//  - Always muted (format v1), never keeps the display awake, never takes mouse events (`hitTest` returns nil), so
//    controls above it stay usable.
//  - Loop: AVPlayerLooper over the trim range. Play once: plays the trim range and holds the last frame.
//  - The still (poster) shows until the first video frame is ready, whenever playback is unavailable, and in `.still`.
//

#if os(macOS)
import AppKit
import AVFoundation
import HCGAnimationPack
import QuartzCore

public enum PlayerDisplay: String, Sendable {
    case playing, paused, still, none
}

public enum PlayerState: Equatable, Sendable {
    case empty
    case loading
    case playing
    case paused
    /// Played once to the end and holding the last frame.
    case finished
    case still(reason: String)
    case hidden
    case failed(reason: String)

    public var label: String {
        switch self {
        case .empty: return "No animation"
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .finished: return "Finished (holding last frame)"
        case .still(let r): return "Still frame — \(r)"
        case .hidden: return "Hidden"
        case .failed(let r): return "Still frame — playback unavailable: \(r)"
        }
    }

    public var showsVideo: Bool {
        switch self {
        case .playing, .paused, .finished: return true
        default: return false
        }
    }
}

@MainActor
public final class PackPlayerView: NSView {
    // MARK: Public

    public var onStateChange: ((PlayerState) -> Void)?
    /// Called about 30 times a second with the source time while `reportsTime` is on (editor playhead).
    public var onTime: ((Double) -> Void)?
    public var reportsTime = false { didSet { updateTimeObserver() } }

    public private(set) var state: PlayerState = .empty {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    public var display: PlayerDisplay = .playing {
        didSet { if display != oldValue { applyDisplay() } }
    }

    /// Why the still is forced (Reduce Motion, Low Power…), shown in `state`.
    public var stillReason = "Still frame selected"

    /// For tests and demos: behave as if the media cannot be played.
    public var simulatePlaybackFailure = false

    public private(set) var preset: BackgroundPreset?
    public private(set) var folder: URL?

    /// Source time of the frame on screen (seconds), or nil without a player.
    public var currentTime: Double? {
        guard let t = player?.currentTime(), t.isValid, t.isNumeric else { return nil }
        return t.seconds
    }

    public var isVideoOnScreen: Bool { !videoLayer.isHidden && videoLayer.isReadyForDisplay && videoLayer.opacity > 0 }
    public var hasStillImage: Bool { stillLayer.contents != nil }

    // MARK: Layers and player

    private let colourLayer = CALayer()
    private let stillLayer = CALayer()
    private let videoLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var asset: AVURLAsset?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var generation = 0
    private var stillTask: Task<Void, Never>?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        let root = CALayer()
        root.masksToBounds = true
        root.backgroundColor = NSColor.clear.cgColor
        layer = root
        layerContentsRedrawPolicy = .never
        let noAnimation: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                                               "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        for l in [colourLayer, stillLayer, videoLayer] as [CALayer] {
            l.actions = noAnimation
            root.addSublayer(l)
        }
        stillLayer.contentsGravity = .resize
        videoLayer.videoGravity = .resize
        videoLayer.isHidden = true
        colourLayer.isHidden = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var acceptsFirstResponder: Bool { false }
    public override var mouseDownCanMoveWindow: Bool { true }

    // MARK: Loading

    /// Shows a placement of an animation pack.
    public func load(pack: AnimationPack, folder: URL, placement: PlacementID) {
        guard let preset = pack.exportedPreset(placement) ?? pack.exportedPreset(pack.defaultPlacement) else { return }
        load(preset: preset, folder: folder)
    }

    /// Shows a background preset whose files are in `folder`.
    public func load(preset: BackgroundPreset, folder: URL) {
        let sameMedia = self.preset?.mediaFile == preset.mediaFile && self.folder == folder && asset != nil
        let samePlayback = sameMedia && self.preset.map { Self.samePlayback($0, preset) } == true
        let sameStill = self.preset?.stillFile == preset.stillFile && self.preset?.stillTime == preset.stillTime && self.folder == folder
        self.preset = preset
        self.folder = folder
        applyColour()
        if !sameStill || stillLayer.contents == nil { loadStill() }
        needsLayout = true
        layoutLayers()
        if samePlayback { applyDisplay(); return }
        releasePlayer(keepState: true)
        applyDisplay()
    }

    /// Removes the player and the still.
    public func unload() {
        releasePlayer(keepState: true)
        stillTask?.cancel()
        stillLayer.contents = nil
        preset = nil
        folder = nil
        colourLayer.isHidden = true
        state = .empty
    }

    /// Frees the decoder (the still stays). The next `.playing` builds it again.
    public func releasePlayer(keepState: Bool = false) {
        generation += 1
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        videoLayer.player = nil
        videoLayer.isHidden = true
        asset = nil
        if !keepState { showStillState(stillReason) }
    }

    static func samePlayback(_ a: BackgroundPreset, _ b: BackgroundPreset) -> Bool {
        a.mediaFile == b.mediaFile && a.trimStart == b.trimStart && a.trimEnd == b.trimEnd && a.loops == b.loops
    }

    // MARK: Display

    private func applyDisplay() {
        guard let preset, let folder else { state = .empty; return }
        // Speed and layout can change without rebuilding the player.
        player?.defaultRate = Float(preset.speed)
        if display == .playing, let player, player.rate != 0 { player.rate = Float(preset.speed) }
        switch display {
        case .none:
            releasePlayer(keepState: true)
            stillLayer.isHidden = true
            colourLayer.isHidden = true
            state = .hidden
        case .still:
            releasePlayer(keepState: true)
            stillLayer.isHidden = false
            applyColour()
            showStillState(stillReason)
        case .playing, .paused:
            stillLayer.isHidden = false
            applyColour()
            if player == nil { buildPlayer(preset: preset, folder: folder) }
            guard let player else { return }
            if display == .playing {
                if state == .finished, !preset.loops { restartOnce() }
                player.play()
            } else {
                player.pause()
            }
            refreshState()
        }
    }

    private func showStillState(_ reason: String) {
        if case .failed = state, display != .still { return }
        state = .still(reason: reason)
        videoLayer.isHidden = true
        stillLayer.isHidden = false
    }

    private func refreshState() {
        guard let player else { return }
        if case .failed = state { return }
        if state == .finished { return }
        if !videoLayer.isReadyForDisplay { state = .loading; return }
        state = display == .playing && player.timeControlStatus != .paused ? .playing : .paused
    }

    private func fail(_ reason: String) {
        releasePlayer(keepState: true)
        stillLayer.isHidden = false
        applyColour()
        state = .failed(reason: reason)
    }

    // MARK: Player

    private func buildPlayer(preset: BackgroundPreset, folder: URL) {
        guard let url = preset.mediaURL(in: folder), FileManager.default.isReadableFile(atPath: url.path) else {
            fail("the video file is missing")
            return
        }
        if simulatePlaybackFailure {
            fail("simulated")
            return
        }
        generation += 1
        let gen = generation
        state = .loading
        let asset = AVURLAsset(url: url)
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        let start = CMTime(seconds: preset.trimStart, preferredTimescale: 600)
        let end = CMTime(seconds: preset.trimEnd, preferredTimescale: 600)
        let range = CMTimeRange(start: start, end: end)
        let qp = AVQueuePlayer()
        qp.isMuted = true
        qp.volume = 0
        qp.preventsDisplaySleepDuringVideoPlayback = false
        qp.actionAtItemEnd = preset.loops ? .advance : .pause
        qp.defaultRate = Float(preset.speed)
        if preset.loops {
            let looper = AVPlayerLooper(player: qp, templateItem: item, timeRange: range)
            self.looper = looper
            observations.append(looper.observe(\.status, options: [.new]) { [weak self] l, _ in
                let failed = l.status == .failed
                let message = l.error?.localizedDescription ?? "the video could not be decoded"
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen, failed else { return }
                    self.fail(message)
                }
            })
        } else {
            item.forwardPlaybackEndTime = end
            qp.insert(item, after: nil)
            qp.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.player?.pause()
                    self.state = .finished
                }
            }
            observations.append(item.observe(\.status, options: [.new]) { [weak self] i, _ in
                let failed = i.status == .failed
                let message = i.error?.localizedDescription ?? "the video could not be decoded"
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen, failed else { return }
                    self.fail(message)
                }
            })
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil,
                                                              queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen, let item = note.object as? AVPlayerItem,
                      item.asset === self.asset || self.player?.items().contains(item) == true else { return }
                self.fail(message ?? "playback stopped")
            }
        }
        observations.append(videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.videoLayer.isHidden = !ready
                self.refreshState()
            }
        })
        observations.append(qp.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.refreshState()
            }
        })
        player = qp
        videoLayer.player = qp
        layoutLayers()
        updateTimeObserver()
    }

    private func restartOnce() {
        guard let preset, let player else { return }
        state = .loading
        player.seek(to: CMTime(seconds: preset.trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Editor scrubbing: shows the frame at `seconds` (pauses).
    public func seek(to seconds: Double) {
        guard let player else { return }
        display = .paused
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Restarts from the trim start (e.g. after the trim changed).
    public func restart() {
        guard preset != nil else { return }
        releasePlayer(keepState: true)
        applyDisplay()
    }

    private func updateTimeObserver() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        guard reportsTime, let player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            let s = t.seconds
            Task { @MainActor [weak self] in self?.onTime?(s) }
        }
    }

    // MARK: Still

    private func loadStill() {
        stillTask?.cancel()
        guard let preset, let folder else { return }
        if let url = preset.stillURL(in: folder), let image = Self.loadImage(url) {
            stillLayer.contents = image
            return
        }
        // No still file: take the frame at stillTime from the video.
        guard let media = preset.mediaURL(in: folder) else { return }
        let time = preset.stillTime
        stillTask = Task { [weak self] in
            let image = await Self.frame(of: media, at: time)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.stillLayer.contents = image }
        }
    }

    nonisolated static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A frame of a video at a time (exact), or nil.
    public nonisolated static func frame(of url: URL, at seconds: Double, maximumSize: CGSize = .zero) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = maximumSize
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: Layout

    private func applyColour() {
        guard let preset else { colourLayer.isHidden = true; return }
        if let c = parseHexColour(preset.backgroundColor) {
            colourLayer.backgroundColor = CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        }
        colourLayer.isHidden = display == .none
    }

    public override func layout() {
        super.layout()
        layoutLayers()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [stillLayer, videoLayer] as [CALayer] { l.contentsScale = scale }
    }

    /// The rectangle (in view coordinates, bottom-left origin) the whole media frame is drawn in.
    public func mediaFrame() -> CGRect {
        guard let preset else { return bounds }
        let r = Layout.frame(container: (Double(bounds.width), Double(bounds.height)),
                             media: (preset.mediaWidth, preset.mediaHeight), scaling: preset.scaling, crop: preset.crop)
        // The C core uses a top-left origin; layers here use bottom-left.
        return CGRect(x: r.x, y: Double(bounds.height) - r.y - r.height, width: r.width, height: r.height)
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colourLayer.frame = bounds
        let f = mediaFrame()
        stillLayer.frame = f
        videoLayer.frame = f
        CATransaction.commit()
    }
}
#endif
