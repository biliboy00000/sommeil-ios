import Foundation
import CoreMotion
import SleepCore

/// Battements du cœur en direct, pour l'écran « Cœur ».
///
/// - Chaque mesure des capteurs (100 par seconde) arrive sur la file des capteurs et passe par
///   `LiveHeartDetector` (SleepCore).
/// - Les dernières secondes du tracé sont gardées pour le dessin (lues par l'écran à chaque image).
/// - Le pouls, l'état et les intervalles sont publiés sur le fil principal, à chaque battement.
final class HeartMonitor: ObservableObject {
    struct Point {
        var time: Double
        var signal: Float
        var envelope: Float
    }

    struct Snapshot {
        var points: [Point] = []
        var beats: [LiveBeat] = []
    }

    /// Une note de qualité, pour comparer des emplacements du téléphone.
    struct QualitySample {
        var heart: Double
        var breath: Double
        var bpm: Double?
    }

    @Published private(set) var state: LiveHeartState = .starting
    /// Pouls d'après les battements repérés (médiane des 10 dernières secondes).
    @Published private(set) var bpm: Double?
    /// Pouls d'après l'autocorrélation (plus lent à réagir, sert de repère).
    @Published private(set) var averageBPM: Double?
    /// Nombre de battements repérés depuis le début (sert à animer le cœur).
    @Published private(set) var beatCount = 0
    @Published private(set) var rmssd: Double?
    /// Intervalles des 60 dernières secondes.
    @Published private(set) var intervals: [HeartRhythm.Interval] = []
    /// Qualité du rythme sur la meilleure voie (0 à 1).
    @Published private(set) var quality: Double = 0
    @Published private(set) var channel = ""
    @Published private(set) var breath: BreathEstimate?
    @Published private(set) var secondsBuffered: Double = 0
    @Published private(set) var recentQuality: [QualitySample] = []

    private let queue: DispatchQueue
    private let detector = LiveHeartDetector(sampleRate: MotionCapture.rate)
    private var rhythm = HeartRhythm()
    private var lastPublishedState: LiveHeartState = .starting
    private var beatsSinceStart = 0
    private var trackingSamples = 0
    private var totalSamples = 0

    // Tracé, protégé par `lock` (écrit sur la file des capteurs, lu par l'écran).
    private let lock = NSLock()
    private let capacity = Int(10 * MotionCapture.rate)
    private var points: [Point]
    private var pointStart = 0
    private var pointCount = 0
    private var beats: [LiveBeat] = []

    init(queue: DispatchQueue) {
        self.queue = queue
        points = Array(repeating: Point(time: 0, signal: 0, envelope: 0), count: Int(10 * MotionCapture.rate))
    }

    /// Repart de zéro (à appeler avant de démarrer les capteurs).
    func reset() {
        queue.sync {
            detector.reset()
            rhythm.reset()
            lastPublishedState = .starting
            beatsSinceStart = 0
            trackingSamples = 0
            totalSamples = 0
        }
        lock.lock()
        pointStart = 0
        pointCount = 0
        beats = []
        lock.unlock()
        state = .starting
        bpm = nil
        averageBPM = nil
        beatCount = 0
        rmssd = nil
        intervals = []
        quality = 0
        channel = ""
        breath = nil
        secondsBuffered = 0
        recentQuality = []
    }

    /// Une mesure des capteurs (sur la file des capteurs).
    func add(_ motion: CMDeviceMotion) {
        let u = motion.userAcceleration, r = motion.rotationRate
        let output = detector.process([u.x, u.y, u.z, r.x, r.y, r.z], time: motion.timestamp)
        totalSamples += 1
        if output.state == .tracking { trackingSamples += 1 }

        lock.lock()
        let index = (pointStart + pointCount) % capacity
        points[index] = Point(time: motion.timestamp, signal: Float(output.display), envelope: Float(output.envelope))
        if pointCount < capacity {
            pointCount += 1
        } else {
            pointStart = (pointStart + 1) % capacity
        }
        if !output.beats.isEmpty {
            beats.append(contentsOf: output.beats)
            if let first = beats.firstIndex(where: { $0.time > motion.timestamp - 12 }), first > 0 {
                beats.removeFirst(first)
            }
        }
        lock.unlock()

        guard !output.beats.isEmpty || output.state != lastPublishedState else { return }
        lastPublishedState = output.state
        output.beats.forEach { rhythm.add($0) }
        beatsSinceStart += output.beats.count
        let now = motion.timestamp
        let tracking = output.state == .tracking
        let currentBPM = tracking ? rhythm.bpm(now: now) : nil
        let currentRMSSD = tracking ? rhythm.rmssd(now: now) : nil
        let recentIntervals = rhythm.intervals.filter { $0.time > now - 60 }
        let count = beatsSinceStart
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = output.state
            self.bpm = currentBPM
            self.rmssd = currentRMSSD
            self.intervals = recentIntervals
            self.beatCount = count
        }
    }

    /// Estimations de la seconde (qualité des voies, respiration), depuis `LiveAnalyzer`.
    func update(with estimate: LiveAnalyzer.Estimate) {
        let qualities = estimate.channels.map(\.quality)
        if qualities.count == LiveHeartDetector.channelCount {
            queue.async { [detector] in
                detector.update(qualities: qualities, hintBPM: estimate.heart.bpm, hintQuality: estimate.heart.quality)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.secondsBuffered = estimate.secondsBuffered
            guard estimate.secondsBuffered >= 6 else { return }
            self.quality = estimate.heart.quality
            self.channel = estimate.heart.channel
            self.averageBPM = estimate.heart.quality >= 0.3 ? estimate.heart.bpm : nil
            if estimate.secondsBuffered >= 20 { self.breath = estimate.breath }
            self.recentQuality.append(QualitySample(heart: estimate.heart.quality,
                                                    breath: estimate.secondsBuffered >= 20 ? estimate.breath.quality : 0,
                                                    bpm: self.bpm ?? self.averageBPM))
            if self.recentQuality.count > 15 { self.recentQuality.removeFirst(self.recentQuality.count - 15) }
        }
    }

    /// Ce qu'il faut dessiner : les points et les battements depuis `since` (horloge des capteurs).
    func snapshot(since: Double) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var result = Snapshot()
        result.points.reserveCapacity(pointCount)
        for k in 0..<pointCount {
            let point = points[(pointStart + k) % capacity]
            if point.time >= since { result.points.append(point) }
        }
        result.beats = beats.filter { $0.time >= since }
        return result
    }

    /// Note le bilan de la mesure dans le journal de diagnostic.
    func logSummary() {
        var text = ""
        queue.sync {
            let share = totalSamples > 0 ? Double(trackingSamples) / Double(totalSamples) : 0
            text = String(format: "Cœur en direct : %d battements, rythme suivi %.0f %% du temps", beatsSinceStart, share * 100)
        }
        if let bpm = bpm ?? averageBPM { text += String(format: ", %.0f bpm", bpm) }
        if let rmssd { text += String(format: ", RMSSD %.0f ms", rmssd) }
        text += String(format: ", qualité %.2f (%@)", quality, channel)
        Diagnostics.shared.log(text)
    }
}
