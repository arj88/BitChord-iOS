import Foundation

/// Where the beats and bars fall in a stretch of a track.
struct BeatGrid {
    /// Tempo in beats per minute.
    var bpm: Double
    /// Beat times in seconds from the start of the track.
    var beats: [Double]
    /// The beats that start a bar (assumes 4/4, which covers nearly all pop music).
    var downbeats: [Double]
    /// First moment with audible music in the analysed stretch (track time).
    var musicStart: Double
    /// Where the track stops being "full" — the start of a fade-out or tail silence (track time).
    var musicEnd: Double
    /// How clearly the beat stands out (≈1 means no detectable pulse; above ~1.6 is solid).
    var confidence: Double

    var beatLength: Double { 60 / bpm }
}

/// Tempo and beat tracking from raw mono audio: spectral-flux onsets, an autocorrelation
/// tempo estimate refined by a comb search, and kick-weighted downbeat selection.
/// Pure Swift so it runs (and is tested) anywhere.
enum BeatAnalysis {
    static let frameSize = 512
    static let hop = 128

    /// - Parameters:
    ///   - samples: mono audio, ideally around 11–12 kHz.
    ///   - startTime: where `samples` begins within the track, in seconds.
    static func analyze(samples: [Float], sampleRate: Double, startTime: Double = 0) -> BeatGrid? {
        let frames = (samples.count - frameSize) / hop
        guard frames > 200 else { return nil }
        let fps = sampleRate / Double(hop)
        let (flux, low, rms) = envelopes(samples, sampleRate: sampleRate, frames: frames)

        // Detrended, normalised onset strength.
        let onset = normalise(detrend(flux, window: Int(fps * 0.5)))

        // 1. Coarse tempo from the autocorrelation, weighted toward the 120 BPM region.
        let minBPM = 70.0, maxBPM = 180.0
        let lagMin = Int(60 * fps / maxBPM), lagMax = Int(60 * fps / minBPM) + 1
        guard lagMax < frames / 2 else { return nil }
        // Autocorrelation out to four beats, so each tempo is also scored by how well
        // its bars (2× and 4× the period) repeat. That keeps syncopated 3-3-2 rhythms
        // from being read as the wrong tempo.
        let maxLag = min(frames - 1, lagMax * 4 + 4)
        var acf = [Double](repeating: 0, count: maxLag + 1)
        for lag in lagMin...maxLag {
            var s = 0.0
            for i in 0..<(frames - lag) { s += Double(onset[i] * onset[i + lag]) }
            acf[lag] = s / Double(frames - lag)
        }
        func peak(_ lag: Int) -> Double {
            guard lag + 1 <= maxLag, lag >= 1 else { return 0 }
            return max(acf[lag - 1], acf[lag], acf[lag + 1])
        }
        var bestLag = lagMin
        var bestScore = -Double.infinity
        for lag in lagMin...lagMax {
            let s = acf[lag] + 0.5 * peak(2 * lag) + 0.25 * peak(4 * lag)
            let bpm = 60 * fps / Double(lag)
            let octave = log2(bpm / 120)
            let weight = exp(-0.5 * octave * octave / (0.9 * 0.9))
            if s * weight > bestScore { bestScore = s * weight; bestLag = lag }
        }

        // 2. Refine period and phase together with a comb over the whole stretch.
        var period = Double(bestLag)
        var phase = 0.0
        var combBest = -Double.infinity
        let coarse = Double(bestLag)
        let step = max(0.01, coarse * 0.0015)
        var p = coarse * 0.97
        while p <= coarse * 1.03 {
            let (ph, score) = bestPhase(onset, period: p)
            if score > combBest { combBest = score; period = p; phase = ph }
            p += step
        }

        // Confidence: best comb against the average over all phases of that period.
        var meanScore = 0.0
        let steps = 24
        for k in 0..<steps { meanScore += comb(onset, period: period, phase: period * Double(k) / Double(steps)) }
        meanScore /= Double(steps)
        let confidence = meanScore > 0 ? combBest / meanScore : 1

        // Beat positions in frames → seconds (frame centres; the same bias applies to every track).
        let offset = Double(frameSize / 2) / sampleRate
        var beatFrames: [Double] = []
        var f = phase
        while f < Double(frames) { beatFrames.append(f); f += period }
        guard beatFrames.count >= 8 else { return nil }

        // 3. Downbeats: the beat-of-four whose beats carry the most low-end (the kick).
        var bestM = 0
        var bestLow = -1.0
        for m in 0..<4 {
            var s = 0.0
            var n = 0
            for (i, bf) in beatFrames.enumerated() where i % 4 == m {
                let idx = min(frames - 1, Int(bf.rounded()))
                s += Double(low[max(0, idx - 1)...min(frames - 1, idx + 2)].max() ?? 0)
                n += 1
            }
            if n > 0 && s / Double(n) > bestLow { bestLow = s / Double(n); bestM = m }
        }

        let beats = beatFrames.map { startTime + $0 / fps + offset }
        let downbeats = beats.enumerated().filter { $0.offset % 4 == bestM }.map(\.element)

        // 4. Where the music is "full": smoothed loudness against the stretch's median.
        let smooth = movingAverage(rms, window: Int(fps))
        let median = smooth.sorted()[smooth.count / 2]
        let startIdx = smooth.firstIndex { $0 > median * 0.05 } ?? 0
        let endIdx = smooth.lastIndex { $0 > median * 0.35 } ?? (frames - 1)

        return BeatGrid(bpm: 60 * fps / period, beats: beats, downbeats: downbeats,
                        musicStart: startTime + Double(startIdx) / fps,
                        musicEnd: startTime + Double(endIdx) / fps,
                        confidence: confidence)
    }

    // MARK: Envelopes

    private static func envelopes(_ x: [Float], sampleRate: Double, frames: Int) -> (flux: [Float], low: [Float], rms: [Float]) {
        let n = frameSize
        let fft = FFT(size: n)
        var window = [Float](repeating: 0, count: n)
        for i in 0..<n { window[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(n - 1)) }
        let bins = n / 2
        let lowBin = max(1, Int(150 / (sampleRate / Double(n))))
        var prev = [Float](repeating: 0, count: bins)
        var flux = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var rms = [Float](repeating: 0, count: frames)
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        for t in 0..<frames {
            let base = t * hop
            var energy: Float = 0
            for i in 0..<n {
                let v = x[base + i]
                energy += v * v
                re[i] = v * window[i]
                im[i] = 0
            }
            rms[t] = (energy / Float(n)).squareRoot()
            fft.forward(&re, &im)
            var sum: Float = 0
            var lowSum: Float = 0
            for k in 1..<bins {
                let mag = (re[k] * re[k] + im[k] * im[k]).squareRoot()
                let l = log1p(100 * mag)
                let d = l - prev[k]
                if d > 0 { sum += d }
                if k <= lowBin { lowSum += mag }
                prev[k] = l
            }
            flux[t] = t == 0 ? 0 : sum
            low[t] = lowSum
        }
        return (flux, low, rms)
    }

    private static func detrend(_ x: [Float], window: Int) -> [Float] {
        let avg = movingAverage(x, window: max(1, window))
        return zip(x, avg).map { max(0, $0 - $1) }
    }

    private static func movingAverage(_ x: [Float], window: Int) -> [Float] {
        guard window > 1 else { return x }
        var out = [Float](repeating: 0, count: x.count)
        var acc: Float = 0
        let half = window / 2
        var lo = 0, hi = -1
        for i in 0..<x.count {
            let newLo = max(0, i - half), newHi = min(x.count - 1, i + half)
            while hi < newHi { hi += 1; acc += x[hi] }
            while lo < newLo { acc -= x[lo]; lo += 1 }
            out[i] = acc / Float(hi - lo + 1)
        }
        return out
    }

    private static func normalise(_ x: [Float]) -> [Float] {
        let mean = x.reduce(0, +) / Float(max(1, x.count))
        let variance = x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(1, x.count))
        let sd = max(1e-6, variance.squareRoot())
        return x.map { $0 / sd }
    }

    // MARK: Comb

    /// Mean onset strength at phase, phase+period, … (linear interpolation).
    private static func comb(_ onset: [Float], period: Double, phase: Double) -> Double {
        var s = 0.0
        var n = 0
        var f = phase
        let last = Double(onset.count - 2)
        while f < last {
            let i = Int(f)
            let frac = Float(f - Double(i))
            // Take the local maximum within ±1 frame so slightly early/late hits still count.
            let a = onset[max(0, i - 1)], b = onset[i] * (1 - frac) + onset[i + 1] * frac, c = onset[min(onset.count - 1, i + 2)]
            s += Double(max(b, 0.6 * max(a, c)))
            n += 1
            f += period
        }
        return n > 0 ? s / Double(n) : 0
    }

    private static func bestPhase(_ onset: [Float], period: Double) -> (Double, Double) {
        var best = (0.0, -Double.infinity)
        var ph = 0.0
        while ph < period {
            let s = comb(onset, period: period, phase: ph)
            if s > best.1 { best = (ph, s) }
            ph += 0.5
        }
        return best
    }
}

/// Iterative radix-2 complex FFT.
struct FFT {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReverse: [Int]

    init(size: Int) {
        self.size = size
        var c = [Float](), s = [Float]()
        for i in 0..<(size / 2) {
            let a = -2 * Double.pi * Double(i) / Double(size)
            c.append(Float(cos(a))); s.append(Float(sin(a)))
        }
        cosTable = c; sinTable = s
        let bits = Int(log2(Double(size)))
        bitReverse = (0..<size).map { i in
            var r = 0, v = i
            for _ in 0..<bits { r = (r << 1) | (v & 1); v >>= 1 }
            return r
        }
    }

    func forward(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<size {
            let j = bitReverse[i]
            if j > i { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= size {
            let half = len / 2
            let step = size / len
            var start = 0
            while start < size {
                for k in 0..<half {
                    let wr = cosTable[k * step], wi = sinTable[k * step]
                    let a = start + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
    }
}

/// How to get from one track into the next.
struct TransitionPlan {
    /// Track time in the outgoing song where the mix begins (on a downbeat).
    var outStart: Double
    /// Track time in the incoming song that lines up with `outStart` (its first downbeat).
    var inStart: Double
    /// Length of the overlap in real seconds.
    var fadeSeconds: Double
    /// Playback rate for the incoming song during the mix, to match tempos (1 = untouched).
    var rate: Double
    /// When the bass swaps from the old song to the new one, as a fraction of the fade.
    var swapAt: Double
    var beatMatched: Bool
    var summary: String
}

enum AutomixPlanner {
    /// - Parameters:
    ///   - outgoing: beats near the end of the playing song.
    ///   - outDuration: the playing song's real length.
    ///   - incoming: beats near the start of the next song.
    ///   - beats: overlap length in beats of the outgoing song (8, 16 or 32).
    ///   - notBefore: the earliest track time the mix may start (now + a scheduling margin).
    static func plan(outgoing: BeatGrid, outDuration: Double, incoming: BeatGrid, beats: Int, notBefore: Double) -> TransitionPlan? {
        let solid = outgoing.confidence > 1.25 && incoming.confidence > 1.25
        // Tempo ratio, allowing for one song being counted at half or double time.
        var rate = 1.0
        var ratioOK = false
        if solid {
            let candidates = [0.5, 1, 2].map { outgoing.bpm / (incoming.bpm * $0) }
            if let r = candidates.min(by: { abs($0 - 1) < abs($1 - 1) }), abs(r - 1) <= 0.08 {
                rate = r
                ratioOK = true
            }
        }
        let beatMatched = solid && ratioOK
        let overlapBeats = beatMatched ? beats : min(beats, 8)
        let fade = Double(overlapBeats) * outgoing.beatLength
        let end = min(outgoing.musicEnd, outDuration) + outgoing.beatLength * 0.5

        // The latest bar that still leaves room for the whole overlap before the music ends.
        let starts = beatMatched ? outgoing.downbeats : outgoing.beats
        guard let outStart = starts.last(where: { $0 + fade <= end && $0 >= notBefore }) else { return nil }
        // Don't cut more than ~45 s of the outgoing song.
        guard outDuration - outStart < 45 else { return nil }

        let inStart = (beatMatched ? incoming.downbeats : incoming.beats)
            .first { $0 >= incoming.musicStart - 0.05 } ?? max(0, incoming.musicStart)

        let summary = beatMatched
            ? String(format: "Automix %.0f→%.0f BPM, %d beats, rate %.3f", incoming.bpm, outgoing.bpm, overlapBeats, rate)
            : String(format: "Automix fade %.1fs (tempos %.0f/%.0f BPM don't match)", fade, outgoing.bpm, incoming.bpm)
        return TransitionPlan(outStart: outStart, inStart: inStart, fadeSeconds: fade, rate: rate,
                              swapAt: 0.5, beatMatched: beatMatched, summary: summary)
    }
}
