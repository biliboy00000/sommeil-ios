import Foundation
import CoreMotion
import SleepCore

/// Lit les capteurs de mouvement à 100 Hz et les écrit sur le disque.
///
/// Tout se passe sur `queue` (une seule file) : les écritures, les compteurs et
/// les appels à `onDeviceMotion`.
final class MotionCapture {
    static let rate = 100.0

    let queue: DispatchQueue
    private let operationQueue = OperationQueue()
    private let manager = CMMotionManager()

    private var writers: [SensorStream: ChunkedStreamWriter] = [:]
    private(set) var trackers: [SensorStream: RateTracker] = [:]
    private var flushTimer: DispatchSourceTimer?
    private var firstTimestampLogged = false
    /// Faux après `stop()` : les dernières mesures en transit sont ignorées.
    private var accepting = false

    /// Appelé à chaque mesure « fusionnée » (sur `queue`).
    var onDeviceMotion: ((CMDeviceMotion) -> Void)?
    /// Appelé quand un trou est repéré dans un flux (sur `queue`).
    var onGap: ((SensorStream, RateTracker.Gap) -> Void)?
    /// Messages pour le journal (sur `queue`).
    var onEvent: ((String, String, [String: Double]?, [String: String]?) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        operationQueue.underlyingQueue = queue
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.name = "sommeil.capteurs"
    }

    var isRunning: Bool { manager.isDeviceMotionActive }

    /// Démarre les capteurs. Si `directory` est nil, rien n'est écrit (test de placement).
    /// Renvoie la liste des flux démarrés.
    @discardableResult
    func start(directory: URL?, raw: Bool) -> [SensorStream] {
        var started: [SensorStream] = []
        let interval = 1.0 / Self.rate
        queue.sync {
            firstTimestampLogged = false
            accepting = true
        }

        if manager.isDeviceMotionAvailable {
            prepare(.deviceMotion, directory: directory)
            manager.deviceMotionUpdateInterval = interval
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: operationQueue) { [weak self] motion, error in
                guard let self else { return }
                if let motion { self.handle(motion) } else if let error { self.reportError(error, stream: "dm") }
            }
            started.append(.deviceMotion)
        } else {
            onEvent?(EventType.error, "Capteur de mouvement fusionné indisponible", nil, nil)
        }

        if raw && manager.isAccelerometerAvailable {
            prepare(.accelerometer, directory: directory)
            manager.accelerometerUpdateInterval = interval
            manager.startAccelerometerUpdates(to: operationQueue) { [weak self] data, error in
                guard let self else { return }
                if let data {
                    let a = data.acceleration
                    self.record(.accelerometer, timestamp: data.timestamp, values: [Float(a.x), Float(a.y), Float(a.z)])
                } else if let error { self.reportError(error, stream: "acc") }
            }
            started.append(.accelerometer)
        }

        if raw && manager.isGyroAvailable {
            prepare(.gyroscope, directory: directory)
            manager.gyroUpdateInterval = interval
            manager.startGyroUpdates(to: operationQueue) { [weak self] data, error in
                guard let self else { return }
                if let data {
                    let r = data.rotationRate
                    self.record(.gyroscope, timestamp: data.timestamp, values: [Float(r.x), Float(r.y), Float(r.z)])
                } else if let error { self.reportError(error, stream: "gyr") }
            }
            started.append(.gyroscope)
        }

        // Écriture sur le disque toutes les secondes.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer
        return started
    }

    /// Arrête les capteurs et ferme les fichiers. À appeler hors de `queue`.
    func stop() {
        manager.stopDeviceMotionUpdates()
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        queue.sync {
            accepting = false
            flushTimer?.cancel()
            flushTimer = nil
            for writer in writers.values { writer.close() }
        }
    }

    /// Nombre de mesures écrites par flux (à lire sur `queue`).
    var counts: [String: Int] {
        var result: [String: Int] = [:]
        for (stream, tracker) in trackers { result[stream.prefix] = tracker.count }
        return result
    }

    var droppedTotal: Int { writers.values.reduce(0) { $0 + $1.droppedCount } }

    private func prepare(_ stream: SensorStream, directory: URL?) {
        trackers[stream] = RateTracker(nominalRate: Self.rate, gapThreshold: 0.25)
        guard let directory else {
            writers[stream] = nil
            return
        }
        let writer = ChunkedStreamWriter(stream: stream,
                                         directory: directory.appendingPathComponent(SessionFiles.sensorsDir),
                                         nominalRate: Self.rate, chunkDuration: 600, clock: { Clock.now })
        writer.onError = { [weak self] message in
            self?.onEvent?(EventType.error, message, nil, ["flux": stream.prefix])
        }
        writers[stream] = writer
    }

    private func handle(_ motion: CMDeviceMotion) {
        guard accepting else { return }
        let u = motion.userAcceleration, g = motion.gravity, r = motion.rotationRate
        let q = motion.attitude.quaternion
        if !firstTimestampLogged {
            firstTimestampLogged = true
            // Vérifie que l'horloge des capteurs est bien celle du système.
            let offset = Clock.uptime - motion.timestamp
            onEvent?(EventType.info, "Première mesure des capteurs", ["decalage_horloge_s": offset], nil)
        }
        record(.deviceMotion, timestamp: motion.timestamp, values: [
            Float(u.x), Float(u.y), Float(u.z),
            Float(g.x), Float(g.y), Float(g.z),
            Float(r.x), Float(r.y), Float(r.z),
            Float(q.x), Float(q.y), Float(q.z), Float(q.w)
        ])
        onDeviceMotion?(motion)
    }

    private func record(_ stream: SensorStream, timestamp: Double, values: [Float]) {
        guard accepting else { return }
        if let gap = trackers[stream]?.add(timestamp) {
            onGap?(stream, gap)
        }
        writers[stream]?.append(timestamp: timestamp, values: values)
    }

    private func flush() {
        for writer in writers.values { writer.flush() }
    }

    private func reportError(_ error: Error, stream: String) {
        onEvent?(EventType.error, "Erreur capteur : \(error.localizedDescription)", nil, ["flux": stream])
    }
}
