import Foundation

// Séance simulée : écrit un dossier au même format que l'app, avec un pouls, une respiration,
// des arrêts de respiration, des positions et des mouvements CONNUS. Sert à tester la lecture
// (scripts Python de référence) et l'analyse de la nuit (tests Swift).
//
// Sans son : l'analyse du son est testée à part, sur des sons synthétiques.

/// Générateur pseudo-aléatoire reproductible (mêmes tirages sur toutes les machines).
public struct SimulationRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    public mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }

    public mutating func gaussian() -> Double {
        let u1 = max(next(), 1e-12), u2 = next()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

public struct SimulationPlan: Sendable {
    public struct Position: Sendable {
        /// Début (s depuis le début de la séance).
        public var from: Double
        /// Gravité vue par le téléphone (g), par exemple (0, 0,1, −0,995) sur le dos.
        public var gravity: (Double, Double, Double)

        public init(from: Double, gravity: (Double, Double, Double)) {
            self.from = from
            self.gravity = gravity
        }
    }

    public var duration: Double = 600
    public var bpm: Double = 62
    public var seed: UInt64 = 1
    /// Force des vibrations du cœur : 1 = signal faible (comme le simulateur d'origine), 3 = net, 0 = absent.
    public var heartScale: Double = 1
    public var breathsPerMinute: Double = 14
    /// Inclinaison du thorax à chaque respiration (degrés, amplitude).
    public var breathTiltDegrees: Double = 0.6
    public var positions: [Position] = SimulationPlan.guidedPositions
    public var breathHolds: [Range<Double>] = [155..<175, 425..<445]
    public var moves: [Range<Double>] = [240..<260, 295..<302, 505..<512]
    /// "test_guide" (avec les marqueurs du test guidé) ou "nuit".
    public var kind = "test_guide"
    /// Heure réelle du début (date fixe : résultats reproductibles).
    public var startUnix = 1_760_120_000.0
    /// Emplacement annoncé ("corps", "a_cote") ou nil (comme les séances d'avant la version 0.3).
    public var placement: String?

    /// Déroulé du test guidé : dos, puis côté gauche, puis côté droit.
    public static let guidedPositions = [
        Position(from: 0, gravity: (0.0, 0.1, -0.995)),
        Position(from: 300, gravity: (0.97, 0.05, -0.2)),
        Position(from: 510, gravity: (-0.97, 0.05, -0.2))
    ]

    public init() {}

    func gravity(at t: Double) -> (Double, Double, Double) {
        positions.last { $0.from <= t }?.gravity ?? positions.first?.gravity ?? (0, 0, -1)
    }

    func holdingBreath(_ t: Double) -> Bool { breathHolds.contains { $0.contains(t) } }
    func moving(_ t: Double) -> Bool { moves.contains { $0.contains(t) } }
}

public enum SimulatedSession {
    /// Écrit la séance dans `directory`. Renvoie la vérité (aussi écrite dans `verite_simulation.json`).
    @discardableResult
    public static func write(to directory: URL, plan: SimulationPlan) throws -> [String: Any] {
        var random = SimulationRandom(seed: plan.seed)
        let fs = 100.0
        let startUnix = plan.startUnix
        let startUptime = 50_000.0
        let breathRate = plan.breathsPerMinute / 60
        let duration = plan.duration
        let bpm = plan.bpm
        var truth: [String: Any] = ["pouls_bpm": bpm, "respiration_par_min": plan.breathsPerMinute, "frequence_hz": fs]

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var clockUptime = startUptime
        let clock: ChunkedStreamWriter.Clock = { (clockUptime, startUnix + clockUptime - startUptime) }
        let sensors = directory.appendingPathComponent(SessionFiles.sensorsDir)
        let dm = ChunkedStreamWriter(stream: .deviceMotion, directory: sensors, nominalRate: fs, chunkDuration: 600, clock: clock)
        let acc = ChunkedStreamWriter(stream: .accelerometer, directory: sensors, nominalRate: fs, chunkDuration: 600, clock: clock)
        let gyr = ChunkedStreamWriter(stream: .gyroscope, directory: sensors, nominalRate: fs, chunkDuration: 600, clock: clock)
        let journal = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.journal))
        let clockLog = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.clock))
        let stateLog = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.state))

        func unix(_ uptime: Double) -> Double { startUnix + uptime - startUptime }

        journal.write(JournalEvent(unix: unix(startUptime), uptime: startUptime, type: EventType.sessionStart,
                                   message: "Début : séance simulée"))
        if plan.kind == "test_guide" {
            for step in GuidedTest.steps where step.at <= duration {
                journal.write(JournalEvent(unix: unix(startUptime + step.at), uptime: startUptime + step.at,
                                           type: EventType.marker, message: step.display,
                                           values: ["t_test_s": step.at], info: ["marqueur": step.marker]))
            }
        }

        // Battements : intervalles autour de la période moyenne, avec une variabilité respiratoire.
        var beats: [Double] = []
        var nextBeat = 0.4
        while nextBeat < duration {
            beats.append(nextBeat)
            let rsa = 0.04 * sin(2 * Double.pi * breathRate * nextBeat)
            nextBeat += 60 / bpm + rsa + 0.015 * random.gaussian()
        }
        truth["battements_s"] = beats
        var beatIndex = 0
        var breathPhase = 0.0
        var calibration = CalibrationAccumulator()
        var gravity = plan.gravity(at: 0)
        let n = Int(duration * fs)
        var samples = 0
        let scale = plan.heartScale

        for i in 0..<n {
            let t = Double(i) / fs
            // Petite irrégularité d'horodatage (±0,3 ms), comme sur un vrai iPhone.
            let timestamp = startUptime + t + 0.0003 * (random.next() - 0.5)
            clockUptime = timestamp

            // Gravité : rejoint doucement la position, plus la respiration.
            let target = plan.gravity(at: t)
            gravity = (gravity.0 + (target.0 - gravity.0) * 0.02, gravity.1 + (target.1 - gravity.1) * 0.02,
                       gravity.2 + (target.2 - gravity.2) * 0.02)
            let holding = plan.holdingBreath(t)
            if !holding { breathPhase += 2 * Double.pi * breathRate / fs }
            let tiltAmplitude = plan.breathTiltDegrees * Double.pi / 180
            let tilt = holding ? 0 : tiltAmplitude * sin(breathPhase)
            // Vitesse de rotation correspondante, vue par le gyroscope (axe x de l'iPhone).
            let tiltRate = holding ? 0 : tiltAmplitude * 2 * Double.pi * breathRate * cos(breathPhase)
            var g = (gravity.0, gravity.1 * cos(tilt) - gravity.2 * sin(tilt), gravity.1 * sin(tilt) + gravity.2 * cos(tilt))
            let norm = (g.0 * g.0 + g.1 * g.1 + g.2 * g.2).squareRoot()
            g = (g.0 / norm, g.1 / norm, g.2 / norm)

            // Battement : vibration amortie (sismocardiographie) sur z, et rotation (gyrocardiographie) sur x et y.
            while beatIndex + 1 < beats.count && beats[beatIndex + 1] <= t { beatIndex += 1 }
            var scg = 0.0, gcg = 0.0
            for k in [beatIndex, beatIndex + 1] where k < beats.count {
                let dt = t - beats[k]
                if dt >= 0 && dt < 0.15 { scg += 0.006 * exp(-dt / 0.035) * sin(2 * Double.pi * 16 * dt) }
                let dt2 = dt - 0.3
                if dt2 >= 0 && dt2 < 0.12 { scg += 0.003 * exp(-dt2 / 0.03) * sin(2 * Double.pi * 22 * dt2) }
                if dt >= 0 && dt < 0.15 { gcg += 0.012 * exp(-dt / 0.04) * sin(2 * Double.pi * 13 * dt) }
            }
            scg *= scale
            gcg *= scale
            var user = (0.0012 * random.gaussian(), 0.0012 * random.gaussian(), scg + 0.0012 * random.gaussian())
            var rotation = (gcg + tiltRate + 0.003 * random.gaussian(), 0.5 * gcg + 0.003 * random.gaussian(),
                            0.003 * random.gaussian())
            if plan.moving(t) {
                user = (user.0 + 0.15 * random.gaussian(), user.1 + 0.15 * random.gaussian(), user.2 + 0.15 * random.gaussian())
                rotation = (rotation.0 + 0.5 * random.gaussian(), rotation.1 + 0.5 * random.gaussian(),
                            rotation.2 + 0.5 * random.gaussian())
            }
            if t < 30 { calibration.add(gravity: g, userAcceleration: user) }

            dm.append(timestamp: timestamp, values: [user.0, user.1, user.2, g.0, g.1, g.2,
                                                     rotation.0, rotation.1, rotation.2, 0, 0, 0, 1].map { Float($0) })
            acc.append(timestamp: timestamp, values: [user.0 + g.0, user.1 + g.1, user.2 + g.2].map { Float($0) })
            gyr.append(timestamp: timestamp, values: [rotation.0 + 0.004, rotation.1 - 0.002, rotation.2 + 0.001].map { Float($0) })
            samples += 1

            if i % 100 == 0 {
                dm.flush(); acc.flush(); gyr.flush()
            }
            if i % 1000 == 0 {
                clockLog.write(ClockPoint(uptime: timestamp, unix: unix(timestamp), continuous: timestamp + 3600))
            }
            if i % 1500 == 0 {
                stateLog.write(DeviceStateSample(unix: unix(timestamp), uptime: timestamp, battery: 0.9 - 0.06 * t / 3600,
                                                 batteryState: "debranche", thermal: "normal", lowPowerMode: false,
                                                 freeDiskMB: 50_000, samples: ["dm": samples, "acc": samples, "gyr": samples],
                                                 audioSeconds: t, audioRunning: true))
            }
        }
        dm.close(); acc.close(); gyr.close()

        let end = startUptime + duration
        journal.write(JournalEvent(unix: unix(end), uptime: end, type: EventType.sessionEnd, message: "Fin de la séance simulée"))
        journal.close(); clockLog.close(); stateLog.close()

        var info = SessionInfo(id: directory.lastPathComponent, kind: plan.kind, appVersion: "simulateur",
                               device: "simulation", systemVersion: "-", startUnix: startUnix, startUptime: startUptime,
                               nominalRate: fs, streams: ["dm", "acc", "gyr"])
        info.endUnix = unix(end)
        info.endUptime = end
        info.endedNormally = true
        info.calibration = calibration.result(startUnix: startUnix, endUnix: startUnix + 30)
        info.placement = plan.placement
        let holds = plan.breathHolds.map { "\(Int($0.lowerBound))-\(Int($0.upperBound)) s" }.joined(separator: " et ")
        info.notes = ["séance simulée : pouls \(bpm) bpm, respiration \(plan.breathsPerMinute.formatted())/min, "
                      + "arrêts de respiration \(holds)"]
        try info.write(to: directory)
        truth["arrets_respiration_s"] = plan.breathHolds.map { [$0.lowerBound, $0.upperBound] }
        truth["mouvements_s"] = plan.moves.map { [$0.lowerBound, $0.upperBound] }
        let truthData = try JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys])
        try truthData.write(to: directory.appendingPathComponent("verite_simulation.json"))
        if let summary = try? SessionSummary.compute(directory: directory, now: unix(end)) {
            try summary.write(to: directory)
        }
        truth["mesures"] = samples
        return truth
    }
}

private extension Double {
    func formatted() -> String {
        self == rounded() ? String(Int(self)) : String(self)
    }
}
