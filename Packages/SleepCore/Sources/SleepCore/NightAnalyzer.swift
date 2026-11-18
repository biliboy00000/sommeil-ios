import Foundation

// Analyse de la nuit, sur l'iPhone, à partir des fichiers de la séance.
//
// 1. Un seul passage sur les capteurs (fichiers de 10 min lus l'un après l'autre) :
//    - par seconde : mouvement (accélération sans gravité filtrée 1–20 Hz, maximum), gravité, chocs ;
//    - à 10 Hz : gravité et rotation (respiration) ;
//    - par tranche de 30 s : pouls sur les six voies, courbes d'autocorrélation par 10 s (pour moyenner
//      sur 5 min quand le signal est faible), battements et variabilité quand le signal est net.
// 2. Le son est analysé à part (`sound`), l'app y verse les fichiers audio décodés.
// 3. `finish()` assemble : mouvements (seuil adaptatif, méthode de la nuit du 22/10), blocs de 5 min,
//    chutes du téléphone, positions, pouls, respiration, pauses possibles, endormissement, note.
//
// Méthodes reprises des analyses Python des nuits du 11, 12 et 22/10 (voir le projet).

public final class NightAnalyzer {
    public static let version = 2
    public static let epochSeconds = 30.0
    public static let blockSeconds = 300.0

    public let directory: URL
    public let info: SessionInfo
    public let clock: SessionClock
    public let journal: [JournalEvent]
    /// Origine des tranches (horloge des capteurs).
    public let origin: Double
    /// Analyse du son (l'app y verse les fichiers audio).
    public let sound: BreathSoundAnalyzer
    public private(set) var soundAnalyzed = false

    // Par seconde.
    private var secCount: [Int32] = []
    private var secMotion: [Float] = []
    private var secAccMax: [Float] = []
    private var secAccMin: [Float] = []
    private var secGravity: [SIMD3<Float>] = []
    // À 10 Hz (NaN si pas de mesure).
    private var g10: [SIMD3<Float>] = []
    private var r10: [SIMD3<Float>] = []
    // Pouls par tranche de 30 s (ancienne méthode : sert encore à la qualité affichée par tranche).
    private var hearts: [EpochHeart?] = []
    /// Suivi continu du pouls (version 0.4).
    private let heartTracker: HeartTracker
    /// Résultats intermédiaires de la dernière analyse (pour les vérifications sur ordinateur).
    public private(set) var lastHeartTrack: HeartTrack?
    public private(set) var lastBreathTracks: (gyro: BreathTrack, sound: BreathTrack)?
    public private(set) var lastMoving: [Bool] = []
    public private(set) var lastPauses: [CheckedPause] = []

    struct EpochHeart {
        var fs: Double
        var best: HeartEstimate
        /// Carrés des différences entre intervalles successifs (ms²), si battements nets.
        var rmssdSquares: [Double]
    }

    // État du passage sur les capteurs.
    private var lastT = -Double.infinity
    private var motionFilters: [FilterChain] = []
    private var bin = -1
    private var binG = SIMD3<Float>(repeating: 0)
    private var binR = SIMD3<Float>(repeating: 0)
    private var binN: Float = 0
    private var epoch = -1
    private var epochBuffer: [[Double]] = Array(repeating: [], count: 6)
    private var epochFirstT = 0.0
    private var epochLastT = 0.0

    public init(directory: URL) throws {
        self.directory = directory
        info = try SessionInfo.read(from: directory)
        clock = SessionClock.read(directory: directory, info: info)
        journal = JSONLinesWriter.read(JournalEvent.self, from: directory.appendingPathComponent(SessionFiles.journal))
        origin = info.startUptime
        sound = BreathSoundAnalyzer(origin: info.startUptime, epochSeconds: Self.epochSeconds)
        heartTracker = HeartTracker(nominalRate: info.nominalRate > 0 ? info.nominalRate : 100)
        resetMotionFilters()
    }

    private var nominalRate: Double { info.nominalRate > 0 ? info.nominalRate : 100 }

    private func resetMotionFilters() {
        motionFilters = (0..<3).map { _ in
            FilterChain([.highPass(cutoff: 1, sampleRate: nominalRate), .lowPass(cutoff: 20, sampleRate: nominalRate)])
        }
    }

    // MARK: - 1. Passage sur les capteurs

    /// Lit tous les fichiers de mouvement. `progress` reçoit une valeur de 0 à 1.
    public func analyzeSensors(progress: ((Double) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) throws {
        let files = SensorChunkReader.files(for: .deviceMotion, in: directory)
        for (index, url) in files.enumerated() {
            if isCancelled?() == true { throw CancellationError() }
            guard let chunk = try? SensorChunkReader.read(url) else { continue }
            consume(chunk)
            progress?(Double(index + 1) / Double(max(1, files.count)))
        }
        finishEpoch()
        flushBin()
    }

    private func ensureSeconds(_ s: Int) {
        guard s >= secCount.count else { return }
        let add = s + 1 - secCount.count + 600
        secCount += [Int32](repeating: 0, count: add)
        secMotion += [Float](repeating: 0, count: add)
        secAccMax += [Float](repeating: 0, count: add)
        secAccMin += [Float](repeating: .infinity, count: add)
        secGravity += [SIMD3<Float>](repeating: .zero, count: add)
    }

    private func consume(_ chunk: SensorChunk) {
        guard chunk.columns.count >= 9 else { return }
        let ts = chunk.timestamps
        let ux = chunk.columns[0], uy = chunk.columns[1], uz = chunk.columns[2]
        let gx = chunk.columns[3], gy = chunk.columns[4], gz = chunk.columns[5]
        let rx = chunk.columns[6], ry = chunk.columns[7], rz = chunk.columns[8]
        for i in 0..<chunk.count {
            let t = ts[i]
            guard t > lastT else { continue }
            if t - lastT > 0.25 {
                resetMotionFilters()
                flushBin()
            }
            lastT = t
            let rel = t - origin
            guard rel >= 0 else { continue }
            let u = (Double(ux[i]), Double(uy[i]), Double(uz[i]))
            let g = SIMD3<Float>(gx[i], gy[i], gz[i])

            // Mouvement et chocs, par seconde.
            let fx = motionFilters[0].process(u.0), fy = motionFilters[1].process(u.1), fz = motionFilters[2].process(u.2)
            let motion = Float((fx * fx + fy * fy + fz * fz).squareRoot())
            let ax = Float(u.0) + g.x, ay = Float(u.1) + g.y, az = Float(u.2) + g.z
            let total = (ax * ax + ay * ay + az * az).squareRoot()
            let s = Int(rel)
            ensureSeconds(s)
            secCount[s] += 1
            if motion > secMotion[s] { secMotion[s] = motion }
            if total > secAccMax[s] { secAccMax[s] = total }
            if total < secAccMin[s] { secAccMin[s] = total }
            secGravity[s] += g
            heartTracker.add(rel: rel, values: (Double(ax), Double(ay), Double(az), Double(rx[i]), Double(ry[i]), Double(rz[i])))

            // Gravité et rotation à 10 Hz.
            let b = Int(rel * 10)
            if b != bin {
                flushBin()
                bin = b
            }
            binG += g
            binR += SIMD3<Float>(rx[i], ry[i], rz[i])
            binN += 1

            // Tranche de 30 s : six voies pour le pouls.
            let e = Int(rel / Self.epochSeconds)
            if e != epoch {
                finishEpoch()
                epoch = e
                epochFirstT = t
            }
            epochLastT = t
            epochBuffer[0].append(u.0)
            epochBuffer[1].append(u.1)
            epochBuffer[2].append(u.2)
            epochBuffer[3].append(Double(rx[i]))
            epochBuffer[4].append(Double(ry[i]))
            epochBuffer[5].append(Double(rz[i]))
        }
    }

    private func flushBin() {
        guard bin >= 0, binN > 0 else {
            binN = 0
            return
        }
        if g10.count <= bin {
            let add = bin + 1 - g10.count + 6000
            g10 += [SIMD3<Float>](repeating: SIMD3(repeating: .nan), count: add)
            r10 += [SIMD3<Float>](repeating: SIMD3(repeating: .nan), count: add)
        }
        g10[bin] = binG / binN
        r10[bin] = binR / binN
        binG = .zero
        binR = .zero
        binN = 0
    }

    private func finishEpoch() {
        defer {
            for c in 0..<6 { epochBuffer[c].removeAll(keepingCapacity: true) }
        }
        guard epoch >= 0 else { return }
        if hearts.count <= epoch { hearts += [EpochHeart?](repeating: nil, count: epoch + 1 - hearts.count) }
        let count = epochBuffer[0].count
        guard count >= Int(0.9 * Self.epochSeconds * nominalRate), epochLastT > epochFirstT else { return }
        let fs = Double(count - 1) / (epochLastT - epochFirstT)
        let envelopes = epochBuffer.map { HeartbeatEstimator.envelope($0, sampleRate: fs) }
        guard envelopes.allSatisfy({ $0.count == count }) else { return }
        let result = HeartbeatEstimator.best(envelopes: envelopes, names: LiveHeartDetector.channelNames, sampleRate: fs)

        var squares: [Double] = []
        if result.best.quality >= 0.85, let bpm = result.best.bpm {
            squares = Self.successiveSquares(envelope: result.bestEnvelope, sampleRate: fs, bpm: bpm)
        }
        hearts[epoch] = EpochHeart(fs: fs, best: result.best, rmssdSquares: squares)
    }

    /// Battements d'une enveloppe nette, intervalles proches de la médiane, carrés des différences successives (ms²).
    static func successiveSquares(envelope env: [Double], sampleRate fs: Double, bpm: Double) -> [Double] {
        let indices = HeartbeatEstimator.beatIndices(envelope: env, sampleRate: fs, bpm: bpm)
        var times: [Double] = []
        for i in indices where i > 0 && i < env.count - 1 {
            let (offset, _) = DSP.parabolicPeak(env[i - 1], env[i], env[i + 1])
            times.append((Double(i) + offset) / fs)
        }
        guard times.count >= 4 else { return [] }
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }
        let median = DSP.percentile(intervals, 50)
        var squares: [Double] = []
        for k in 1..<intervals.count {
            let a = intervals[k - 1], b = intervals[k]
            guard abs(a - median) <= 0.2 * median, abs(b - median) <= 0.2 * median else { continue }
            let d = (b - a) * 1000
            squares.append(d * d)
        }
        return squares
    }

    // MARK: - 2. Son

    /// Ajoute un fichier son décodé (16 kHz mono), dans l'ordre.
    public func addSound(startUptime: Double, samples: [Float]) {
        sound.process(startUptime: startUptime, samples: samples)
        soundAnalyzed = true
    }

    // MARK: - 3. Bilan

    public func finish(now: Double = Date().timeIntervalSince1970) -> NightReport {
        if soundAnalyzed { sound.finish() }
        let endUptime = max(info.endUptime ?? 0, lastT.isFinite ? lastT : origin)
        let seconds = max(0, Int((endUptime - origin).rounded(.up)))
        ensureSeconds(seconds)
        let epochCount = Int((Double(seconds) / Self.epochSeconds).rounded(.up))
        let blockCount = Int((Double(seconds) / Self.blockSeconds).rounded(.up))
        if hearts.count < epochCount { hearts += [EpochHeart?](repeating: nil, count: epochCount - hearts.count) }
        let unix = { (uptime: Double) in self.clock.unix(uptime) }
        var notes: [String] = []

        // Mouvements : maximum par seconde > 4 × la médiane des 20 minutes autour (et ≥ 5 mg).
        let minutes = seconds / 60 + 1
        var baseline = [Float](repeating: 0, count: minutes)
        for m in 0..<minutes {
            let from = max(0, m * 60 - 600), to = min(seconds, m * 60 + 660)
            var values: [Float] = []
            values.reserveCapacity(max(0, to - from))
            for s in from..<max(from, to) where secCount[s] > 0 { values.append(secMotion[s]) }
            baseline[m] = values.isEmpty ? 0 : BreathSoundAnalyzer.select(&values, rank: values.count / 2)
        }
        var moving = [Bool](repeating: false, count: seconds)
        for s in 0..<seconds where secCount[s] > 0 {
            moving[s] = secMotion[s] > max(4 * baseline[s / 60], 0.005)
        }
        let movingPrefix = moving.reduce(into: [0]) { $0.append($0.last! + ($1 ? 1 : 0)) }
        func movingCount(_ a: Int, _ b: Int) -> Int {
            let lo = max(0, min(seconds, a)), hi = max(lo, min(seconds, b))
            return movingPrefix[hi] - movingPrefix[lo]
        }
        func isMoving(_ a: Double, _ b: Double) -> Bool {
            movingCount(Int((a - origin).rounded(.down)) - 2, Int((b - origin).rounded(.up)) + 2) > 0
        }

        // Événements de mouvement (écarts ≤ 5 s fusionnés) ; grand = > 30 mg ou ≥ 10 s.
        var movements: [(start: Int, end: Int, peak: Float)] = []
        var s = 0
        while s < seconds {
            guard moving[s] else { s += 1; continue }
            var end = s, peak = secMotion[s], k = s + 1
            while k < seconds, k - end <= 5 {
                if moving[k] {
                    end = k
                    peak = max(peak, secMotion[k])
                }
                k += 1
            }
            movements.append((s, end, peak))
            s = end + 1
        }
        let big = movements.filter { $0.peak > 0.03 || $0.end - $0.start + 1 >= 10 }

        // Gravité moyenne d'un intervalle de secondes.
        func gravity(_ a: Int, _ b: Int) -> SIMD3<Float>? {
            var sum = SIMD3<Float>(repeating: 0), n: Int32 = 0
            for k in max(0, a)..<max(max(0, a), min(seconds, b)) where secCount[k] > 0 {
                sum += secGravity[k]
                n += secCount[k]
            }
            guard n > 0 else { return nil }
            let mean = sum / Float(n)
            let norm = (mean * mean).sum().squareRoot()
            return norm > 0.5 ? mean / norm : nil
        }
        func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
            Double(acos(max(-1, min(1, (a * b).sum())))) * 180 / .pi
        }

        // Mouvement respiratoire du thorax (gyroscope), pour l'emplacement et le recoupement des pauses.
        var rotation10 = Array(r10.prefix(seconds * 10))
        if rotation10.count < seconds * 10 {
            rotation10 += [SIMD3<Float>](repeating: SIMD3(repeating: .nan), count: seconds * 10 - rotation10.count)
        }
        let chest = ChestWave(rotation10: rotation10, moving: moving)
        let stillAmplitudes = chest.envelope.enumerated().compactMap { i, v -> Double? in i % 10 == 0 && !v.isNaN ? v : nil }
        let breathingAmplitude = stillAmplitudes.count >= 600 ? DSP.percentile(stillAmplitudes, 50) : nil

        // Emplacement : annoncé au coucher, sinon deviné d'après l'amplitude respiratoire au gyroscope
        // (médiane ≈ 0,4 mrad/s sur le matelas le 03/11, ≈ 3,3 mrad/s sur la poitrine le 12/10).
        let guessed = (breathingAmplitude ?? 0) >= 0.0015 ? "corps" : "a_cote"
        let placement = info.placement ?? guessed
        if let declared = info.placement, let amplitude = breathingAmplitude {
            if declared == "corps", amplitude < 0.0006 {
                notes.append("Le téléphone était annoncé sur la poitrine, mais il bougeait très peu avec la respiration : il a peut-être glissé, ou était posé à côté.")
            } else if declared == "a_cote", amplitude > 0.0024 {
                notes.append("Le téléphone était annoncé à côté, mais il bougeait beaucoup avec la respiration : il était peut-être sur toi.")
            }
        }
        let onBody = placement == "corps"

        var events: [NightReport.Event] = []
        let audio = soundAnalyzed

        // Chutes du téléphone (chute libre puis choc) et téléphone déplacé (gravité changée autour d'un mouvement).
        var lastFall = -100
        for k in 0..<seconds where secCount[k] > 0 && secAccMin[k] < 0.3 {
            let shock = max(secAccMax[k], k + 1 < seconds ? secAccMax[k + 1] : 0)
            guard shock > 2.5, k - lastFall > 30 else { continue }
            lastFall = k
            events.append(.init(kind: "chute", startUnix: unix(origin + Double(k)), duration: 1,
                                title: "Chute ou secousse du téléphone",
                                detail: String(format: "Choc de %.1f g après une brève chute libre.", shock),
                                hasSound: audio))
        }
        if !onBody {
            for m in big {
                guard let before = gravity(m.start - 20, m.start), let after = gravity(m.end + 1, m.end + 21),
                      angle(before, after) > 40,
                      !events.contains(where: { $0.kind == "chute" && abs($0.startUnix - unix(origin + Double(m.start))) < 30 })
                else { continue }
                events.append(.init(kind: "telephone_deplace", startUnix: unix(origin + Double(m.start)),
                                    duration: Double(m.end - m.start + 1), title: "Téléphone déplacé",
                                    detail: String(format: "Son orientation a changé de %.0f°.", angle(before, after)),
                                    hasSound: audio))
            }
        }

        // Positions du corps (téléphone sur la poitrine), corrigées par la calibration.
        var rotation = Rotation.identity
        if let c = info.calibration, c.gravity.count == 3, c.isPlausible || info.calibrationMode != "automatique" {
            let v = SIMD3<Float>(Float(c.gravity[0]), Float(c.gravity[1]), Float(c.gravity[2]))
            if c.tiltDegrees <= Calibration.maxPlausibleTilt { rotation = Rotation(from: v, to: SIMD3(0, 0, -1)) }
        }
        var positions = [String](repeating: "", count: epochCount)
        if onBody {
            for e in 0..<epochCount {
                guard let g = gravity(e * 30, e * 30 + 30) else { continue }
                positions[e] = Self.position(rotation.apply(g))
            }
        }

        // Pouls : suivi continu (fenêtres de 10 s tous les 5 s), médianes par tranche et par bloc.
        let track = heartTracker.finish(moving: moving)
        lastHeartTrack = track
        lastMoving = moving
        var heartBPM = [Double?](repeating: nil, count: epochCount)
        var heartQuality = [Double](repeating: 0, count: epochCount)
        for e in 0..<epochCount {
            heartQuality[e] = hearts[e]?.best.quality ?? 0
            heartBPM[e] = track.median(from: Double(e) * Self.epochSeconds, to: Double(e + 1) * Self.epochSeconds, minimum: 2)
        }
        let perBlock = Int(Self.blockSeconds / Self.epochSeconds)
        var blockHeart = [Double?](repeating: nil, count: blockCount)
        for b in 0..<blockCount {
            blockHeart[b] = track.median(from: Double(b) * Self.blockSeconds, to: Double(b + 1) * Self.blockSeconds, minimum: 6)
        }
        let heartValues = blockHeart.compactMap { $0 }
        let heartWindowShare = track.count > 0 ? Double(track.confident.filter { $0 }.count) / Double(track.count) : 0
        let rmssdEpochs = (0..<epochCount).compactMap { e -> Double? in
            guard onBody, let h = hearts[e], h.rmssdSquares.count >= 10, movingCount(e * 30, e * 30 + 30) == 0 else { return nil }
            return (h.rmssdSquares.reduce(0, +) / Double(h.rmssdSquares.count)).squareRoot()
        }

        // Respiration : gyroscope et micro suivis séparément, puis recoupés.
        let gyroSignal = (0..<3).map { c in rotation10.map { $0[c] } }
        let gyroTrack = BreathTracker.track(gyroSignal, moving: moving, thresholds: BreathTracker.gyroThresholds)
        var soundExcess = [Float](repeating: .nan, count: seconds * 10)
        var soundTrack = BreathTrack.empty
        if audio {
            for i in 0..<min(soundExcess.count, sound.score10.count) {
                let s = sound.score10[i], th = sound.threshold10[i]
                if !s.isNaN, !th.isNaN { soundExcess[i] = s - th }
            }
            var masked = soundExcess.map { $0.isNaN ? Float.nan : min(max($0 + 1, 0), 4) }
            for event in sound.events where event.kind == .continuous {
                let a = max(0, Int((event.start - origin) * 10)), z = min(masked.count, Int((event.start + event.duration - origin) * 10))
                if a < z { for i in a..<z { masked[i] = .nan } }
            }
            for (second, noisy) in sound.noisySeconds.enumerated() where noisy {
                for i in (second * 10)..<min(masked.count, second * 10 + 10) { masked[i] = .nan }
            }
            soundTrack = BreathTracker.track([masked], moving: moving, thresholds: BreathTracker.soundThresholds)
        }
        lastBreathTracks = (gyroTrack, soundTrack)
        var breathRate = [Double?](repeating: nil, count: epochCount)
        var breathSource = [String](repeating: "", count: epochCount)
        var bothEpochs = 0, agreeingEpochs = 0
        for e in 0..<epochCount {
            let from = Double(e) * Self.epochSeconds, to = from + Self.epochSeconds
            let g = gyroTrack.median(from: from, to: to), s = soundTrack.median(from: from, to: to)
            switch (g, s) {
            case let (g?, s?):
                bothEpochs += 1
                if abs(g - s) <= 1.5 {
                    agreeingEpochs += 1
                    breathRate[e] = (g + s) / 2
                    breathSource[e] = "mouvement+son"
                } else {
                    breathSource[e] = "desaccord"
                }
            case let (g?, nil):
                breathRate[e] = g
                breathSource[e] = "mouvement"
            case let (nil, s?):
                breathRate[e] = s
                breathSource[e] = "son"
            default:
                break
            }
        }

        // Pauses : silences du micro et baisses du mouvement du thorax, recoupés.
        var candidates: [(start: Double, end: Double, source: String)] = []
        if audio {
            for p in sound.pauses(isMoving: isMoving) {
                candidates.append((p.lastBreath - origin, p.nextBreath - origin, "son"))
            }
        }
        for d in PauseChecker.chestDrops(chest)
        where !candidates.contains(where: { $0.start < d.end + 5 && $0.end > d.start - 5 }) {
            candidates.append((d.start, d.end, "mouvement"))
        }
        candidates.sort { $0.start < $1.start }
        func rateNear(_ t: Double) -> Double? {
            guard gyroTrack.count > 0 else { return nil }
            let w = max(0, min(gyroTrack.count - 1, Int(((t - 20 - BreathTracker.window / 2) / BreathTracker.hop).rounded())))
            return gyroTrack.confident[w] ? gyroTrack.rate[w] : nil
        }
        let breathTimes = sound.events.filter { $0.kind == .breath }.map { $0.start - origin }
        let checked = candidates.map {
            PauseChecker.check(start: $0.start, end: $0.end, source: $0.source, chest: chest, soundExcess: soundExcess,
                               breathTimes: breathTimes, breathRate: rateNear($0.start), heart: track, moving: moving)
        }
        for p in checked {
            // ratio vaut NaN quand le thorax n'est pas mesurable : Int(NaN) arrêterait l'app.
            let percent = p.ratio.isFinite ? Int((p.ratio * 100).rounded()) : 0
            switch p.verdict {
            case .reduced:
                let what = p.source == "son" ? "sans souffle au micro" : "repéré au mouvement"
                events.append(.init(kind: "pause", startUnix: unix(origin + p.start), duration: p.duration,
                                    title: "Respiration réduite possible",
                                    detail: "Le mouvement du thorax est tombé à \(percent) % de son niveau pendant \(Int(p.duration.rounded())) s, \(what)."
                                        + (p.heartRise.map { $0 >= 6 ? String(format: " Le pouls est monté de %.0f bpm ensuite.", $0) : "" } ?? ""),
                                    hasSound: audio))
            case .unverifiable:
                events.append(.init(kind: "pause_inverifiable", startUnix: unix(origin + p.start), duration: p.duration,
                                    title: "Pause non vérifiable",
                                    detail: "Silence de \(Int(p.duration.rounded())) s au micro ; le mouvement du thorax est trop faible ici pour savoir si la respiration continuait.",
                                    hasSound: audio))
            case .breathing:
                break
            }
        }
        lastPauses = checked
        let reduced = checked.filter { $0.verdict == .reduced }
        let unverifiable = checked.filter { $0.verdict == .unverifiable }
        let dismissed = checked.filter { $0.verdict == .breathing }

        // Ronflements possibles : au moins 3 tranches de suite avec des souffles graves et forts.
        let soundEpochs = audio ? sound.epochs(count: epochCount) : []
        var snore = [Int](repeating: 0, count: epochCount)
        if audio {
            for e in 0..<epochCount { snore[e] = soundEpochs[e].snoreCandidates }
            var e = 0
            while e < epochCount {
                guard snore[e] >= 3 else { e += 1; continue }
                var end = e
                while end + 1 < epochCount, snore[end + 1] >= 3 { end += 1 }
                if end - e + 1 >= 3 {
                    events.append(.init(kind: "ronflement", startUnix: unix(origin + Double(e) * 30),
                                        duration: Double(end - e + 1) * 30, title: "Ronflements possibles",
                                        detail: "Souffles graves et forts, réguliers, pendant \(TimeText.duration(Double(end - e + 1) * 30)).",
                                        hasSound: true))
                }
                e = end + 1
            }
        }

        // Interruptions et trous notés pendant la nuit.
        for event in journal where event.type == EventType.interruptionStart {
            events.append(.init(kind: "interruption", startUnix: event.unix, duration: 0, title: "Interruption du son",
                                detail: event.message, hasSound: false))
        }
        for event in journal where event.type == EventType.sensorGap && (event.info?["flux"] ?? "dm") == "dm" {
            let duration = event.values?["duree_s"] ?? 0
            guard duration >= 1 else { continue }
            events.append(.init(kind: "trou", startUnix: event.values?["debut_unix"] ?? event.unix, duration: duration,
                                title: "Mesures perdues", detail: "Capteurs muets pendant \(TimeText.duration(duration)).",
                                hasSound: false))
        }
        events.sort { $0.startUnix < $1.startUnix }

        // Sommeil et éveil (mouvement + pouls), avec une fourchette selon le seuil de mouvement.
        let epochMoving = (0..<epochCount).map { movingCount($0 * 30, $0 * 30 + 30) }
        let sleepEstimate = SleepEstimator.estimate(movingSeconds: epochMoving, heart: heartBPM)
        var strict = SleepEstimator.Settings(), lenient = SleepEstimator.Settings()
        strict.wakeMoving = 15
        lenient.wakeMoving = 30
        let sleepLow = SleepEstimator.estimate(movingSeconds: epochMoving, heart: heartBPM, settings: strict).sleepSeconds
        let sleepHigh = SleepEstimator.estimate(movingSeconds: epochMoving, heart: heartBPM, settings: lenient).sleepSeconds
        let asleep = sleepEstimate.asleep

        // Blocs de 5 min : éveil (majorité des tranches éveillées après l'endormissement), calme, léger.
        var blocks: [NightReport.Block] = []
        for b in 0..<blockCount {
            let a = b * 300, z = min(seconds, a + 300)
            let present = (a..<z).filter { secCount[$0] > 0 }.count
            let movingSeconds = movingCount(a, z)
            let range = (b * perBlock)..<min(epochCount, (b + 1) * perBlock)
            let awake = range.filter { !asleep[$0] }.count
            let level: String
            if present < 150 {
                level = "manquant"
            } else if awake * 2 > range.count {
                level = "eveil"
            } else if movingSeconds >= 1 {
                level = "leger"
            } else {
                level = "calme"
            }
            let rates = range.compactMap { breathRate[$0] }
            blocks.append(.init(startUnix: unix(origin + Double(a)), level: level, movingSeconds: movingSeconds,
                                heartBPM: blockHeart[b], heartSource: blockHeart[b] == nil ? nil : "suivi",
                                breathRate: rates.count >= 3 ? DSP.percentile(rates, 50) : nil))
        }

        // Bilan.
        let recorded = Double((0..<seconds).filter { secCount[$0] > 0 }.count)
        let measured = blocks.filter { $0.level != "manquant" }
        let calmBlocks = measured.filter { $0.level == "calme" }.count
        let lightBlocks = measured.filter { $0.level == "leger" }.count
        let awakeBlocks = measured.filter { $0.level == "eveil" }.count
        var positionSeconds: [String: Double] = [:]
        for p in positions where !p.isEmpty { positionSeconds[p, default: 0] += Self.epochSeconds }
        let breathEpochs = breathRate.compactMap { $0 }
        let breathHours = Double(breathEpochs.count) * Self.epochSeconds / 3600
        let noise = soundEpochs.isEmpty ? 0 : soundEpochs.map(\.continuousShare).reduce(0, +) / Double(soundEpochs.count)
        let firstHearts = Array(heartValues.prefix(3)), lastHearts = Array(heartValues.suffix(3))
        let asleepHearts = (0..<epochCount).compactMap { asleep[$0] ? heartBPM[$0] : nil }
        let sleepHours = sleepEstimate.sleepSeconds / 3600
        // Appareils de référence (ceinture cardio, oxymètre), s'ils ont été utilisés cette nuit.
        let strap = JSONLinesWriter.read(StrapSample.self, from: directory.appendingPathComponent(ReferenceFiles.strap))
        let oximeter = OximeterImport.read(from: directory)
        let unixOrigin = unix(origin)
        let references = ReferenceComparison.report(
            strap: strap, origin: origin, oximeter: oximeter, rel: { $0 - unixOrigin }, track: track, pauses: checked,
            asleep: { t in let e = Int(t / Self.epochSeconds); return e >= 0 && e < asleep.count && asleep[e] },
            sleepSeconds: sleepEstimate.sleepSeconds)

        let summary = NightReport.Summary(
            recorded: recorded,
            restSeconds: sleepEstimate.sleepSeconds,
            calmShare: measured.isEmpty ? 0 : Double(calmBlocks) / Double(measured.count),
            calmSeconds: Double(calmBlocks) * Self.blockSeconds,
            lightSeconds: Double(lightBlocks) * Self.blockSeconds,
            agitatedSeconds: Double(awakeBlocks) * Self.blockSeconds,
            movementEvents: movements.count,
            bigMovements: big.count,
            bigMovementsPerHour: recorded > 0 ? Double(big.count) / (recorded / 3600) : 0,
            sleepOnsetUnix: sleepEstimate.onsetEpoch.map { unix(origin + Double($0) * Self.epochSeconds) },
            lastCalmEndUnix: sleepEstimate.endEpoch.map { unix(origin + Double($0) * Self.epochSeconds) },
            awakenings: sleepEstimate.wakeBouts.count,
            positions: positionSeconds,
            heartMedian: heartValues.isEmpty ? nil : DSP.percentile(heartValues, 50),
            heartMin: heartValues.min(),
            heartStart: heartValues.count >= 6 ? DSP.percentile(firstHearts, 50) : nil,
            heartEnd: heartValues.count >= 6 ? DSP.percentile(lastHearts, 50) : nil,
            heartCoverage: measured.isEmpty ? 0 : Double(heartValues.count) / Double(measured.count),
            rmssd: rmssdEpochs.count >= 5 ? DSP.percentile(rmssdEpochs, 50) : nil,
            breathMedian: breathEpochs.isEmpty ? nil : DSP.percentile(breathEpochs, 50),
            breathCoverage: epochCount > 0 ? Double(breathEpochs.count) / Double(epochCount) : 0,
            breathHours: breathHours,
            pauses: reduced.count,
            pausesPerHour: sleepHours >= 1 ? Double(reduced.count) / sleepHours : nil,
            snoreMinutes: events.filter { $0.kind == "ronflement" }.reduce(0) { $0 + $1.duration } / 60,
            soundNoiseShare: noise,
            sleepSeconds: sleepEstimate.sleepSeconds,
            sleepLowSeconds: min(sleepLow, sleepHigh, sleepEstimate.sleepSeconds),
            sleepHighSeconds: max(sleepLow, sleepHigh, sleepEstimate.sleepSeconds),
            onsetLatency: sleepEstimate.onsetEpoch.map { Double($0) * Self.epochSeconds },
            wakeAfterOnset: sleepEstimate.wakeAfterOnset,
            heartAwake: sleepEstimate.heartAwake,
            heartAsleep: asleepHearts.count >= 20 ? DSP.percentile(asleepHearts, 50) : nil,
            heartWindowShare: heartWindowShare,
            breathAgreement: bothEpochs >= 20 ? Double(agreeingEpochs) / Double(bothEpochs) : nil,
            pausesUnverifiable: unverifiable.count,
            silencesDismissed: dismissed.count,
            breathingAmplitude: breathingAmplitude,
            desaturationsPerHour: references?.oxygen?.desaturationsPerHour)

        if !audio { notes.append("Le son n'a pas été analysé : la respiration n'est suivie que par le mouvement.") }
        if noise > 0.15 {
            notes.append("Un bruit continu (vidéo, podcast, parole…) couvre \(Int((noise * 100).rounded())) % de la nuit : "
                         + "la respiration ne s'entend pas pendant ces moments.")
        }
        if !onBody { notes.append("Téléphone à côté : la position du corps ne se mesure pas.") }
        if !dismissed.isEmpty {
            notes.append("\(dismissed.count) silence\(dismissed.count > 1 ? "s" : "") entendu\(dismissed.count > 1 ? "s" : "") au micro "
                         + "\(dismissed.count > 1 ? "ont été écartés" : "a été écarté") : le thorax continuait de bouger normalement.")
        }
        if sleepEstimate.onsetEpoch != nil, !sleepEstimate.usedHeart {
            notes.append("L'endormissement est daté par le mouvement seul (pouls trop peu mesuré ou sans baisse nette) : il est moins sûr.")
        }

        return NightReport(
            version: Self.version, computedUnix: now,
            startUnix: unix(origin), endUnix: unix(origin + Double(seconds)),
            epochSeconds: Self.epochSeconds, blockSeconds: Self.blockSeconds,
            placement: placement, placementDeclared: info.placement != nil, soundAnalyzed: audio,
            epochs: .init(coverage: (0..<epochCount).map { e in
                              Double((e * 30..<min(seconds, e * 30 + 30)).filter { secCount[$0] > 0 }.count) / Self.epochSeconds
                          },
                          movingSeconds: epochMoving,
                          position: positions, heartBPM: heartBPM, heartQuality: heartQuality,
                          breathRate: breathRate, breathSource: breathSource,
                          soundNoise: soundEpochs.isEmpty ? Array(repeating: 0, count: epochCount) : soundEpochs.map(\.continuousShare),
                          snore: snore, asleep: asleep),
            blocks: blocks, events: events, summary: summary, score: NightScoring.score(summary), notes: notes,
            references: references)
    }

    /// Valeurs manquantes (NaN) remplacées par la valeur précédente.
    static func filled(_ values: [Double]) -> [Double] {
        var last = values.first { !$0.isNaN } ?? 0
        return values.map { value in
            if value.isNaN { return last }
            last = value
            return value
        }
    }

    /// Position du corps d'après la gravité, téléphone sur la poitrine, haut vers la tête.
    static func position(_ g: SIMD3<Float>) -> String {
        if g.z < -0.7 { return "dos" }
        if g.z > 0.7 { return "ventre" }
        if abs(g.y) > abs(g.x), g.y < -0.6 { return "debout" }
        if g.x > 0.5 { return "gauche" }
        if g.x < -0.5 { return "droite" }
        return g.z < 0 ? "dos" : "ventre"
    }
}

/// Rotation qui amène un vecteur sur un autre (formule de Rodrigues).
struct Rotation {
    var m: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    static let identity = Rotation(m: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)))

    init(m: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) { self.m = m }

    init(from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let u = a / max(1e-6, (a * a).sum().squareRoot()), w = b / max(1e-6, (b * b).sum().squareRoot())
        let v = SIMD3<Float>(u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x)
        let c = (u * w).sum()
        guard c > -0.999 else {
            self = Rotation(m: (SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, -1)))
            return
        }
        let k = 1 / (1 + c)
        m = (SIMD3(1 - k * (v.y * v.y + v.z * v.z), k * v.x * v.y - v.z, k * v.x * v.z + v.y),
             SIMD3(k * v.x * v.y + v.z, 1 - k * (v.x * v.x + v.z * v.z), k * v.y * v.z - v.x),
             SIMD3(k * v.x * v.z - v.y, k * v.y * v.z + v.x, 1 - k * (v.x * v.x + v.y * v.y)))
    }

    func apply(_ g: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((m.0 * g).sum(), (m.1 * g).sum(), (m.2 * g).sum())
    }
}
