import Foundation

// Souffles entendus au micro (téléphone à l'air libre, près de la tête).
//
// Méthode reprise du test du Blue Yeti (27/10) et de la troisième nuit (22/10) :
// - spectre toutes les 20 ms (fenêtres de 32 ms), 24 bandes de 150 à 5000 Hz ;
// - bruit de fond de chaque bande = 20e centile sur les 15 dernières secondes ÷ 0,223 ;
// - score = moyenne des rapports son / bruit (détecteur d'énergie « blanchi »), en dB, lissé sur 0,25 s ;
// - seuil = niveau du bruit (estimé sur 30 s) + max(0,5 dB, 3,5 écarts-types) ;
// - souffle = au moins 0,3 s au-dessus du seuil ; plus de 5 s = bruit continu (vidéo, parole, ventilateur) ;
//   plus de 18 dB = bruit fort (parole, toux, choc) ;
// - rythme : autocorrélation du score sur 60 s (écrêté pour ignorer les chocs).
// Vérifié sur des sons synthétiques seulement (voir BreathSoundTests).

/// Un son repéré.
public struct SoundEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case breath = "souffle"
        case continuous = "bruit_continu"
        case loud = "bruit_fort"
    }

    public var kind: Kind
    /// Horloge des capteurs (s).
    public var start: Double
    public var duration: Double
    /// Hauteur au-dessus du bruit (dB).
    public var peakDB: Double
    /// Part de l'énergie sous 500 Hz (0 à 1) : élevée pour un ronflement.
    public var lowShare: Double
}

/// Bilan du son pour une tranche de 30 s.
public struct SoundEpoch: Sendable {
    /// Respirations par minute d'après le son, si un rythme net est trouvé.
    public var breathRate: Double?
    public var quality: Double = 0
    /// Part du temps occupée par un bruit continu (vidéo, parole…).
    public var continuousShare: Double = 0
    /// Part du temps avec du son enregistré.
    public var coverage: Double = 0
    public var breaths = 0
    /// Souffles graves et forts (ronflements possibles).
    public var snoreCandidates = 0

    /// Le rythme respiratoire s'entend nettement pendant cette tranche.
    public var usable: Bool { breathRate != nil && quality >= 0.3 && continuousShare < 0.2 && coverage >= 0.8 }
}

/// Une pause possible entendue (silence anormalement long au milieu de souffles réguliers).
public struct SoundPause: Equatable, Sendable {
    /// Dernier souffle avant le silence (horloge des capteurs).
    public var lastBreath: Double
    /// Souffle qui reprend.
    public var nextBreath: Double
    /// Intervalle habituel entre deux souffles juste avant (s).
    public var usualInterval: Double

    public var silence: Double { nextBreath - lastBreath }
}

public final class BreathSoundAnalyzer {
    public static let sampleRate = 16_000.0
    public static let frameSize = 512
    public static let hop = 320
    static let bandCount = 24
    /// Bandes sous 500 Hz (pour la part grave des sons).
    static let lowBandCount = 8
    static let noiseFrames = 750       // 15 s
    static let thresholdFrames = 1500  // 30 s
    static let updateEvery = 50        // 1 s
    static let smoothFrames = 13       // 0,25 s

    /// Origine des tranches (horloge des capteurs), la même que pour les capteurs.
    public let origin: Double
    public let epochSeconds: Double

    public private(set) var events: [SoundEvent] = []
    /// Score et seuil à 10 Hz depuis `origin` (NaN = pas de son).
    public private(set) var score10: [Float] = []
    public private(set) var threshold10: [Float] = []
    /// Niveau du bruit de fond (dB), une valeur par seconde depuis `origin` (NaN = pas de son).
    public private(set) var floorDB: [Float] = []
    private var noisyCache: [Bool]?

    private let spectrum = PowerSpectrum(size: BreathSoundAnalyzer.frameSize)
    private var power: [Float] = []
    private let bandRanges: [Range<Int>]

    // État d'un segment de son continu.
    private var bandHistory: [[Float]]
    private var historyIndex = 0
    private var historyCount = 0
    private var noise: [Float]
    private var noiseReady = false
    private var smooth: [Float] = []
    private var scoreHistory: [Float] = []
    private var threshold: Float = .nan
    private var framesSinceUpdate = 0
    private var lastSegmentEnd: Double?
    private var carry: [Float] = []
    private var carryStart = 0.0

    // Événement en cours.
    private var eventStart: Double?
    private var eventLast = 0.0
    private var eventPeak: Float = 0
    private var eventLow: Double = 0
    private var eventTotal: Double = 0
    private var framesBelow = 0

    // Moyennes à 10 Hz.
    private var binIndex = -1
    private var binScore: Float = 0
    private var binThreshold: Float = 0
    private var binCount = 0

    public init(origin: Double, epochSeconds: Double = 30) {
        self.origin = origin
        self.epochSeconds = epochSeconds
        let binHz = Self.sampleRate / Double(Self.frameSize)
        let low = 150.0, high = 5000.0
        let ratio = pow(high / low, 1 / Double(Self.bandCount))
        var ranges: [Range<Int>] = []
        for b in 0..<Self.bandCount {
            let f0 = low * pow(ratio, Double(b)), f1 = low * pow(ratio, Double(b + 1))
            let k0 = Int((f0 / binHz).rounded())
            let k1 = max(k0 + 1, Int((f1 / binHz).rounded()))
            ranges.append(k0..<k1)
        }
        bandRanges = ranges
        bandHistory = Array(repeating: Array(repeating: 0, count: Self.noiseFrames), count: Self.bandCount)
        noise = Array(repeating: 0, count: Self.bandCount)
    }

    /// Ajoute un morceau de son (16 kHz, mono) commençant à `startUptime` (horloge des capteurs).
    /// Les morceaux doivent arriver dans l'ordre. Un trou de plus de 0,5 s remet le bruit de fond à zéro.
    public func process(startUptime: Double, samples: [Float]) {
        let continuous = lastSegmentEnd.map { abs(startUptime - $0) <= 0.5 } ?? false
        if !continuous {
            resetSegment()
            carry = []
        }
        let bufferStart = carry.isEmpty ? startUptime : carryStart
        let buffer = carry + samples
        lastSegmentEnd = startUptime + Double(samples.count) / Self.sampleRate
        var offset = 0
        buffer.withUnsafeBufferPointer { pointer in
            while offset + Self.frameSize <= pointer.count {
                let time = bufferStart + Double(offset + Self.frameSize / 2) / Self.sampleRate
                frame(pointer, offset: offset, time: time)
                offset += Self.hop
            }
        }
        carry = Array(buffer[offset...])
        carryStart = bufferStart + Double(offset) / Self.sampleRate
    }

    /// À appeler après le dernier morceau.
    public func finish() {
        closeEvent()
        flushBin()
    }

    private func resetSegment() {
        closeEvent()
        historyIndex = 0
        historyCount = 0
        noiseReady = false
        smooth = []
        scoreHistory = []
        threshold = .nan
        framesSinceUpdate = 0
    }

    private func frame(_ samples: UnsafeBufferPointer<Float>, offset: Int, time: Double) {
        spectrum.compute(samples, offset: offset, into: &power)
        var bands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            var sum: Float = 0
            for k in bandRanges[b] { sum += power[k] }
            bands[b] = sum
            bandHistory[b][historyIndex] = sum
        }
        historyIndex = (historyIndex + 1) % Self.noiseFrames
        historyCount = min(historyCount + 1, Self.noiseFrames)
        framesSinceUpdate += 1
        if framesSinceUpdate >= Self.updateEvery || !noiseReady && historyCount >= Self.updateEvery {
            updateNoise(time: time)
        }
        guard noiseReady else { return }

        var ratioSum: Float = 0
        var low = 0.0, total = 0.0
        for b in 0..<Self.bandCount {
            let n = max(noise[b], 1e-20)
            ratioSum += bands[b] / n
            let excess = Double(max(0, bands[b] - n))
            total += excess
            if b < Self.lowBandCount { low += excess }
        }
        let scoreDB = 10 * log10(max(ratioSum / Float(Self.bandCount), 1e-6))
        smooth.append(scoreDB)
        if smooth.count > Self.smoothFrames { smooth.removeFirst() }
        let smoothed = smooth.reduce(0, +) / Float(smooth.count)
        scoreHistory.append(smoothed)
        if scoreHistory.count > Self.thresholdFrames { scoreHistory.removeFirst(scoreHistory.count - Self.thresholdFrames) }
        if threshold.isNaN { updateThreshold() }
        guard !threshold.isNaN else { return }

        addToBin(time: time, score: smoothed, threshold: threshold)
        if smoothed > threshold {
            if eventStart == nil {
                eventStart = time
                eventPeak = smoothed
                eventLow = 0
                eventTotal = 0
            }
            eventLast = time
            eventPeak = max(eventPeak, smoothed)
            eventLow += low
            eventTotal += total
            framesBelow = 0
        } else if eventStart != nil {
            framesBelow += 1
            if framesBelow >= 8 { closeEvent() }
        }
    }

    private func updateNoise(time: Double) {
        framesSinceUpdate = 0
        var values = [Float](repeating: 0, count: historyCount)
        for b in 0..<Self.bandCount {
            for i in 0..<historyCount { values[i] = bandHistory[b][i] }
            noise[b] = Self.select(&values, rank: Int(0.2 * Double(historyCount - 1))) / 0.223
        }
        noiseReady = true
        updateThreshold()
        let second = Int(time - origin)
        if second >= 0 {
            if floorDB.count <= second { floorDB += [Float](repeating: .nan, count: second + 1 - floorDB.count) }
            floorDB[second] = 10 * log10(max(noise.reduce(0, +), 1e-20))
            noisyCache = nil
        }
    }

    /// Secondes où le bruit de fond dépasse de 8 dB le calme de la nuit (vidéo, podcast, ventilateur…).
    /// Le bruit de fond s'adapte en 15 s : sans cette comparaison, une vidéo deviendrait vite le « fond ».
    public var noisySeconds: [Bool] {
        if let noisyCache { return noisyCache }
        var valid = floorDB.filter { !$0.isNaN }
        var flags = [Bool](repeating: false, count: floorDB.count)
        if valid.count >= 30 {
            let quiet = Self.select(&valid, rank: valid.count / 10)
            for i in floorDB.indices where !floorDB[i].isNaN && floorDB[i] > quiet + 8 { flags[i] = true }
        }
        noisyCache = flags
        return flags
    }

    private func isNoisy(_ start: Double, _ end: Double) -> Bool {
        let flags = noisySeconds
        let a = max(0, Int(start - origin)), b = min(flags.count, Int((end - origin).rounded(.up)) + 1)
        return a < b && flags[a..<b].contains(true)
    }

    private func updateThreshold() {
        guard scoreHistory.count >= 150 else { return }
        var values = scoreHistory
        let n = values.count - 1
        let p5 = Self.select(&values, rank: Int(0.05 * Double(n)))
        let p25 = Self.select(&values, rank: Int(0.25 * Double(n)))
        let sigma = max(0.05, (p25 - p5) / 0.97)
        let mean = p25 + 0.674 * sigma
        threshold = mean + max(0.5, 3.5 * sigma)
    }

    private func closeEvent() {
        guard let start = eventStart else { return }
        eventStart = nil
        framesBelow = 0
        let duration = eventLast - start + Double(Self.hop) / Self.sampleRate
        guard duration >= 0.3 else { return }
        let kind: SoundEvent.Kind
        if duration > 5 {
            kind = .continuous
        } else if eventPeak > 18 {
            kind = .loud
        } else {
            kind = .breath
        }
        events.append(SoundEvent(kind: kind, start: start, duration: duration, peakDB: Double(eventPeak),
                                 lowShare: eventTotal > 0 ? eventLow / eventTotal : 0))
    }

    private func addToBin(time: Double, score: Float, threshold: Float) {
        let index = Int(((time - origin) * 10).rounded(.down))
        guard index >= 0 else { return }
        if index != binIndex {
            flushBin()
            binIndex = index
        }
        binScore += score
        binThreshold += threshold
        binCount += 1
    }

    private func flushBin() {
        guard binIndex >= 0, binCount > 0 else { return }
        if score10.count <= binIndex {
            score10 += [Float](repeating: .nan, count: binIndex + 1 - score10.count)
            threshold10 += [Float](repeating: .nan, count: binIndex + 1 - threshold10.count)
        }
        score10[binIndex] = binScore / Float(binCount)
        threshold10[binIndex] = binThreshold / Float(binCount)
        binScore = 0
        binThreshold = 0
        binCount = 0
    }

    /// k-ième plus petite valeur (sélection rapide, modifie le tableau).
    static func select(_ values: inout [Float], rank: Int) -> Float {
        guard !values.isEmpty else { return 0 }
        var low = 0, high = values.count - 1
        let k = max(0, min(rank, high))
        while low < high {
            let pivot = values[(low + high) / 2]
            var i = low, j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { high = j } else if k >= i { low = i } else { break }
        }
        return values[k]
    }

    // MARK: - Bilan par tranche de 30 s

    /// Rythme et qualité du son pour les `count` premières tranches.
    public func epochs(count: Int) -> [SoundEpoch] {
        let perEpoch = Int(epochSeconds * 10)
        var result: [SoundEpoch] = []
        result.reserveCapacity(count)
        let breaths = events.filter { $0.kind == .breath }
        let continuous = events.filter { $0.kind == .continuous }
        for e in 0..<count {
            var epoch = SoundEpoch()
            let from = e * perEpoch, to = from + perEpoch
            let start = origin + Double(e) * epochSeconds, end = start + epochSeconds
            let present = (from..<to).filter { $0 < score10.count && !score10[$0].isNaN }.count
            epoch.coverage = Double(present) / Double(perEpoch)
            guard epoch.coverage > 0 else {
                result.append(epoch)
                continue
            }
            var busy = [Bool](repeating: false, count: Int(epochSeconds))
            for event in continuous where event.start < end && event.start + event.duration > start {
                for k in Int(max(start, event.start) - start)..<min(busy.count, Int((min(end, event.start + event.duration) - start).rounded(.up))) {
                    busy[k] = true
                }
            }
            let flags = noisySeconds
            for k in 0..<busy.count {
                let second = Int(start - origin) + k
                if second >= 0, second < flags.count, flags[second] { busy[k] = true }
            }
            epoch.continuousShare = Double(busy.filter { $0 }.count) / epochSeconds
            let inEpoch = breaths.filter { $0.start >= start && $0.start < end }
            epoch.breaths = inEpoch.count
            epoch.snoreCandidates = inEpoch.filter { $0.peakDB >= 10 && $0.lowShare >= 0.5 }.count
            let rhythm = rate(from: from - perEpoch / 2, to: to + perEpoch / 2)
            epoch.breathRate = rhythm.rate
            epoch.quality = rhythm.quality
            result.append(epoch)
        }
        return result
    }

    /// Rythme sur les cases 10 Hz [from, to) : autocorrélation du score au-dessus du seuil.
    func rate(from: Int, to: Int) -> (rate: Double?, quality: Double) {
        let lo = max(0, from), hi = min(score10.count, to)
        guard hi - lo >= 300 else { return (nil, 0) }
        var x: [Double] = []
        x.reserveCapacity(hi - lo)
        var missing = 0
        for i in lo..<hi {
            let s = score10[i], th = threshold10[i]
            if s.isNaN || th.isNaN {
                missing += 1
                x.append(.nan)
            } else {
                // Au-dessus du seuil seulement, écrêté à 3 dB pour ignorer les chocs.
                x.append(Double(min(max(s - th + 1, 0), 4)))
            }
        }
        guard Double(missing) / Double(x.count) <= 0.2 else { return (nil, 0) }
        let valid = x.filter { !$0.isNaN }
        let mean = DSP.mean(valid)
        x = x.map { $0.isNaN ? 0 : $0 - mean }
        let minLag = 15, maxLag = 100   // 1,5 à 10 s : 6 à 40 respirations par minute
        let ac = DSP.autocorrelation(x, lags: (minLag - 1)...(maxLag + 1))
        guard let peak = DSP.fundamentalPeak(ac, lagStart: minLag - 1) else { return (nil, 0) }
        let n = Double(x.count)
        let quality = max(0, min(1, peak.value * n / (n - peak.lag)))
        let perMinute = 600 / peak.lag
        guard quality > 0.1, perMinute >= 6, perMinute <= 40 else { return (nil, quality) }
        return (perMinute, quality)
    }

    // MARK: - Pauses possibles

    /// Silences anormalement longs au milieu de souffles réguliers, sans mouvement ni bruit continu.
    /// `isMoving(a, b)` : la personne bouge-t-elle entre a et b (horloge des capteurs) ?
    public func pauses(isMoving: (Double, Double) -> Bool) -> [SoundPause] {
        let breaths = events.filter { $0.kind == .breath }.map(\.start)
        let noisy = events.filter { $0.kind != .breath }
        var result: [SoundPause] = []
        guard breaths.count >= 10 else { return [] }
        for i in 5..<(breaths.count - 3) {
            let gap = breaths[i + 1] - breaths[i]
            guard gap >= 10 else { continue }
            let before = (i - 5..<i).map { breaths[$0 + 1] - breaths[$0] }
            let usual = DSP.percentile(before, 50)
            guard usual >= 1.5, usual <= 10, gap >= 2 * usual else { continue }
            // Souffles réguliers avant (pas de souffles manqués) et reprise normale après.
            let spread = DSP.standardDeviation(before) / usual
            guard spread < 0.35 else { continue }
            let expected = 60 / usual
            let counted = breaths.filter { $0 > breaths[i] - 60 && $0 <= breaths[i] }.count
            guard Double(counted) >= 0.7 * expected else { continue }
            let after = (i + 1..<i + 4).map { breaths[$0 + 1] - breaths[$0] }
            let resumed = DSP.percentile(after, 50)
            guard resumed >= 0.5 * usual, resumed <= 2 * usual else { continue }
            // Ni bruit continu ni bruit fort pendant le silence, ni mouvement.
            let start = breaths[i], end = breaths[i + 1]
            guard !noisy.contains(where: { $0.start < end && $0.start + $0.duration > start }),
                  !isNoisy(start - 5, end + 5) else { continue }
            guard !isMoving(start, end) else { continue }
            let first = Int((start - origin) * 10), last = Int((end - origin) * 10)
            guard first >= 0, last < score10.count, !(first...last).contains(where: { score10[$0].isNaN }) else { continue }
            result.append(SoundPause(lastBreath: start, nextBreath: end, usualInterval: usual))
        }
        return result
    }
}
