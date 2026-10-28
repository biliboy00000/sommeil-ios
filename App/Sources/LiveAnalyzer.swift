import Foundation
import CoreMotion
import AVFoundation
import SleepCore

/// Garde les dernières secondes de capteurs en mémoire et calcule, une fois par seconde,
/// la qualité des battements sur chaque voie (autocorrélation sur 8 s) et la respiration (40 s).
/// Sert à l'écran « Cœur » : ces qualités guident le détecteur de battements en direct.
final class LiveAnalyzer {
    struct Estimate {
        /// Meilleure estimation du pouls (une voie, ou la combinaison des six).
        var heart = HeartEstimate(bpm: nil, quality: 0, channel: "")
        /// Une estimation par voie, dans l'ordre de `LiveHeartDetector.channelNames`.
        var channels: [HeartEstimate] = []
        var breath = BreathEstimate(perMinute: nil, quality: 0, amplitudeDegrees: 0)
        /// Agitation des 2 dernières secondes (g).
        var movement: Double = 0
        var secondsBuffered: Double = 0
    }

    /// Appelé une fois par seconde, sur une file de calcul (pas le fil principal).
    var onEstimate: ((Estimate) -> Void)?

    private let fs = MotionCapture.rate
    private let heartSeconds = 8.0
    private let breathSeconds = 40.0
    private let analysisQueue = DispatchQueue(label: "sommeil.analyse", qos: .utility)

    // Accès uniquement depuis la file des capteurs.
    private var heartBuffers = [RingBuffer](repeating: RingBuffer(capacity: 800), count: 6)
    private var gravityBuffers = [RingBuffer](repeating: RingBuffer(capacity: 4000), count: 3)
    private var sampleCount = 0
    private var sensorQueue: DispatchQueue?
    private var timer: DispatchSourceTimer?

    /// À appeler sur la file des capteurs pour chaque mesure.
    func add(_ motion: CMDeviceMotion) {
        let u = motion.userAcceleration, r = motion.rotationRate, g = motion.gravity
        heartBuffers[0].append(u.x)
        heartBuffers[1].append(u.y)
        heartBuffers[2].append(u.z)
        heartBuffers[3].append(r.x)
        heartBuffers[4].append(r.y)
        heartBuffers[5].append(r.z)
        gravityBuffers[0].append(g.x)
        gravityBuffers[1].append(g.y)
        gravityBuffers[2].append(g.z)
        sampleCount += 1
    }

    func start(sensorQueue: DispatchQueue) {
        self.sensorQueue = sensorQueue
        sensorQueue.sync {
            heartBuffers = [RingBuffer](repeating: RingBuffer(capacity: Int(fs * heartSeconds)), count: 6)
            gravityBuffers = [RingBuffer](repeating: RingBuffer(capacity: Int(fs * breathSeconds)), count: 3)
            sampleCount = 0
        }
        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.analyze() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func analyze() {
        guard let sensorQueue else { return }
        var heart: [[Double]] = []
        var gravity: [[Double]] = []
        var count = 0
        sensorQueue.sync {
            heart = heartBuffers.map { $0.values }
            gravity = gravityBuffers.map { $0.values }
            count = sampleCount
        }
        var result = Estimate()
        result.secondsBuffered = Double(count) / fs
        let recent = Int(2 * fs)
        if heart[0].count > recent {
            result.movement = MovementLevel.level(ux: Array(heart[0].suffix(recent)),
                                                  uy: Array(heart[1].suffix(recent)),
                                                  uz: Array(heart[2].suffix(recent)))
        }
        if heart[0].count >= Int(fs * 6) {
            let channels = zip(LiveHeartDetector.channelNames, heart).map { (name: $0.0, signal: $0.1) }
            let estimate = HeartbeatEstimator.best(channels: channels, sampleRate: fs)
            result.heart = estimate.best
            result.channels = estimate.perChannel
        }
        if gravity[0].count >= Int(fs * 20) {
            result.breath = BreathingEstimator.estimate(gx: gravity[0], gy: gravity[1], gz: gravity[2], sampleRate: fs)
        }
        onEstimate?(result)
    }
}

/// Tampon circulaire de taille fixe.
struct RingBuffer {
    private var storage: [Double]
    private var start = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Double](repeating: 0, count: max(1, capacity))
    }

    mutating func append(_ value: Double) {
        let capacity = storage.count
        if count < capacity {
            storage[(start + count) % capacity] = value
            count += 1
        } else {
            storage[start] = value
            start = (start + 1) % capacity
        }
    }

    /// Valeurs dans l'ordre, de la plus ancienne à la plus récente.
    var values: [Double] {
        let capacity = storage.count
        return (0..<count).map { storage[(start + $0) % capacity] }
    }
}

/// Voix française pour les consignes du test guidé et de la calibration.
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    var enabled = true

    func say(_ text: String) {
        guard enabled else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        utterance.rate = 0.47
        utterance.volume = 1
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
