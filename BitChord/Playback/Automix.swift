import AVFoundation
import Foundation
import MediaToolbox

/// The iOS half of Automix: reading audio for analysis, and building the audio mixes
/// (equal-power volume curves plus a bass-swap high-pass filter) that AVPlayer applies
/// sample-accurately during a transition. Playback itself stays on AVPlayer.
enum AutomixAudio {
    static let analysisRate = 11025.0

    /// Beat grids, cached per track and section so a song is analysed once.
    private static var cache: [String: BeatGrid] = [:]
    private static let lock = NSLock()

    static func grid(videoId: String, url: URL, section: Section, duration: Double) async -> BeatGrid? {
        let key = videoId + (section == .head ? "|head" : "|tail")
        if let hit = cached(key) { return hit }
        let start = section == .head ? 0 : max(0, duration - 90)
        let length = section == .head ? min(60, duration) : min(90, duration)
        let grid: BeatGrid? = await Task.detached(priority: .utility) {
            guard let audio = await readMono(url: url, start: start, duration: length) else { return nil }
            return BeatAnalysis.analyze(samples: audio.samples, sampleRate: audio.rate, startTime: start)
        }.value
        if let grid { store(grid, key) }
        return grid
    }

    enum Section { case head, tail }

    private static func cached(_ key: String) -> BeatGrid? { lock.lock(); defer { lock.unlock() }; return cache[key] }
    private static func store(_ grid: BeatGrid, _ key: String) {
        lock.lock()
        if cache.count > 60 { cache.removeAll() }
        cache[key] = grid
        lock.unlock()
    }

    // MARK: Decoding

    /// Mono float samples of a section of a file, near 11 kHz.
    static func readMono(url: URL, start: Double, duration: Double) async -> (samples: [Float], rate: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000),
                                duration: CMTime(seconds: duration, preferredTimescale: 1000))

        // Ask the reader to downmix and resample for us…
        let converted: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: analysisRate,
        ]
        if let samples = read(asset: asset, track: track, range: range, settings: converted) {
            return (samples, analysisRate)
        }
        // …or do it ourselves if it won't.
        let native: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let raw = read(asset: asset, track: track, range: range, settings: native),
              let desc = formats.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
        else { return nil }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100
        let factor = max(1, Int((rate / analysisRate).rounded()))
        let frames = raw.count / channels
        var out = [Float]()
        out.reserveCapacity(frames / factor + 1)
        var i = 0
        while i + factor <= frames {
            var acc: Float = 0
            for f in i..<(i + factor) {
                for c in 0..<channels { acc += raw[f * channels + c] }
            }
            out.append(acc / Float(factor * channels))
            i += factor
        }
        return (out, rate / Double(factor))
    }

    private static func read(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, settings: [String: Any]) -> [Float]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { return nil }
        var samples = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples += chunk
        }
        if reader.status == .failed || samples.isEmpty { return nil }
        return samples
    }

    // MARK: Mixes

    /// Equal-power curve points between two times (item time), as (time, gain).
    static func equalPower(from start: Double, to end: Double, fadingIn: Bool) -> [(Double, Float)] {
        stride(from: 0.0, through: 1.0, by: 0.125).map { x in
            let g = fadingIn ? sin(x * .pi / 2) : cos(x * .pi / 2)
            return (start + (end - start) * x, Float(g))
        }
    }

    static func audioMix(for item: AVPlayerItem, volume points: [(Double, Float)], filter: BassSwapFilter?) async -> AVAudioMix? {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        if let first = points.first { params.setVolume(first.1, at: .zero) }
        for i in 0..<max(0, points.count - 1) {
            let a = points[i], b = points[i + 1]
            params.setVolumeRamp(fromStartVolume: a.1, toEndVolume: b.1,
                                 timeRange: CMTimeRange(start: CMTime(seconds: a.0, preferredTimescale: 48000),
                                                        end: CMTime(seconds: b.0, preferredTimescale: 48000)))
        }
        if let filter, let tap = filter.makeTap() { params.audioTapProcessor = tap }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

/// A high-pass filter whose cutoff follows an automation curve in item time: the "bass
/// swap" DJs use so two kick drums never thump at once. Runs inside AVPlayer through an
/// MTAudioProcessingTap.
final class BassSwapFilter {
    /// (item time in seconds, cutoff in Hz), interpolated geometrically. Below ~25 Hz it's bypassed.
    let points: [(Double, Double)]
    private var sampleRate = 44100.0
    private var interleaved = false
    private var channels = 2
    private var x1 = [Double](repeating: 0, count: 8), x2 = [Double](repeating: 0, count: 8)
    private var y1 = [Double](repeating: 0, count: 8), y2 = [Double](repeating: 0, count: 8)

    init(points: [(Double, Double)]) { self.points = points }

    func cutoff(at t: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 0..<(points.count - 1) where t <= points[i + 1].0 {
            let a = points[i], b = points[i + 1]
            let x = (t - a.0) / max(1e-6, b.0 - a.0)
            return exp(log(max(1, a.1)) + (log(max(1, b.1)) - log(max(1, a.1))) * x)
        }
        return last.1
    }

    fileprivate func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channels = max(1, min(8, Int(format.mChannelsPerFrame)))
        for i in 0..<8 { x1[i] = 0; x2[i] = 0; y1[i] = 0; y2[i] = 0 }
    }

    fileprivate func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, startTime: Double) {
        let hz = cutoff(at: startTime)
        guard hz > 25, frames > 0 else { return }
        // RBJ high-pass biquad, Q = 0.707.
        let w0 = 2 * Double.pi * min(hz, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let cw = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 + cw) / 2 / a0, b1 = -(1 + cw) / a0, b2 = (1 + cw) / 2 / a0
        let a1 = -2 * cw / a0, a2 = (1 - alpha) / a0

        func run(_ p: UnsafeMutablePointer<Float>, count: Int, stride: Int, ch: Int) {
            var px1 = x1[ch], px2 = x2[ch], py1 = y1[ch], py2 = y2[ch]
            var i = 0
            for _ in 0..<count {
                let x = Double(p[i])
                let y = b0 * x + b1 * px1 + b2 * px2 - a1 * py1 - a2 * py2
                px2 = px1; px1 = x; py2 = py1; py1 = y
                p[i] = Float(y)
                i += stride
            }
            x1[ch] = px1; x2[ch] = px2; y1[ch] = py1; y2[ch] = py2
        }

        if interleaved, let buffer = buffers.first, let data = buffer.mData {
            let p = data.assumingMemoryBound(to: Float.self)
            let ch = max(1, Int(buffer.mNumberChannels))
            for c in 0..<min(ch, 8) { run(p + c, count: frames, stride: ch, ch: c) }
        } else {
            for (c, buffer) in buffers.enumerated() where c < 8 {
                guard let data = buffer.mData else { continue }
                run(data.assumingMemoryBound(to: Float.self), count: frames, stride: 1, ch: c)
            }
        }
    }

    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<BassSwapFilter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<BassSwapFilter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut)
                guard status == noErr else { return }
                let filter = Unmanaged<BassSwapFilter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let start = range.start.isValid ? range.start.seconds : 0
                filter.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee), startTime: start)
            }
        )
        let created = Self.create { MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, $0) }
        guard let created else {
            // The tap never took ownership of the retained client info.
            Unmanaged<BassSwapFilter>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        // Depending on the SDK, the tap comes back either managed or as Unmanaged.
        if let unmanaged = created as? Unmanaged<MTAudioProcessingTap> { return unmanaged.takeRetainedValue() }
        return (created as AnyObject) as? MTAudioProcessingTap
    }

    private static func create<T>(_ body: (UnsafeMutablePointer<T?>) -> OSStatus) -> T? {
        var out: T?
        let status = body(&out)
        return status == noErr ? out : nil
    }
}
