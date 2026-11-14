import Foundation

// Appareils de référence (version 0.4) : ceinture cardio Bluetooth (pouls battement par battement) et
// oxymètre de nuit (oxygène). Ils servent à mesurer la vraie précision de l'app, nuit après nuit.

public enum ReferenceFiles {
    /// Une ligne par notification de la ceinture : `StrapSample`.
    public static let strap = "ceinture.jsonl"
    /// Oxymètre importé, format normalisé : « unix,spo2,pouls » (vide = pas de mesure).
    public static let oximeter = "oxymetre.csv"
}

/// Notification d'une ceinture cardio (service Bluetooth standard « Heart Rate »).
public struct StrapSample: Codable, Equatable, Sendable {
    /// Horloge des capteurs (secondes depuis le démarrage de l'iPhone), comme les mesures de mouvement.
    public var uptime: Double
    public var bpm: Int
    /// Intervalles entre battements (ms), dans l'ordre.
    public var rr: [Double]
    /// Contact des électrodes avec la peau (nil si la ceinture ne le dit pas).
    public var contact: Bool?

    public init(uptime: Double, bpm: Int, rr: [Double], contact: Bool?) {
        self.uptime = uptime
        self.bpm = bpm
        self.rr = rr
        self.contact = contact
    }

    /// Décode la caractéristique 0x2A37 (Heart Rate Measurement).
    public static func decode(_ bytes: [UInt8], uptime: Double) -> StrapSample? {
        guard bytes.count >= 2 else { return nil }
        let flags = bytes[0]
        var i = 1
        let bpm: Int
        if flags & 0x01 != 0 {
            guard bytes.count >= 3 else { return nil }
            bpm = Int(bytes[1]) | Int(bytes[2]) << 8
            i = 3
        } else {
            bpm = Int(bytes[1])
            i = 2
        }
        let contactSupported = flags & 0x04 != 0
        let contact: Bool? = contactSupported ? (flags & 0x02 != 0) : nil
        if flags & 0x08 != 0 { i += 2 }   // énergie dépensée
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < bytes.count {
                let raw = Int(bytes[i]) | Int(bytes[i + 1]) << 8
                rr.append(Double(raw) * 1000 / 1024)
                i += 2
            }
        }
        return StrapSample(uptime: uptime, bpm: bpm, rr: rr, contact: contact)
    }
}

/// Une mesure d'oxymètre.
public struct OximeterSample: Equatable, Sendable {
    public var unix: Double
    public var spo2: Double?
    public var pulse: Double?
}

public enum OximeterImport {
    /// Lit un export CSV d'oxymètre (ViHealth / Wellue O2Ring, EMAY, OSCAR, ou format normalisé de l'app).
    /// Les heures sans fuseau sont lues dans le fuseau de l'iPhone.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> [OximeterSample] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [] }
        if lines[0].hasPrefix("\u{FEFF}") { lines[0].removeFirst() }
        // En-tête : première ligne qui parle d'oxygène.
        guard let headerIndex = lines.prefix(30).firstIndex(where: { line in
            let l = line.lowercased()
            return l.contains("spo2") || l.contains("oxy") || l.contains("o2")
        }) else { return [] }
        let separator: Character = [";", "\t", ","].first { lines[headerIndex].contains($0) } ?? ","
        let header = split(lines[headerIndex], separator).map { $0.lowercased() }
        func column(_ keys: [String], excluding: [String] = []) -> Int? {
            header.firstIndex { h in keys.contains { h.contains($0) } && !excluding.contains { h.contains($0) } }
        }
        let spo2Column = column(["spo2", "oxy", "o2"], excluding: ["reminder", "alarm", "rappel"])
        let pulseColumn = column(["pulse", "pouls", "bpm", "heart", "pr(", "pr "], excluding: ["reminder", "alarm", "rappel"])
            ?? header.firstIndex(of: "pr")
        let timeColumn = column(["time", "heure", "unix"]) ?? column(["date"])
        let dateOnlyColumn = header.firstIndex { $0 == "date" }
        guard let spo2Column, let timeColumn else { return [] }
        let formatters = makeFormatters(timeZone)
        var result: [OximeterSample] = []
        for line in lines[(headerIndex + 1)...] {
            let fields = split(line, separator)
            guard fields.count > max(spo2Column, timeColumn) else { continue }
            var stamp = fields[timeColumn]
            if let d = dateOnlyColumn, d != timeColumn, d < fields.count { stamp = fields[d] + " " + stamp }
            guard let unix = parseTime(stamp, formatters) else { continue }
            let spo2 = value(fields[spo2Column], range: 50...100)
            let pulse = pulseColumn.flatMap { $0 < fields.count ? value(fields[$0], range: 25...250) : nil }
            guard spo2 != nil || pulse != nil else { continue }
            result.append(OximeterSample(unix: unix, spo2: spo2, pulse: pulse))
        }
        return result.sorted { $0.unix < $1.unix }
    }

    /// Format normalisé enregistré dans la séance.
    public static func normalized(_ samples: [OximeterSample]) -> String {
        var out = "unix,spo2,pouls\n"
        for s in samples {
            out += String(format: "%.1f", s.unix) + "," + (s.spo2.map { String(format: "%.0f", $0) } ?? "") + ","
                + (s.pulse.map { String(format: "%.0f", $0) } ?? "") + "\n"
        }
        return out
    }

    /// Importe l'export de l'oxymètre dans une séance : garde les mesures de la nuit (±1 h) et les enregistre
    /// au format normalisé. Renvoie le nombre de mesures gardées (0 : rien n'est écrit).
    @discardableResult
    public static func save(_ text: String, to directory: URL, startUnix: Double, endUnix: Double,
                            timeZone: TimeZone = .current) throws -> Int {
        let kept = parse(text, timeZone: timeZone).filter { $0.unix >= startUnix - 3600 && $0.unix <= endUnix + 3600 }
        guard !kept.isEmpty else { return 0 }
        try normalized(kept).write(to: directory.appendingPathComponent(ReferenceFiles.oximeter),
                                   atomically: true, encoding: .utf8)
        return kept.count
    }

    public static func read(from directory: URL) -> [OximeterSample] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(ReferenceFiles.oximeter), encoding: .utf8)
        else { return [] }
        return parse(text, timeZone: TimeZone(identifier: "UTC")!)
    }

    static func split(_ line: String, _ separator: Character) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == separator, !quoted {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    static func value(_ text: String, range: ClosedRange<Double>) -> Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)),
              range.contains(v) else { return nil }
        return v
    }

    static func makeFormatters(_ timeZone: TimeZone) -> [DateFormatter] {
        let patterns = ["hh:mm:ssa MMM d, yyyy", "hh:mm:ss a MMM d, yyyy", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss",
                        "yyyy/MM/dd HH:mm:ss", "dd/MM/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm:ss", "dd.MM.yyyy HH:mm:ss",
                        "yyyy-MM-dd HH:mm", "dd/MM/yyyy HH:mm", "MM/dd/yyyy hh:mm:ss a", "MMM d, yyyy hh:mm:ss a"]
        return patterns.map { p in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = p
            return f
        }
    }

    static func parseTime(_ text: String, _ formatters: [DateFormatter]) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let v = Double(t), v > 1_000_000_000 { return v > 1e12 ? v / 1000 : v }
        for f in formatters { if let d = f.date(from: t) { return d.timeIntervalSince1970 } }
        return nil
    }
}

// MARK: - Comparaison avec l'app

public struct ReferenceReport: Codable, Sendable {
    public var strap: PulseComparison?
    public var oximeterPulse: PulseComparison?
    public var oxygen: Oxygen?

    public struct PulseComparison: Codable, Sendable {
        /// Minutes où la référence donne un pouls, et part de ces minutes où l'app en donne un aussi.
        public var referenceMinutes: Double
        public var appCoverage: Double
        /// Écart moyen absolu, écart moyen (app − référence), part à ± 3 et ± 5 bpm.
        public var meanAbsoluteError: Double
        public var bias: Double
        public var within3: Double
        public var within5: Double
        public var compared: Int
    }

    public struct Oxygen: Codable, Sendable {
        /// Pendant le sommeil estimé.
        public var median: Double
        public var minimum: Double
        public var secondsBelow90: Double
        /// Baisses d'au moins 3 points (≥ 10 s) et nombre par heure de sommeil.
        public var desaturations: Int
        public var desaturationsPerHour: Double?
        /// Pauses de l'app suivies d'une baisse d'oxygène (dans les 40 s), par verdict.
        public var reducedPauses: Int
        public var reducedWithDesaturation: Int
        public var dismissedPauses: Int
        public var dismissedWithDesaturation: Int
        /// Baisses d'oxygène sans pause de l'app juste avant.
        public var desaturationsWithoutPause: Int
        public var minutes: Double
    }
}

public enum ReferenceComparison {
    /// Pouls de référence par fenêtre du suivi (médiane des battements de la fenêtre).
    static func compare(track: HeartTrack, reference: (Double, Double) -> Double?) -> ReferenceReport.PulseComparison? {
        var errors: [Double] = []
        var referenceWindows = 0, covered = 0
        for w in 0..<track.count {
            let t = track.times[w]
            guard let ref = reference(t - HeartTracker.window / 2, t + HeartTracker.window / 2) else { continue }
            referenceWindows += 1
            guard track.confident[w] else { continue }
            covered += 1
            errors.append(track.bpm[w] - ref)
        }
        guard referenceWindows >= 60, errors.count >= 30 else { return nil }
        let absolute: [Double] = errors.map { abs($0) }
        let n = Double(absolute.count)
        let mae: Double = absolute.reduce(0, +) / n
        let bias: Double = errors.reduce(0, +) / n
        let within3: Double = Double(absolute.filter { $0 <= 3 }.count) / n
        let within5: Double = Double(absolute.filter { $0 <= 5 }.count) / n
        let minutes: Double = Double(referenceWindows) * HeartTracker.hop / 60
        let coverage: Double = Double(covered) / Double(referenceWindows)
        return .init(referenceMinutes: minutes, appCoverage: coverage, meanAbsoluteError: mae, bias: bias,
                     within3: within3, within5: within5, compared: errors.count)
    }

    /// `rel(unix)` : secondes depuis l'origine de la séance. `asleep(rel)` : endormi à cet instant ?
    public static func report(strap: [StrapSample], origin: Double, oximeter: [OximeterSample], rel: (Double) -> Double,
                              track: HeartTrack, pauses: [CheckedPause], asleep: (Double) -> Bool,
                              sleepSeconds: Double) -> ReferenceReport? {
        var report = ReferenceReport()
        // Ceinture : battements datés à partir de la notification (le dernier intervalle finit à la notification).
        var beats: [(t: Double, bpm: Double)] = []
        for s in strap where s.contact != false {
            var t = s.uptime - origin
            for rr in s.rr.reversed() where rr >= 300 && rr <= 2000 {
                beats.append((t, 60_000 / rr))
                t -= rr / 1000
            }
        }
        beats.sort { $0.t < $1.t }
        if !beats.isEmpty {
            let times = beats.map(\.t)
            report.strap = compare(track: track) { a, b in
                let lo = lowerBound(times, a), hi = lowerBound(times, b)
                guard hi - lo >= 5 else { return nil }
                return DSP.percentile(beats[lo..<hi].map(\.bpm), 50)
            }
        }
        // Oxymètre.
        let ox = oximeter.map { (t: rel($0.unix), spo2: $0.spo2, pulse: $0.pulse) }
        if !ox.isEmpty {
            let times = ox.map(\.t)
            report.oximeterPulse = compare(track: track) { a, b in
                let lo = lowerBound(times, a - 2), hi = lowerBound(times, b + 2)
                let values = ox[lo..<hi].compactMap(\.pulse)
                return values.isEmpty ? nil : DSP.percentile(values, 50)
            }
            report.oxygen = oxygen(ox.compactMap { s in s.spo2.map { (s.t, $0) } }, pauses: pauses, asleep: asleep,
                                   sleepSeconds: sleepSeconds)
        }
        return report.strap == nil && report.oximeterPulse == nil && report.oxygen == nil ? nil : report
    }

    /// Baisses d'oxygène : au moins 3 points sous le maximum des 2 minutes d'avant, pendant au moins 10 s.
    static func desaturations(_ samples: [(t: Double, spo2: Double)]) -> [(start: Double, end: Double, drop: Double)] {
        var result: [(start: Double, end: Double, drop: Double)] = []
        var i = 0, lo = 0
        while i < samples.count {
            let (t, v) = samples[i]
            while lo < i, samples[lo].t < t - 120 { lo += 1 }
            let base = samples[lo..<max(lo, i)].map(\.spo2).max() ?? v
            guard base - v >= 3 else { i += 1; continue }
            var j = i, lowest = v
            while j + 1 < samples.count, base - samples[j + 1].spo2 >= 2, samples[j + 1].t - samples[j].t <= 10 {
                j += 1
                lowest = min(lowest, samples[j].spo2)
            }
            if samples[j].t - t >= 10 || j - i >= 2 { result.append((t, samples[j].t, base - lowest)) }
            i = j + 1
            // Le maximum suivant se calcule après la baisse.
            lo = i
        }
        return result
    }

    static func oxygen(_ samples: [(t: Double, spo2: Double)], pauses: [CheckedPause], asleep: (Double) -> Bool,
                       sleepSeconds: Double) -> ReferenceReport.Oxygen? {
        let sleeping = samples.filter { asleep($0.t) }
        guard sleeping.count >= 60 else { return nil }
        let values = sleeping.map(\.spo2)
        var below = 0.0
        for k in 1..<sleeping.count where sleeping[k].spo2 < 90 {
            below += min(10, sleeping[k].t - sleeping[k - 1].t)
        }
        let desats = desaturations(samples).filter { asleep($0.start) }
        func followed(_ p: CheckedPause) -> Bool {
            desats.contains { $0.start >= p.start - 5 && $0.start <= p.end + 40 }
        }
        let reduced = pauses.filter { $0.verdict == .reduced }
        let dismissed = pauses.filter { $0.verdict == .breathing }
        let orphan = desats.filter { d in !pauses.contains { d.start >= $0.start - 5 && d.start <= $0.end + 40 } }
        let minutes = Double(sleeping.count) * max(1, (sleeping.last!.t - sleeping.first!.t) / Double(sleeping.count)) / 60
        return .init(median: DSP.percentile(values, 50), minimum: values.min() ?? 0, secondsBelow90: below,
                     desaturations: desats.count,
                     desaturationsPerHour: sleepSeconds >= 3600 ? Double(desats.count) / (sleepSeconds / 3600) : nil,
                     reducedPauses: reduced.count, reducedWithDesaturation: reduced.filter(followed).count,
                     dismissedPauses: dismissed.count, dismissedWithDesaturation: dismissed.filter(followed).count,
                     desaturationsWithoutPause: orphan.count, minutes: minutes)
    }

    static func lowerBound(_ x: [Double], _ v: Double) -> Int {
        var lo = 0, hi = x.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if x[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
