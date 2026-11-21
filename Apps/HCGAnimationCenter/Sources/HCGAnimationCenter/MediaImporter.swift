//
//  MediaImporter.swift
//  HCG Animation Center for Mac — Hakmi Capital Group
//
//  Turns a local MP4, MOV or GIF into an animation pack folder:
//   - MP4 / MOV are probed (display size after rotation, duration, codec) and copied unchanged; they always play muted.
//   - GIFs are converted once to H.264 (.mov) with the same frame timing and size rules as the iOS importer
//     (HCGBackgroundCore: hcgbg_gif_frame_delay, hcgbg_even_fit).
//   - A poster frame is written as JPEG.
//  Files that are damaged, unsupported, too long or too large are refused with a reason.
//

import AppKit
import AVFoundation
import Foundation
import HCGAnimationPack
import ImageIO
import UniformTypeIdentifiers

struct MediaInfo: Equatable {
    var width: Double
    var height: Double
    var duration: Double
    var codec: String?
}

enum MediaImporter {
    static let acceptedTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .gif, .movie]

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads the clip's numbers with AVFoundation and checks them against the format's limits.
    static func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
            duration = try await asset.load(.duration)
        } catch {
            throw ImportError(message: "\(url.lastPathComponent) could not be read as a video (\(error.localizedDescription)).")
        }
        guard let track = tracks.first else { throw ImportError(message: "\(url.lastPathComponent) has no video track.") }
        let (natural, transform, formats) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
        let size = natural.applying(transform)
        let w = abs(size.width), h = abs(size.height)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds >= Layout.minClipSeconds else {
            throw ImportError(message: "\(url.lastPathComponent) is shorter than \(Layout.minClipSeconds) s.")
        }
        guard seconds <= Layout.maxSourceSeconds else {
            throw ImportError(message: "\(url.lastPathComponent) is longer than 10 minutes; trim it first.")
        }
        guard Layout.dimensionRange.contains(Double(w)), Layout.dimensionRange.contains(Double(h)) else {
            throw ImportError(message: "\(url.lastPathComponent) is \(Int(w))×\(Int(h)); backgrounds must be 16–8192 pixels per side.")
        }
        var codec: String?
        if let f = formats.first {
            let code = CMFormatDescriptionGetMediaSubType(f)
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
            codec = String(chars).trimmingCharacters(in: .whitespaces)
        }
        // Make sure it can actually be decoded on this Mac.
        let playable = (try? await asset.load(.isPlayable)) ?? false
        guard playable else { throw ImportError(message: "\(url.lastPathComponent) uses a format this Mac cannot play (\(codec ?? "unknown codec")).") }
        return MediaInfo(width: Double(w), height: Double(h), duration: seconds, codec: codec)
    }

    /// Imports a file into a new pack folder inside `library` and returns the folder and the pack.
    static func importFile(_ source: URL, into library: URL) async throws -> (AnimationPack, URL) {
        let ext = source.pathExtension.lowercased()
        let name = source.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        let packID = UUID().uuidString
        let staging = library.appendingPathComponent(".import-\(packID)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let mediaName: String
            let origin: String
            if ext == "gif" {
                mediaName = "media.mov"
                origin = "gif"
                try await convertGIF(source, to: staging.appendingPathComponent(mediaName))
            } else {
                guard ["mp4", "mov", "m4v"].contains(ext) else {
                    throw ImportError(message: "\(source.lastPathComponent): choose an MP4, MOV or GIF file.")
                }
                mediaName = "media.\(ext == "m4v" ? "mp4" : ext)"
                origin = "video"
                try fm.copyItem(at: source, to: staging.appendingPathComponent(mediaName))
            }
            let info = try await probe(staging.appendingPathComponent(mediaName))
            let posterTime = min(1.0, info.duration / 2)
            try await writeStill(of: staging.appendingPathComponent(mediaName), at: posterTime,
                                 to: staging.appendingPathComponent("poster.jpg"))
            let pack = try AnimationPack.assemble(
                in: staging, name: name, mediaFile: mediaName, width: info.width, height: info.height,
                duration: info.duration, origin: origin, codec: info.codec, posterFile: "poster.jpg",
                posterTime: posterTime, generator: ["app": "HCG Animation Center for Mac", "version": .string(AppInfo.version)],
                id: packID)
            try pack.writeManifest(to: staging)
            let destination = library.appendingPathComponent("\(packID).hcgpack", isDirectory: true)
            try fm.moveItem(at: staging, to: destination)
            EventLog.shared.log("import: \(source.lastPathComponent) → \(pack.name) \(Int(info.width))x\(Int(info.height)) \(info.duration)s \(info.codec ?? "?")")
            return (pack, destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Writes the frame at `seconds` as a JPEG.
    static func writeStill(of video: URL, at seconds: Double, to output: URL) async throws {
        guard let image = await PackPlayerFrames.frame(of: video, at: seconds) else {
            throw ImportError(message: "A still frame could not be taken from the video.")
        }
        try writeJPEG(image, to: output)
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.86) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError(message: "The still could not be written.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImportError(message: "The still could not be written.") }
    }

    // MARK: GIF → H.264

    static func convertGIF(_ source: URL, to output: URL) async throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ImportError(message: "\(source.lastPathComponent) is not a readable GIF.")
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0, let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImportError(message: "\(source.lastPathComponent) has no frames.")
        }
        var delays: [Double] = []
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let declared = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            delays.append(Layout.gifFrameDelay(declared))
        }
        let total = delays.reduce(0, +)
        guard total >= Layout.minClipSeconds else {
            throw ImportError(message: "\(source.lastPathComponent) lasts \(String(format: "%.2f", total)) s; backgrounds need at least \(Layout.minClipSeconds) s.")
        }
        guard total <= Layout.maxSourceSeconds else { throw ImportError(message: "\(source.lastPathComponent) is longer than 10 minutes.") }
        let size = Layout.evenFit(width: Double(first.width), height: Double(first.height), maxLongSide: 3840)
        let w = Int(size.width), h = Int(size.height)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, w * h * 4),
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw ImportError(message: "The GIF could not be converted.") }
        writer.add(input)
        guard writer.startWriting() else { throw ImportError(message: "The GIF could not be converted (\(writer.error?.localizedDescription ?? "writer")).") }
        writer.startSession(atSourceTime: .zero)

        var time = 0.0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil), let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            draw(frame, into: buffer, width: w, height: h)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 6000))
            time += delays[i]
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: total, preferredTimescale: 6000))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ImportError(message: "The GIF could not be converted (\(writer.error?.localizedDescription ?? "unknown error")).")
        }
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// Frame grabbing shared by the importer, the poster button and the timeline thumbnails.
enum PackPlayerFrames {
    static func frame(of url: URL, at seconds: Double, maximumSize: CGSize = .zero) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = maximumSize
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// `count` evenly spaced thumbnails (for the trim timeline).
    static func thumbnails(of url: URL, duration: Double, count: Int, height: CGFloat) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 3, height: height * 2)
        let tolerance = CMTime(seconds: duration / Double(max(count, 1)) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var out: [CGImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let img = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { out.append(img) }
        }
        return out
    }
}
